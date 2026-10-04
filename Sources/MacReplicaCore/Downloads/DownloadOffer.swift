import Foundation

/// One official way to get an application back that MacReplica cannot install automatically.
public struct DownloadOffer: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The vendor's own update feed (Sparkle appcast) declared in the app.
        case vendorFeed
        /// The vendor download that Homebrew's cask points to, downloaded directly.
        case homebrewCask
        /// Only the vendor's website: the user downloads there.
        case vendorWebsite
        /// The app's page in the Mac App Store.
        case appStore
        /// The user's own installer, from the backup or from where it was kept (e.g. an external drive). Works offline.
        case ownInstaller
    }

    /// A further package of the user's own installers, opened in Installer after the app (e.g. an activation package).
    public struct LocalPackage: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var path: String
        public var sha256: String
        public var teamIdentifier: String?
        public init(name: String, path: String, sha256: String, teamIdentifier: String?) {
            self.name = name
            self.path = path
            self.sha256 = sha256
            self.teamIdentifier = teamIdentifier
        }
    }

    /// What MacReplica verifies before anything is installed, strongest first.
    public enum Trust: String, Codable, Sendable, Comparable {
        /// The file carries the vendor's EdDSA signature (Sparkle) and the app's developer team matches.
        case vendorSignature
        /// The file matches Homebrew's reviewed SHA-256 and the app's developer team matches.
        case checksum
        /// No file checksum is published; the app's code signature and developer team must match the original.
        case developerSignature
        /// Nothing can be verified: MacReplica does not download it and only links to the vendor.
        case none

        private var rank: Int { [.vendorSignature: 0, .checksum: 1, .developerSignature: 2, .none: 3][self] ?? 3 }
        public static func < (lhs: Trust, rhs: Trust) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: String
    /// The restore item the offer belongs to (`manual:<path>`).
    public var itemID: String
    public var kind: Kind
    public var url: String
    public var version: String?
    public var channel: ReleaseChannel?
    public var expectedLength: Int64?
    public var sha256: String?
    public var edSignature: String?
    public var publicEDKey: String?
    public var expectedBundleIdentifier: String?
    public var expectedTeamIdentifier: String?
    public var minimumSystemVersion: String?
    /// The download is an installer package (`.pkg`), opened in Installer for the user.
    public var isPackage: Bool
    /// Suggested choice: same channel and source as on the old Mac, best verification.
    public var recommended: Bool
    public var trust: Trust
    /// For `.ownInstaller`: the installer file on this Mac (in the backup or on the drive it was kept on).
    public var localPath: String?
    public var followUps: [LocalPackage]?

    public init(id: String, itemID: String, kind: Kind, url: String, version: String? = nil, channel: ReleaseChannel? = nil,
                expectedLength: Int64? = nil, sha256: String? = nil, edSignature: String? = nil, publicEDKey: String? = nil,
                expectedBundleIdentifier: String? = nil, expectedTeamIdentifier: String? = nil, minimumSystemVersion: String? = nil,
                isPackage: Bool = false, recommended: Bool = false, trust: Trust = .none) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.url = url
        self.version = version
        self.channel = channel
        self.expectedLength = expectedLength
        self.sha256 = sha256
        self.edSignature = edSignature
        self.publicEDKey = publicEDKey
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.minimumSystemVersion = minimumSystemVersion
        self.isPackage = isPackage
        self.recommended = recommended
        self.trust = trust
    }

    /// Offers MacReplica downloads itself; websites and the App Store are opened for the user.
    public var isDownloadable: Bool { (kind == .vendorFeed || kind == .homebrewCask) && trust != .none }

    /// The host shown to the user next to the offer.
    public var host: String { URL(string: url)?.host ?? "" }
}

/// One `<item>` of a Sparkle appcast, reduced to what choosing and verifying a download needs.
public struct AppcastItem: Equatable, Sendable {
    public var title: String?
    /// `sparkle:version` (the bundle version Sparkle compares).
    public var version: String?
    public var shortVersion: String?
    public var channel: String?
    public var minimumSystemVersion: String?
    public var maximumSystemVersion: String?
    /// Sparkle 2.9+: `arm64` means the update runs on Apple silicon only.
    public var hardwareRequirements: String?
    public var enclosureURL: String?
    public var length: Int64?
    public var edSignature: String?
    public var installationType: String?
    /// An informational update has no file, only a page (`<link>`).
    public var isInformational: Bool
    public var link: String?

    public init(title: String? = nil, version: String? = nil, shortVersion: String? = nil, channel: String? = nil,
                minimumSystemVersion: String? = nil, maximumSystemVersion: String? = nil, hardwareRequirements: String? = nil,
                enclosureURL: String? = nil, length: Int64? = nil, edSignature: String? = nil, installationType: String? = nil,
                isInformational: Bool = false, link: String? = nil) {
        self.title = title
        self.version = version
        self.shortVersion = shortVersion
        self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.hardwareRequirements = hardwareRequirements
        self.enclosureURL = enclosureURL
        self.length = length
        self.edSignature = edSignature
        self.installationType = installationType
        self.isInformational = isInformational
        self.link = link
    }

    public var displayVersion: String? { shortVersion ?? version }
}

/// Parses Sparkle appcasts (RSS 2.0 with the `sparkle:` namespace). `sparkle:version` and
/// `sparkle:shortVersionString` may be elements or attributes of `<enclosure>`; delta updates are ignored.
public final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var inDeltas = false

    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item": current = AppcastItem()
        case "sparkle:deltas": inDeltas = true
        case "sparkle:informationalUpdate": current?.isInformational = true
        case "enclosure" where !inDeltas && current != nil:
            current?.enclosureURL = attributes["url"]
            current?.length = attributes["length"].flatMap { Int64($0) }
            current?.edSignature = attributes["sparkle:edSignature"]
            current?.installationType = attributes["sparkle:installationType"]
            if current?.version == nil { current?.version = attributes["sparkle:version"] }
            if current?.shortVersion == nil { current?.shortVersion = attributes["sparkle:shortVersionString"] }
            if let os = attributes["sparkle:os"], os != "macos" { current?.enclosureURL = nil }
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard current != nil else { return }
        switch name {
        case "item":
            if let item = current { items.append(item) }
            current = nil
        case "sparkle:deltas": inDeltas = false
        case "title": current?.title = value
        case "sparkle:version" where !value.isEmpty: current?.version = value
        case "sparkle:shortVersionString" where !value.isEmpty: current?.shortVersion = value
        case "sparkle:channel": current?.channel = value.isEmpty ? nil : value
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
        case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value
        case "sparkle:hardwareRequirements": current?.hardwareRequirements = value
        case "link": current?.link = value
        default: break
        }
    }
}
