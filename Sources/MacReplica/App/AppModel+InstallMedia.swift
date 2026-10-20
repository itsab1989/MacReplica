import AppKit
import MacReplicaCore
import SwiftUI
import UniformTypeIdentifiers

/// Tools › Create macOS Installer: choose a release, get its installer, choose a drive, confirm, create, check.
struct InstallMediaState {
    enum Step: Equatable { case choose, installer, drive, confirm, working, finished, failed }

    var step: Step = .choose
    var catalog = MacOSInstallerCatalog()
    var refreshing = false
    var selected: MacOSRelease?
    var report: InstallerAppReport?
    var inspecting = false
    var downloading = false
    var downloadPercent: Double?
    var downloadProblem: String?
    /// The App Store or Apple's download page was opened; the user comes back with “Check Again”.
    var openedExternally = false
    var drives: [DriveCandidate] = []
    var scanningDrives = false
    var driveProblem: String?
    var selectedDrive: String?
    /// Expert option: list empty partitions of internal disks.
    var showInternalPartitions = false
    var understood = false
    /// The second confirmation an internal partition needs.
    var understoodInternal = false
    /// The final question before erasing an internal partition.
    var askingFinalConfirmation = false
    var stage: InstallMediaStage?
    var startedAt: Date?
    var result: InstallMediaResult?
    var failure: InstallMediaError?
    /// Whether the drive was erased before the failure (then it holds no installer).
    var driveErased = false
    /// The confirmed drive changed or disappeared while the confirmation was open.
    var confirmedDriveChanged = false
    var task: Task<Void, Never>?
    /// The Apple installers in Applications, checked.
    var localInstallers: [InstallerAppReport] = []
    var checkingLocal = false
    /// An installer the user chose outside Applications, waiting for “Copy”.
    var pendingCopy: URL?
    /// Its size (measured in the background) plus room, and the free space in Applications.
    var pendingCopyNeeded: Int64?
    var copying = false
    var copyProblem: String?
    /// An installer waiting for the Trash confirmation.
    var trashCandidate: URL?
    var trashCandidateSize: Int64?
    var trashing = false
    var trashMessage: String?
    var trashFailed = false

    var confirmedCandidate: DriveCandidate? { drives.first { $0.id == selectedDrive && $0.isEligible } }
    var confirmedDrive: InstallMediaDrive? { confirmedCandidate?.drive }
    /// Everything needed before “Erase and Create Installer” can be pressed.
    var readyToCreate: Bool { understood && (confirmedCandidate?.isPartition == true ? understoodInternal : true) }
}

extension AppModel {
    var installMediaInspector: InstallerInspector {
        InstallerInspector(layout: services.layout, runner: services.runner, environment: tools.environment,
                           hasRosetta: FileManager.default.fileExists(atPath: services.layout.rosettaMarker))
    }

    var installMediaScanner: InstallMediaDriveScanner {
        var protected = [Bundle.main.bundleURL]
        if let app = installMedia.report?.app { protected.append(app) }
        if let backup = defaults.string(forKey: "lastBackup") { protected.append(URL(fileURLWithPath: backup)) }
        return InstallMediaDriveScanner(layout: services.layout, runner: services.runner, protectedPaths: protected,
                                        includeInternalPartitions: installMedia.showInternalPartitions)
    }

    var installerFiles: InstallerFiles {
        InstallerFiles(layout: services.layout, runner: services.runner, privileged: services.privileged)
    }

    var installMediaCreator: InstallMediaCreator {
        InstallMediaCreator(layout: services.layout, runner: services.runner, privileged: services.privileged,
                            scanner: installMediaScanner, inspector: installMediaInspector)
    }

    var installerCatalogLoader: MacOSInstallerCatalogLoader {
        let cache = services.layout.caches.appendingPathComponent("macos-installers.json")
        guard let root = services.simulationRoot else {
            return MacOSInstallerCatalogLoader(layout: services.layout, runner: services.runner, cacheFile: cache)
        }
        // A simulated Mac reads its own copy of Apple's page, never the network.
        let page = root.appendingPathComponent("install-media/apple-102662.html")
        return MacOSInstallerCatalogLoader(layout: services.layout, runner: services.runner, cacheFile: cache) { _ in
            try String(contentsOf: page, encoding: .utf8)
        }
    }

