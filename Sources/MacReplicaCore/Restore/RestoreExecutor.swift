import Foundation

/// What a step is doing right now, for the progress screen.
public enum RestoreActivity: String, Sendable, Equatable {
    case checking
    case downloading
    case installing
    case copying
    case verifying
    case waitingForCommandLineTools
    case waitingForAdmin
    case creatingEnvironment
    case installingPackages
}

public enum RestoreEvent: Sendable {
    case started(item: RestoreItem, index: Int, total: Int)
    case activity(itemID: String, RestoreActivity)
    case finished(item: RestoreItem, result: ItemResult, index: Int, total: Int)
    case completed(RestoreSummary)
}

/// Everything the restore needs from the outside world. Tests and the simulation
/// environment pass sandboxed implementations.
public struct RestoreEnvironment: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var privileged: PrivilegedExecuting
    public var homebrewSource: HomebrewPackageSource
    public var localizer: Localizer
    public var log: LogStore
    public var targetArchitecture: CPUArchitecture
    public var rosettaInstalled: Bool
    /// Path of the bundled helper that asks for the administrator password when a cask needs it.
    public var askpassPath: String?
    public var commandLineToolsPollInterval: TimeInterval
    public var commandLineToolsTimeout: TimeInterval
    /// Passphrase for encrypted credentials, entered by the user for this restore only. Never stored or logged.
    public var credentialPassphrase: String?
    /// Reports whether an app with this bundle identifier is running. Providers whose
    /// app must be closed are not restored while it runs.
    public var isApplicationRunning: @Sendable (String) -> Bool = { _ in false }

    public init(layout: SystemLayout, runner: CommandRunning, privileged: PrivilegedExecuting, homebrewSource: HomebrewPackageSource,
                localizer: Localizer, log: LogStore, targetArchitecture: CPUArchitecture = SystemInfo.currentArchitecture,
                rosettaInstalled: Bool? = nil, askpassPath: String? = nil,
                commandLineToolsPollInterval: TimeInterval = 5, commandLineToolsTimeout: TimeInterval = 3600) {
        self.layout = layout
        self.runner = runner
        self.privileged = privileged
        self.homebrewSource = homebrewSource
        self.localizer = localizer
        self.log = log
        self.targetArchitecture = targetArchitecture
        self.rosettaInstalled = rosettaInstalled ?? FileManager.default.fileExists(atPath: layout.rosettaMarker)
        self.askpassPath = askpassPath
        self.commandLineToolsPollInterval = commandLineToolsPollInterval
        self.commandLineToolsTimeout = commandLineToolsTimeout
    }

    var homebrew: HomebrewClient { HomebrewClient(layout: layout, runner: runner) }
    var mas: MASClient { MASClient(layout: layout, runner: runner) }

    var askpassEnvironment: [String: String] {
        ["MACREPLICA_ASKPASS_TITLE": localizer.t("askpass.title"),
         "MACREPLICA_ASKPASS_MESSAGE": localizer.t("askpass.message"),
         "MACREPLICA_ASKPASS_OK": localizer.t("askpass.ok"),
         "MACREPLICA_ASKPASS_CANCEL": localizer.t("common.cancel")]
    }
}

/// The predicted effect of a step, used by the dry run and to skip work that is already done.
public enum Prediction: Equatable, Sendable {
    case willInstall
    case willCopy
    case alreadyPresent(version: String?)
    case identicalFileExists
    /// The same font or profile is installed under another name or in an equal version.
    case equivalentFileExists
    /// macOS already provides this font or profile; its own version is kept.
    case keepsMacOSVersion
    case conflict(resolution: ConflictResolution)
    case willSkip(SkipReason)
    case backupFileDamaged
    /// Depends on an earlier step (e.g. Homebrew is not installed yet), so it cannot be checked in advance.
    case dependsOnEarlierStep
    /// A Python environment will be created from scratch.
    case willRecreateEnvironment
    /// A compatible environment exists; missing packages will be added to it.
    case willCompleteEnvironment
    /// Something else already exists where the environment belongs; it is not touched.
    case environmentConflict
    /// A Homebrew package; looked up only in the full dry run and during the restore.
    case checkedWhenRestoring
    /// The user performs this step (App Store, vendor download, a command MacReplica cannot run);
    /// MacReplica guides and verifies it.
    case manualStep
}

public struct DryRunEntry: Equatable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: RestoreItem
    public var prediction: Prediction
    public var requiresAdmin: Bool
    public var notes: [ResultNote]
    /// For fonts and profiles: how the backup copy relates to what this Mac has.
    public var fileAssessment: FileAssessment?
}

extension RestoreSelection {
    /// Items that should start deselected on this Mac according to a destination check: fonts and
    /// profiles that cannot be read here, legacy formats, Apple profiles this macOS no longer ships and
    /// display profiles of the old Mac. Everything else that was backed up stays selected.
    public static func notRecommended(_ entries: [DryRunEntry]) -> Set<String> {
        Set(entries.filter { $0.fileAssessment.map { !$0.selectedByDefault } ?? false }.map(\.item.id))
    }
}

/// Read-only checks shared by the dry run and the real restore.
struct Inspector: Sendable {
    let environment: RestoreEnvironment
    let backupRoot: URL
    let selection: RestoreSelection
    let damagedFiles: Set<String>
    /// False for the quick check of the restore selection: Homebrew packages are not looked up one by one.
    var checkPackages = true
    let fileIndexes = FileIndexes()

    var layout: SystemLayout { environment.layout }

