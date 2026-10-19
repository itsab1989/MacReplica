import Foundation

/// The macOS versions a bootable installer can be made of, discovered at run time – never from a list in the app:
///
/// 1. **Software Update** (`softwareupdate --list-full-installers`): Apple's catalog of full installers for the Mac
///    MacReplica runs on, with version, build and size. The only route MacReplica downloads automatically
///    (`--fetch-full-installer`, Apple: support.apple.com/102662). New macOS versions appear here by themselves.
/// 2. **Apple's support page** “How to download and install macOS” (support.apple.com/102662), read live: the App Store
///    links and Apple's disk images for releases Software Update no longer offers. Only links to `apps.apple.com` and
///    Apple's update CDN are accepted.
///
/// Neither source is exhaustive: Software Update lists only what Apple offers this Mac (Apple: no earlier than the
/// version the Mac came with), and the page lists one entry per major release.
public struct MacOSRelease: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Source: Codable, Equatable, Hashable, Sendable {
        /// Apple's Software Update catalog of this Mac; downloadable with `softwareupdate --fetch-full-installer`.
        case softwareUpdate
        /// The App Store page Apple links to (`id`); the user downloads it there.
        case appStore(id: Int, url: String)
        /// A disk image on Apple's update CDN with a package that places the installer in Applications.
        case appleDiskImage(url: String)
    }

    /// e.g. "macOS Sonoma", "macOS 27 Golden Gate", "OS X El Capitan".
    public var name: String
    /// The major release: "14", "26", "10.15".
    public var major: String
    /// The full version ("14.8.9"), when the source names it.
    public var version: String?
    public var build: String?
    public var sizeBytes: Int64?
    public var source: Source
    /// Where the entry came from and when, shown under **Details**.
    public var provenance: String

    public init(name: String, major: String, version: String? = nil, build: String? = nil, sizeBytes: Int64? = nil,
                source: Source, provenance: String) {
        self.name = name
        self.major = major
        self.version = version
        self.build = build
        self.sizeBytes = sizeBytes
        self.source = source
        self.provenance = provenance
    }

    public var id: String {
        switch source {
        case .softwareUpdate: return "su-\(version ?? major)-\(build ?? "")"
        case .appStore(let id, _): return "appstore-\(id)"
        case .appleDiskImage(let url): return "dmg-\(major)-\(url.split(separator: "/").suffix(2).joined(separator: "-"))"
        }
    }

    /// The installer app Apple's tools create: "Install " + the release name (Apple's naming, support.apple.com/101578).
    public var installerAppName: String { "Install \(name).app" }

    /// Version used for sorting: the full version when known, else the major release.
    var sortVersion: String { version ?? major }
}

/// One major release with its versions, the newest first.
public struct MacOSMajorRelease: Equatable, Sendable, Identifiable {
    public var major: String
    public var name: String
    public var releases: [MacOSRelease]
    public var id: String { major }
}

/// How a release relates to the Mac MacReplica runs on – separate from whether Apple offers it.
public enum InstallerSuitability: Equatable, Sendable {
    /// Software Update offers it to this Mac: MacReplica downloads and checks it.
    case downloadHere
    /// Apple offers it in the App Store; the App Store decides whether this Mac may download it.
    case appStore
    /// Apple's disk image with an installer package; this Mac can run that macOS family's installer package.
    case appleDiskImage
    /// Apple silicon Macs start only macOS 11 or later (Apple), so this Mac can neither download nor create it in a
    /// supported way. An Intel Mac can.
    case intelMacsOnly
}

public enum MacOSInstallerCatalogError: Error, Equatable, Sendable {
    case commandFailed(String)
    case pageUnavailable(String)
}

/// The catalog as shown: both sources, when each was last read, and what failed.
public struct MacOSInstallerCatalog: Codable, Equatable, Sendable {
    public var releases: [MacOSRelease]
    /// When Software Update was last read successfully; nil if never.
    public var softwareUpdateCheckedAt: Date?
    /// When Apple's page was last read successfully; nil if never.
    public var applePageCheckedAt: Date?
    /// Why the last attempt to read a source failed (shown; the entries of the last success stay, marked as such).
    public var softwareUpdateProblem: String?
    public var applePageProblem: String?