    func openInstallMedia() {
        installMedia.task?.cancel()
        installMedia = InstallMediaState()
        installMedia.catalog = installerCatalogLoader.cached()
        screen = .installMedia
        refreshInstallerCatalog()
        refreshLocalInstallers()
    }

    /// Reads the Apple installers in Applications (version, signature, tool).
    func refreshLocalInstallers() {
        let inspector = installMediaInspector
        installMedia.checkingLocal = true
        Task {
            var reports: [InstallerAppReport] = []
            for app in inspector.installedInstallers() where InstallerFiles.isAppleInstaller(app) {
                reports.append(await inspector.inspect(app))
            }
            installMedia.localInstallers = reports.sorted { VersionComparison.compare($0.macOSVersion ?? "0", $1.macOSVersion ?? "0") == .orderedDescending }
            installMedia.checkingLocal = false
            appLog.info("Install media: installers on this Mac: \(reports.map { "\($0.app.lastPathComponent) \($0.macOSVersion ?? "?")" }.joined(separator: ", "))",
                        component: .tools)
        }
    }

    /// Continues with an installer that is already on this Mac.
    func useLocalInstaller(_ report: InstallerAppReport) {
        installMedia.selected = InstallerFiles.release(from: report)
        installMedia.report = report
        installMedia.downloadProblem = nil
        installMedia.openedExternally = false
        installMedia.step = .installer
    }

