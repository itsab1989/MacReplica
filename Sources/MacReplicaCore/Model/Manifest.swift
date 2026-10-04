import Foundation

/// The machine-readable description of a MacReplica backup.
///
/// The manifest is written as `manifest.json` with snake_case keys. Field names
/// are stable and language-independent; human-readable text never goes in here.
/// Unknown keys are ignored when decoding, so additions that older versions may
/// safely ignore stay readable by them, and `ManifestIO` migrates older manifest
/// versions forward.
///
/// Version 2 (MacReplica 1.0.1) adds data an older MacReplica would restore wrongly if it
/// ignored it, above all application data in the shared `/Library` (`scope`). MacReplica
/// 1.0.0 refuses version 2 backups instead of misplacing files.
///
/// Version 3 (MacReplica 1.0.2) adds application data whose files contain a placeholder for the home
/// folder (`homePlaceholder`), data in `/Users/Shared` (`usersShared` scope), the Launchpad layout and the
/// user's own installers. MacReplica 1.0.1 would write the placeholder into the files as it is, so it
/// refuses version 3 backups.
public struct Manifest: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public var manifestVersion: Int
    public var macreplicaVersion: String
    public var macreplicaBuild: String?
    public var createdAt: Date
    public var macosVersion: String
    public var architecture: CPUArchitecture
    public var homebrew: HomebrewSnapshot?
    public var applications: [AppRecord]
    public var brewFormulae: [BrewFormulaRecord]
    public var brewCasks: [BrewCaskRecord]
    public var brewTaps: [BrewTapRecord]
    public var masApps: [MASAppRecord]
    public var fonts: [FileRecord]
    public var iccProfiles: [FileRecord]
    public var python: PythonSnapshot
    public var applicationData: [AppDataFolder]
    /// Things that were selected but could not be included; non-empty means a partial backup.
    public var backupIssues: [BackupIssue]
    /// Which locations were scanned, missing, or not readable.
    public var locations: [LocationAccess]
    public var developer: DeveloperSettings
    public var credentials: [CredentialRecord]
    /// Detected services that need a new sign-in or a manual export on the new Mac.
    public var guidance: [GuidanceRecord]
    /// How many fonts and profiles were found and how many the user chose to back up.
    public var backupSelection: BackupSelectionSummary?
    /// Package managers, version managers, runtimes and global tools besides Homebrew and the App Store.
    public var toolchains: [ToolchainRecord]
    /// Salted hashes that let a restore recognise the same Mac and the same displays (no identifiers are stored).
    public var hardwareKeys: HardwareKeys?
    /// Profiles the user assigned to displays (System Settings › Displays › Color profile).
    public var displayProfiles: [DisplayProfileAssignment]
    /// The Launchpad arrangement (macOS 13–15): pages, folders with their names, and the order of the apps.
    public var launchpadLayout: LaunchpadLayout?

    public init(
        manifestVersion: Int = Manifest.currentVersion,
        macreplicaVersion: String,
        createdAt: Date,
        macosVersion: String,
        architecture: CPUArchitecture,
        homebrew: HomebrewSnapshot? = nil,
        applications: [AppRecord] = [],
        brewFormulae: [BrewFormulaRecord] = [],
        brewCasks: [BrewCaskRecord] = [],
        brewTaps: [BrewTapRecord] = [],
        masApps: [MASAppRecord] = [],
        fonts: [FileRecord] = [],
        iccProfiles: [FileRecord] = [],
        python: PythonSnapshot = PythonSnapshot(),
        applicationData: [AppDataFolder] = [],
        backupIssues: [BackupIssue] = [],
        locations: [LocationAccess] = [],
        developer: DeveloperSettings = DeveloperSettings(),
        credentials: [CredentialRecord] = [],
        guidance: [GuidanceRecord] = [],
        toolchains: [ToolchainRecord] = []
    ) {
        self.toolchains = toolchains
        self.displayProfiles = []
        self.manifestVersion = manifestVersion
        self.macreplicaVersion = macreplicaVersion
        self.createdAt = createdAt
        self.macosVersion = macosVersion
        self.architecture = architecture
        self.homebrew = homebrew
        self.applications = applications
        self.brewFormulae = brewFormulae
        self.brewCasks = brewCasks
        self.brewTaps = brewTaps
        self.masApps = masApps
        self.fonts = fonts
        self.iccProfiles = iccProfiles
        self.python = python
        self.applicationData = applicationData
        self.backupIssues = backupIssues
        self.locations = locations
        self.developer = developer
        self.credentials = credentials
        self.guidance = guidance
    }

    private enum CodingKeys: String, CodingKey {
        case manifestVersion, macreplicaVersion, macreplicaBuild, createdAt, macosVersion, architecture, homebrew
        case applications, brewFormulae, brewCasks, brewTaps, masApps, fonts, iccProfiles
        case python, applicationData, backupIssues, locations, developer, credentials, guidance, backupSelection, toolchains
        case hardwareKeys, displayProfiles, launchpadLayout
    }

    // Collections are decoded leniently: a missing list is treated as empty so
    // that manifests written by future versions that drop or rename a section
    // still load instead of failing completely.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try c.decode(Int.self, forKey: .manifestVersion)
        macreplicaBuild = try c.decodeIfPresent(String.self, forKey: .macreplicaBuild)
        macreplicaVersion = try c.decodeIfPresent(String.self, forKey: .macreplicaVersion) ?? "unknown"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        macosVersion = try c.decodeIfPresent(String.self, forKey: .macosVersion) ?? "unknown"
        architecture = try c.decodeIfPresent(CPUArchitecture.self, forKey: .architecture) ?? .unknown
        homebrew = try c.decodeIfPresent(HomebrewSnapshot.self, forKey: .homebrew)
        applications = try c.decodeIfPresent([AppRecord].self, forKey: .applications) ?? []
        brewFormulae = try c.decodeIfPresent([BrewFormulaRecord].self, forKey: .brewFormulae) ?? []
        brewCasks = try c.decodeIfPresent([BrewCaskRecord].self, forKey: .brewCasks) ?? []
        brewTaps = try c.decodeIfPresent([BrewTapRecord].self, forKey: .brewTaps) ?? []
        masApps = try c.decodeIfPresent([MASAppRecord].self, forKey: .masApps) ?? []
        fonts = try c.decodeIfPresent([FileRecord].self, forKey: .fonts) ?? []
        iccProfiles = try c.decodeIfPresent([FileRecord].self, forKey: .iccProfiles) ?? []
        python = try c.decodeIfPresent(PythonSnapshot.self, forKey: .python) ?? PythonSnapshot()
        applicationData = try c.decodeIfPresent([AppDataFolder].self, forKey: .applicationData) ?? []
        backupIssues = try c.decodeIfPresent([BackupIssue].self, forKey: .backupIssues) ?? []
        locations = try c.decodeIfPresent([LocationAccess].self, forKey: .locations) ?? []
        developer = try c.decodeIfPresent(DeveloperSettings.self, forKey: .developer) ?? DeveloperSettings()
        credentials = try c.decodeIfPresent([CredentialRecord].self, forKey: .credentials) ?? []
        guidance = try c.decodeIfPresent([GuidanceRecord].self, forKey: .guidance) ?? []
        backupSelection = try c.decodeIfPresent(BackupSelectionSummary.self, forKey: .backupSelection)
        // Providers added by later versions are dropped instead of failing the whole manifest.
        toolchains = try c.decodeIfPresent(LenientList<ToolchainRecord>.self, forKey: .toolchains)?.elements ?? []
        hardwareKeys = try c.decodeIfPresent(HardwareKeys.self, forKey: .hardwareKeys)
        displayProfiles = try c.decodeIfPresent(LenientList<DisplayProfileAssignment>.self, forKey: .displayProfiles)?.elements ?? []
        // A layout this version cannot read is left out rather than failing the manifest.
        launchpadLayout = try? c.decodeIfPresent(LaunchpadLayout.self, forKey: .launchpadLayout)
    }
}