    /// The destination's fonts and profiles, read on first use and kept up to date during a run.
    final class FileIndexes: @unchecked Sendable {
        private let lock = NSLock()
        private var indexes: [BackupFileKind: DestinationFileIndex] = [:]

        func index(_ kind: BackupFileKind, layout: SystemLayout) -> DestinationFileIndex {
            if let index = lock.withLock({ indexes[kind] }) { return index }
            let index = DestinationFileIndex.build(kind: kind, layout: layout)
            lock.withLock { indexes[kind] = index }
            return index
        }
    }

    func architectureSkip(_ item: RestoreItem) -> SkipReason? {
        guard !item.architectures.isEmpty, environment.targetArchitecture != .unknown else { return nil }
        if environment.targetArchitecture == .x86_64, !item.architectures.contains(.x86_64) {
            return .incompatibleArchitecture(required: item.architectures)
        }
        return nil
    }

    func notes(for item: RestoreItem) -> [ResultNote] {
        if environment.targetArchitecture == .arm64, !item.architectures.isEmpty, !item.architectures.contains(.arm64) {
            return [.requiresRosetta]
        }
        return []
    }

    /// The installed `.app` matching the item, checked by bundle name and, when known, bundle identifier.
    func installedApp(for item: RestoreItem) -> URL? {
        for folder in layout.applicationFolders {
            for name in item.appBundleNames {
                guard PathSafety.isSafeRelativePath(name), !name.contains("/") else { continue }
                let url = folder.appendingPathComponent(name)
                guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { continue }
                if let expected = item.bundleIdentifier {
                    if (info["CFBundleIdentifier"] as? String)?.lowercased() == expected.lowercased() { return url }
                } else {
                    return url
                }
            }
            // Without a known bundle name, search by bundle identifier.
            if item.appBundleNames.isEmpty, let expected = item.bundleIdentifier?.lowercased(),
               let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for url in items where url.pathExtension == "app" {
                    let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                    if (info?["CFBundleIdentifier"] as? String)?.lowercased() == expected { return url }
                }
            }
        }
        return nil
    }

    func installedVersion(ofApp url: URL) -> String? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    func commandLineToolsInstalled() async -> Bool {
        guard layout.commandLineToolsMarkers.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return false }
        let result = try? await environment.runner.run(Command(
            executable: layout.xcodeSelect, arguments: ["-p"],
            environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 30))
        return result?.succeeded == true
    }

    struct FileTargets {
        var source: URL
        var destination: URL
        var base: URL
    }

    func fileTargets(_ item: RestoreItem) -> FileTargets? {
        guard let record = item.file,
              let source = PathSafety.resolve(record.backupPath, inside: backupRoot) else { return nil }
        let base = layout.baseFolder(for: item.kind == .font ? .font : .colorProfile, domain: record.domain)
        guard let destination = PathSafety.resolve(record.relativePath, inside: base) else { return nil }
        return FileTargets(source: source, destination: destination, base: base)
    }

    /// True if writing to the destination folder needs administrator rights.
    func fileNeedsAdmin(_ targets: FileTargets) -> Bool {
        var folder = targets.destination.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            folder.deleteLastPathComponent()
        }
        return !FileManager.default.isWritableFile(atPath: folder.path)
    }

    static func fileKind(_ item: RestoreItem) -> BackupFileKind { item.kind == .font ? .font : .colorProfile }

    /// Compares the backup copy with the fonts or profiles on this Mac; nil if the backup copy is missing or damaged.
    func assessFile(_ item: RestoreItem) -> FileConflictAnalyzer.Result? {
        guard let record = item.file, let targets = fileTargets(item), !damagedFiles.contains(record.backupPath),
              FileManager.default.fileExists(atPath: targets.source.path) else { return nil }
        let kind = Self.fileKind(item)
        return FileConflictAnalyzer(index: fileIndexes.index(kind, layout: layout))
            .assess(record: record, kind: kind, source: targets.source, destination: targets.destination,
                    destinationLocation: record.domain == .user ? .user : .shared)
    }

    func predictFile(_ item: RestoreItem) -> Prediction {
        guard let result = assessFile(item) else { return .backupFileDamaged }
        return Self.prediction(for: result.assessment, item: item, selection: selection)
    }

    /// The same mapping is used by the restore selection, the dry run and the restore.
    static func prediction(for assessment: FileAssessment, item: RestoreItem, selection: RestoreSelection) -> Prediction {
        switch assessment.status {
        case .identical: return .identicalFileExists
        case .equivalent: return .equivalentFileExists
        // macOS's own version is preferred; the backup copy is only added if the user asked for it.
        case .providedByMacOS: return selection.conflictOverrides[item.id] == .replace ? .willCopy : .keepsMacOSVersion
        case .differentVersion, .differentFile:
            let allowed = assessment.conflictChoices(kind: item.kind)
            // A per-item choice wins; a non-default general choice applies where it is allowed;
            // otherwise the safe default for this kind of conflict.
            let chosen = selection.conflictOverrides[item.id].flatMap { allowed.contains($0) ? $0 : nil }
            let general = selection.conflictResolution != .keepExisting && allowed.contains(selection.conflictResolution)
                ? selection.conflictResolution : nil
            return .conflict(resolution: chosen ?? general ?? assessment.defaultResolution(kind: item.kind))
        case .incompatible: return .willSkip(.fileNotSupported)
        case .displayProfile: return .willSkip(.displaySpecificProfile)
        case .ready, .obsoleteAppleProfile, .legacyFormat: return .willCopy
        }
    }

    func predict(_ item: RestoreItem, brew: HomebrewInstallation?, taps: Set<String>?) async -> Prediction {
        switch item.kind {
        case .commandLineTools:
            return await commandLineToolsInstalled() ? .alreadyPresent(version: nil) : .willInstall
        case .homebrew:
            if let brew { return .alreadyPresent(version: brew.version) }
            return .willInstall
        case .tap where !checkPackages, .formula where !checkPackages:
            if item.kind == .tap, !selection.enabledTaps.contains(item.identifier.lowercased()) { return .willSkip(.tapNotEnabled(tap: item.identifier)) }
            return .checkedWhenRestoring
        case .cask where !checkPackages:
            if let reason = architectureSkip(item) { return .willSkip(reason) }
            if let app = installedApp(for: item) { return .alreadyPresent(version: installedVersion(ofApp: app)) }
            return .checkedWhenRestoring
        case .tap:
            if !selection.enabledTaps.contains(item.identifier.lowercased()) && !selection.enabledTaps.contains(item.identifier) {
                return .willSkip(.tapNotEnabled(tap: item.identifier))
            }
            guard let taps else { return .dependsOnEarlierStep }
            return taps.contains(item.identifier.lowercased()) ? .alreadyPresent(version: nil) : .willInstall
        case .masTool:
            if environment.mas.locate() != nil { return .alreadyPresent(version: nil) }
            return brew == nil ? .dependsOnEarlierStep : .willInstall
        case .formula:
            guard let brew else { return .dependsOnEarlierStep }
            if let version = try? await environment.homebrew.installedFormulaVersion(brew, name: item.identifier) {
                return .alreadyPresent(version: version)
            }
            return .willInstall
        case .cask:
            if let reason = architectureSkip(item) { return .willSkip(reason) }
            if let brew, let version = try? await environment.homebrew.installedCaskVersion(brew, token: item.identifier) {
                return .alreadyPresent(version: version)
            }
            if let app = installedApp(for: item) { return .alreadyPresent(version: installedVersion(ofApp: app)) }
            return brew == nil ? .dependsOnEarlierStep : .willInstall
        case .appStoreApp:
            if let reason = architectureSkip(item) { return .willSkip(reason) }
            if let app = installedApp(for: item), item.bundleIdentifier != nil || !item.appBundleNames.isEmpty {
                return .alreadyPresent(version: installedVersion(ofApp: app))
            }
            // `mas install` needs root since mas 7; the user installs from the App Store page MacReplica opens.
            return .manualStep
        case .font, .colorProfile:
            return predictFile(item)
        case .pythonEnvironment:
            return predictPython(item, brew: brew)
        case .applicationData:
            return predictApplicationData(item)
        case .gitConfiguration:
            return predictGitConfiguration(item)
        case .credential:
            return environment.credentialPassphrase == nil ? .willSkip(.passphraseNotProvided) : .willCopy
        case .toolchainStep:
            return predictToolchain(item)
        case .manualApp:
            if let app = installedApp(for: item) { return .alreadyPresent(version: installedVersion(ofApp: app)) }
            return .manualStep
        }
    }
}

