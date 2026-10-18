import Foundation

extension Inspector {
    func predictLaunchpad(_ item: RestoreItem) -> Prediction {
        guard let recorded = item.launchpadLayout, LaunchpadLayout.isSupported(macOSVersion: environment.macOSVersion) else {
            return .willSkip(.launchpadNotAvailable)
        }
        // Launchpad belongs to the user logged in at the screen: MacReplica started as another user (e.g. with sudo)
        // looks in that other user's folder and Dock. Never assumed in a simulation.
        if layout.simulationRoot == nil, !LaunchpadStore.runsAsLoggedInUser { return .willSkip(.launchpadOtherUser) }
        // This macOS has Launchpad: a database that cannot be found is not a missing Launchpad.
        guard let store = layout.launchpadStore, FileManager.default.fileExists(atPath: store.database.path) else {
            return .willSkip(layout.launchpadStore?.accessDenied == true ? .launchpadAccessDenied : .launchpadDatabaseMissing)
        }
        if let current = try? store.read(macOSVersion: environment.macOSVersion, work: launchpadWorkFolder),
           recorded.matches(current, installed: current.appEntryCounts),
           Set(recorded.appEntryCounts.keys).isSubset(of: current.appEntryCounts.keys) {
            return .alreadyPresent(version: nil)
        }
        return .willInstall
    }

    var launchpadWorkFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macreplica-launchpad-\(UUID().uuidString)")
    }
}

extension RestoreExecutor {
    /// Arranges Launchpad as on the old Mac. Runs last, so the apps of this restore are installed: apps that
    /// are not on this Mac are left out (their folders keep the others), apps that were not in the layout
    /// follow on further pages. While apps of this restore still wait to be installed, the step stays open and
    /// arranges Launchpad again when the restore continues.
    func restoreLaunchpad(_ item: RestoreItem, inspector: Inspector, plan: RestorePlan, session: RestoreSession,
                          onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> ItemResult {
        switch inspector.predictLaunchpad(item) {
        case .willSkip(let reason):
            if reason == .launchpadDatabaseMissing || reason == .launchpadAccessDenied || reason == .launchpadOtherUser {
                // Only on a real Mac: which database the running Dock has open (none, or one MacReplica could not use).
                let dock = layout.simulationRoot == nil
                    ? "; the Dock has open: " + (LaunchpadStore.openDockDatabase()?.path ?? "none") + "; " + LaunchpadStore.userReport() : ""
                log.warning("\(item.id): Launchpad database cannot be used – " + (layout.launchpadStore?.locationReport() ?? "no user folder (confstr failed)") + dock,
                            component: .restore)
            }
            return ItemResult(itemID: item.id, outcome: .skipped(reason))
        default: break
        }
        guard let recorded = item.launchpadLayout, let store = layout.launchpadStore else {
            return ItemResult(itemID: item.id, outcome: .skipped(.launchpadDatabaseMissing))
        }
        if store.computedDatabase != nil { log.info("\(item.id): \(store.sourceReport)", component: .restore) }
        let recordedApps = Set(recorded.appEntryCounts.keys)
        let appKinds: Set<RestoreItemKind> = [.cask, .appStoreApp, .manualApp]
        let appItems = plan.items.filter { appKinds.contains($0.kind) && $0.bundleIdentifier.map(recordedApps.contains) == true }
        let installedNow = Set(appItems.filter { session.results[$0.id]?.outcome.isSuccessLike == true }.compactMap(\.bundleIdentifier))
        let stillWaiting = appItems.filter { session.results[$0.id]?.outcome.isOpen == true }.count
        let work = inspector.launchpadWorkFolder
        defer { try? FileManager.default.removeItem(at: work) }

        // The Dock lists a newly installed app after a moment; wait for the apps this restore installed.
        onEvent(.activity(itemID: item.id, .verifying))
        let deadline = Date().addingTimeInterval(environment.launchpadSettleTimeout)
        while true {
            let listed = (try? store.read(macOSVersion: environment.macOSVersion, work: work))?.appEntryCounts ?? [:]
            if installedNow.isSubset(of: listed.keys) || Date() >= deadline || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        onEvent(.activity(itemID: item.id, .installing))
        do {
            try store.applyAndReloadDock(recorded)
        } catch LaunchpadError.databaseMissing {
            return ItemResult(itemID: item.id, outcome: .skipped(.launchpadDatabaseMissing))
        } catch {
            return failed(item, .unknown, layout.redact(String(describing: error)))
        }
        guard let after = try? store.read(macOSVersion: environment.macOSVersion, work: work),
              recorded.matches(after, installed: after.appEntryCounts) else {
            return failed(item, .verificationFailed, "Launchpad arrangement differs after rebuilding")
        }
        log.info("\(item.id): Launchpad arranged (\(after.pages.count) pages, \(after.folderNames.count) folders)", component: .restore)
        if stillWaiting > 0 { return ItemResult(itemID: item.id, outcome: .skipped(.launchpadWaitingForApps(count: stillWaiting))) }
        return ItemResult(itemID: item.id, outcome: .succeeded)
    }
}
