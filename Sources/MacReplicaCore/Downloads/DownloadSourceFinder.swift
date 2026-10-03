import Foundation

/// Fetches small documents (appcasts) over the network.
public protocol HTTPFetching: Sendable {
    /// Returns the body and the final URL after redirects. Throws for errors and bodies over `maxBytes`.
    func fetch(_ url: URL, maxBytes: Int) async throws -> (data: Data, finalURL: URL)
}

public enum DownloadError: Error, Equatable, Sendable {
    case insecureURL(String)
    case httpStatus(Int)
    case tooLarge
    case network(String)
    case cancelled
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case signatureInvalid
    case noApplicationFound
    case wrongApplication(String)
    case wrongDeveloper(expected: String, actual: String?)
    case codeSignatureInvalid
    case incompatibleArchitecture
    case requiresNewerMacOS(String)
    case licenseAgreement
    case untrustedPackage(String)
    case alreadyInstalled
    case applicationsFolderNotWritable
    case extractionFailed(String)
}

/// Fetches with a default URLSession and refuses redirects from HTTPS to anything else.
public final class URLSessionFetcher: NSObject, HTTPFetching, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func fetch(_ url: URL, maxBytes: Int) async throws -> (data: Data, finalURL: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("MacReplica/\(SystemInfo.appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.network("no HTTP response") }
        guard http.statusCode == 200 else { throw DownloadError.httpStatus(http.statusCode) }
        guard data.count <= maxBytes else { throw DownloadError.tooLarge }
        return (data, http.url ?? url)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        // An HTTPS request may only be redirected to HTTPS.
        if task.originalRequest?.url?.scheme == "https", request.url?.scheme != "https" { return nil }
        return request
    }
}

/// Serves `https://<host>/<path>` from `<root>/downloads/<host>/<path>`; used by tests and the simulation.
public struct LocalFetcher: HTTPFetching {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static func file(for url: URL, root: URL) -> URL? {
        guard let host = url.host, PathSafety.isSafeRelativePath(host) else { return nil }
        let relative = host + url.path
        return PathSafety.resolve(relative, inside: root.appendingPathComponent("downloads"))
    }

    public func fetch(_ url: URL, maxBytes: Int) async throws -> (data: Data, finalURL: URL) {
        guard let file = Self.file(for: url, root: root), let data = FileManager.default.contents(atPath: file.path) else {
            throw DownloadError.httpStatus(404)
        }
        guard data.count <= maxBytes else { throw DownloadError.tooLarge }
        return (data, url)
    }
}

/// Finds official download sources for an application that has no automatic installation.
///
/// Sources are only ever the vendor's own update feed declared in the app, the vendor download
/// Homebrew's cask points to, the vendor's website and the Mac App Store — never download portals or mirrors.
/// The network is contacted only when the user asks for downloads.
public struct DownloadSourceFinder: Sendable {
    public var fetcher: HTTPFetching
    public var catalog: CaskCatalog?
    public var macOSVersion: String
    public var architecture: CPUArchitecture

