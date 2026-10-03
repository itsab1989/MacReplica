import AppKit
import Foundation
import MacReplicaCore

/// The guided installation as the views see it.
struct GuidedUIState {
    /// Official download sources per restore item, after the user asked to look them up.
    var offers: [String: [DownloadOffer]] = [:]
    var findingOffers = false
    var searched = false
    /// Apps ticked for "install one after another".
    var selected = Set<String>()
    var states: [String: GuidedInstallState] = [:]
    var downloads: [String: DownloadState] = [:]
    /// The step MacReplica is waiting for, if any.
    var pending: PendingGuidedStep?
    var running = false
}

struct PendingGuidedStep: Equatable {
    var itemID: String
    var step: GuidedStep
}

/// Bridges the guided installation to AppKit and to the sheet that asks the user.
struct AppGuidedInteraction: GuidedInstallInteraction {
    let model: AppModel

    func openPackage(_ url: URL) async {
        await MainActor.run {
            let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
            NSWorkspace.shared.open([url], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openInFinder(_ url: URL) async {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func open(_ url: URL) async {
        await MainActor.run {
            guard ["https", "macappstore"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                model.pendingDecision = continuation
                model.guided.pending = PendingGuidedStep(itemID: itemID, step: step)
            }
        }
    }
}

extension AppModel {
    /// Steps of the current restore that wait for the user, in plan order.
    var openItems: [RestoreItem] {
        guard let plan, let session else { return [] }
        return plan.items.filter { session.results[$0.id]?.outcome.isOpen == true }
    }

    /// App Store apps and apps without automatic installation that are still open.
    var openApps: [RestoreItem] { openItems.filter { $0.kind == .manualApp || $0.kind == .appStoreApp } }

    /// Developer tool steps the user performs (commands MacReplica cannot run).
    var openToolchainSteps: [RestoreItem] { openItems.filter { $0.kind == .toolchainStep || $0.kind == .displayProfile } }

    func resetGuided() {
        guidedTask?.cancel()
        guidedTask = nil
        pendingDecision?.resume(returning: .later)
        pendingDecision = nil
        guided = GuidedUIState()
        guidedInstallation = nil
        downloadQueue = nil
    }

    func showGuidedInstall() {
        if guided.selected.isEmpty { guided.selected = Set(openApps.map(\.id)) }
        screen = .guidedInstall
    }

    private func makeGuidedInstallation() -> GuidedInstallation {
        if let guidedInstallation { return guidedInstallation }
        let installer = DownloadInstaller(layout: services.layout, runner: services.runner, macOSVersion: services.macOSVersion,
                                          architecture: services.architecture,
                                          rosettaInstalled: FileManager.default.fileExists(atPath: services.layout.rosettaMarker))
        let log = restoreLog ?? LogStore.session(in: services.layout.logs, name: "restore", homeDirectory: services.layout.homeDirectory)
        try? FileManager.default.createDirectory(at: installer.downloadsFolder, withIntermediateDirectories: true)
        if OwnershipMarker.read(from: installer.downloadsFolder) == nil { try? OwnershipMarker(kind: .downloads).write(into: installer.downloadsFolder) }
        let queue = DownloadQueue(transport: services.downloadTransport, folder: installer.downloadsFolder, log: log) { [weak self] id, state in
            Task { @MainActor in self?.guided.downloads[id] = state }
        }
        let installation = GuidedInstallation(installer: installer, queue: queue, log: log) { [weak self] id, state in
            Task { @MainActor in self?.guided.states[id] = state }
        }
        downloadQueue = queue
        guidedInstallation = installation
        return installation
    }

    /// Looks up official sources for the open apps. Only now is the network contacted for them.
    func findOffers() {
        guard let manifest else { return }
        guided.findingOffers = true
        let items = openApps
        let fetcher = services.downloadFetcher
        let catalogProvider = services.catalogProvider
        let macOS = services.macOSVersion
        let architecture = services.architecture
        appLog.info("Looking up official downloads for \(items.count) apps", component: .downloads)
        guidedTask = Task { [weak self] in
            let catalog = try? await catalogProvider.loadCatalog()
            let finder = DownloadSourceFinder(fetcher: fetcher, catalog: catalog, macOSVersion: macOS, architecture: architecture)
            var found: [String: [DownloadOffer]] = [:]
            for item in items {
                let app = item.app ?? manifest.applications.first { $0.bundleIdentifier == item.bundleIdentifier }
                    ?? AppRecord(name: item.title, bundleIdentifier: item.bundleIdentifier, path: item.identifier, source: .appStore,
                                 restoreMethod: Int(item.identifier).map { .appStore(id: $0) } ?? .manual)
                found[item.id] = await finder.offers(for: app, itemID: item.id)
            }
            guard let self else { return }
            self.guided.offers = found
            self.guided.findingOffers = false
            self.guided.searched = true
            for (id, offers) in found where self.selection.sourceChoices[id] == nil {
                if let recommended = offers.first(where: \.recommended) { self.selection.sourceChoices[id] = recommended.id }
            }
            self.appLog.info("Official downloads found for \(found.values.filter { $0.contains(where: \.isDownloadable) }.count) apps", component: .downloads)
        }
    }

    func chosenOffer(for itemID: String) -> DownloadOffer? {
        let offers = guided.offers[itemID] ?? []
        return offers.first { $0.id == selection.sourceChoices[itemID] } ?? offers.first(where: \.recommended) ?? offers.first
    }

    func chooseOffer(_ offerID: String, for itemID: String) {
        selection.sourceChoices[itemID] = offerID
        session?.selection.sourceChoices[itemID] = offerID
    }

    /// Starts downloading the chosen offers of the selected apps (installation follows separately).
    func downloadSelected() {
        let installation = makeGuidedInstallation()
        _ = installation
        guard let queue = downloadQueue else { return }
        let offers = guided.selected.compactMap { chosenOffer(for: $0) }.filter(\.isDownloadable)
        Task { for offer in offers { await queue.enqueue(offer) } }
    }

    func pauseDownload(_ id: String) { Task { await downloadQueue?.pause(id) } }
    func resumeDownload(_ id: String) { Task { await downloadQueue?.resume(id) } }
    func retryDownload(_ id: String) { Task { await downloadQueue?.retry(id) } }
    func cancelDownload(_ id: String) { Task { await downloadQueue?.cancel(id) } }

    /// Installs the given apps one after another: download, verify, install or hand over, check.
    func installSequentially(_ itemIDs: [String]) {
        guard !guided.running else { return }
        let installation = makeGuidedInstallation()
        let entries = openApps.filter { itemIDs.contains($0.id) }.map { ($0, chosenOffer(for: $0.id)) }
        guard !entries.isEmpty else { return }
        guided.running = true
        let layout = services.layout
        let interaction = AppGuidedInteraction(model: self)
        appLog.info("Guided installation of \(entries.count) apps started", component: .downloads)
        guidedTask = Task { [weak self] in
            await installation.runSequence(entries, interaction: interaction, isInstalled: { item in
                AppModel.installedVersion(of: item, layout: layout)
            }, record: { id, result in
                await MainActor.run { self?.recordGuided(id, result) }
            })
            await MainActor.run {
                self?.guided.running = false
                self?.guided.pending = nil
            }
        }
    }

    /// The user's answer to the waiting sheet.
    func answerPending(_ decision: GuidedDecision) {
        guided.pending = nil
        let continuation = pendingDecision
        pendingDecision = nil
        continuation?.resume(returning: decision)
    }

    /// Skips or postpones an app without starting anything.
    func markGuided(_ itemID: String, _ reason: SkipReason) {
        recordGuided(itemID, ItemResult(itemID: itemID, outcome: .skipped(reason)))
    }

    /// Stores a guided result in the restore session (saved, so it survives quitting) and updates the summary.
    func recordGuided(_ itemID: String, _ result: ItemResult) {
        guard var session else { return }
        session.results[itemID] = result
        session.updatedAt = Date()
        if session.remainingItemIDs.isEmpty { session.status = .completed }
        self.session = session
        try? services.sessionStore.save(session)
        restoreLog?.info("\(itemID): \(result.decisionCode)", component: .downloads)
        if session.status == .completed { services.sessionStore.pruneCompleted() }
        guided.selected.remove(itemID)
        if let plan { writeRestoreReport(plan: plan, session: session) }
    }

    /// Checks the open steps again (after the user did something) and continues with what depends on them.
    func checkOpenStepsAgain() {
        guard let session else { return }
        resetGuided()
        resumeRestore(session)
    }

    /// The installed version of an app the item describes, or nil if it is not installed.
    nonisolated static func installedVersion(of item: RestoreItem, layout: SystemLayout) -> String?? {
        for folder in layout.applicationFolders {
            for name in item.appBundleNames where !name.contains("/") {
                let info = NSDictionary(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                guard let info else { continue }
                if let expected = item.bundleIdentifier, (info["CFBundleIdentifier"] as? String)?.lowercased() != expected.lowercased() { continue }
                return .some(info["CFBundleShortVersionString"] as? String)
            }
        }
        return nil
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The instruction for a guided developer-tool step, or the website for installing its manager.
    func instruction(for item: RestoreItem) -> String? {
        if let assignment = item.displayAssignment {
            let profile = assignment.profileDescription ?? assignment.macOSProfile ?? ""
            return l.t("guided.display.instruction", assignment.displayName ?? item.title, profile)
        }
        guard let action = item.toolchain else { return nil }
        return ToolchainCatalog.provider(action.provider).manualInstruction(for: action)
    }
}
