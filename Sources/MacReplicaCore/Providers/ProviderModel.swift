import Foundation

/// How much MacReplica trusts a provider. Only `fixtureTested` and `verified`
/// providers are offered; the other states exist so research is recorded honestly.
public enum VerificationStatus: String, Codable, Sendable {
    /// Locations researched, nothing implemented.
    case researched
    /// Implemented and covered by automated tests with synthetic data that mirrors the
    /// documented layout. The real application was not run.
    case fixtureTested
    /// Additionally confirmed with the real application.
    case verified
}

/// What a location contains, which decides whether it may be migrated automatically.
public enum DataClassification: String, Codable, Sendable {
    /// User-created customization with a stable format: migrated when selected (default on).
    case safe
    /// Useful, but may not work across app versions: offered, default off, with an explanation.
    case compatibilitySensitive
    /// Useful, but user content may contain API keys (e.g. automation workflows): offered, default off, with a warning.
    case mayContainSecrets
    /// Never migrated by a provider (listed for documentation and tests).
    case cache, database, temporary, log, credential

    public var isOffered: Bool { self == .safe || self == .compatibilitySensitive || self == .mayContainSecrets }
    public var selectedByDefault: Bool { self == .safe }

    public init(from decoder: Decoder) throws {
        self = DataClassification(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .cache
    }
}

/// A source document a provider is based on.
public struct Evidence: Sendable, Equatable {
    public var title: String
    public var url: String
}

/// One kind of data inside an application's folder.
public struct AppDataCategory: Sendable {
    /// Localization key suffix (`appData.category.<key>`).
    public var key: String
    /// Path below the (versioned) application folder. A folder is copied with its contents;
    /// with `files`, only those file names directly inside it are copied.
    public var path: String
    public var files: [String]?
    /// Names (files or folders, at any depth) that are never copied, e.g. caches inside a user folder.
    public var excluding: [String]
    public var classification: DataClassification
    /// For versioned apps: the files also work in another version of the app, so they may be restored
    /// into the version installed on the new Mac. In `files`, `{folder}` stands for the version folder's
    /// name without a trailing " Settings" (e.g. "Adobe Photoshop 2026 Prefs.psp").
    public var movesBetweenVersions: Bool

    public init(_ key: String, _ path: String, files: [String]? = nil, excluding: [String] = [], _ classification: DataClassification = .safe,
                movesBetweenVersions: Bool = false) {
        self.key = key
        self.path = path
        self.files = files
        self.excluding = excluding
        self.classification = classification
        self.movesBetweenVersions = movesBetweenVersions
    }
}

/// Where an application keeps the data a provider describes.
public enum AppDataScope: String, Codable, Sendable {
    /// Below the user's home folder (the usual case).
    case home
    /// Below `/Library`, shared by all users of the Mac — e.g. DaVinci Resolve's LUT folder. Only provider
    /// locations are ever read or written there; user-chosen folders are always inside the home folder.
    case sharedLibrary
}

/// Everything MacReplica knows about migrating one application's user data.
/// Providers are pure data: the backup and restore engine contains no
/// application-specific knowledge.
public struct AppDataProvider: Sendable {
    public var id: String
    public var appName: String
    public var bundleIdentifiers: [String]
    /// Path below the home folder (or `/Library` for `scope == .sharedLibrary`) to the application's data folder.
    public var base: String
    /// Pattern for versioned sub-folders, e.g. `^Adobe Photoshop \d{4}$`.
    public var versionFolderPattern: String?
    public var categories: [AppDataCategory]
    /// The app reads these files at launch and may overwrite them on quit.
    public var mustBeClosed: Bool
    public var status: VerificationStatus
    public var evidence: [Evidence]
    public var researchedOn: String
    /// Short English notes for maintainers (shown in docs, not in the UI).
    public var limitations: [String]
    public var scope: AppDataScope = .home
    /// The installer package (`pkgutil` ID) that ships content into the same folder. Files listed in its
    /// receipt came with the app, so they are left out: the app's installer puts them back on the new Mac.
    public var shippedByPackage: String? = nil
    /// The data is only restored once the app is installed on the new Mac (it lives in the app's own
    /// folders, or its format belongs to the installed version); until then the step waits.
    public var appMustBeInstalled = false
    /// The files carry the app's database version and must not go to an older version of the app.
    public var notForOlderApp = false
}

/// What a backed-up application data folder came from. Stored in the manifest so a
/// restore does not depend on the provider catalogue of the restoring version.
public struct AppDataProfileReference: Codable, Equatable, Hashable, Sendable {
    public var provider: String
    public var appName: String
    public var category: String
    /// The app version folder the data came from, e.g. "Adobe Photoshop 2025".
    public var appVersion: String?
    public var bundleIdentifiers: [String]
    public var mustBeClosed: Bool
    public var classification: DataClassification
    /// The pattern other version folders of the same app match (e.g. `^Adobe Photoshop \d{4}$`); with
    /// `movesBetweenVersions`, the data may be restored into one of them. Nil in backups of earlier versions.
    public var versionFolderPattern: String?
    public var movesBetweenVersions: Bool
    /// The version of the app on the old Mac (for `notForOlderApp`).
    public var sourceAppVersion: String?
    public var appMustBeInstalled: Bool
    public var notForOlderApp: Bool