    public init(releases: [MacOSRelease] = [], softwareUpdateCheckedAt: Date? = nil, applePageCheckedAt: Date? = nil,
                softwareUpdateProblem: String? = nil, applePageProblem: String? = nil) {
        self.releases = releases
        self.softwareUpdateCheckedAt = softwareUpdateCheckedAt
        self.applePageCheckedAt = applePageCheckedAt
        self.softwareUpdateProblem = softwareUpdateProblem
        self.applePageProblem = applePageProblem
    }

    public static let applePage = "https://support.apple.com/en-us/102662"

    // MARK: Ordering

    /// Major releases, the newest first; inside each, the newest version first. A release Software Update offers is
    /// listed before the page's entry for the same major release.
    public var grouped: [MacOSMajorRelease] {
        var byMajor: [String: [MacOSRelease]] = [:]
        for release in releases { byMajor[release.major, default: []].append(release) }
        return byMajor.map { major, releases in
            let sorted = releases.sorted { a, b in
                let order = VersionComparison.compare(a.sortVersion, b.sortVersion)
                if order != .orderedSame { return order == .orderedDescending }
                if (a.source == .softwareUpdate) != (b.source == .softwareUpdate) { return a.source == .softwareUpdate }
                return (a.build ?? "") > (b.build ?? "")
            }
            let name = sorted.first(where: { $0.source == .softwareUpdate })?.name ?? sorted.first?.name ?? major
            return MacOSMajorRelease(major: major, name: name, releases: sorted)
        }
        .sorted { VersionComparison.compare($0.major, $1.major) == .orderedDescending }
    }

    // MARK: Merging

    /// The page's entries are kept only for major releases Software Update does not offer: for those it is better
    /// (versions, builds, automatic download). Duplicates (same version and build) are dropped.
    public static func merged(softwareUpdate: [MacOSRelease], applePage: [MacOSRelease]) -> [MacOSRelease] {
        var seen = Set<String>()
        var result: [MacOSRelease] = []
        for release in softwareUpdate where seen.insert(release.id).inserted { result.append(release) }
        let offered = Set(softwareUpdate.map(\.major))
        for release in applePage where !offered.contains(release.major) && seen.insert(release.id).inserted { result.append(release) }
        return result
    }

    // MARK: Suitability

    /// What this Mac can do with a release. Apple silicon Macs start only macOS 11 or later (Apple, “Mac computers
    /// with Apple silicon”); everything else is decided by Apple's own catalog and tools at run time.
    public static func suitability(of release: MacOSRelease, on environment: ToolEnvironment) -> InstallerSuitability {
        if environment.architecture == .arm64, VersionComparison.compare(release.major, "11") == .orderedAscending { return .intelMacsOnly }
        switch release.source {
        case .softwareUpdate: return .downloadHere
        case .appStore: return .appStore
        case .appleDiskImage: return .appleDiskImage
        }
    }

    // MARK: Software Update

