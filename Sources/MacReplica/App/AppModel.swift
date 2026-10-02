import AppKit
import Foundation
import MacReplicaCore
import SwiftUI

enum Screen: Equatable {
    case home
    case scanning
    case inventoryResults
    case savingBackup
    case backupSaved
    case restoreSelection
    case dryRun
    case restoring
    case restoreSummary
    case verifying
    case verificationResult
    case problem
}

/// A friendly explanation for something that stopped a whole workflow.
struct ProblemInfo: Equatable {
    var title: String
    var message: String
    var detail: String?
}

/// Live state of a running restore, derived from executor events.
struct RestoreProgressState {
    var total = 0
    var position = 0
    var currentItem: RestoreItem?
    var activity: RestoreActivity = .checking
    var succeeded = 0
    var failed = 0
    var skipped = 0
    var finished: [(item: RestoreItem, result: ItemResult)] = []
    var estimator = ProgressEstimator(items: [])
    var stopping = false

    var fraction: Double { total == 0 ? 0 : Double(succeeded + failed + skipped) / Double(total) }
}

@MainActor
final class AppModel: ObservableObject {
    let services: AppServices
    private let defaults: UserDefaults

    @Published var language: AppLanguage
    @Published private(set) var l: Localizer
    @Published var screen: Screen = .home
    @Published var problem: ProblemInfo?

    // Inventory
    @Published var inventoryProgress = InventoryProgress(phase: .applications, fraction: 0, detail: nil)
    @Published var inventory: InventoryResult?
    @Published var backupProgress: Double = 0
    @Published var savedBackup: URL?
    @Published var backupOutcome: BackupOutcome?
    /// Python environments the user wants in the backup.
    @Published var selectedPythonEnvironments = Set<String>()
    @Published var includePythonSettings = true
    @Published var pythonSearchFolders: [URL] = []
    @Published var addingApplicationData = false
    @Published var notice: ProblemInfo?
    @Published var includeGitSettings = true
    @Published var includeGitEmail = false
    /// Credential providers the user explicitly switched on (always empty by default).
    @Published var selectedCredentialProviders = Set<String>()
    var credentialPassphrase: String?
    /// Application data folders the user switched off (compatibility-sensitive ones start off).
    @Published var excludedApplicationData = Set<String>()
    /// Fonts and profiles the user left out of the backup (`InventoryResult.selectionID`).
    @Published var excludedBackupFiles = Set<String>()
    /// Passphrase for restoring encrypted credentials; requested right before the restore.
    @Published var askForRestorePassphrase = false
    var restorePassphrase: String?
    /// An interrupted restore that continues once the passphrase was asked again.
    private var pendingResume: RestoreSession?

    /// `nil` means the user chose to skip the credentials.
    func restorePassphraseEntered(_ passphrase: String?) {
        askForRestorePassphrase = false
        if let session = pendingResume {
            pendingResume = nil
            // Without a passphrase the credential steps are recorded as skipped, nothing else changes.
            restorePassphrase = passphrase
            resumeRestore(session, askForPassphrase: false)
            return
        }
        if let passphrase { restorePassphrase = passphrase } else { selection.components.remove(.credentials) }
        startRestore()
    }

    func cancelRestorePassphrase() {
        askForRestorePassphrase = false
        if pendingResume != nil {
            pendingResume = nil
            screen = .home
        }
    }
    @Published var updateStatus: UpdateStatus?
    @Published var checkingForUpdates = false

    // Startup and diagnostics
    let startup: StartupRecorder
    let appLog: LogStore
    @Published private(set) var safeMode = false
    @Published var showSafeModeNotice = false

    // Restore
    @Published var unfinishedSession: RestoreSession?
    @Published var backupURL: URL?
    @Published var manifest: Manifest?
    @Published var verification: VerificationReport?
    @Published var selection = RestoreSelection()
    @Published var plan: RestorePlan?
    @Published var dryRunEntries: [DryRunEntry] = []
    @Published var dryRunInProgress = false
    @Published var progress = RestoreProgressState()
    @Published var session: RestoreSession?
    @Published var pendingConflicts: [DryRunEntry] = []
    /// The quick destination check behind the restore selection: item ID → what restoring it would do here.
    @Published var assessments: [String: DryRunEntry] = [:]
    @Published var assessing = false
    /// Items MacReplica deselected because restoring them is not recommended on this Mac.
    @Published var notRecommendedItemIDs = Set<String>()
    /// An interrupted restore whose remaining selection the user is reviewing before continuing.
    @Published var reviewingSession: RestoreSession?
    private var assessmentTask: Task<Void, Never>?
    @Published var adminNotice: AdminNotice?