    public init(fetcher: HTTPFetching, catalog: CaskCatalog?, macOSVersion: String, architecture: CPUArchitecture) {
        self.fetcher = fetcher
        self.catalog = catalog
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    public func offers(for app: AppRecord, itemID: String) async -> [DownloadOffer] {
        var offers: [DownloadOffer] = []
        if let feed = app.updateFeed { offers += await feedOffers(feed, app: app, itemID: itemID) }
        offers += caskOffers(app: app, itemID: itemID)
        if case .appStore(let id) = app.restoreMethod {
            offers.append(DownloadOffer(id: "appstore:\(id)", itemID: itemID, kind: .appStore,
                                        url: "macappstore://apps.apple.com/app/id\(id)", recommended: true))
        }
        if let website = app.homepage ?? caskMatch(app)?.homepage, Self.isWebsite(website) {
            offers.append(DownloadOffer(id: "website", itemID: itemID, kind: .vendorWebsite, url: website))
        }
        return Self.markRecommended(offers, originalChannel: app.channel)
    }

    static func isWebsite(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil
    }

    /// The recommended offer: the original channel (stable if none was recorded) with the strongest verification.
    static func markRecommended(_ offers: [DownloadOffer], originalChannel: ReleaseChannel?) -> [DownloadOffer] {
        var result = offers.map { offer -> DownloadOffer in
            var copy = offer
            copy.recommended = offer.kind == .appStore
            return copy
        }
        let wanted = originalChannel ?? .stable
        let candidates = result.indices.filter { result[$0].isDownloadable }
        let best = candidates.filter { (result[$0].channel ?? .stable) == wanted }.min { result[$0].trust < result[$1].trust }
        if let best { result[best].recommended = true }
        return result
    }

    // MARK: Vendor feed

    func feedOffers(_ feed: UpdateFeed, app: AppRecord, itemID: String) async -> [DownloadOffer] {
        guard let url = URL(string: feed.url), let scheme = url.scheme else { return [] }
        // Plain HTTP feeds are only usable when every file is signed with the vendor's key.
        guard scheme == "https" || (scheme == "http" && feed.publicEDKey != nil) else { return [] }
        guard let (data, _) = try? await fetcher.fetch(url, maxBytes: 5_000_000) else { return [] }
        return Self.feedOffers(AppcastParser.parse(data), feed: feed, app: app, itemID: itemID, macOSVersion: macOSVersion, architecture: architecture)
    }

    /// The newest compatible item per channel.
    static func feedOffers(_ items: [AppcastItem], feed: UpdateFeed, app: AppRecord, itemID: String, macOSVersion: String,
                           architecture: CPUArchitecture) -> [DownloadOffer] {
        var best: [String: AppcastItem] = [:]
        for item in items where !item.isInformational {
            guard let enclosure = item.enclosureURL, let url = URL(string: enclosure), url.host != nil else { continue }
            // HTTPS for the file, or a vendor signature that MacReplica can check.
            guard url.scheme == "https" || (url.scheme == "http" && item.edSignature != nil && feed.publicEDKey != nil) else { continue }
            if let minimum = item.minimumSystemVersion, VersionComparison.compare(macOSVersion, minimum) == .orderedAscending { continue }
            if let maximum = item.maximumSystemVersion, VersionComparison.compare(macOSVersion, maximum) == .orderedDescending { continue }
            if item.hardwareRequirements?.contains("arm64") == true, architecture == .x86_64 { continue }
            let key = item.channel ?? ""
            if let current = best[key], VersionComparison.compare(current.version ?? "", item.version ?? "") != .orderedAscending { continue }
            best[key] = item
        }
        return best.keys.sorted().compactMap { key in
            guard let item = best[key], let enclosure = item.enclosureURL else { return nil }
            let channel = key.isEmpty ? ReleaseChannel.stable : (ChannelDetector.channel(feedURL: key) ?? ChannelDetector.channel(version: key) ?? .beta)
            let signed = item.edSignature != nil && feed.publicEDKey != nil
            let trust: DownloadOffer.Trust = signed ? .vendorSignature : (app.teamIdentifier != nil ? .developerSignature : .none)
            return DownloadOffer(
                id: "feed:\(key.isEmpty ? "default" : key)", itemID: itemID, kind: .vendorFeed, url: enclosure,
                version: item.displayVersion, channel: channel, expectedLength: item.length, edSignature: item.edSignature,
                publicEDKey: feed.publicEDKey, expectedBundleIdentifier: app.bundleIdentifier, expectedTeamIdentifier: app.teamIdentifier,
                minimumSystemVersion: item.minimumSystemVersion,
                isPackage: item.installationType == "package" || enclosure.lowercased().hasSuffix(".pkg"), trust: trust)
        }
    }

    // MARK: Homebrew cask download

    func caskMatch(_ app: AppRecord) -> CaskInfo? {
        guard let catalog else { return nil }
        if case .homebrewCask(let token) = app.restoreMethod, let cask = catalog.cask(token: token) { return cask }
        if let bundleID = app.bundleIdentifier?.lowercased(),
           let cask = catalog.casks.first(where: { $0.bundleIdentifiers.contains(bundleID) && !$0.disabled }) { return cask }
        return catalog.casks.first { $0.appArtifacts.contains { $0.caseInsensitiveCompare(app.bundleFileName) == .orderedSame } && !$0.disabled }
    }

    func caskOffers(app: AppRecord, itemID: String) -> [DownloadOffer] {
        guard let cask = caskMatch(app), !cask.disabled, let download = cask.download(macOSVersion: macOSVersion, architecture: architecture),
              !download.needsBrowser else { return [] }
        if let minimum = cask.minimumMacOS, VersionComparison.compare(macOSVersion, minimum) == .orderedAscending { return [] }
        if !cask.requiredArchitectures.isEmpty, !cask.requiredArchitectures.contains(architecture) { return [] }
        let trust: DownloadOffer.Trust = download.sha256 != nil ? .checksum : (app.teamIdentifier != nil ? .developerSignature : .none)
        let version = cask.version.map { String($0.split(separator: ",").first ?? Substring($0)) }
        return [DownloadOffer(
            id: "cask:\(cask.token)", itemID: itemID, kind: .homebrewCask, url: download.url, version: version,
            channel: ChannelDetector.channel(caskToken: cask.token) ?? .stable, sha256: download.sha256,
            expectedBundleIdentifier: app.bundleIdentifier, expectedTeamIdentifier: app.teamIdentifier,
            isPackage: download.url.lowercased().hasSuffix(".pkg"), trust: trust)]
    }
}
