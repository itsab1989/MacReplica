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
}

public struct DryRunEntry: Equatable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: RestoreItem
    public var prediction: Prediction
    public var requiresAdmin: Bool
    public var notes: [ResultNote]
}

/// Read-only checks shared by the dry run and the real restore.
struct Inspector: Sendable {
    let environment: RestoreEnvironment
    let backupRoot: URL
    let selection: RestoreSelection
    let damagedFiles: Set<String>

    var layout: SystemLayout { environment.layout }

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

    func predictFile(_ item: RestoreItem) -> Prediction {
        guard let record = item.file, let targets = fileTargets(item) else { return .backupFileDamaged }
        if damagedFiles.contains(record.backupPath) { return .backupFileDamaged }
        guard FileManager.default.fileExists(atPath: targets.source.path) else { return .backupFileDamaged }
        if FileManager.default.fileExists(atPath: targets.destination.path) {
            if (try? Hashing.sha256Hex(ofFile: targets.destination)) == record.sha256 { return .identicalFileExists }
            return .conflict(resolution: selection.resolution(for: item.id))
        }
        return .willCopy
    }

    func predict(_ item: RestoreItem, brew: HomebrewInstallation?, taps: Set<String>?) async -> Prediction {
        switch item.kind {
        case .commandLineTools:
            return await commandLineToolsInstalled() ? .alreadyPresent(version: nil) : .willInstall
        case .homebrew:
            if let brew { return .alreadyPresent(version: brew.version) }
            return .willInstall
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
            return .willInstall
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

    /// Describes what a restore would do. Only read-only checks are performed.
    public func dryRun(plan: RestorePlan, selection: RestoreSelection) async -> [DryRunEntry] {
        let inspector = Inspector(environment: environment, backupRoot: backupRoot, selection: selection, damagedFiles: damagedFiles)
        let brew = await environment.homebrew.locate().installation
        let taps: Set<String>? = brew == nil ? nil : ((try? await environment.homebrew.installedTaps(brew!)) ?? [])
        var entries: [DryRunEntry] = []
        var blocked = Set<String>()
        for item in plan.items {
            var prediction = await inspector.predict(item, brew: brew, taps: taps)
            if let dependency = item.dependsOn.first(where: { blocked.contains($0) }) {
                if case .alreadyPresent = prediction {} else {
                    prediction = .willSkip(.dependencyFailed(itemTitle: plan.item(id: dependency)?.title ?? dependency))
                }
            }
            if case .willSkip = prediction { blocked.insert(item.id) }
            var requiresAdmin = false
            if item.kind == .homebrew, prediction == .willInstall { requiresAdmin = true }
            if item.kind.isFile, let targets = inspector.fileTargets(item) {
                switch prediction {
                case .willCopy, .conflict(.replace): requiresAdmin = inspector.fileNeedsAdmin(targets)
                default: break
                }
            }
            entries.append(DryRunEntry(item: item, prediction: prediction, requiresAdmin: requiresAdmin, notes: inspector.notes(for: item)))
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
        let total = plan.items.count
        log.info("Restore session \(session.id): \(total) steps, \(session.finishedItemIDs.count) already finished", component: .restore)
        persist(&session)

        for (index, item) in plan.items.enumerated() {
            if session.results[item.id] != nil { continue }
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
                if case .alreadyPresent(let version) = await inspector.predict(item, brew: context.brew, taps: nil) {
                    result = ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)
                } else {
                    let title = plan.item(id: blocker)?.title ?? blocker
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
            case .formula: return try await installFormula(item, context: context, onEvent: onEvent)
            case .cask: return try await installCask(item, inspector: inspector, context: context, onEvent: onEvent)
            case .appStoreApp: return try await installAppStoreApp(item, inspector: inspector, onEvent: onEvent)
            case .font, .colorProfile:
                return await restoreFile(item, inspector: inspector, context: &context, plan: plan, session: session, onEvent: onEvent)
            case .pythonEnvironment:
                return try await restorePythonEnvironment(item, inspector: inspector, brew: context.brew, onEvent: onEvent)
            case .applicationData:
                return restoreApplicationData(item, inspector: inspector, session: session, onEvent: onEvent)
            case .gitConfiguration:
                return restoreGitConfiguration(item, inspector: inspector, session: session)
            case .credential:
                return restoreCredential(item, inspector: inspector, session: session, onEvent: onEvent)
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
        if taps.contains(item.identifier.lowercased()) { return ItemResult(itemID: item.id, outcome: .alreadyPresent) }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.homebrew.install(brew, package: .tap(name: item.identifier, remote: item.tapRemote), askpass: nil)
        guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
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
        guard let original, let installed, original != installed,
              VersionComparison.compare(original, installed) == .orderedAscending else { return [] }
        return [.newerVersionInstalled(original: original, installed: installed)]
    }

    private func installFormula(_ item: RestoreItem, context: RunContext,
                                onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        guard let brew = context.brew else { return failed(item, .homebrewUnavailable) }
        if let version = try await environment.homebrew.installedFormulaVersion(brew, name: item.identifier) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)
        }
        onEvent(.activity(itemID: item.id, .installing))
        let result = try await environment.homebrew.install(brew, package: .formula(item.identifier), askpass: environment.askpassPath,
                                                           extraEnvironment: environment.askpassEnvironment)
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
    func asideLocation(for item: RestoreItem, session: RestoreSession) -> URL? {
        guard let record = item.file else { return nil }
        let folder = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/\(item.kind == .font ? "fonts" : "icc_profiles")/\(record.domain.rawValue)")
        return PathSafety.resolve(record.relativePath, inside: folder)
    }

    enum FileAction: Sendable { case copy, replace }

    private func fileAction(_ item: RestoreItem, inspector: Inspector) -> (FileAction?, ItemResult?) {
        switch inspector.predictFile(item) {
        case .backupFileDamaged:
            return (nil, failed(item, .backupFileDamaged, item.file?.backupPath ?? ""))
        case .identicalFileExists:
            return (nil, ItemResult(itemID: item.id, outcome: .alreadyPresent, notes: [.identicalFileExists]))
        case .conflict(let resolution):
            switch resolution {
            case .keepExisting: return (nil, ItemResult(itemID: item.id, outcome: .skipped(.keptExisting)))
            case .skip: return (nil, ItemResult(itemID: item.id, outcome: .skipped(.userSkipped)))
            case .replace: return (.replace, nil)
            }
        default:
            return (.copy, nil)
        }
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
            return verifyPrivilegedCopy(item, record: record, targets: targets, batch: batch, session: session, onEvent: onEvent)
        }
        let (action, early) = fileAction(item, inspector: inspector)
        if let early { return early }
        guard let action else { return failed(item, .unknown) }
        guard sourceIsIntact(item, targets) else { return failed(item, .backupFileDamaged, record.backupPath) }
        let aside = action == .replace ? asideLocation(for: item, session: session) : nil
        if action == .replace, aside == nil { return failed(item, .unknown, "no location for the replaced file") }

        if inspector.fileNeedsAdmin(targets) {
            if !context.privilegedBatchDone {
                await runPrivilegedFileBatch(plan: plan, session: session, inspector: inspector, context: &context, onEvent: onEvent)
            }
            guard let batch = context.privilegedFileResults[item.id] else { return failed(item, .adminRightsDenied) }
            return verifyPrivilegedCopy(item, record: record, targets: targets, batch: batch, session: session, onEvent: onEvent)
        } else {
            onEvent(.activity(itemID: item.id, .copying))
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: targets.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if action == .replace, let aside {
                    try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                    try fm.moveItem(at: targets.destination, to: aside)
                }
                try fm.copyItem(at: targets.source, to: targets.destination)
            } catch {
                let nsError = error as NSError
                let category: FailureCategory = nsError.code == NSFileWriteOutOfSpaceError ? .diskFull : .unknown
                return failed(item, category, layout.redact(nsError.localizedDescription))
            }
        }

        onEvent(.activity(itemID: item.id, .verifying))
        guard (try? Hashing.sha256Hex(ofFile: targets.destination)) == record.sha256 else {
            return failed(item, .verificationFailed, "checksum differs after copying")
        }
        var notes: [ResultNote] = []
        if let aside { notes.append(.existingFileMovedAside(path: layout.displayPath(aside))) }
        return ItemResult(itemID: item.id, outcome: .succeeded, notes: notes)
    }

    private func verifyPrivilegedCopy(_ item: RestoreItem, record: FileRecord, targets: Inspector.FileTargets,
                                      batch: Result<FileAction, PrivilegedError>, session: RestoreSession,
                                      onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        switch batch {
        case .failure(.denied): return failed(item, .adminRightsDenied)
        case .failure(let error): return failed(item, .unknown, layout.redact(String(describing: error)))
        case .success(let action):
            onEvent(.activity(itemID: item.id, .verifying))
            guard (try? Hashing.sha256Hex(ofFile: targets.destination)) == record.sha256 else {
                return failed(item, .verificationFailed, "checksum differs after copying")
            }
            var notes: [ResultNote] = []
            if action == .replace, let aside = asideLocation(for: item, session: session) {
                notes.append(.existingFileMovedAside(path: layout.displayPath(aside)))
            }
            return ItemResult(itemID: item.id, outcome: .succeeded, notes: notes)
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
            let (action, early) = fileAction(item, inspector: inspector)
            guard early == nil, let action, sourceIsIntact(item, targets) else { continue }
            let folder = targets.destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path), createdFolders.insert(folder.path).inserted {
                operations.append(.createFolder(folder))
            }
            if action == .replace, let aside = asideLocation(for: item, session: session) {
                try? FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                operations.append(.move(source: targets.destination, destination: aside))
            }
            operations.append(.installFile(source: targets.source, destination: targets.destination))
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