    public init(provider: String, appName: String, category: String, appVersion: String? = nil, bundleIdentifiers: [String] = [],
                mustBeClosed: Bool = false, classification: DataClassification = .safe, versionFolderPattern: String? = nil,
                movesBetweenVersions: Bool = false, sourceAppVersion: String? = nil, appMustBeInstalled: Bool = false, notForOlderApp: Bool = false) {
        self.sourceAppVersion = sourceAppVersion
        self.appMustBeInstalled = appMustBeInstalled
        self.notForOlderApp = notForOlderApp
        self.provider = provider
        self.appName = appName
        self.category = category
        self.appVersion = appVersion
        self.bundleIdentifiers = bundleIdentifiers
        self.mustBeClosed = mustBeClosed
        self.classification = classification
        self.versionFolderPattern = versionFolderPattern
        self.movesBetweenVersions = movesBetweenVersions
    }

    private enum CodingKeys: String, CodingKey {
        case provider, appName, category, appVersion, bundleIdentifiers, mustBeClosed, classification, versionFolderPattern, movesBetweenVersions
        case sourceAppVersion, appMustBeInstalled, notForOlderApp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        appName = try c.decode(String.self, forKey: .appName)
        category = try c.decode(String.self, forKey: .category)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        bundleIdentifiers = try c.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        mustBeClosed = try c.decodeIfPresent(Bool.self, forKey: .mustBeClosed) ?? false
        classification = try c.decodeIfPresent(DataClassification.self, forKey: .classification) ?? .safe
        versionFolderPattern = try c.decodeIfPresent(String.self, forKey: .versionFolderPattern)
        movesBetweenVersions = try c.decodeIfPresent(Bool.self, forKey: .movesBetweenVersions) ?? false
        sourceAppVersion = try c.decodeIfPresent(String.self, forKey: .sourceAppVersion)
        appMustBeInstalled = try c.decodeIfPresent(Bool.self, forKey: .appMustBeInstalled) ?? false
        notForOlderApp = try c.decodeIfPresent(Bool.self, forKey: .notForOlderApp) ?? false
    }
}

public struct DetectedAppData: Sendable {
    public var profile: AppDataProfileReference
    public var folder: URL
    public var scope: AppDataScope = .home
    /// The installer package whose files are left out (see `AppDataProvider.shippedByPackage`).
    public var shippedByPackage: String?
    /// Only these file names directly inside `folder`, or everything when nil.
    public var files: [String]?
    /// Names that are skipped wherever they occur.
    public var excluding: [String] = []
}

/// Services and apps whose sign-in or data MacReplica deliberately does not move.
public struct MigrationGuidance: Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The account must be signed in again on the new Mac (device-bound or Keychain-held login).
        case reauthenticationRequired
        /// The app has its own export/sync; use it instead of copying files.
        case manualMigration
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Detected when one of these apps is installed …
    public var bundleIdentifiers: [String]
    /// … or one of these paths (below the home folder) exists.
    public var paths: [String]
    public var evidence: [Evidence]
}

/// Manifest entry for a detected service that needs re-authentication or a manual step.
public struct GuidanceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: MigrationGuidance.Kind

    public init(id: String, name: String, kind: MigrationGuidance.Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