/// The selection made on the old Mac. The backup itself contains exactly the selected items that
/// could be copied; items that could not be copied are listed in `backupIssues`.
public struct BackupSelectionSummary: Codable, Equatable, Sendable {
    public var fontsFound: Int
    public var fontsSelected: Int
    public var profilesFound: Int
    public var profilesSelected: Int

    public init(fontsFound: Int, fontsSelected: Int, profilesFound: Int, profilesSelected: Int) {
        self.fontsFound = fontsFound
        self.fontsSelected = fontsSelected
        self.profilesFound = profilesFound
        self.profilesSelected = profilesSelected
    }
}

/// CPU architecture of a Mac or of an executable slice.
public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CPUArchitecture(rawValue: raw) ?? .unknown
    }
}

public struct HomebrewSnapshot: Codable, Equatable, Sendable {
    public var version: String
    public var prefix: String

    public init(version: String, prefix: String) {
        self.version = version
        self.prefix = prefix
    }
}

/// How an application originally got onto the Mac, as far as MacReplica can tell.
/// `unknown` is used whenever there is no reliable evidence — MacReplica never guesses.
public enum InstallSource: Codable, Equatable, Hashable, Sendable {
    case homebrewCask(token: String)
    case appStore
    case package(identifier: String)
    case downloaded(agent: String)
    case unknown