/// Runs a restore plan step by step.
///
/// A failing step never stops the restore: it is recorded with a reason, steps
/// that depend on it are skipped, and everything else continues. The session is
/// saved after every step for resuming.
public final class RestoreExecutor: Sendable {
    public let environment: RestoreEnvironment
    public let backupRoot: URL
    public let sessionStore: SessionStore?
    private let damagedFiles: Set<String>

    public init(environment: RestoreEnvironment, backupRoot: URL, sessionStore: SessionStore?, damagedFiles: Set<String> = []) {
        self.environment = environment
        self.backupRoot = backupRoot
        self.sessionStore = sessionStore
        self.damagedFiles = damagedFiles
    }

    var layout: SystemLayout { environment.layout }
    var log: LogStore { environment.log }

    // MARK: Dry run

    /// What restoring a font or profile does with `selection`; the same rule the restore applies.
    public static func filePrediction(for assessment: FileAssessment, item: RestoreItem, selection: RestoreSelection) -> Prediction {
        Inspector.prediction(for: assessment, item: item, selection: selection)
    }

    /// Describes what a restore would do. Only read-only checks are performed.
    /// With `checkPackages` false, Homebrew packages are not looked up one by one (used for the quick
    /// check behind the restore selection); everything else is checked exactly as in the restore.
    public func dryRun(plan: RestorePlan, selection: RestoreSelection, checkPackages: Bool = true) async -> [DryRunEntry] {
        var inspector = Inspector(environment: environment, backupRoot: backupRoot, selection: selection, damagedFiles: damagedFiles)
        inspector.checkPackages = checkPackages
        let brew = await environment.homebrew.locate().installation
        let taps: Set<String>? = brew == nil || !checkPackages ? nil : ((try? await environment.homebrew.installedTaps(brew!)) ?? [])
        var entries: [DryRunEntry] = []
        var blocked = Set<String>()
        var guided = Set<String>()
        for item in plan.items {
            var prediction = await inspector.predict(item, brew: brew, taps: taps)
            if let dependency = item.dependsOn.first(where: { blocked.contains($0) }) {
                if case .alreadyPresent = prediction {} else {
                    prediction = .willSkip(.dependencyFailed(itemTitle: plan.item(id: dependency)?.title ?? dependency))
                }
            }
            if case .willSkip = prediction { blocked.insert(item.id) }
            // A step that needs a guided step first can only be checked after the user did it.
            if item.dependsOn.contains(where: { guided.contains($0) }) {
                if case .alreadyPresent = prediction {} else { prediction = .dependsOnEarlierStep }
            }
            if prediction == .manualStep || item.dependsOn.contains(where: { guided.contains($0) }) { guided.insert(item.id) }
            var requiresAdmin = false
            if item.kind == .homebrew, prediction == .willInstall { requiresAdmin = true }
            if item.kind.isFile, let targets = inspector.fileTargets(item) {
                switch prediction {
                case .willCopy, .conflict(.replace): requiresAdmin = inspector.fileNeedsAdmin(targets)
                default: break
                }
            }
            let assessment = item.kind.isFile ? inspector.assessFile(item)?.assessment : nil
            entries.append(DryRunEntry(item: item, prediction: prediction, requiresAdmin: requiresAdmin, notes: inspector.notes(for: item),
                                       fileAssessment: assessment))
        }
        return entries
    }

