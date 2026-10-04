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

/// How far MacReplica's support for a kind of application data goes. Shown in the backup and restore
/// selection so nobody assumes more than was proven.
public enum DataConfidence: String, Codable, Sendable, CaseIterable {
    /// Backed up, restored, and the result confirmed inside the real application.
    case full
    /// Backed up and restored, checked by checksum; that the app uses it was not confirmed by MacReplica.
    case checkInApp
    /// Locations only from community sources, or the effect in the app is uncertain.
    case experimental
    /// Detected and explained only (guidance), nothing is restored.
    case notSupported

    public init(from decoder: Decoder) throws {
        self = DataConfidence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .checkInApp
    }
}

/// What a location contains, which decides whether it may be migrated automatically.
public enum DataClassification: String, Codable, Sendable {
    /// User-created customization with a stable format: migrated when selected (default on).
    case safe
    /// Useful, but may not work across app versions: offered, default off, with an explanation.
    case compatibilitySensitive
    /// Useful, but user content may contain API keys (e.g. automation workflows): offered, default off, with a warning.
    case mayContainSecrets
    /// Plug-ins, scripts and macros: code that runs inside the app. Offered, default off, with a note.
    case containsCode
    /// Never migrated by a provider (listed for documentation and tests).
    case cache, database, temporary, log, credential

    public var isOffered: Bool { self == .safe || self == .compatibilitySensitive || self == .mayContainSecrets || self == .containsCode }
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
    /// Other names the same folder has on some Macs (e.g. Office's `User Content` vs `User Content.localized`);
    /// the first one that exists is used.
    public var alternatePaths: [String]
    /// Only files whose names match this regular expression, directly inside the folder (instead of `files`).
    public var filePattern: String?
    /// Text files that contain absolute paths in the home folder: the backup stores a placeholder instead of
    /// the old home path, and the restore writes this Mac's home path.
    public var rewritesHomeFolder: Bool

    public init(_ key: String, _ path: String, files: [String]? = nil, excluding: [String] = [], _ classification: DataClassification = .safe,
                movesBetweenVersions: Bool = false, alternatePaths: [String] = [], filePattern: String? = nil, rewritesHomeFolder: Bool = false) {
        self.key = key
        self.path = path
        self.files = files
        self.excluding = excluding
        self.classification = classification
        self.movesBetweenVersions = movesBetweenVersions
        self.alternatePaths = alternatePaths
        self.filePattern = filePattern
        self.rewritesHomeFolder = rewritesHomeFolder
    }
}

/// Where an application keeps the data a provider describes.
public enum AppDataScope: String, Codable, Sendable {
    /// Below the user's home folder (the usual case).
    case home
    /// Below `/Library`, shared by all users of the Mac — e.g. DaVinci Resolve's LUT folder. Only provider
    /// locations are ever read or written there; user-chosen folders are always inside the home folder.
    case sharedLibrary
    /// Below `/Users/Shared` (some vendors keep user-created settings there, e.g. BenQ Palette Master).
    case usersShared
}

/// An app-specific check after the files were restored. The engine stays generic; each case only reads
/// the restored files and reports what the user still has to do.
public enum AppDataVerification: String, Codable, Sendable {
    /// Cryptomator's `settings.json`: every registered vault folder exists and contains its vault file.
    case cryptomatorVaults
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
    /// Categories whose restore was confirmed inside the real application (see docs/VALIDATION_REPORT.md).
    public var verifiedCategories: Set<String> = []
    /// Locations from community sources only, or the app's use of the restored data is uncertain.
    public var experimental = false
    /// The data is in a location macOS protects (Mail, other developers' app containers): reading and
    /// writing it needs Full Disk Access for MacReplica.
    public var requiresFullDiskAccess = false
    public var verification: AppDataVerification? = nil
    /// Other names of `base` on some Macs; the first existing one is used.
    public var alternateBases: [String] = []

    public func confidence(of category: String) -> DataConfidence {
        if verifiedCategories.contains(category) { return .full }
        return experimental ? .experimental : .checkInApp
    }
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
    /// Nil in backups of earlier versions (shown as "check in the app").
    public var confidence: DataConfidence?
    public var requiresFullDiskAccess: Bool = false
    public var verification: AppDataVerification? = nil

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
        case sourceAppVersion, appMustBeInstalled, notForOlderApp, confidence, requiresFullDiskAccess, verification
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
        confidence = try c.decodeIfPresent(DataConfidence.self, forKey: .confidence)
        requiresFullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .requiresFullDiskAccess) ?? false
        verification = try? c.decodeIfPresent(AppDataVerification.self, forKey: .verification)
    }

    public var effectiveConfidence: DataConfidence { confidence ?? .checkInApp }
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
    public var rewritesHomeFolder = false
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
    /// … or an app with one of these names is installed (for apps whose bundle identifier is not documented).
    public var appNames: [String] = []
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

    /// The name this version of MacReplica uses for the service (a backup keeps the name of the version that made it).
    public var currentName: String { GuidanceCatalog.entries.first { $0.id == id }?.name ?? name }
}