    private enum CodingKeys: String, CodingKey { case kind, token, identifier, agent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "homebrew_cask": self = .homebrewCask(token: try c.decode(String.self, forKey: .token))
        case "app_store": self = .appStore
        case "package": self = .package(identifier: try c.decode(String.self, forKey: .identifier))
        case "downloaded": self = .downloaded(agent: try c.decode(String.self, forKey: .agent))
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .homebrewCask(let token):
            try c.encode("homebrew_cask", forKey: .kind)
            try c.encode(token, forKey: .token)
        case .appStore:
            try c.encode("app_store", forKey: .kind)
        case .package(let identifier):
            try c.encode("package", forKey: .kind)
            try c.encode(identifier, forKey: .identifier)
        case .downloaded(let agent):
            try c.encode("downloaded", forKey: .kind)
            try c.encode(agent, forKey: .agent)
        case .unknown:
            try c.encode("unknown", forKey: .kind)
        }
    }
}

/// The method MacReplica will use to bring an application back.
public enum RestoreMethod: Codable, Equatable, Hashable, Sendable {
    case homebrewCask(token: String)
    case homebrewFormula(name: String)
    case appStore(id: Int)
    case officialDownload(url: String)
    case manual

    private enum CodingKeys: String, CodingKey { case kind, token, name, id, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "homebrew_cask": self = .homebrewCask(token: try c.decode(String.self, forKey: .token))
        case "homebrew_formula": self = .homebrewFormula(name: try c.decode(String.self, forKey: .name))
        case "app_store": self = .appStore(id: try c.decode(Int.self, forKey: .id))
        case "official_download": self = .officialDownload(url: try c.decode(String.self, forKey: .url))
        default: self = .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .homebrewCask(let token):
            try c.encode("homebrew_cask", forKey: .kind)
            try c.encode(token, forKey: .token)
        case .homebrewFormula(let name):
            try c.encode("homebrew_formula", forKey: .kind)
            try c.encode(name, forKey: .name)
        case .appStore(let id):
            try c.encode("app_store", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .officialDownload(let url):
            try c.encode("official_download", forKey: .kind)
            try c.encode(url, forKey: .url)
        case .manual:
            try c.encode("manual", forKey: .kind)
        }
    }

    public var category: RestoreCategory {
        switch self {
        case .homebrewCask, .homebrewFormula: return .homebrew
        case .appStore: return .appStore
        case .officialDownload: return .officialDownload
        case .manual: return .manual
        }
    }
}

public enum RestoreCategory: String, Codable, Sendable, CaseIterable {
    case homebrew, appStore, officialDownload, manual
}