    // MARK: Restore

    /// Runs the remaining steps of `session`. Steps that already have a result are not run again.
    @discardableResult
    public func run(plan: RestorePlan, session initial: RestoreSession,
                    onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> RestoreSession {
        var session = initial
        let inspector = Inspector(environment: environment, backupRoot: backupRoot, selection: session.selection, damagedFiles: damagedFiles)
        var context = RunContext()
        context.brew = await environment.homebrew.locate().installation
        prepareToolchains(plan: plan, context: &context)
        let total = plan.items.count
        log.info("Restore session \(session.id): \(total) steps, \(session.finishedItemIDs.count) already finished", component: .restore)
        persist(&session)

        for (index, item) in plan.items.enumerated() {
            // Finished steps are not repeated; steps that wait for the user are checked again.
            if let previous = session.results[item.id], !previous.outcome.isOpen { continue }
            if Task.isCancelled {
                log.warning("Restore cancelled before \(item.id)", component: .restore)
                break
            }
            session.currentItemID = item.id
            persist(&session)
            onEvent(.started(item: item, index: index, total: total))

            let started = Date()
            var result: ItemResult
            if let blocker = item.dependsOn.first(where: { id in
                guard let dependency = session.results[id] else { return false }
                return !dependency.outcome.isSuccessLike
            }) {
                // Something that is already installed stays "already present", even if a
                // prerequisite is missing; this matches what the dry run reports.
                let title = plan.item(id: blocker)?.title ?? blocker
                if case .alreadyPresent(let version) = await inspector.predict(item, brew: context.brew, taps: nil) {
                    result = ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)
                } else if session.results[blocker]?.outcome.isOpen == true {
                    // The prerequisite waits for the user, so this step waits as well.
                    result = ItemResult(itemID: item.id, outcome: .skipped(.waitingForManualStep(itemTitle: title)))
                } else {
                    result = ItemResult(itemID: item.id, outcome: .skipped(.dependencyFailed(itemTitle: title)))
                }
            } else {
                result = await perform(item, inspector: inspector, context: &context, plan: plan, session: session, onEvent: onEvent)
            }
            if Task.isCancelled, result.outcome.isFailure {
                // Stopping terminates the running tool, which makes the step fail. Leave it
                // unfinished instead, so that resuming runs it again.
                log.warning("Restore cancelled during \(item.id)", component: .restore)
                break
            }
            result.duration = Date().timeIntervalSince(started)
            result.finishedAt = Date()
            session.results[item.id] = result
            session.currentItemID = nil
            persist(&session)
            log.write(result.outcome.isFailure ? .error : .info, "\(item.id): \(describe(result.outcome))", component: item.kind.logComponent)
            onEvent(.finished(item: item, result: result, index: index, total: total))
        }

        if session.remainingItemIDs.isEmpty {
            session.status = .completed
            persist(&session)
            sessionStore?.pruneCompleted()
        }
        let summary = RestoreSummary(results: Array(session.results.values), total: total)
        log.info("Restore finished: \(summary.succeeded) succeeded, \(summary.failed) failed, \(summary.skipped) skipped", component: .restore)
        onEvent(.completed(summary))
        return session
    }

    private func persist(_ session: inout RestoreSession) {
        session.updatedAt = Date()
        do { try sessionStore?.save(session) } catch { log.error("Could not save restore session: \(error)", component: .restore) }
    }

