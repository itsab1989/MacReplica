import Foundation

/// The groups the user can switch on or off before restoring.
public enum RestoreComponent: String, Codable, Sendable, CaseIterable, Identifiable {
    case applications
    case brewFormulae
    case brewCasks
    case appStore
    case python
    case developerSettings
    case applicationData
    case fonts
    case colorProfiles
    /// Encrypted credentials; only restored when the user switches this on.
    case credentials

    public var id: String { rawValue }

    /// Everything except credentials, which always need an explicit choice.
    public static let defaultSelection: Set<RestoreComponent> = Set(allCases).subtracting([.credentials])
}

public enum RestoreItemKind: String, Codable, Sendable {
    case commandLineTools
    case homebrew
    case tap
    case masTool
    case formula
    case cask
    case appStoreApp
    case font
    case colorProfile
    case pythonEnvironment
    case applicationData
    case gitConfiguration
    case credential

    /// Rough relative duration, used to estimate the remaining time before real timings exist.
    var weight: Double {
        switch self {
        case .commandLineTools: return 300
        case .homebrew: return 120
        case .tap: return 10
        case .masTool: return 20
        case .formula: return 30
        case .cask: return 60
        case .appStoreApp: return 60
        case .font, .colorProfile: return 0.3
        case .pythonEnvironment: return 90
        case .applicationData: return 5
        case .gitConfiguration, .credential: return 1
        }
    }

    public var isFile: Bool { self == .font || self == .colorProfile }

    var logComponent: LogStore.Component {
        switch self {
        case .commandLineTools, .homebrew, .tap, .formula, .cask: return .homebrew
        case .masTool, .appStoreApp: return .appStore
        case .font, .colorProfile: return .restore
        case .pythonEnvironment: return .python
        case .applicationData, .gitConfiguration: return .applicationData
        case .credential: return .permissions
        }
    }
}

/// One step of a restore.
public struct RestoreItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable identifier such as `cask:example-editor` or `font:user/Example.otf`; used for resuming.
    public var id: String
    public var kind: RestoreItemKind
    /// Human-readable name (an app or file name, never translated).
    public var title: String
    /// The technical identifier: cask token, formula name, tap name or App Store ID.
    public var identifier: String
    public var originalVersion: String?
    public var bundleIdentifier: String?
    /// `.app` names expected after installation, for verification.
    public var appBundleNames: [String]
    public var tapRemote: String?
    public var file: FileRecord?
    public var architectures: [CPUArchitecture]
    public var dependsOn: [String]
    public var component: RestoreComponent?
    public var pythonEnvironment: PythonEnvironment?
    public var applicationData: AppDataFolder?
    /// Sanitized Git configuration to write to `~/.gitconfig`.
    public var gitConfig: String?

    public init(id: String, kind: RestoreItemKind, title: String, identifier: String, originalVersion: String? = nil,
                bundleIdentifier: String? = nil, appBundleNames: [String] = [], tapRemote: String? = nil, file: FileRecord? = nil,
                architectures: [CPUArchitecture] = [], dependsOn: [String] = [], component: RestoreComponent? = nil,
                pythonEnvironment: PythonEnvironment? = nil, applicationData: AppDataFolder? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.identifier = identifier
        self.originalVersion = originalVersion
        self.bundleIdentifier = bundleIdentifier
        self.appBundleNames = appBundleNames
        self.tapRemote = tapRemote
        self.file = file
        self.architectures = architectures
        self.dependsOn = dependsOn
        self.component = component
        self.pythonEnvironment = pythonEnvironment
        self.applicationData = applicationData
    }

    public static let commandLineToolsID = "prerequisite:command-line-tools"
    public static let homebrewID = "prerequisite:homebrew"
    public static let masToolID = "prerequisite:mas"
}

/// What to do when a font or profile already exists with different content.
public enum ConflictResolution: String, Codable, Sendable, CaseIterable {
    /// Leave the existing file untouched and do not restore the backup copy.
    case keepExisting
    /// Put the existing file aside in MacReplica's folder, then restore the backup copy.
    case replace
    /// Do not process this file at all.
    case skip
}

/// Everything the user chose on the restore screen.
public struct RestoreSelection: Codable, Equatable, Sendable {
    public var components: Set<RestoreComponent>
    /// Items the user unticked individually.
    public var excludedItemIDs: Set<String>
    /// Third-party taps the user explicitly allowed.
    public var enabledTaps: Set<String>
    /// For apps with several possible Homebrew packages: app path → chosen cask token
    /// (an empty string means "none of these").
    public var matchDecisions: [String: String]
    /// Default for conflicts; per-file choices override it.
    public var conflictResolution: ConflictResolution
    public var conflictOverrides: [String: ConflictResolution]