/// A candidate Homebrew package for an application that was not installed with Homebrew.
public struct MatchCandidate: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case cask, formula }

    public var kind: Kind
    public var token: String
    public var name: String
    public var homepage: String?
    public var score: Int
    public var evidence: [MatchEvidence]

    public init(kind: Kind, token: String, name: String, homepage: String?, score: Int, evidence: [MatchEvidence]) {
        self.kind = kind
        self.token = token
        self.name = name
        self.homepage = homepage
        self.score = score
        self.evidence = evidence
    }

    public var restoreMethod: RestoreMethod {
        kind == .cask ? .homebrewCask(token: token) : .homebrewFormula(name: token)
    }
}

public enum MatchEvidence: String, Codable, Sendable, CaseIterable {
    case appBundleName
    case bundleIdentifier
    case displayName
    case tokenName
    case vendor
}

public struct AppRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { bundleIdentifier ?? path }

    public var name: String
    public var version: String?
    public var buildVersion: String?
    public var bundleIdentifier: String?
    /// Path with the home directory replaced by `~`, e.g. `/Applications/Example.app`.
    public var path: String
    public var vendor: String?
    public var architectures: [CPUArchitecture]
    public var minimumSystemVersion: String?
    public var source: InstallSource
    public var restoreMethod: RestoreMethod
    /// Possible Homebrew packages when the match was not unambiguous.
    public var candidates: [MatchCandidate]
    public var homepage: String?
    /// The release channel (beta, nightly …) when there is evidence for one; nil means none was found.
    public var channel: ReleaseChannel?
    public var channelEvidence: ChannelEvidence?
    /// The vendor's update feed declared in the bundle, used to find an official download.
    public var updateFeed: UpdateFeed?
    /// Apple Developer Team ID of the bundle's signature; downloads must carry the same one.
    public var teamIdentifier: String?
    /// Further copies of the same app (same bundle identifier) found in other places, e.g. an older one in
    /// `~/Applications`. The app is listed and restored once; these are shown so the user knows about them.
    public var otherCopies: [OtherCopy]? = nil
    /// Installers the user keeps for this app, in the order they are run (e.g. the installer, then an
    /// activation package). See `InstallerArchive`.
    public var ownInstallers: [InstallerArchive]? = nil

    public struct OtherCopy: Codable, Equatable, Hashable, Sendable {
        public var path: String
        public var version: String?
        public init(path: String, version: String?) { self.path = path; self.version = version }
    }

    public init(
        name: String,
        version: String? = nil,
        buildVersion: String? = nil,
        bundleIdentifier: String? = nil,
        path: String,
        vendor: String? = nil,
        architectures: [CPUArchitecture] = [],
        minimumSystemVersion: String? = nil,
        source: InstallSource = .unknown,
        restoreMethod: RestoreMethod = .manual,
        candidates: [MatchCandidate] = [],
        homepage: String? = nil
    ) {
        self.name = name
        self.version = version
        self.buildVersion = buildVersion
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.vendor = vendor
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.source = source
        self.restoreMethod = restoreMethod
        self.candidates = candidates
        self.homepage = homepage
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, buildVersion, bundleIdentifier, path, vendor, architectures
        case minimumSystemVersion, source, restoreMethod, candidates, homepage, channel, channelEvidence, updateFeed, teamIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        buildVersion = try c.decodeIfPresent(String.self, forKey: .buildVersion)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        path = try c.decode(String.self, forKey: .path)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        architectures = try c.decodeIfPresent([CPUArchitecture].self, forKey: .architectures) ?? []
        minimumSystemVersion = try c.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        source = try c.decodeIfPresent(InstallSource.self, forKey: .source) ?? .unknown
        restoreMethod = try c.decodeIfPresent(RestoreMethod.self, forKey: .restoreMethod) ?? .manual
        candidates = try c.decodeIfPresent([MatchCandidate].self, forKey: .candidates) ?? []
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        channel = try c.decodeIfPresent(ReleaseChannel.self, forKey: .channel)
        channelEvidence = try c.decodeIfPresent(ChannelEvidence.self, forKey: .channelEvidence)
        updateFeed = try c.decodeIfPresent(UpdateFeed.self, forKey: .updateFeed)
        teamIdentifier = try c.decodeIfPresent(String.self, forKey: .teamIdentifier)
    }

    /// True when MacReplica found possible Homebrew packages but none was certain enough
    /// to use automatically, so the user should pick one (or none).
    public var needsMatchDecision: Bool {
        restoreMethod.category != .homebrew && restoreMethod.category != .appStore && !candidates.isEmpty
    }

    /// The `.app` file name, e.g. `Example Editor.app`.
    public var bundleFileName: String {
        (path as NSString).lastPathComponent
    }
}