    private func describe(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .succeeded: return "succeeded"
        case .alreadyPresent: return "already present"
        case .skipped(let reason): return "skipped (\(reason))"
        case .failed(let failure): return "failed (\(failure.category.rawValue)) \(failure.technicalDetail)"
        }
    }

    struct RunContext {
        var brew: HomebrewInstallation?
        /// The runner for toolchain steps: the normal allow-list plus the exact executables of this plan's steps.
        var toolchainRunner: CommandRunning?
        var toolchainContext: ToolchainContext?
        var installedTaps: Set<String>?
        /// Results of the batched administrator copy for files in shared folders.
        var privilegedFileResults: [String: Result<FileAction, PrivilegedError>] = [:]
        var privilegedBatchDone = false
    }

    func failed(_ item: RestoreItem, _ category: FailureCategory, _ detail: String = "") -> ItemResult {
        ItemResult(itemID: item.id, outcome: .failed(RestoreFailure(category: category, technicalDetail: detail)))
    }

    func failure(from result: CommandResult) -> RestoreFailure {
        RestoreFailure(category: ErrorClassifier.classify(result.combinedOutput, exitCode: result.exitCode, timedOut: result.timedOut),
                       technicalDetail: ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout))
    }

    private func perform(_ item: RestoreItem, inspector: Inspector, context: inout RunContext, plan: RestorePlan,
                         session: RestoreSession, onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> ItemResult {
        onEvent(.activity(itemID: item.id, .checking))
        do {
            switch item.kind {
            case .commandLineTools: return await installCommandLineTools(item, inspector: inspector, onEvent: onEvent)
            case .homebrew: return await installHomebrew(item, context: &context, onEvent: onEvent)
            case .tap: return try await installTap(item, inspector: inspector, context: &context, onEvent: onEvent)
            case .masTool: return try await installMasTool(item, context: context, onEvent: onEvent)
            case .formula: return try await installFormula(item, inspector: inspector, context: context, onEvent: onEvent)
            case .cask: return try await installCask(item, inspector: inspector, context: context, onEvent: onEvent)
            case .appStoreApp: return await checkAppStoreInstall(item, inspector: inspector)
            case .font, .colorProfile:
                return await restoreFile(item, inspector: inspector, context: &context, plan: plan, session: session, onEvent: onEvent)
            case .pythonEnvironment:
                return try await restorePythonEnvironment(item, inspector: inspector, brew: context.brew, context: context, onEvent: onEvent)
            case .applicationData:
                return restoreApplicationData(item, inspector: inspector, session: session, onEvent: onEvent)
            case .gitConfiguration:
                return restoreGitConfiguration(item, inspector: inspector, session: session)
            case .credential:
                return restoreCredential(item, inspector: inspector, session: session, onEvent: onEvent)
            case .toolchainStep:
                return try await restoreToolchainStep(item, inspector: inspector, context: context, onEvent: onEvent)
            case .manualApp:
                return checkGuidedInstall(item, inspector: inspector)
            }
        } catch is CancellationError {
            return failed(item, .cancelled)
        } catch let error as CommandError {
            return failed(item, .unknown, String(describing: error))
        } catch {
            return failed(item, .unknown, layout.redact(String(describing: error)))
        }
    }

    // MARK: Prerequisites

    private func installCommandLineTools(_ item: RestoreItem, inspector: Inspector,
                                         onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> ItemResult {
        if await inspector.commandLineToolsInstalled() {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent)
        }
        // Opens Apple's own installation dialog; the user confirms it there.
        _ = try? await environment.runner.run(Command(
            executable: layout.xcodeSelect, arguments: ["--install"],
            environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 60))
        onEvent(.activity(itemID: item.id, .waitingForCommandLineTools))
        let deadline = Date().addingTimeInterval(environment.commandLineToolsTimeout)
        while Date() < deadline {
            if Task.isCancelled { return failed(item, .cancelled) }
            if await inspector.commandLineToolsInstalled() {
                onEvent(.activity(itemID: item.id, .verifying))
                return ItemResult(itemID: item.id, outcome: .succeeded)
            }
            try? await Task.sleep(nanoseconds: UInt64(environment.commandLineToolsPollInterval * 1_000_000_000))
        }
        return failed(item, .commandLineToolsUnavailable, "Command Line Tools were not installed in time")
    }

    private func installHomebrew(_ item: RestoreItem, context: inout RunContext,
                                 onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> ItemResult {
        switch await environment.homebrew.locate() {
        case .ready(let brew):
            context.brew = brew
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: brew.version)
        case .broken(let executable, let reason):
            return failed(item, .homebrewBroken, layout.redact("\(executable): \(reason)"))
        case .notInstalled:
            break
        }
        onEvent(.activity(itemID: item.id, .downloading))
        let installer = HomebrewInstaller(layout: layout, runner: environment.runner,
                                          source: environment.homebrewSource, privileged: environment.privileged)
        do {
            onEvent(.activity(itemID: item.id, .waitingForAdmin))
            let brew = try await installer.install(reason: environment.localizer.t("admin.reason.homebrew"), log: log)
            context.brew = brew
            return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: brew.version)
        } catch PrivilegedError.denied {
            return failed(item, .adminRightsDenied)
        } catch let error as HomebrewInstallError {
            switch error {
            case .releaseInfoUnavailable(let detail), .downloadFailed(let detail):
                return failed(item, .network, detail)
            case .checksumMismatch:
                return failed(item, .verificationFailed, "checksum mismatch")
            case .untrustedSignature:
                return failed(item, .verificationFailed, "untrusted package signature")
            case .installFailed(let detail):
                return failed(item, .unknown, layout.redact(detail))
            case .notWorkingAfterInstall(let detail):
                return failed(item, .homebrewBroken, layout.redact(detail))
            }
        } catch {
            return failed(item, .unknown, layout.redact(String(describing: error)))
        }
    }

    private func installTap(_ item: RestoreItem, inspector: Inspector, context: inout RunContext,
                            onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        let enabled = inspector.selection.enabledTaps
        guard enabled.contains(item.identifier) || enabled.contains(item.identifier.lowercased()) else {
            return ItemResult(itemID: item.id, outcome: .skipped(.tapNotEnabled(tap: item.identifier)))
        }
        guard let brew = context.brew else { return failed(item, .homebrewUnavailable) }
        let taps = try await environment.homebrew.installedTaps(brew)
        if taps.contains(item.identifier.lowercased()) {
            if HomebrewClient.requiresTapTrust(brew.version) { _ = try? await environment.homebrew.trustTap(brew, name: item.identifier) }
            return ItemResult(itemID: item.id, outcome: .alreadyPresent)
        }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.homebrew.install(brew, package: .tap(name: item.identifier, remote: item.tapRemote), askpass: nil)
        guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
        // Homebrew 6+ loads packages from third-party taps only once they are trusted. The user allowed
        // this tap on the restore screen, so MacReplica records that decision with Homebrew.
        if HomebrewClient.requiresTapTrust(brew.version) {
            let trusted = try await environment.homebrew.trustTap(brew, name: item.identifier)
            guard trusted.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: trusted))) }
        }
        onEvent(.activity(itemID: item.id, .verifying))
        guard try await environment.homebrew.installedTaps(brew).contains(item.identifier.lowercased()) else {
            return failed(item, .verificationFailed, "tap not listed after installation")
        }
        return ItemResult(itemID: item.id, outcome: .succeeded)
    }

    private func installMasTool(_ item: RestoreItem, context: RunContext,
                                onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        if environment.mas.locate() != nil { return ItemResult(itemID: item.id, outcome: .alreadyPresent) }
        guard let brew = context.brew else { return failed(item, .homebrewUnavailable) }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.homebrew.install(brew, package: .formula("mas"), askpass: nil)
        guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
        onEvent(.activity(itemID: item.id, .verifying))
        guard environment.mas.locate() != nil else { return failed(item, .masUnavailable, "mas not found after installation") }
        return ItemResult(itemID: item.id, outcome: .succeeded)
    }

    private func versionNotes(original: String?, installed: String?) -> [ResultNote] {
        guard let original, let installed, original != installed, !original.hasPrefix("HEAD"),
              VersionComparison.compare(original, installed) == .orderedAscending else { return [] }
        return [.newerVersionInstalled(original: original, installed: installed)]
    }

    private func installFormula(_ item: RestoreItem, inspector: Inspector, context: RunContext,
                                onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        guard let brew = context.brew else { return failed(item, .homebrewUnavailable) }
        if let version = try await environment.homebrew.installedFormulaVersion(brew, name: item.identifier) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)
        }
        onEvent(.activity(itemID: item.id, .installing))
        let head = inspector.selection.installsHead(item)
        let result = try await environment.homebrew.install(brew, package: head ? .formulaHead(item.identifier) : .formula(item.identifier),
                                                           askpass: environment.askpassPath, extraEnvironment: environment.askpassEnvironment)
        guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
        onEvent(.activity(itemID: item.id, .verifying))
        guard let version = try await environment.homebrew.installedFormulaVersion(brew, name: item.identifier) else {
            return failed(item, .verificationFailed, "formula not listed after installation")
        }
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version,
                          notes: versionNotes(original: item.originalVersion, installed: version))
    }

    private func installCask(_ item: RestoreItem, inspector: Inspector, context: RunContext,
                             onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        if let reason = inspector.architectureSkip(item) { return ItemResult(itemID: item.id, outcome: .skipped(reason)) }
        guard let brew = context.brew else { return failed(item, .homebrewUnavailable) }
        if let version = try await environment.homebrew.installedCaskVersion(brew, token: item.identifier) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)
        }
        if let app = inspector.installedApp(for: item) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: inspector.installedVersion(ofApp: app))
        }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.homebrew.install(brew, package: .cask(item.identifier), askpass: environment.askpassPath,
                                                           extraEnvironment: environment.askpassEnvironment)
        guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
        onEvent(.activity(itemID: item.id, .verifying))
        guard let version = try await environment.homebrew.installedCaskVersion(brew, token: item.identifier) else {
            return failed(item, .verificationFailed, "cask not listed after installation")
        }
        var installedVersion = version
        if !item.appBundleNames.isEmpty {
            guard let app = inspector.installedApp(for: item) else {
                return failed(item, .verificationFailed, "application bundle not found after installation")
            }
            installedVersion = inspector.installedVersion(ofApp: app) ?? version
        }
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: installedVersion,
                          notes: versionNotes(original: item.originalVersion, installed: installedVersion) + inspector.notes(for: item))
    }

    private func installAppStoreApp(_ item: RestoreItem, inspector: Inspector,
                                    onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        if let reason = inspector.architectureSkip(item) { return ItemResult(itemID: item.id, outcome: .skipped(reason)) }
        let identifiable = item.bundleIdentifier != nil || !item.appBundleNames.isEmpty
        if identifiable, let app = inspector.installedApp(for: item) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: inspector.installedVersion(ofApp: app))
        }
        guard let mas = environment.mas.locate() else { return failed(item, .masUnavailable) }
        guard let appStoreID = Int(item.identifier) else { return failed(item, .packageNotFound, "invalid App Store ID") }
        if !identifiable, let installed = try? await environment.mas.installedApps(mas: mas),
           installed.contains(where: { $0.appStoreID == appStoreID }) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent)
        }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.mas.install(mas: mas, appStoreID: appStoreID)
        // mas sometimes exits with 0 although nothing was installed, so the output is checked as well.
        let category = ErrorClassifier.classify(result.combinedOutput, exitCode: result.exitCode, timedOut: result.timedOut)
        if !result.succeeded || category == .appStoreNotSignedIn {
            var failure = failure(from: result)
            if category == .appStoreNotSignedIn { failure.category = .appStoreNotSignedIn }
            return ItemResult(itemID: item.id, outcome: .failed(failure))
        }
        onEvent(.activity(itemID: item.id, .verifying))
        if identifiable {
            guard let app = inspector.installedApp(for: item) else {
                return failed(item, .verificationFailed, "application not found after installation")
            }
            let version = inspector.installedVersion(ofApp: app)
            return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version,
                              notes: versionNotes(original: item.originalVersion, installed: version))
        }
        let installed = try await environment.mas.installedApps(mas: mas)
        guard let entry = installed.first(where: { $0.appStoreID == appStoreID }) else {
            return failed(item, .verificationFailed, "app not listed by mas after installation")
        }
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: entry.version)
    }

    // MARK: Fonts and color profiles

    /// Where an existing file is moved before it is replaced. It is never deleted.
    func asideLocation(for target: URL, item: RestoreItem, session: RestoreSession) -> URL? {
        guard let record = item.file else { return nil }
        let base = layout.baseFolder(for: Inspector.fileKind(item), domain: record.domain)
        guard let relative = FileScanner.relativePath(of: target, below: base) else { return nil }
        let folder = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/\(item.kind == .font ? "fonts" : "icc_profiles")/\(record.domain.rawValue)")
        return PathSafety.resolve(relative, inside: folder)
    }

    enum FileAction: Sendable, Equatable {
        case copy
        /// Move `existing` aside, then copy the backup file.
        case replace(existing: URL, aside: URL)
        /// Copy the backup file next to an existing file of the same name.
        case copyAs(URL)

        func destination(_ targets: Inspector.FileTargets) -> URL {
            if case .copyAs(let url) = self { return url }
            return targets.destination
        }

        var aside: URL? {
            if case .replace(_, let aside) = self { return aside }
            return nil
        }
    }

    private func fileAction(_ item: RestoreItem, inspector: Inspector, session: RestoreSession) -> (FileAction?, ItemResult?) {
        // A damaged backup copy is reported as such before anything is compared.
        guard let targets = inspector.fileTargets(item), sourceIsIntact(item, targets), let analysis = inspector.assessFile(item) else {
            return (nil, failed(item, .backupFileDamaged, item.file?.backupPath ?? ""))
        }
        let assessment = analysis.assessment
        func replacing(_ existing: URL?) -> (FileAction?, ItemResult?) {
            guard let existing else { return (.copy, nil) }
            guard let aside = asideLocation(for: existing, item: item, session: session) else {
                return (nil, failed(item, .unknown, "no location for the replaced file"))
            }
            return (.replace(existing: existing, aside: aside), nil)
        }
        switch Inspector.prediction(for: assessment, item: item, selection: inspector.selection) {
        case .identicalFileExists:
            return (nil, ItemResult(itemID: item.id, outcome: .alreadyPresent, notes: [.identicalFileExists]))
        case .equivalentFileExists:
            return (nil, ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: assessment.installedVersion,
                                    notes: [.equivalentFileInstalled]))
        case .keepsMacOSVersion:
            return (nil, ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: assessment.installedVersion,
                                    notes: [.providedByMacOS]))
        case .willSkip(let reason):
            return (nil, ItemResult(itemID: item.id, outcome: .skipped(reason)))
        case .conflict(let resolution):
            switch resolution {
            case .keepExisting: return (nil, ItemResult(itemID: item.id, outcome: .skipped(.keptExisting)))
            case .skip: return (nil, ItemResult(itemID: item.id, outcome: .skipped(.userSkipped)))
            case .replace:
                // Only a file in the folder MacReplica restores into is moved aside; a copy in another
                // folder stays where it is.
                return replacing(analysis.replaceTarget)
            case .keepBoth:
                if !FileManager.default.fileExists(atPath: targets.destination.path) { return (.copy, nil) }
                guard let alternative = Self.alternativeName(for: targets.destination) else {
                    return (nil, failed(item, .unknown, "no free file name"))
                }
                return (.copyAs(alternative), nil)
            }
        default:
            // Anything already at the destination path is never overwritten in place.
            return replacing(FileManager.default.fileExists(atPath: targets.destination.path) ? targets.destination : nil)
        }
    }

    /// "Example Paper.icc" → "Example Paper (MacReplica).icc", then "(MacReplica 2)" … in the same folder.
    static func alternativeName(for url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for number in 1...99 {
            let suffix = number == 1 ? " (MacReplica)" : " (MacReplica \(number))"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func sourceIsIntact(_ item: RestoreItem, _ targets: Inspector.FileTargets) -> Bool {
        guard let record = item.file else { return false }
        return (try? Hashing.sha256Hex(ofFile: targets.source)) == record.sha256
    }

    private func restoreFile(_ item: RestoreItem, inspector: Inspector, context: inout RunContext, plan: RestorePlan,
                             session: RestoreSession, onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> ItemResult {
        guard let record = item.file, let targets = inspector.fileTargets(item) else {
            return failed(item, .backupFileDamaged, item.file?.backupPath ?? "")
        }
        // Already handled by the batched administrator copy: only verify.
        if let batch = context.privilegedFileResults[item.id] {
            return verifyInstalledFile(item, record: record, targets: targets, batch: batch, inspector: inspector, onEvent: onEvent)
        }
        let (action, early) = fileAction(item, inspector: inspector, session: session)
        if let early {
            log.info("\(item.id): decision \(early.decisionCode)", component: item.kind.logComponent)
            return early
        }
        guard let action else { return failed(item, .unknown) }
        guard sourceIsIntact(item, targets) else { return failed(item, .backupFileDamaged, record.backupPath) }

        if inspector.fileNeedsAdmin(targets) {
            if !context.privilegedBatchDone {
                await runPrivilegedFileBatch(plan: plan, session: session, inspector: inspector, context: &context, onEvent: onEvent)
            }
            guard let batch = context.privilegedFileResults[item.id] else { return failed(item, .adminRightsDenied) }
            return verifyInstalledFile(item, record: record, targets: targets, batch: batch, inspector: inspector, onEvent: onEvent)
        }
        onEvent(.activity(itemID: item.id, .copying))
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: action.destination(targets).deletingLastPathComponent(), withIntermediateDirectories: true)
            if case .replace(let existing, let aside) = action {
                try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                try fm.moveItem(at: existing, to: aside)
                inspector.fileIndexes.index(Inspector.fileKind(item), layout: layout).remove(existing)
            }
            try fm.copyItem(at: targets.source, to: action.destination(targets))
        } catch {
            let nsError = error as NSError
            let category: FailureCategory = nsError.code == NSFileWriteOutOfSpaceError ? .diskFull
                : (nsError.code == NSFileWriteNoPermissionError ? .adminRightsDenied : .unknown)
            return failed(item, category, layout.redact(nsError.localizedDescription))
        }
        return verifyInstalledFile(item, record: record, targets: targets, batch: .success(action), inspector: inspector, onEvent: onEvent)
    }

    /// A restored file counts only if its checksum matches and macOS on this Mac can read it.
    private func verifyInstalledFile(_ item: RestoreItem, record: FileRecord, targets: Inspector.FileTargets,
                                     batch: Result<FileAction, PrivilegedError>, inspector: Inspector,
                                     onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        switch batch {
        case .failure(.denied): return failed(item, .adminRightsDenied)
        case .failure(let error): return failed(item, .unknown, layout.redact(String(describing: error)))
        case .success(let action):
            onEvent(.activity(itemID: item.id, .verifying))
            let installed = action.destination(targets)
            guard (try? Hashing.sha256Hex(ofFile: installed)) == record.sha256 else {
                return failed(item, .verificationFailed, "checksum differs after copying")
            }
            let kind = Inspector.fileKind(item)
            guard FileVerification.isUsable(installed, kind: kind) else {
                return failed(item, .verificationFailed, "macOS cannot read the restored file")
            }
            inspector.fileIndexes.index(kind, layout: layout)
                .record(installed: installed, location: record.domain == .user ? .user : .shared, kind: kind, sha256: record.sha256)
            var notes: [ResultNote] = []
            if let aside = action.aside { notes.append(.existingFileMovedAside(path: layout.displayPath(aside))) }
            if case .copyAs(let url) = action { notes.append(.installedUnderNewName(name: url.lastPathComponent)) }
            let result = ItemResult(itemID: item.id, outcome: .succeeded, notes: notes)
            log.info("\(item.id): decision \(result.decisionCode)", component: item.kind.logComponent)
            return result
        }
    }

    /// Copies all remaining files that need administrator rights after a single password prompt.
    private func runPrivilegedFileBatch(plan: RestorePlan, session: RestoreSession, inspector: Inspector,
                                        context: inout RunContext, onEvent: @escaping @Sendable (RestoreEvent) -> Void) async {
        context.privilegedBatchDone = true
        var operations: [PrivilegedOperation] = []
        var itemIDs: [String] = []
        var actions: [String: FileAction] = [:]
        var createdFolders = Set<String>()
        for item in plan.items where item.kind.isFile && session.results[item.id] == nil {
            guard let targets = inspector.fileTargets(item), inspector.fileNeedsAdmin(targets) else { continue }
            let (action, early) = fileAction(item, inspector: inspector, session: session)
            guard early == nil, let action, sourceIsIntact(item, targets) else { continue }
            let folder = targets.destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path), createdFolders.insert(folder.path).inserted {
                operations.append(.createFolder(folder))
            }
            if case .replace(let existing, let aside) = action {
                try? FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                operations.append(.move(source: existing, destination: aside))
            }
            operations.append(.installFile(source: targets.source, destination: action.destination(targets)))
            itemIDs.append(item.id)
            actions[item.id] = action
        }
        guard !operations.isEmpty else { return }
        let fontCount = plan.items.filter { itemIDs.contains($0.id) && $0.kind == .font }.count
        let profileCount = itemIDs.count - fontCount
        let reason = environment.localizer.t("admin.reason.files", fontCount, profileCount)
        if let first = itemIDs.first { onEvent(.activity(itemID: first, .waitingForAdmin)) }
        log.info("Requesting administrator rights for \(itemIDs.count) files in shared folders", component: .permissions)
        do {
            try await environment.privileged.run(operations, reason: reason)
            for id in itemIDs { context.privilegedFileResults[id] = .success(actions[id] ?? .copy) }
        } catch let error as PrivilegedError {
            for id in itemIDs { context.privilegedFileResults[id] = .failure(error) }
        } catch {
            for id in itemIDs { context.privilegedFileResults[id] = .failure(.failed(String(describing: error))) }
        }
    }
}

extension RestorePlan {
    /// The steps needed to retry `itemIDs`, including their prerequisites.
    public func subset(retrying itemIDs: Set<String>) -> RestorePlan {
        var needed = itemIDs
        var changed = true
        while changed {
            changed = false
            for item in items where needed.contains(item.id) {
                for dependency in item.dependsOn where !needed.contains(dependency) {
                    needed.insert(dependency)
                    changed = true
                }
            }
        }
        return RestorePlan(items: items.filter { needed.contains($0.id) }, manualApps: manualApps)
    }
}
