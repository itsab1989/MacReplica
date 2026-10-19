import AppKit
import MacReplicaCore
import SwiftUI

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
    var understood = false
    var stage: InstallMediaStage?
    var startedAt: Date?
    var result: InstallMediaResult?
    var failure: InstallMediaError?
    /// Whether the drive was erased before the failure (then it holds no installer).
    var driveErased = false
    var task: Task<Void, Never>?

    var confirmedDrive: InstallMediaDrive? { drives.first { $0.id == selectedDrive && $0.isEligible }?.drive }
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
        return InstallMediaDriveScanner(layout: services.layout, runner: services.runner, protectedPaths: protected)
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
        guard let app = inspector.installer(for: release) else {
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
        case .softwareUpdate: return
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

    func scanDrives() {
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
            appLog.info("Install media: drives \(installMedia.drives.map { "\($0.id)=\($0.isEligible ? "eligible" : "protected")" }.joined(separator: ","))",
                        component: .tools)
        }
    }

    func continueToConfirm() {
        guard installMedia.confirmedDrive != nil else { return }
        installMedia.understood = false
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
    func createInstallMedia() {
        guard installMedia.understood, let drive = installMedia.confirmedDrive, let report = installMedia.report,
              let release = installMedia.selected else { return }
        installMedia.step = .working
        installMedia.stage = nil
        installMedia.startedAt = Date()
        installMedia.result = nil
        installMedia.failure = nil
        installMedia.driveErased = false
        let creator = installMediaCreator
        appLog.info("Install media: creating \(report.app.lastPathComponent) on \(drive.device) (\(drive.busProtocol), \(drive.sizeBytes) bytes)", component: .tools)
        // The Mac must not go to sleep while the drive is written.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Creating a macOS installer")
        installMedia.task = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let result = try await creator.create(installer: report, on: drive) { stage in
                    Task { @MainActor in
                        self.installMedia.stage = stage
                        if stage == .creating { self.installMedia.driveErased = true }
                    }
                }
                installMedia.result = result
                installMedia.step = .finished
                recordInstallMedia(release: release, report: report, drive: drive, result: result.verification == .failed ? .failed : .succeeded,
                                   verification: result.verification)
                appLog.info("Install media: finished, \(result.verification.rawValue); \(result.checks.map { "\($0.item.rawValue)=\($0.passed)" }.joined(separator: ","))",
                            component: .tools)
            } catch {
                let failure = (error as? InstallMediaError) ?? .createFailed(services.layout.redact(String(describing: error)))
                installMedia.failure = failure
                if case .eraseFailed = failure { installMedia.driveErased = true }
                installMedia.step = .failed
                recordInstallMedia(release: release, report: report, drive: drive, result: failure == .passwordDenied ? .cancelled : .failed,
                                   verification: .notVerified)
                appLog.info("Install media: failed: \(installMediaMessage(error))", component: .tools)
            }
        }
    }

    private func recordInstallMedia(release: MacOSRelease, report: InstallerAppReport, drive: InstallMediaDrive, result: ToolHistoryEntry.Result,
                                    verification: ToolVerification) {
        // No drive or volume names (they can be personal): the macOS version, the connection and the size.
        let state = "macOS=\(report.macOSVersion ?? release.version ?? release.major);build=\(report.build ?? release.build ?? "?");drive=\(drive.busProtocol) \(drive.sizeBytes / 1_000_000_000) GB"
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