public struct BrewFormulaRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var version: String
    public var tap: String?
    /// False for formulae that were only pulled in as dependencies.
    public var installedOnRequest: Bool

    /// A development build from the formula's source repository (`brew install --HEAD`).
    public var isHead: Bool { version.hasPrefix("HEAD") }

    public init(name: String, version: String, tap: String? = nil, installedOnRequest: Bool = true) {
        self.name = name
        self.version = version
        self.tap = tap
        self.installedOnRequest = installedOnRequest
    }
}

public struct BrewCaskRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { token }
    public var token: String
    public var version: String
    public var tap: String?
    /// The `.app` bundles this cask installs, used to link casks and applications.
    public var appArtifacts: [String]

    public init(token: String, version: String, tap: String? = nil, appArtifacts: [String] = []) {
        self.token = token
        self.version = version
        self.tap = tap
        self.appArtifacts = appArtifacts
    }
}

public struct BrewTapRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var remote: String?

    public init(name: String, remote: String? = nil) {
        self.name = name
        self.remote = remote
    }

    /// Official taps that Homebrew provides out of the box and that never need tapping.
    public var isBuiltIn: Bool {
        ["homebrew/core", "homebrew/cask", "homebrew/bundle", "homebrew/services"].contains(name.lowercased())
    }
}

public struct MASAppRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { appStoreID }
    public var appStoreID: Int
    public var name: String
    public var version: String?
    public var bundleIdentifier: String?

    public init(appStoreID: Int, name: String, version: String? = nil, bundleIdentifier: String? = nil) {
        self.appStoreID = appStoreID
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }

    // "appStoreId" so that the snake_case key "app_store_id" round-trips.
    private enum CodingKeys: String, CodingKey {
        case appStoreID = "appStoreId"
        case name, version, bundleIdentifier
    }
}

/// Where a font or color profile lives: the current user's library or the shared one.
public enum FileDomain: String, Codable, Sendable, CaseIterable {
    case user
    case system
}

/// Something that was selected for the backup but could not be included.
public struct BackupIssue: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case unreadable, refusedSensitive, tooLarge, changedDuringBackup }
    /// Display path (home written as `~`).
    public var path: String
    public var reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// A font or ICC profile file stored in the backup.
public struct FileRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(domain.rawValue)/\(relativePath)" }

    public var fileName: String
    public var domain: FileDomain
    /// Path below the domain's base folder, e.g. `Example Sans/ExampleSans-Bold.otf`.
    public var relativePath: String
    /// Original location with the home directory written as `~`.
    public var originalPath: String
    /// Location of the copy inside the backup folder, relative to the backup root.
    public var backupPath: String
    public var sha256: String
    public var size: Int64
    public var modifiedAt: Date?
    public var metadata: [String: String]
    /// Identity used to recognize the same font or profile on the destination Mac, independent of the file name.
    public var font: FontIdentity?
    public var profile: ProfileIdentity?
    public var origin: FileOrigin?

    public init(
        fileName: String,
        domain: FileDomain,
        relativePath: String,
        originalPath: String,
        backupPath: String,
        sha256: String,
        size: Int64,
        modifiedAt: Date? = nil,
        metadata: [String: String] = [:],
        font: FontIdentity? = nil,
        profile: ProfileIdentity? = nil,
        origin: FileOrigin? = nil
    ) {
        self.font = font
        self.profile = profile
        self.origin = origin
        self.fileName = fileName
        self.domain = domain
        self.relativePath = relativePath
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
        self.metadata = metadata
    }
}