    // Verification
    @Published var verificationProgress: Double = 0

    private var task: Task<Void, Never>?
    private var restoreLog: LogStore?

    struct AdminNotice: Equatable {
        var installsHomebrew: Bool
        var copiesSharedFiles: Bool
        var installsCommandLineTools: Bool
    }

    init(services: AppServices = .make()) {
        self.services = services
        self.defaults = services.defaults
        // Every startup stage is written to disk immediately; if a launch does not
        // reach the user interface, the next one starts in safe mode.
        let startup = StartupRecorder(fileURL: services.layout.logs.appendingPathComponent("startup.json"))
        self.startup = startup
        startup.reached(.configuration)
        let safeMode = startup.previousLaunchFailed
        self.appLog = LogStore.session(in: services.layout.logs, name: "app", homeDirectory: services.layout.homeDirectory)
        if safeMode {
            appLog.warning("The previous launch stopped at stage '\(startup.previousLaunch?.lastStage?.rawValue ?? "unknown")'; starting in safe mode",
                           component: .startup)
        }

        // English is the default. The macOS language is deliberately not used,
        // so the app always starts in English until the user picks a language.
        let stored = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
        self.language = safeMode ? .english : stored
        self.l = Localizer(language: safeMode ? .english : stored)
        if !Localizer(language: .english).hasTranslation("home.inventory.title") {
            startup.failed(.localization, error: "localization resources missing")
            appLog.error("Localization resources are missing from the app bundle", component: .startup)
        }
        startup.reached(.localization)

        // A damaged restore session must not be able to block every launch, so safe mode skips it.
        if !safeMode { unfinishedSession = services.sessionStore.unfinishedSession() }
        startup.reached(.storage)
        appLog.info("Simulation: \(services.layout.isSimulation ? "yes" : "no"), safe mode: \(safeMode ? "yes" : "no")", component: .startup)
        startup.reached(.environment)
        self.safeMode = safeMode
        self.showSafeModeNotice = safeMode
        applySystemMenuLanguage(self.language)
    }

    /// Called once the main window is on screen.
    func userInterfaceReady() {
        guard !startup.current.completed else { return }
        startup.completed()
        appLog.info("Startup completed", component: .startup)
    }

    func leaveSafeMode() {
        showSafeModeNotice = false
        safeMode = false
        unfinishedSession = services.sessionStore.unfinishedSession()
    }

    // MARK: Logs and diagnostics

    func openLogs() {
        try? FileManager.default.createDirectory(at: services.layout.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(services.layout.logs)
    }

    func exportDiagnosticReport() {
        let report = DiagnosticReport.make(layout: services.layout, startupFile: startup.fileURL)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacReplica-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = l.t("diagnostics.saveMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            notice = ProblemInfo(title: l.t("diagnostics.failed"), message: services.layout.redact(error.localizedDescription), detail: nil)
        }
    }

    var logsDisplayPath: String { services.layout.displayPath(services.layout.logs) }

    var isSimulation: Bool { services.layout.isSimulation }

    // MARK: Language

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        l = Localizer(language: language)
        defaults.set(language.rawValue, forKey: "appLanguage")
        applySystemMenuLanguage(language)
    }

