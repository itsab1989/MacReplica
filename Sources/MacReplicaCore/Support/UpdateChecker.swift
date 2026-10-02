import Foundation

/// A published MacReplica release.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var pageURL: URL
    public var isPrerelease: Bool

    public init(version: String, pageURL: URL, isPrerelease: Bool) {
        self.version = version
        self.pageURL = pageURL
        self.isPrerelease = isPrerelease
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate(current: String)
    case available(release: ReleaseInfo, current: String)
    case unableToCheck
}

public protocol ReleaseFetching: Sendable {
    func releases() async throws -> [ReleaseInfo]
}

/// Reads release metadata from the project's official GitHub Releases. Nothing is
/// downloaded or installed: MacReplica only informs the user and opens the release page.
public struct GitHubReleaseFetcher: ReleaseFetching {
    public static let repository = "itsab1989/MacReplica"
    public static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    public static let releasePagePrefix = "https://github.com/\(repository)/releases/"

    public init() {}

    public func releases() async throws -> [ReleaseInfo] {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Self.parse(data)
    }

    /// Parses the GitHub releases JSON. Drafts and releases whose page is not on the
    /// official repository are ignored.
    public static func parse(_ data: Data) throws -> [ReleaseInfo] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return items.compactMap { item in
            guard item["draft"] as? Bool != true,
                  let tag = item["tag_name"] as? String, let version = SemanticVersion(tag),
                  let page = item["html_url"] as? String, page.hasPrefix(releasePagePrefix), let url = URL(string: page)
            else { return nil }
            return ReleaseInfo(version: version.description, pageURL: url, isPrerelease: (item["prerelease"] as? Bool ?? false) || version.isPrerelease)
        }
    }
}

/// Reads release metadata from a local JSON file (tests and the simulation environment).
public struct LocalReleaseFetcher: ReleaseFetching {
    public var file: URL
    public init(file: URL) { self.file = file }
    public func releases() async throws -> [ReleaseInfo] { try GitHubReleaseFetcher.parse(Data(contentsOf: file)) }
}

public struct UpdateChecker: Sendable {
    public var fetcher: ReleaseFetching
    public init(fetcher: ReleaseFetching) { self.fetcher = fetcher }

    public func check(currentVersion: String = SystemInfo.appVersion, includePrereleases: Bool = false) async -> UpdateStatus {
        guard let current = SemanticVersion(currentVersion), let releases = try? await fetcher.releases() else { return .unableToCheck }
        let candidates = releases.filter { includePrereleases || !$0.isPrerelease }
        guard let newest = candidates.compactMap({ release in SemanticVersion(release.version).map { ($0, release) } })
            .max(by: { $0.0 < $1.0 }) else {
            return .upToDate(current: currentVersion)
        }
        return newest.0 > current ? .available(release: newest.1, current: currentVersion) : .upToDate(current: currentVersion)
    }
}

/// MAJOR.MINOR.PATCH with an optional pre-release suffix (`1.2.0-beta.1`), compared per semver rules.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        value = String(value.split(separator: "+", maxSplits: 1).first ?? "")
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts.first.map { $0.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) } } ?? []
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2], major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if parts.count > 1 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.contains(where: \.isEmpty) else { return nil }
            self.prerelease = identifiers
        } else {
            self.prerelease = []
        }
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release is newer than any of its pre-releases.
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
            switch (Int(l), Int(r)) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