    /// An installer from anywhere: used where it is if it is in Applications, otherwise copied there after a question.
    func chooseInstallerFile() {
        installMedia.copyProblem = nil
        let url: URL
        if services.simulationRoot != nil, defaults.bool(forKey: "stagingSkipPanels"), let path = defaults.string(forKey: "stagingInstallerApp") {
            url = URL(fileURLWithPath: path)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.message = l.t("installMedia.local.panel")
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard InstallerFiles.isAppleInstaller(url) else {
            installMedia.copyProblem = l.t("installMedia.copy.notAnInstaller")
            return
        }
        if PrivilegedOperation.isInstallerApp(url, applicationFolders: services.layout.applicationFolders) {
            useInstallerAt(url)
        } else {
            installMedia.pendingCopy = url
            installMedia.pendingCopyNeeded = nil
            Task {
                // Measured off the main thread; the answer is used only if the same installer is still waiting.
                let needed = await Task.detached { InstallerInspector.allocatedSize(of: url) + 1_073_741_824 }.value
                if installMedia.pendingCopy == url { installMedia.pendingCopyNeeded = needed }
            }
        }
    }

    private func useInstallerAt(_ url: URL) {
        let inspector = installMediaInspector
        installMedia.inspecting = true
        Task {
            let report = await inspector.inspect(url)
            installMedia.inspecting = false
            useLocalInstaller(report)
            refreshLocalInstallers()
        }
    }

    func cancelCopy() { installMedia.pendingCopy = nil }

    func confirmCopy() {
        guard let source = installMedia.pendingCopy else { return }
        installMedia.copying = true
        installMedia.copyProblem = nil
        let files = installerFiles
        appLog.info("Install media: copying \(source.lastPathComponent) into Applications", component: .tools)
        Task {
            do {
                let copied = try await files.copyIntoApplications(source)
                installMedia.copying = false
                installMedia.pendingCopy = nil
                useInstallerAt(copied)
            } catch {
                installMedia.copying = false
                installMedia.copyProblem = installerFilesMessage(error)
            }
        }
    }

    func askToTrash(_ app: URL, size: Int64?) {
        installMedia.trashMessage = nil
        installMedia.trashCandidateSize = size
        installMedia.trashCandidate = app
    }

    func confirmTrash() {
        guard let app = installMedia.trashCandidate else { return }
        installMedia.trashCandidate = nil
        installMedia.trashing = true
        let files = installerFiles
        Task {
            do {
                try await files.moveToTrash(app)
                installMedia.trashFailed = false
                installMedia.trashMessage = l.t("installMedia.trash.done", app.lastPathComponent)
                appLog.info("Install media: moved \(app.lastPathComponent) to the Trash", component: .tools)
            } catch {
                installMedia.trashFailed = true
                installMedia.trashMessage = installerFilesMessage(error)
                appLog.info("Install media: could not move \(app.lastPathComponent) to the Trash: \(error)", component: .tools)
            }
            installMedia.trashing = false
            refreshLocalInstallers()
        }
    }

    func installerFilesMessage(_ error: Error) -> String {
        switch error as? InstallerFilesError {
        case .notAnInstaller: return l.t("installMedia.copy.notAnInstaller")
        case .alreadyInApplications(let name): return l.t("installMedia.copy.already", name)
        case .notEnoughSpace(let needed, let available): return l.t("installMedia.copy.space", l.fileSize(needed), l.fileSize(available))
        case .copyFailed(let detail): return l.t("installMedia.copy.failedDetail", detail)
        case .trashFailed(let detail): return l.t("installMedia.trash.failed", detail)
        case .passwordDenied: return l.t("installMedia.trash.password")
        case nil: return services.layout.redact(String(describing: error))
        }
    }

    /// Back to the start screen from any step except while the drive is written (that cannot be stopped safely).
    func installMediaGoHome() {
        guard installMedia.step != .working else { return }
        installMedia.task?.cancel()
        installMedia = InstallMediaState()
        goHome()
    }

    /// Starts watching for connected and removed drives on the drive and confirm steps, stops everywhere else.
    func updateDriveWatcher() {
        let watching = screen == .installMedia && (installMedia.step == .drive || installMedia.step == .confirm)
        if watching, driveWatcher == nil {
            let watcher = DriveWatcher { [weak self] in self?.drivesChanged() }
            watcher.start()
            driveWatcher = watcher
        } else if !watching, let watcher = driveWatcher {
            watcher.stop()
            driveWatcher = nil
        }
    }

    /// A drive was connected, removed or changed: read the drives again. If the drive being confirmed is no longer
    /// exactly the same, go back to the list (the check right before erasing would stop anyway).
    func drivesChanged() {
        guard installMedia.step == .drive || installMedia.step == .confirm, !installMedia.scanningDrives else { return }
        appLog.info("Install media: a drive was connected, removed or changed; reading the drives again", component: .tools)
        let confirming = installMedia.step == .confirm ? installMedia.confirmedCandidate : nil
        scanDrives { [weak self] in
            guard let self, let confirming, self.installMedia.step == .confirm else { return }
            let now = self.installMedia.drives.first { $0.id == confirming.id }
            if now == nil || now?.drive.fingerprint != confirming.drive.fingerprint || now?.partition != confirming.partition || now?.isEligible != true {
                self.installMedia.selectedDrive = nil
                self.installMedia.understood = false
                self.installMedia.understoodInternal = false
                self.installMedia.confirmedDriveChanged = true
                self.installMedia.step = .drive
            }
        }
    }

    func setShowInternalPartitions(_ on: Bool) {
        installMedia.showInternalPartitions = on
        installMedia.selectedDrive = nil
        scanDrives()
    }

    func closeInstallMedia() {
        guard installMedia.step != .working else { return }
        installMedia.task?.cancel()
        installMedia = InstallMediaState()
        tools.history = toolHistory.entries()
        screen = .tools
    }

    func refreshInstallerCatalog() {
        guard !installMedia.refreshing else { return }
        installMedia.refreshing = true
        let loader = installerCatalogLoader
        Task {
            let catalog = await loader.refresh()
            installMedia.catalog = catalog
            installMedia.refreshing = false
            appLog.info("Install media: catalog \(catalog.releases.count) releases; Software Update \(catalog.softwareUpdateProblem ?? "ok"), Apple page \(catalog.applePageProblem ?? "ok")",
                        component: .tools)
        }
    }

    func suitability(of release: MacOSRelease) -> InstallerSuitability {
        MacOSInstallerCatalog.suitability(of: release, on: tools.environment)
    }

    func chooseRelease(_ release: MacOSRelease) {
        installMedia.selected = release
        installMedia.report = nil
        installMedia.downloadProblem = nil
        installMedia.openedExternally = false
        installMedia.step = .installer
        checkForInstaller()
    }

    /// Looks for the release's installer in Applications (Apple's name for it) and reads it.
    func checkForInstaller() {
        guard let release = installMedia.selected else { return }
        let inspector = installMediaInspector
        var found = inspector.installer(for: release)
        if case .onThisMac(let path) = release.source {
            found = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let app = found else {
            installMedia.report = nil
            return
        }
        installMedia.inspecting = true
        Task {
            let report = await inspector.inspect(app)
            installMedia.report = report
            installMedia.inspecting = false
            appLog.info("Install media: \(app.lastPathComponent) \(report.appVersion ?? "?"), macOS \(report.macOSVersion ?? "?"), signed by Apple \(report.signedByApple), createinstallmedia \(report.createInstallMedia != nil)",
                        component: .tools)
        }
    }

    var installerProblems: [InstallerAppProblem] {
        guard let report = installMedia.report else { return [] }
        return installMediaInspector.problems(of: report)
    }

    func downloadInstaller() {
        guard let release = installMedia.selected, !installMedia.downloading else { return }
        installMedia.downloading = true
        installMedia.downloadPercent = nil
        installMedia.downloadProblem = nil
        let creator = installMediaCreator
        appLog.info("Install media: downloading \(release.version ?? release.major) from Software Update", component: .tools)
        installMedia.task = Task {
            do {
                _ = try await creator.download(release) { percent in
                    Task { @MainActor in self.installMedia.downloadPercent = percent }
                }
                installMedia.downloading = false
                checkForInstaller()
            } catch is CancellationError {
                installMedia.downloading = false
            } catch {
                installMedia.downloading = false
                installMedia.downloadProblem = Task.isCancelled ? nil : installMediaMessage(error)
            }
        }
    }

    func cancelDownload() {
        installMedia.task?.cancel()
        installMedia.downloading = false
        appLog.info("Install media: download cancelled", component: .tools)
    }

    /// The App Store page or Apple's disk image, opened for the user (MacReplica downloads only from Software Update).
    func openExternalInstaller() {
        guard let release = installMedia.selected else { return }
        let link: String
        switch release.source {
        case .appStore(_, let url): link = url
        case .appleDiskImage(let url): link = url
        case .softwareUpdate, .onThisMac: return
        }
        installMedia.openedExternally = true
        appLog.info("Install media: opened Apple's link for \(release.name) \(release.major)", component: .tools)
        if services.simulationRoot == nil, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func continueToDrives() {
        installMedia.step = .drive
        installMedia.selectedDrive = nil
        scanDrives()
    }

    func scanDrives(then done: (@MainActor () -> Void)? = nil) {
        guard let report = installMedia.report else { return }
        installMedia.scanningDrives = true
        installMedia.driveProblem = nil
        let scanner = installMediaScanner
        Task {
            do {
                installMedia.drives = try await scanner.scan(required: report.requiredBytes)
                if let selected = installMedia.selectedDrive, !installMedia.drives.contains(where: { $0.id == selected && $0.isEligible }) {
                    installMedia.selectedDrive = nil
                }
            } catch {
                installMedia.drives = []
                installMedia.driveProblem = installMediaMessage(error)
            }
            installMedia.scanningDrives = false
            done?()
            appLog.info("Install media: drives \(installMedia.drives.map { "\($0.id)=\($0.isEligible ? "eligible" : "protected")" }.joined(separator: ","))",
                        component: .tools)
        }
    }

    func continueToConfirm() {
        guard installMedia.confirmedDrive != nil else { return }
        installMedia.confirmedDriveChanged = false
        installMedia.understood = false
        installMedia.understoodInternal = false
        installMedia.step = .confirm
    }

    func installMediaBack() {
        switch installMedia.step {
        case .installer: if !installMedia.downloading { installMedia.step = .choose }
        case .drive: installMedia.step = .installer
        case .confirm: installMedia.step = .drive; scanDrives()
        case .failed: installMedia.step = .drive; scanDrives()
        case .choose, .finished: closeInstallMedia()
        case .working: break
        }
    }

    /// Erases the confirmed drive and creates the installer – once; a failure is shown, never retried by itself.
    /// The button: an internal partition gets one more question first.
    func requestCreateInstallMedia() {
        guard installMedia.readyToCreate, let candidate = installMedia.confirmedCandidate else { return }
        if candidate.isPartition { installMedia.askingFinalConfirmation = true } else { createInstallMedia() }
    }

    func createInstallMedia() {
        installMedia.askingFinalConfirmation = false
        guard installMedia.readyToCreate, let candidate = installMedia.confirmedCandidate, let report = installMedia.report,
              let release = installMedia.selected else { return }
        let drive = candidate.drive
        installMedia.step = .working
        installMedia.stage = nil
        installMedia.startedAt = Date()
        installMedia.result = nil
        installMedia.failure = nil
        installMedia.driveErased = false
        let creator = installMediaCreator
        appLog.info("Install media: creating \(report.app.lastPathComponent) on \(candidate.partition?.device ?? drive.device) (\(candidate.isPartition ? "partition of internal disk" : drive.busProtocol), \(candidate.partition?.sizeBytes ?? drive.sizeBytes) bytes)", component: .tools)
        // The Mac stays awake while the drive is written (`updateSleepPrevention`, from the working step).
        installMedia.task = Task {
            do {
                let result = try await creator.create(installer: report, on: candidate) { stage in
                    Task { @MainActor in self.installMedia.stage = stage }
                }
                installMedia.result = result
                installMedia.step = .finished
                recordInstallMedia(release: release, report: report, drive: drive, partition: candidate.isPartition, result: result.verification == .failed ? .failed : .succeeded,
                                   verification: result.verification)
                appLog.info("Install media: finished, \(result.verification.rawValue); \(result.checks.map { "\($0.item.rawValue)=\($0.passed)" }.joined(separator: ","))",
                            component: .tools)
            } catch {
                let failure = (error as? InstallMediaError) ?? .createFailed(services.layout.redact(String(describing: error)))
                installMedia.failure = failure
                // Read the drive again rather than guess from the step: was anything erased?
                if case .drive = failure { installMedia.driveErased = false }
                else if case .installerUnusable = failure { installMedia.driveErased = false }
                else if case .refused = failure { installMedia.driveErased = false }
                else { installMedia.driveErased = await creator.wasErased(candidate) }
                installMedia.step = .failed
                recordInstallMedia(release: release, report: report, drive: drive, partition: candidate.isPartition, result: failure == .passwordDenied ? .cancelled : .failed,
                                   verification: .notVerified)
                appLog.info("Install media: failed: \(installMediaMessage(error))", component: .tools)
            }
        }
    }

    private func recordInstallMedia(release: MacOSRelease, report: InstallerAppReport, drive: InstallMediaDrive, partition: Bool, result: ToolHistoryEntry.Result,
                                    verification: ToolVerification) {
        // No drive or volume names (they can be personal): the macOS version, the connection and the size.
        let state = "macOS=\(report.macOSVersion ?? release.version ?? release.major);build=\(report.build ?? release.build ?? "?");drive=\(drive.busProtocol) \(drive.sizeBytes / 1_000_000_000) GB" + (partition ? ";target=internalPartition" : "")
        try? toolHistory.append(ToolHistoryEntry(tool: "installMedia", change: "installMedia.create", previousState: nil, resultingState: state,
                                                 macOSVersion: tools.environment.macOSVersion, result: result, verification: verification,
                                                 revertAvailable: false))
    }

    func installMediaMessage(_ error: Error) -> String {
        guard let error = error as? InstallMediaError else {
            if let drive = error as? InstallMediaDriveError { return installMediaMessage(InstallMediaError.drive(drive)) }
            return services.layout.redact(String(describing: error))
        }
        switch error {
        case .downloadFailed(let detail): return l.t("installMedia.error.download", detail)
        case .installerNotFound(let name): return l.t("installMedia.error.notFound", name)
        case .installerUnusable: return l.t("installMedia.error.unusable")
        case .drive(.driveChanged): return l.t("installMedia.error.driveChanged")
        case .drive(.driveNotEligible): return l.t("installMedia.error.driveNotEligible")
        case .drive(.listFailed(let detail)): return l.t("installMedia.error.listFailed", detail)
        case .eraseFailed(let detail): return l.t("installMedia.error.erase", detail)
        case .volumeMissing: return l.t("installMedia.error.volumeMissing")
        case .passwordDenied: return l.t("installMedia.error.password")
        case .createFailed(let detail): return l.t("installMedia.error.create", detail)
        case .refused(let detail): return l.t("installMedia.error.refused", detail)
        }
    }
}