    /// AppKit's own menu items (Edit, Window …) follow `AppleLanguages`, which takes effect at the next launch.
    private func applySystemMenuLanguage(_ language: AppLanguage) {
        guard !isSimulation else { return }
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    // MARK: Navigation

    func goHome() {
        task?.cancel()
        task = nil
        screen = .home
        inventory = nil
        savedBackup = nil
        backupOutcome = nil
        pythonSearchFolders = []
        selectedCredentialProviders = []
        credentialPassphrase = nil
        excludedApplicationData = []
        excludedBackupFiles = []
        manifest = nil
        backupURL = nil
        verification = nil
        plan = nil
        dryRunEntries = []
        assessmentTask?.cancel()
        assessments = [:]
        notRecommendedItemIDs = []
        reviewingSession = nil
        pendingConflicts = []
        session = nil
        problem = nil
        selection = RestoreSelection()
        progress = RestoreProgressState()
        unfinishedSession = services.sessionStore.unfinishedSession()
    }

    func show(_ problem: ProblemInfo) {
        self.problem = problem
        screen = .problem
    }

    // MARK: Inventory

    func startInventory() {
        screen = .scanning
        inventoryProgress = InventoryProgress(phase: .applications, fraction: 0, detail: nil)
        let service = InventoryService(layout: services.layout, runner: services.runner, catalogProvider: services.catalogProvider,
                                       macOSVersion: services.macOSVersion, architecture: services.architecture,
                                       pythonSearchFolders: pythonSearchFolders)
        appLog.info("Inventory started", component: .inventory)
        let model = self
        task = Task { [weak self] in
            do {
                let result = try await service.run { progress in
                    Task { @MainActor in model.inventoryProgress = progress }
                }
                guard !Task.isCancelled else { return }
                self?.inventory = result
                self?.selectedPythonEnvironments = Set(result.manifest.python.environments.map(\.id))
                // Data that may not work across app versions is offered, but not pre-selected.
                self?.excludedApplicationData = Set(result.manifest.applicationData
                    .filter { $0.profile.map { !$0.classification.selectedByDefault } ?? false }.map(\.id))
                self?.excludedBackupFiles = result.filesNotSelectedByDefault
                self?.appLog.info("Inventory finished: \(result.manifest.applications.count) apps, \(result.manifest.python.environments.count) Python environments, \(result.warnings.count) warnings", component: .inventory)
                self?.screen = .inventoryResults
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.appLog.error("Inventory failed: \(error)", component: .inventory)
                self.show(ProblemInfo(title: self.l.t("inventory.failed.title"), message: self.l.t("inventory.failed.message"),
                                      detail: self.services.layout.redact(String(describing: error))))
            }
        }
    }

    /// Applies the user's choice for an app with several possible Homebrew packages.
    func decideMatch(appID: String, token: String?) {
        guard var result = inventory, let index = result.manifest.applications.firstIndex(where: { $0.id == appID }) else { return }
        var app = result.manifest.applications[index]
        if let token, let candidate = app.candidates.first(where: { $0.token == token }) {
            app.restoreMethod = candidate.restoreMethod
            app.homepage = candidate.homepage ?? app.homepage
        } else {
            app.restoreMethod = app.homepage.map { .officialDownload(url: $0) } ?? .manual
        }
        result.manifest.applications[index] = app
        inventory = result
    }

    // MARK: Python and application data

    /// Searches an additional folder (for example inside Documents) for Python environments.
    func addPythonSearchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l.t("python.search.choose")
        panel.message = l.t("python.search.message")
        panel.directoryURL = services.layout.homeDirectory
        guard panel.runModal() == .OK, let folder = panel.url, var result = inventory else { return }
        pythonSearchFolders.append(folder)
        let scan = PythonScanner(layout: services.layout, extraRoots: pythonSearchFolders).scan()
        let known = Set(result.manifest.python.environments.map(\.id))
        result.extraFiles.removeAll { $0.record.backupPath.hasPrefix("development/python/") }
        result.extraFiles += scan.projectFiles
        result.manifest.python = scan.snapshot
        for environment in scan.snapshot.environments where !known.contains(environment.id) {
            selectedPythonEnvironments.insert(environment.id)
        }
        inventory = result
        appLog.info("Searched an extra folder for Python environments: \(scan.snapshot.environments.count) found", component: .python)
    }

