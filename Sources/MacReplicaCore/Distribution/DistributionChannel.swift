import Foundation

/// The release channel an application came from. MacReplica records it only with evidence;
/// without evidence nothing is recorded instead of assuming "stable".
public enum ReleaseChannel: String, Codable, Sendable, CaseIterable {
    case stable
    case beta
    case nightly
    /// Insider builds (e.g. Visual Studio Code Insiders).
    case insider
    /// Developer previews, early-access programs, technology previews.
    case preview

    public init(from decoder: Decoder) throws {
        self = ReleaseChannel(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stable
    }

    public var isPrerelease: Bool { self != .stable }
}

/// What the channel was derived from, shown to the user next to the channel.
public enum ChannelEvidence: String, Codable, Sendable {
    case homebrewCask
    case bundleIdentifier
    case appName
    case version
    case updateFeed

    public init(from decoder: Decoder) throws {
        self = ChannelEvidence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .appName
    }
}

/// The vendor's own update feed declared in the app bundle (Sparkle). Only the values from the
/// bundle's `Info.plist` are recorded; they are the same for every user of that app version.
public struct UpdateFeed: Codable, Equatable, Hashable, Sendable {
    /// The appcast URL (`SUFeedURL`).
    public var url: String
    /// The vendor's EdDSA public key (`SUPublicEDKey`, base64 of 32 bytes) used to verify downloads.
    public var publicEDKey: String?

    public init(url: String, publicEDKey: String? = nil) {
        self.url = url
        self.publicEDKey = publicEDKey
    }

    // "publicEdKey" so that the snake_case manifest key "public_ed_key" round-trips.
    private enum CodingKeys: String, CodingKey {
        case url
        case publicEDKey = "publicEdKey"
    }

    /// Reads `SUFeedURL` and `SUPublicEDKey`. Placeholders, non-web URLs and URLs with credentials are ignored.
    public static func from(info: [String: Any]) -> UpdateFeed? {
        guard let value = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil, value.count <= 500 else { return nil }
        var key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces)
        if let current = key, Data(base64Encoded: current)?.count != 32 { key = nil }
        return UpdateFeed(url: value, publicEDKey: key)
    }
}

/// Derives the release channel from what an installed app reveals about itself.
public enum ChannelDetector {
    /// Channel words and the channel they mean, checked in this order.
    static let words: [(String, ReleaseChannel)] = [
        ("technologypreview", .preview), ("technology preview", .preview), ("developeredition", .preview), ("developer edition", .preview),
        ("insiders", .insider), ("insider", .insider), ("nightly", .nightly), ("canary", .nightly), ("daily", .nightly),
        ("snapshot", .nightly), ("preview", .preview), ("eap", .preview), ("beta", .beta), ("alpha", .beta), ("dev", .nightly),
    ]

    /// Homebrew's naming: `firefox@nightly`, `visual-studio-code@insiders`, `intellij-idea@eap`. Numeric suffixes are versions.
    public static func channel(caskToken token: String) -> ReleaseChannel? {
        guard let at = token.lastIndex(of: "@") else { return nil }
        let suffix = token[token.index(after: at)...].lowercased()
        switch suffix {
        case "beta", "alpha", "prerelease", "rc", "ptb", "next": return .beta
        case "nightly", "daily", "canary", "dev", "devel", "snapshot", "experimental": return .nightly
        case "insiders", "insider": return .insider
        case "preview", "eap", "early-adopter", "developer-edition": return .preview
        case "esr", "lts": return .stable
        default: return nil
        }
    }

    /// Bundle identifier suffixes such as `com.google.Chrome.canary`, `com.microsoft.VSCodeInsiders`, `…-EAP`.
    /// Channel words count as the last component (`.canary`), after a dash (`-EAP`) or, for a few
    /// unambiguous words, directly attached (`VSCodeInsiders`, `firefoxdeveloperedition`).
    public static func channel(bundleIdentifier: String) -> ReleaseChannel? {
        let last = bundleIdentifier.lowercased().split(separator: ".").last.map(String.init) ?? ""
        let attached: Set<String> = ["insiders", "developeredition", "technologypreview"]
        for (word, channel) in words where !word.contains(" ") {
            if last == word || last.hasSuffix("-" + word) || (attached.contains(word) && last.hasSuffix(word)) { return channel }
        }
        return nil
    }

    /// App names that end in a channel word, such as "Firefox Nightly", "Google Chrome Canary", "Xcode-beta" or
    /// "Firefox Developer Edition". Only the end of the name counts, and "Preview" alone does not
    /// (it is a common product name).
    public static func channel(appName: String) -> ReleaseChannel? {
        let tokens = appName.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let last = tokens.last else { return nil }
        let lastTwo = tokens.suffix(2).joined(separator: " ")
        for (word, channel) in words where word != "preview" && word != "snapshot" {
            if word.contains(" ") ? lastTwo == word : last == word { return channel }
        }
        return nil
    }

    /// Version strings such as `158.0b3`, `159.0a1`, `1.141.0-insider`, `3.7.4beta1`, `8.12.40-27.BETA`, `2.0-rc2`.
    public static func channel(version: String) -> ReleaseChannel? {
        let lower = version.lowercased()
        if lower.contains("insider") { return .insider }
        if lower.contains("nightly") || lower.range(of: #"\d+a\d+$"#, options: .regularExpression) != nil { return .nightly }
        if lower.contains("preview") { return .preview }
        if lower.contains("beta") || lower.contains("alpha") || lower.range(of: #"\d+b\d+$"#, options: .regularExpression) != nil
            || lower.range(of: #"[-.]rc\d*$"#, options: .regularExpression) != nil { return .beta }
        return nil
    }

    /// Feed URLs with a channel in their path or query (`…/appcast-beta.xml`, `?channel=nightly`).
    public static func channel(feedURL: String) -> ReleaseChannel? {
        let lower = feedURL.lowercased()
        for (word, channel) in [("nightly", ReleaseChannel.nightly), ("beta", .beta), ("prerelease", .beta), ("insider", .insider), ("preview", .preview)]
        where lower.contains(word) { return channel }
        return nil
    }

    /// The channel with its evidence, strongest evidence first. Nil when nothing points to a channel.
    public static func detect(caskToken: String?, bundleIdentifier: String?, appName: String, version: String?,
                              feedURL: String?) -> (ReleaseChannel, ChannelEvidence)? {
        if let caskToken, let channel = channel(caskToken: caskToken) { return (channel, .homebrewCask) }
        if let bundleIdentifier, let channel = channel(bundleIdentifier: bundleIdentifier) { return (channel, .bundleIdentifier) }
        if let channel = channel(appName: appName) { return (channel, .appName) }
        if let version, let channel = channel(version: version) { return (channel, .version) }
        if let feedURL, let channel = channel(feedURL: feedURL) { return (channel, .updateFeed) }
        return nil
    }
}