    /// `softwareupdate --list-full-installers`:
    /// `* Title: macOS Sonoma, Version: 14.8.9, Size: 13334756KiB, Build: 23J631, Deferred: NO` (checked on macOS 27).
    public static func parseSoftwareUpdate(_ output: String, checkedAt: Date) -> [MacOSRelease] {
        let stamp = ISO8601DateFormatter().string(from: checkedAt)
        var result: [MacOSRelease] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("* Title:") else { continue }
            var fields: [String: String] = [:]
            for part in line.dropFirst(2).components(separatedBy: ", ") {
                guard let colon = part.firstIndex(of: ":") else { continue }
                fields[part[..<colon].trimmingCharacters(in: .whitespaces)] = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let title = fields["Title"], Self.isSafeName(title),
                  let version = fields["Version"], Self.isVersion(version) else { continue }
            let build = fields["Build"].flatMap { $0.range(of: #"^[0-9A-Za-z]{3,12}$"#, options: .regularExpression) != nil ? $0 : nil }
            result.append(MacOSRelease(name: title, major: majorRelease(of: version), version: version, build: build,
                                       sizeBytes: fields["Size"].flatMap(parseSize), source: .softwareUpdate,
                                       provenance: "softwareupdate --list-full-installers, \(stamp)"))
        }
        return result
    }

    /// "13334756KiB" → bytes.
    static func parseSize(_ text: String) -> Int64? {
        let units: [(String, Int64)] = [("KiB", 1024), ("MiB", 1_048_576), ("GiB", 1_073_741_824), ("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            guard let value = Int64(text.dropLast(unit.count)) else { return nil }
            return value.multipliedReportingOverflow(by: factor).overflow ? nil : value * factor
        }
        return Int64(text)
    }

    /// "14.8.9" → "14"; "10.15.7" → "10.15" (until macOS 11 the second number was the release).
    public static func majorRelease(of version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard let first = parts.first else { return version }
        if first == "10", parts.count > 1 { return "10.\(parts[1])" }
        return first
    }

    static func isVersion(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$"#, options: .regularExpression) != nil
    }

    /// Names come from Apple's tools and page but are still treated as untrusted: letters, digits, spaces, dots.
    static func isSafeName(_ text: String) -> Bool {
        text.count <= 60 && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9 .]*$"#, options: .regularExpression) != nil
    }

    // MARK: Apple's page

    /// Links on support.apple.com/102662 (checked 2026-10-19): `<a href="macappstores://apps.apple.com/app/macos-sonoma/
    /// id6450717509?mt=12" …>macOS Sonoma 14</a>` and `<a href="http://updates-http.cdn-apple.com/…/InstallOS.dmg" …>
    /// Sierra 10.12</a>`. Only these two kinds of Apple links are taken; anything else on the page is ignored.
    public static func parseApplePage(_ html: String, checkedAt: Date) -> [MacOSRelease] {
        let stamp = ISO8601DateFormatter().string(from: checkedAt)
        let pattern = #"<a\s[^>]*href="([^"]+)"[^>]*>([^<]{1,80})</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var result: [MacOSRelease] = []
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = decodeEntities(ns.substring(with: match.range(at: 1)))
            let text = decodeEntities(ns.substring(with: match.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (name, major) = releaseName(text) else { continue }
            if let id = appStoreID(href) {
                result.append(MacOSRelease(name: name, major: major, source: .appStore(id: id, url: "macappstores://apps.apple.com/app/id\(id)?mt=12"),
                                           provenance: "support.apple.com/102662, \(stamp)"))
            } else if let url = appleDiskImageURL(href) {
                result.append(MacOSRelease(name: name, major: major, source: .appleDiskImage(url: url),
                                           provenance: "support.apple.com/102662, \(stamp)"))
            }
        }
        return result
    }

    /// "macOS Sonoma 14" → ("macOS Sonoma", "14"); "Sierra 10.12" → ("macOS Sierra", "10.12"); "El Capitan 10.11" →
    /// ("OS X El Capitan", "10.11") – the product names Apple used for those releases.
    static func releaseName(_ text: String) -> (String, String)? {
        guard let match = text.range(of: #"^(.+?)\s+([0-9]{1,2}(\.[0-9]{1,2})?)$"#, options: .regularExpression) else { return nil }
        let words = text[match].split(separator: " ").map(String.init)
        guard let major = words.last, isVersion(major) else { return nil }
        var name = words.dropLast().joined(separator: " ")
        guard isSafeName(name) else { return nil }
        if !name.hasPrefix("macOS") && !name.hasPrefix("OS X") && !name.hasPrefix("Mac OS X") {
            // Apple's own names: “OS X” for 10.8 to 10.11, “Mac OS X” before, “macOS” from 10.12.
            let minor = Int(major.split(separator: ".").last ?? "") ?? 0
            if major.hasPrefix("10.") { name = (minor >= 12 ? "macOS " : minor >= 8 ? "OS X " : "Mac OS X ") + name } else { name = "macOS " + name }
        }
        return (name, major)
    }

    /// `macappstores://apps.apple.com/app/<slug>/id<number>` or the https form → the number.
    static func appStoreID(_ href: String) -> Int? {
        guard let url = URL(string: href), ["macappstores", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "apps.apple.com", let last = url.pathComponents.last, last.hasPrefix("id") else { return nil }
        return Int(last.dropFirst(2))
    }

    /// A `.dmg` on Apple's update CDN, always as https. The page's `http://updates-http.cdn-apple.com/…` links serve the
    /// same files from `https://updates.cdn-apple.com/…` (same sizes, checked 2026-10-19).
    static func appleDiskImageURL(_ href: String) -> String? {
        guard var components = URLComponents(string: href), let host = components.host?.lowercased(),
              ["updates.cdn-apple.com", "updates-http.cdn-apple.com"].contains(host),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.path.lowercased().hasSuffix(".dmg"), !components.path.contains("..") else { return nil }
        components.scheme = "https"
        components.host = "updates.cdn-apple.com"
        components.query = nil
        return components.url?.absoluteString
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&#x3D;", with: "=").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// Reads both sources and keeps the last good result of each when a source fails.
public struct MacOSInstallerCatalogLoader: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    /// Fetches Apple's page; replaced in tests and the simulation.
    public var fetchPage: @Sendable (URL) async throws -> String
    public var cacheFile: URL

    public init(layout: SystemLayout, runner: CommandRunning, cacheFile: URL,
                fetchPage: @escaping @Sendable (URL) async throws -> String = MacOSInstallerCatalogLoader.fetchApplePage) {
        self.layout = layout
        self.runner = runner
        self.cacheFile = cacheFile
        self.fetchPage = fetchPage
    }

    public static func fetchApplePage(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else {
            throw MacOSInstallerCatalogError.pageUnavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The last catalog saved on this Mac, or an empty one.
    public func cached() -> MacOSInstallerCatalog {
        guard let data = try? Data(contentsOf: cacheFile), let catalog = try? Self.decoder.decode(MacOSInstallerCatalog.self, from: data) else {
            return MacOSInstallerCatalog()
        }
        return catalog
    }

    /// Reads both sources again. A source that fails keeps its last entries (with the time they were read) and its
    /// problem; nothing is made up.
    public func refresh(now: Date = Date()) async -> MacOSInstallerCatalog {
        let previous = cached()
        var catalog = previous
        var softwareUpdate = previous.releases.filter { $0.source == .softwareUpdate }
        var page = previous.releases.filter { $0.source != .softwareUpdate }
        do {
            let result = try await runner.run(Command(executable: layout.softwareupdate, arguments: ["--list-full-installers"],
                                                      environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 300))
            let parsed = MacOSInstallerCatalog.parseSoftwareUpdate(result.stdout, checkedAt: now)
            if result.succeeded || !parsed.isEmpty {
                softwareUpdate = parsed
                catalog.softwareUpdateCheckedAt = now
                catalog.softwareUpdateProblem = parsed.isEmpty ? "Software Update listed no full installers" : nil
            } else {
                catalog.softwareUpdateProblem = result.timedOut ? "softwareupdate did not finish in time"
                    : layout.redact(ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout, maxLines: 2))
            }
        } catch {
            catalog.softwareUpdateProblem = layout.redact((error as NSError).localizedDescription)
        }
        do {
            let html = try await fetchPage(URL(string: MacOSInstallerCatalog.applePage)!)
            let parsed = MacOSInstallerCatalog.parseApplePage(html, checkedAt: now)
            if parsed.isEmpty {
                catalog.applePageProblem = "Apple's page contained no download links MacReplica recognises"
            } else {
                page = parsed
                catalog.applePageCheckedAt = now
                catalog.applePageProblem = nil
            }
        } catch {
            // One readable sentence (“The request timed out.”), not the whole error object.
            catalog.applePageProblem = (error as? MacOSInstallerCatalogError).map { "\($0)" } ?? (error as NSError).localizedDescription
        }
        catalog.releases = MacOSInstallerCatalog.merged(softwareUpdate: softwareUpdate, applePage: page)
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(catalog) { try? data.write(to: cacheFile, options: .atomic) }
        return catalog
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