    public init(components: Set<RestoreComponent> = RestoreComponent.defaultSelection, excludedItemIDs: Set<String> = [],
                enabledTaps: Set<String> = [], matchDecisions: [String: String] = [:],
                conflictResolution: ConflictResolution = .keepExisting, conflictOverrides: [String: ConflictResolution] = [:]) {
        self.components = components
        self.excludedItemIDs = excludedItemIDs
        self.enabledTaps = enabledTaps
        self.matchDecisions = matchDecisions
        self.conflictResolution = conflictResolution
        self.conflictOverrides = conflictOverrides
    }

    public func resolution(for itemID: String) -> ConflictResolution {
        conflictOverrides[itemID] ?? conflictResolution
    }
}

/// Why something went wrong, in categories that map to friendly explanations.
public enum FailureCategory: String, Codable, Sendable, CaseIterable {
    case network
    case appStoreNotSignedIn
    case packageNotFound
    case adminRightsDenied
    case appAlreadyExists
    case incompatible
    case diskFull
    case verificationFailed
    case backupFileDamaged
    case homebrewUnavailable
    case homebrewBroken
    case commandLineToolsUnavailable
    case masUnavailable
    case pythonVersionUnavailable
    case pythonPackagesIncomplete
    case pythonEnvironmentConflict
    case credentialCannotBeOpened
    case timeout
    case cancelled
    case unknown
}

public struct RestoreFailure: Codable, Equatable, Sendable {
    public var category: FailureCategory
    /// Redacted technical detail (last lines of tool output) for the log and the details view.
    public var technicalDetail: String

    public init(category: FailureCategory, technicalDetail: String = "") {
        self.category = category
        self.technicalDetail = technicalDetail
    }
}

public enum SkipReason: Codable, Equatable, Sendable {
    case keptExisting
    case userSkipped
    case dependencyFailed(itemTitle: String)
    case tapNotEnabled(tap: String)
    case incompatibleArchitecture(required: [CPUArchitecture])
    case projectFolderMissing(path: String)
    case passphraseNotProvided
    case cancelled
}

public enum ItemOutcome: Codable, Equatable, Sendable {
    case succeeded
    case alreadyPresent
    case skipped(SkipReason)
    case failed(RestoreFailure)

    public var isSuccessLike: Bool {
        switch self {
        case .succeeded, .alreadyPresent: return true
        default: return false
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isSkip: Bool {
        if case .skipped = self { return true }
        return false
    }
}

public struct ItemResult: Codable, Equatable, Sendable {
    public var itemID: String
    public var outcome: ItemOutcome
    public var installedVersion: String?
    public var finishedAt: Date
    public var duration: TimeInterval
    /// Extra facts worth telling the user, e.g. a newer version was installed.
    public var notes: [ResultNote]

    public init(itemID: String, outcome: ItemOutcome, installedVersion: String? = nil, finishedAt: Date = Date(),
                duration: TimeInterval = 0, notes: [ResultNote] = []) {
        self.itemID = itemID
        self.outcome = outcome
        self.installedVersion = installedVersion
        self.finishedAt = finishedAt
        self.duration = duration
        self.notes = notes
    }
}

public enum ResultNote: Codable, Equatable, Sendable {
    case newerVersionInstalled(original: String, installed: String)
    case requiresRosetta
    case existingFileMovedAside(path: String)
    case identicalFileExists
    /// Packages installed from local folders or repositories must be reinstalled by hand.
    case pythonPackagesNeedManualSetup(names: [String])
    /// Exact versions were not available; current compatible versions were installed.
    case pythonPackagesUpdated(count: Int)
    /// An environment already existed and only missing packages were added.
    case pythonEnvironmentReused
    case pythonSettingsToApply(count: Int)
    case applicationDataCopied(copied: Int, identical: Int, kept: Int)
    /// Data was restored into the folder of a different app version than the one installed.
    case applicationVersionDiffers(original: String)
}

public struct RestoreSummary: Equatable, Sendable {
    public var succeeded: Int
    public var failed: Int
    public var skipped: Int
    public var total: Int

    public init(results: [ItemResult], total: Int) {
        succeeded = results.filter { $0.outcome.isSuccessLike }.count
        failed = results.filter { $0.outcome.isFailure }.count
        skipped = results.filter { $0.outcome.isSkip }.count
        self.total = total
    }
}