    /// Lets the user include a folder of application data, e.g. in Application Support.
    func addApplicationDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l.t("appData.add.choose")
        panel.message = l.t("appData.add.message")
        panel.directoryURL = services.layout.homeDirectory.appendingPathComponent("Library/Application Support")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scanner = AppDataScanner(layout: services.layout)
        addingApplicationData = true
        task = Task.detached { [weak self] in
            let outcome = Result { try scanner.scan(folder) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.addingApplicationData = false
                switch outcome {
                case .success(let scan):
                    self.inventory?.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
                    self.appLog.info("Added application data folder with \(scan.files.count) files, \(scan.issues.count) left out", component: .applicationData)
                case .failure(let error):
                    let message: String
                    switch error as? AppDataError {
                    case .outsideHome?: message = self.l.t("appData.error.outsideHome")
                    case .wholeHomeOrLibrary?: message = self.l.t("appData.error.tooBroad")
                    case .sensitiveLocation?: message = self.l.t("appData.error.sensitive")
                    default: message = self.l.t("appData.error.notAFolder")
                    }
                    self.appLog.warning("Application data folder refused: \(error)", component: .applicationData)
                    self.notice = ProblemInfo(title: self.l.t("appData.error.title"), message: message, detail: nil)
                }
            }
        }
    }

    func removeApplicationData(id: String) {
        inventory?.removeApplicationData(id: id)
    }

    func chooseBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l.t("inventory.save.choose")
        panel.message = l.t("inventory.save.message")
        panel.directoryURL = lastFolder(key: "lastBackupParent") ?? defaultBackupParent
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        defaults.set(parent.path, forKey: "lastBackupParent")
        saveBackup(into: parent)
    }

    private var defaultBackupParent: URL {
        services.layout.homeDirectory.appendingPathComponent("Desktop")
    }

    private func lastFolder(key: String) -> URL? {
        guard let path = defaults.string(forKey: key), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func saveBackup(into parent: URL) {
        guard var inventory else { return }
        inventory.keepPythonEnvironments(selectedPythonEnvironments, includeSettings: includePythonSettings)
        applyDeveloperChoices(to: &inventory)
        for id in excludedApplicationData { inventory.removeApplicationData(id: id) }
        inventory.excludeFiles(excludedBackupFiles)
        let credentials = selectedCredentialProviders.isEmpty ? nil
            : credentialPassphrase.map { CredentialExportRequest(providerIDs: selectedCredentialProviders.sorted(), passphrase: $0) }
        screen = .savingBackup
        backupProgress = 0
        let writer = BackupWriter(layout: services.layout, localizer: l)
        let log = LogStore.session(in: services.layout.logs, name: "inventory", homeDirectory: services.layout.homeDirectory)
        log.info("Inventory: \(inventory.manifest.applications.count) applications, \(inventory.fonts.count) fonts, \(inventory.colorProfiles.count) ICC profiles, \(inventory.manifest.python.environments.count) Python environments, \(inventory.manifest.applicationData.count) data folders", component: .inventory)
        for warning in inventory.warnings { log.warning("Inventory warning: \(warning)", component: .inventory) }
        let model = self
        task = Task.detached { [weak self] in
            do {
                let outcome = try writer.write(inventory, into: parent, log: log, credentials: credentials) { progress in
                    Task { @MainActor in model.backupProgress = progress.fraction }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.savedBackup = outcome.url
                    self.backupOutcome = outcome
                    // The passphrase is not kept once the vault is written.
                    self.credentialPassphrase = nil
                    self.defaults.set(outcome.url.path, forKey: "lastBackup")
                    self.appLog.info("Backup saved (\(outcome.fileCount) files, complete: \(outcome.isComplete))", component: .backup)
                    self.screen = .backupSaved
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.appLog.error("Backup failed: \(error)", component: .backup)
                    let message: String
                    if case BackupError.destinationNotWritable = error {
                        message = self.l.t("backup.failed.notWritable")
                    } else {
                        message = self.l.t("backup.failed.message")
                    }
                    self.show(ProblemInfo(title: self.l.t("backup.failed.title"), message: message,
                                          detail: self.services.layout.redact(String(describing: error))))
                }
            }
        }
    }

    // MARK: Opening a backup

    /// Asks for a backup folder. `purpose` decides what happens next.
    func chooseBackup(for purpose: BackupPurpose) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l.t("backup.open.choose")
        panel.message = l.t("backup.open.message")
        panel.directoryURL = lastFolder(key: "lastBackup") ?? defaultBackupParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch purpose {
        case .restore: openBackupForRestore(url)
        case .verify: verifyBackup(url)
        }
    }

    enum BackupPurpose { case restore, verify }

    func openBackupForRestore(_ url: URL, resuming: RestoreSession? = nil, reviewing: Bool = false) {
        screen = .verifying
        verificationProgress = 0
        let verifier = BackupVerifier(layout: services.layout)
        let model = self
        task = Task.detached { [weak self] in
            let report = verifier.verify(backupAt: url) { fraction in
                Task { @MainActor in model.verificationProgress = fraction }
            }
            await MainActor.run { [weak self] in
                self?.finishOpening(url: url, report: report, resuming: resuming, reviewing: reviewing)
            }
        }
    }

    private func finishOpening(url: URL, report: VerificationReport, resuming: RestoreSession?, reviewing: Bool = false) {
        guard let manifest = report.manifest, report.isUsable else {
            showUnusableBackup(report)
            return
        }
        defaults.set(url.path, forKey: "lastBackup")
        backupURL = url
        self.manifest = manifest
        verification = report
        assessments = [:]
        notRecommendedItemIDs = []
        if let resuming, reviewing {
            // The earlier choices stay; only steps that have not run yet can be changed.
            selection = resuming.selection
            reviewingSession = resuming
            screen = .restoreSelection
            assessDestination(applyDefaults: false)
        } else if let resuming {
            selection = resuming.selection
            resumeRestore(resuming)
        } else {
            reviewingSession = nil
            selection = RestoreSelection()
            // Third-party taps stay off until the user allows them.
            selection.enabledTaps = []
            screen = .restoreSelection
            assessDestination(applyDefaults: true)
        }
    }

    private func showUnusableBackup(_ report: VerificationReport) {
        if report.issues.contains(where: { if case .unsupportedVersion = $0 { return true }; return false }) {
            show(ProblemInfo(title: l.t("backup.newerVersion.title"), message: l.t("backup.newerVersion.message"), detail: nil))
        } else if report.issues.contains(.checksumMismatch) {
            show(ProblemInfo(title: l.t("backup.damaged.title"), message: l.t("backup.damaged.checksum"), detail: nil))
        } else {
            show(ProblemInfo(title: l.t("backup.unreadable.title"), message: l.t("backup.unreadable.message"),
                             detail: report.issues.map { l.verificationIssueText($0) }.joined(separator: "\n")))
        }
    }

    // MARK: Verification

    func verifyBackup(_ url: URL) {
        screen = .verifying
        verificationProgress = 0
        backupURL = url
        let verifier = BackupVerifier(layout: services.layout)
        let model = self
        task = Task.detached { [weak self] in
            let report = verifier.verify(backupAt: url) { fraction in
                Task { @MainActor in model.verificationProgress = fraction }
            }
            await MainActor.run { [weak self] in
                self?.verification = report
                self?.screen = .verificationResult
            }
        }
    }

    // MARK: Restore selection

    var candidateItems: [RestoreItem] {
        guard let manifest else { return [] }
        return RestorePlanner().candidateItems(manifest: manifest, selection: selection)
    }

    func currentPlan() -> RestorePlan? {
        guard let manifest else { return nil }
        return RestorePlanner().plan(manifest: manifest, selection: selection)
    }

    private func makeExecutor(log: LogStore) -> RestoreExecutor? {
        guard let backupURL else { return nil }
        var environment = RestoreEnvironment(
            layout: services.layout, runner: services.runner, privileged: services.privileged,
            homebrewSource: services.homebrewSource, localizer: l, log: log, targetArchitecture: services.architecture,
            askpassPath: services.askpassPath)
        environment.credentialPassphrase = restorePassphrase
        environment.isApplicationRunning = { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        return RestoreExecutor(environment: environment, backupRoot: backupURL, sessionStore: services.sessionStore,
                               damagedFiles: verification?.damagedFiles ?? [])
    }

    /// Checks every item of the backup against this Mac (read-only) for the restore selection. With
    /// `applyDefaults`, items that should not be restored here (e.g. display profiles of the old Mac)
    /// start deselected; the user can change that.
    func assessDestination(applyDefaults: Bool) {
        guard let manifest, let executor = makeExecutor(log: LogStore(fileURL: nil, homeDirectory: services.layout.homeDirectory)) else { return }
        var everything = selection
        everything.components = Set(RestoreComponent.allCases)
        everything.excludedItemIDs = []
        let plan = RestorePlanner().plan(manifest: manifest, selection: everything)
        let current = selection
        assessing = true
        assessmentTask?.cancel()
        assessmentTask = Task { [weak self] in
            let entries = await executor.dryRun(plan: plan, selection: current, checkPackages: false)
            guard let self, !Task.isCancelled else { return }
            self.assessments = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let notRecommended = RestoreSelection.notRecommended(entries)
            self.notRecommendedItemIDs = notRecommended
            if applyDefaults {
                self.selection.excludedItemIDs.formUnion(notRecommended)
                self.appLog.info("Destination check: \(entries.count) items, \(notRecommended.count) not recommended for this Mac", component: .restore)
            }
            self.assessing = false
        }
    }

    /// What restoring a font or profile would do with the current choices.
    func filePrediction(_ entry: DryRunEntry) -> Prediction? {
        guard let assessment = entry.fileAssessment else { return nil }
        return RestoreExecutor.filePrediction(for: assessment, item: entry.item, selection: selection)
    }

    func startDryRun() {
        guard let plan = currentPlan(), let executor = makeExecutor(log: LogStore(fileURL: nil, homeDirectory: services.layout.homeDirectory)) else { return }
        self.plan = plan
        dryRunEntries = []
        dryRunInProgress = true
        screen = .dryRun
        let selection = self.selection
        task = Task { [weak self] in
            let entries = await executor.dryRun(plan: plan, selection: selection)
            self?.dryRunEntries = entries
            self?.dryRunInProgress = false
        }
    }

    /// Checks for conflicts and administrator needs, then starts the restore or asks first.
    func requestRestoreStart() {
        guard let plan = currentPlan(), let executor = makeExecutor(log: LogStore(fileURL: nil, homeDirectory: services.layout.homeDirectory)) else { return }
        self.plan = plan
        let selection = self.selection
        task = Task { [weak self] in
            let entries = await executor.dryRun(plan: plan, selection: selection)
            guard let self else { return }
            // Every conflict needs a decision; choices made earlier in the item list count.
            let conflicts = entries.filter { entry in
                guard case .conflict = entry.prediction else { return false }
                return self.selection.conflictOverrides[entry.item.id] == nil
            }
            if !conflicts.isEmpty {
                self.pendingConflicts = conflicts
                return
            }
            self.checkAdminAndStart(entries: entries)
        }
    }

    func resolveConflicts(_ choices: [String: ConflictResolution]) {
        selection.conflictOverrides.merge(choices) { _, new in new }
        pendingConflicts = []
        guard let plan, let executor = makeExecutor(log: LogStore(fileURL: nil, homeDirectory: services.layout.homeDirectory)) else { return }
        let selection = self.selection
        task = Task { [weak self] in
            let entries = await executor.dryRun(plan: plan, selection: selection)
            self?.checkAdminAndStart(entries: entries)
        }
    }

    private func checkAdminAndStart(entries: [DryRunEntry]) {
        let notice = AdminNotice(
            installsHomebrew: entries.contains { $0.item.kind == .homebrew && $0.prediction == .willInstall },
            copiesSharedFiles: entries.contains { $0.item.kind.isFile && $0.requiresAdmin },
            installsCommandLineTools: entries.contains { $0.item.kind == .commandLineTools && $0.prediction == .willInstall })
        if notice.installsHomebrew || notice.copiesSharedFiles || notice.installsCommandLineTools {
            adminNotice = notice
        } else {
            startRestore()
        }
    }

    func startRestore() {
        adminNotice = nil
        if selection.components.contains(.credentials), !(manifest?.credentials.isEmpty ?? true), restorePassphrase == nil {
            askForRestorePassphrase = true
            return
        }
        guard let plan = plan ?? currentPlan(), let backupURL else { return }
        if let reviewing = reviewingSession, let manifest {
            // Continue the interrupted restore with the reviewed choices; finished steps keep their results.
            reviewingSession = nil
            let (merged, session) = RestorePlanner().continuation(of: reviewing, manifest: manifest, selection: selection)
            let finished = reviewing.results.keys
            appLog.info("Continuing restore \(session.id) with a reviewed selection: \(finished.count) finished, \(session.remainingItemIDs.count) remaining", component: .restore)
            run(plan: merged, session: session)
            return
        }
        let session = RestoreSession(backupPath: services.layout.displayPath(backupURL), selection: selection, itemIDs: plan.items.map(\.id))
        run(plan: plan, session: session)
    }

    private func run(plan: RestorePlan, session: RestoreSession) {
        let log = LogStore.session(in: services.layout.logs, name: "restore", homeDirectory: services.layout.homeDirectory)
        restoreLog = log
        // Items the user left out never reach the plan; their decision is still recorded.
        let planned = Set(plan.items.map(\.id))
        for item in candidateItems where !planned.contains(item.id) && session.selection.excludedItemIDs.contains(item.id) {
            log.info("\(item.id): decision skipped_by_user", component: item.kind.logComponent)
        }
        guard let executor = makeExecutor(log: log) else { return }
        self.plan = plan
        self.session = session
        var state = RestoreProgressState()
        state.total = plan.items.count
        state.estimator = ProgressEstimator(items: plan.items, alreadyFinished: session.finishedItemIDs)
        for item in plan.items {
            guard let result = session.results[item.id] else { continue }
            state.finished.append((item, result))
            count(result.outcome, into: &state)
        }
        progress = state
        screen = .restoring
        unfinishedSession = nil
        let model = self
        task = Task { [weak self] in
            let finalSession = await executor.run(plan: plan, session: session) { event in
                Task { @MainActor in model.handle(event) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.session = finalSession
                self.screen = .restoreSummary
                self.writeRestoreReport(plan: plan, session: finalSession)
            }
        }
    }

    private func count(_ outcome: ItemOutcome, into state: inout RestoreProgressState) {
        if outcome.isSuccessLike { state.succeeded += 1 } else if outcome.isFailure { state.failed += 1 } else { state.skipped += 1 }
    }

    private func handle(_ event: RestoreEvent) {
        switch event {
        case .started(let item, let index, let total):
            progress.currentItem = item
            progress.position = index + 1
            progress.total = total
            progress.activity = .checking
        case .activity(_, let activity):
            progress.activity = activity
        case .finished(let item, let result, _, _):
            progress.finished.append((item, result))
            count(result.outcome, into: &progress)
            progress.estimator.record(itemID: item.id, duration: result.duration, didWork: result.outcome == .succeeded || result.outcome.isFailure)
        case .completed:
            progress.currentItem = nil
        }
    }

    /// Stops after the current step; the session stays resumable.
    func stopRestore() {
        progress.stopping = true
        task?.cancel()
    }

    func resumeRestore(_ session: RestoreSession, askForPassphrase: Bool = true) {
        guard let manifest else {
            let url = services.layout.resolve(displayPath: session.backupPath)
            openBackupForRestore(url, resuming: session)
            return
        }
        selection = session.selection
        // The passphrase is never stored, so it is asked again if credentials are still to be restored.
        let credentialsPending = session.itemIDs.contains { $0.hasPrefix("credential:") && session.results[$0] == nil }
        if session.selection.components.contains(.credentials), credentialsPending, !manifest.credentials.isEmpty, restorePassphrase == nil, askForPassphrase {
            pendingResume = session
            askForRestorePassphrase = true
            return
        }
        let plan = RestorePlanner().plan(manifest: manifest, selection: session.selection)
        run(plan: plan, session: session)
    }

    func resumeUnfinished() {
        guard let session = unfinishedSession else { return }
        let url = services.layout.resolve(displayPath: session.backupPath)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(ManifestIO.fileName).path) else {
            show(ProblemInfo(title: l.t("resume.backupMissing.title"), message: l.t("resume.backupMissing.message", session.backupPath), detail: nil))
            return
        }
        openBackupForRestore(url, resuming: session)
    }

    /// Opens the interrupted restore's backup so the remaining choices can be changed before continuing.
    func reviewUnfinished() {
        guard let session = unfinishedSession else { return }
        let url = services.layout.resolve(displayPath: session.backupPath)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(ManifestIO.fileName).path) else {
            show(ProblemInfo(title: l.t("resume.backupMissing.title"), message: l.t("resume.backupMissing.message", session.backupPath), detail: nil))
            return
        }
        openBackupForRestore(url, resuming: session, reviewing: true)
    }

    func discardUnfinished() {
        guard let session = unfinishedSession else { return }
        try? services.sessionStore.remove(id: session.id)
        restorePassphrase = nil
        unfinishedSession = services.sessionStore.unfinishedSession()
    }

    func retryFailed() {
        guard let plan, let session, let backupURL else { return }
        let failedIDs = Set(session.results.filter { $0.value.outcome.isFailure }.map(\.key))
        guard !failedIDs.isEmpty else { return }
        let retryPlan = plan.subset(retrying: failedIDs)
        let retrySession = RestoreSession(backupPath: services.layout.displayPath(backupURL), selection: session.selection,
                                          itemIDs: retryPlan.items.map(\.id))
        run(plan: retryPlan, session: retrySession)
    }

    // MARK: Reports

    @Published var lastReport: URL?

    private func writeRestoreReport(plan: RestorePlan, session: RestoreSession) {
        guard let manifest else { return }
        let html = ReportBuilder(localizer: l).restoreSummaryReport(plan: plan, session: session, manifest: manifest)
        let folder = services.layout.applicationSupport.appendingPathComponent("Reports")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("restore-\(session.id.prefix(8)).html")
        if (try? Data(html.utf8).write(to: url, options: .atomic)) != nil { lastReport = url }
        // Keep only the newest reports in MacReplica's own folder.
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let reports = items.filter { $0.lastPathComponent.hasPrefix("restore-") && $0.pathExtension == "html" }
                .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
            for old in reports.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        }
    }

    func exportDryRunReport() {
        guard let manifest, let plan else { return }
        let html = ReportBuilder(localizer: l).dryRunReport(dryRunEntries, manualApps: plan.manualApps, manifest: manifest)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dry_run.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(html.utf8).write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openWebPage(_ string: String?) {
        guard let string, let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func displayPath(_ url: URL) -> String { services.layout.displayPath(url) }
}

extension URL {
    var modificationDate: Date? { try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}

// MARK: - Updates, permissions, developer settings and credentials

extension AppModel {
    var includePrereleases: Bool {
        get { services.defaults.bool(forKey: "includePrereleases") }
        set { services.defaults.set(newValue, forKey: "includePrereleases"); objectWillChange.send() }
    }

    var checkAutomatically: Bool {
        get { services.defaults.bool(forKey: "checkForUpdatesAutomatically") }
        set { services.defaults.set(newValue, forKey: "checkForUpdatesAutomatically"); objectWillChange.send() }
    }

    /// Checks GitHub Releases. Only informs; nothing is downloaded.
    func checkForUpdates(userInitiated: Bool) {
        checkingForUpdates = true
        let checker = UpdateChecker(fetcher: services.releaseFetcher)
        let prereleases = includePrereleases
        Task { [weak self] in
            let status = await checker.check(includePrereleases: prereleases)
            guard let self else { return }
            self.checkingForUpdates = false
            self.services.defaults.set(Date(), forKey: "lastUpdateCheck")
            self.appLog.info("Update check: \(status)", component: .general)
            // Automatic checks only speak up when there is something new.
            if userInitiated { self.updateStatus = status } else if case .available = status { self.updateStatus = status }
        }
    }

    /// At most once a week, and only if the user switched it on.
    func automaticUpdateCheckIfDue() {
        guard checkAutomatically, !safeMode else { return }
        let last = services.defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 7 * 24 * 3600 { checkForUpdates(userInitiated: false) }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(AccessProbe.fullDiskAccessSettingsURL)
    }

    /// Locations macOS did not let MacReplica read during the scan.
    var blockedLocations: [LocationAccess] {
        (inventory?.manifest.locations ?? []).filter { $0.status == .noPermission }
    }

    /// Credential providers with something to export on this Mac, and what they would export.
    var detectedCredentials: [(provider: CredentialProvider, items: [String])] {
        CredentialProviders.all.compactMap { provider in
            let items = provider.detect(layout: services.layout)
            return items.isEmpty ? nil : (provider, items)
        }
    }

    /// Applies the Git choices (include settings, include email) to the inventory before saving.
    func applyDeveloperChoices(to inventory: inout InventoryResult) {
        var developer = DeveloperSettingsScanner(layout: services.layout).scan(includeEmail: includeGitEmail)
        if !includeGitSettings {
            developer.gitConfig = nil
            developer.gitConfigIncludesEmail = false
            developer.removedGitSections = []
        }
        inventory.manifest.developer = developer
    }
}
