import Foundation

/// The groups the user can switch on or off before restoring.
public enum RestoreComponent: String, Codable, Sendable, CaseIterable, Identifiable {
    case applications
    case brewFormulae
    case brewCasks
    case appStore
    case python
    /// Version managers, language runtimes and global tools (Node.js, Ruby, Rust, Go, Java, .NET, Python tools).
    case developerTools
    /// Package managers besides Homebrew (MacPorts, Nix, Pixi, mise, asdf).
    case packageManagers
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
    /// A runtime, global package or environment of a version or package manager.
    case toolchainStep
    /// An application without automatic installation: guided download and installation.
    case manualApp
    /// A profile assigned to a display on the old Mac, assigned again here.
    case displayProfile

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
        case .toolchainStep: return 60
        case .manualApp, .displayProfile: return 1
        }
    }

    public var isFile: Bool { self == .font || self == .colorProfile }

    public var logComponent: LogStore.Component {
        switch self {
        case .commandLineTools, .homebrew, .tap, .formula, .cask: return .homebrew
        case .masTool, .appStoreApp: return .appStore
        case .font, .colorProfile: return .restore
        case .pythonEnvironment: return .python
        case .applicationData, .gitConfiguration: return .applicationData
        case .credential: return .permissions
        case .toolchainStep: return .developerTools
        case .manualApp: return .downloads
        case .displayProfile: return .restore
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
    /// For `toolchainStep`: what to do with which version or package manager.
    public var toolchain: ToolchainAction?
    /// For `manualApp` and guided App Store installs: the application as recorded on the old Mac.
    public var app: AppRecord?
    /// For `displayProfile`: the assignment and the keys to recognise the display.
    public var displayAssignment: DisplayProfileAssignment?
    public var hardwareKeys: HardwareKeys?

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
    /// Leave the existing file untouched and install the backup copy next to it under a new name.
    case keepBoth
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
    /// Where an item should come from when there are several sources: a download offer ID for
    /// guided installs, or `stable` for a Homebrew formula that was a development (HEAD) build.
    public var sourceChoices: [String: String]

    public init(components: Set<RestoreComponent> = RestoreComponent.defaultSelection, excludedItemIDs: Set<String> = [],
                enabledTaps: Set<String> = [], matchDecisions: [String: String] = [:],
                conflictResolution: ConflictResolution = .keepExisting, conflictOverrides: [String: ConflictResolution] = [:],
                sourceChoices: [String: String] = [:]) {
        self.components = components
        self.excludedItemIDs = excludedItemIDs
        self.enabledTaps = enabledTaps
        self.matchDecisions = matchDecisions
        self.conflictResolution = conflictResolution
        self.conflictOverrides = conflictOverrides
        self.sourceChoices = sourceChoices
    }

    private enum CodingKeys: String, CodingKey {
        case components, excludedItemIDs, enabledTaps, matchDecisions, conflictResolution, conflictOverrides, sourceChoices
    }

    // Sessions saved by earlier versions lack newer fields; they are read with defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        components = Set((try c.decodeIfPresent(LenientList<RestoreComponent>.self, forKey: .components)?.elements) ?? Array(RestoreComponent.defaultSelection))
        excludedItemIDs = try c.decodeIfPresent(Set<String>.self, forKey: .excludedItemIDs) ?? []
        enabledTaps = try c.decodeIfPresent(Set<String>.self, forKey: .enabledTaps) ?? []
        matchDecisions = try c.decodeIfPresent([String: String].self, forKey: .matchDecisions) ?? [:]
        conflictResolution = try c.decodeIfPresent(ConflictResolution.self, forKey: .conflictResolution) ?? .keepExisting
        conflictOverrides = try c.decodeIfPresent([String: ConflictResolution].self, forKey: .conflictOverrides) ?? [:]
        sourceChoices = try c.decodeIfPresent([String: String].self, forKey: .sourceChoices) ?? [:]
    }

    /// True if a Homebrew development (HEAD) build should be installed as such.
    public func installsHead(_ item: RestoreItem) -> Bool {
        item.kind == .formula && (item.originalVersion?.hasPrefix("HEAD") ?? false) && sourceChoices[item.id] != "stable"
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
    case applicationRunning
    /// A folder MacReplica must write to does not allow it.
    case permissionDenied
    /// The version or package manager a step needs is not installed.
    case toolUnavailable
    /// A download did not pass verification (checksum, signature, vendor).
    case downloadNotTrusted
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
    /// macOS on this Mac cannot read the font or profile.
    case fileNotSupported
    /// A profile macOS generated for a display of the old Mac; macOS creates its own for this Mac.
    case displaySpecificProfile
    case cancelled
    /// A guided step: the user performs it (install from the App Store, a vendor download, a command
    /// MacReplica cannot run), then MacReplica checks the result.
    case manualStepRequired
    /// Waits for a guided step it depends on.
    case waitingForManualStep(itemTitle: String)
    /// The user chose to do this later.
    case postponedByUser
    /// The user cancelled an installation that was in progress (not a technical failure).
    case cancelledByUser
    /// The display is not connected; it is assigned when it is (or in System Settings).
    case displayNotConnected(name: String)
    /// The profile belonged to the built-in display of the Mac the backup was made on.
    case displayOfAnotherMac
    /// The assigned profile is neither in the backup nor on this Mac.
    case profileNotAvailable
    /// The data belongs to an app that is not installed on this Mac yet; offered again when the restore continues.
    case applicationNotInstalled(name: String)
    /// The app on this Mac is older than the one the data came from; its files could not be read by it.
    case applicationVersionOlder(name: String, installed: String, backup: String)
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

    /// Steps that still wait for the user: they are offered again when the restore continues.
    public var isOpen: Bool {
        guard case .skipped(let reason) = self else { return false }
        switch reason {
        case .manualStepRequired, .waitingForManualStep, .postponedByUser, .cancelledByUser, .displayNotConnected,
             .applicationNotInstalled, .applicationVersionOlder: return true
        default: return false
        }
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
    /// The same font or profile is already installed (same identity and version), possibly under another file name.
    case equivalentFileInstalled
    /// macOS provides this font or profile itself; its own version was kept.
    case providedByMacOS
    /// The backup copy was installed next to an existing file with the same name.
    case installedUnderNewName(name: String)
    /// Packages installed from local folders or repositories must be reinstalled by hand.
    case pythonPackagesNeedManualSetup(names: [String])
    /// Exact versions were not available; current compatible versions were installed.
    case pythonPackagesUpdated(count: Int)
    /// An environment already existed and only missing packages were added.
    case pythonEnvironmentReused
    /// The environment was rebuilt exactly from the project's lock file.
    case pythonLockFileUsed(file: String)
    /// The saved copy of the environment was restored and verified by running it.
    case pythonEnvironmentPreserved
    /// The saved copy could not be used; the environment was rebuilt from its packages instead.
    case pythonPreservationNotUsed(reason: PythonPreservationProblem)
    case pythonSettingsToApply(count: Int)
    case applicationDataCopied(copied: Int, identical: Int, kept: Int)
    /// Data was restored into the folder of a different app version than the one installed.
    case applicationVersionDiffers(original: String)
    /// The app version of the backup is not on this Mac; the data went into another installed version.
    case restoredIntoVersion(original: String, target: String)
}

public struct RestoreSummary: Equatable, Sendable {
    public var succeeded: Int
    public var failed: Int
    public var skipped: Int
    /// Guided, postponed or cancelled steps that are still open.
    public var waiting: Int
    public var total: Int

    public init(results: [ItemResult], total: Int) {
        succeeded = results.filter { $0.outcome.isSuccessLike }.count
        failed = results.filter { $0.outcome.isFailure }.count
        waiting = results.filter { $0.outcome.isOpen }.count
        skipped = results.filter { $0.outcome.isSkip && !$0.outcome.isOpen }.count
        self.total = total
    }
}

extension ItemResult {
    /// A language-independent decision code for logs and reports, e.g. `conflict_kept_destination`.
    public var decisionCode: String {
        switch outcome {
        case .succeeded:
            if notes.contains(where: { if case .installedUnderNewName = $0 { return true }; return false }) { return "conflict_kept_both" }
            return notes.contains { if case .existingFileMovedAside = $0 { return true }; return false } ? "conflict_restored_backup" : "restored"
        case .alreadyPresent:
            if notes.contains(.identicalFileExists) { return "identical_existing" }
            if notes.contains(.equivalentFileInstalled) { return "equivalent_existing" }
            if notes.contains(.providedByMacOS) { return "kept_macos_version" }
            return "already_present"
        case .skipped(let reason):
            switch reason {
            case .keptExisting: return "conflict_kept_destination"
            case .userSkipped: return "skipped_by_user"
            case .fileNotSupported, .incompatibleArchitecture, .displaySpecificProfile, .displayOfAnotherMac: return "incompatible"
            case .projectFolderMissing, .passphraseNotProvided, .manualStepRequired, .waitingForManualStep, .displayNotConnected,
                 .profileNotAvailable, .applicationNotInstalled, .applicationVersionOlder: return "manual_action_required"
            case .postponedByUser: return "postponed_by_user"
            case .cancelledByUser: return "cancelled_by_user"
            default: return "skipped"
            }
        case .failed: return "failed"
        }
    }
}
