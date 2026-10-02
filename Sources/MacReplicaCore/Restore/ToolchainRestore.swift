import Foundation

// MARK: - Read-only checks

extension Inspector {
    var toolchainContext: ToolchainContext {
        ToolchainContext(layout: layout, workFolder: layout.caches.appendingPathComponent("Work"), architecture: environment.targetArchitecture)
    }

    func predictToolchain(_ item: RestoreItem) -> Prediction {
        guard let action = item.toolchain else { return .willSkip(.userSkipped) }
        let provider = ToolchainCatalog.provider(action.provider)
        let context = toolchainContext
        if provider.isSatisfied(action, context: context) { return .alreadyPresent(version: nil) }
        guard provider.supportLevel(for: action) == .automatic else { return .manualStep }
        if provider.commands(for: action, context: context) != nil { return .willInstall }
        // The manager or runtime is installed by an earlier step, or the user installs it first.
        return item.dependsOn.isEmpty ? .manualStep : .dependsOnEarlierStep
    }
}

// MARK: - Restore

extension RestoreExecutor {
    /// Allows exactly the executables this plan's toolchain steps may start, for this run only.
    func prepareToolchains(plan: RestorePlan, context: inout RunContext) {
        let toolchainContext = ToolchainContext(layout: layout, workFolder: layout.caches.appendingPathComponent("Work"),
                                                architecture: environment.targetArchitecture)
        let actions = plan.items.compactMap(\.toolchain)
        context.toolchainContext = toolchainContext
        guard !actions.isEmpty else { return }
        let executables = ToolchainCatalog.executables(for: actions, context: toolchainContext)
        context.toolchainRunner = (environment.runner as? CommandPolicyExtending)?.allowing(executables) ?? environment.runner
    }

    func restoreToolchainStep(_ item: RestoreItem, inspector: Inspector, context: RunContext,
                              onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        guard let action = item.toolchain, let toolchain = context.toolchainContext else { return failed(item, .unknown) }
        let provider = ToolchainCatalog.provider(action.provider)
        if provider.isSatisfied(action, context: toolchain) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: action.runtime?.version ?? action.package?.version)
        }
        guard provider.supportLevel(for: action) == .automatic else {
            return ItemResult(itemID: item.id, outcome: .skipped(.manualStepRequired))
        }
        guard let commands = provider.commands(for: action, context: toolchain) else {
            // Nothing in this plan installs the tool: the user installs it, then the step is checked again.
            if item.dependsOn.isEmpty { return ItemResult(itemID: item.id, outcome: .skipped(.manualStepRequired)) }
            return failed(item, .toolUnavailable, ToolchainCatalog.descriptor(action.provider).name)
        }
        let runner = context.toolchainRunner ?? environment.runner
        onEvent(.activity(itemID: item.id, .installing))
        for command in commands {
            try Task.checkCancellation()
            let written = try writeInputFiles(command.inputFiles)
            defer { removeInputFiles(written) }
            let result = try await runner.run(Command(executable: command.executable, arguments: command.arguments,
                                                      environment: command.environment, timeout: command.timeout))
            guard result.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: result))) }
        }
        onEvent(.activity(itemID: item.id, .verifying))
        guard provider.isSatisfied(action, context: toolchain) else {
            return failed(item, .verificationFailed, "\(action.itemID) not found after installation")
        }
        log.info("\(item.id): installed with \(ToolchainCatalog.descriptor(action.provider).name)", component: .developerTools)
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: action.runtime?.version ?? action.package?.version)
    }

    /// Input files go into MacReplica's own work folder and are removed right after the command.
    private func writeInputFiles(_ files: [URL: String]) throws -> [URL] {
        let folder = layout.caches.appendingPathComponent("Work")
        var written: [URL] = []
        for (url, content) in files {
            guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
                throw CleanupError.outsideOwnedFolder(url.path)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return written
    }

    private func removeInputFiles(_ files: [URL]) {
        for url in files { try? FileManager.default.removeItem(at: url) }
    }

    /// App Store apps are installed by the user from the App Store page (`mas install` needs root since mas 7).
    /// Without bundle information the read-only `mas list` tells whether the app is there.
    func checkAppStoreInstall(_ item: RestoreItem, inspector: Inspector) async -> ItemResult {
        let identifiable = item.bundleIdentifier != nil || !item.appBundleNames.isEmpty
        if !identifiable, inspector.architectureSkip(item) == nil, let mas = environment.mas.locate(), let id = Int(item.identifier),
           let entry = (try? await environment.mas.installedApps(mas: mas))?.first(where: { $0.appStoreID == id }) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: entry.version)
        }
        return checkGuidedInstall(item, inspector: inspector)
    }

    /// Guided installs (App Store, vendor downloads): done when the app is there, otherwise waiting for the user.
    func checkGuidedInstall(_ item: RestoreItem, inspector: Inspector) -> ItemResult {
        if let reason = inspector.architectureSkip(item) { return ItemResult(itemID: item.id, outcome: .skipped(reason)) }
        let identifiable = item.bundleIdentifier != nil || !item.appBundleNames.isEmpty
        if identifiable, let app = inspector.installedApp(for: item) {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: inspector.installedVersion(ofApp: app))
        }
        return ItemResult(itemID: item.id, outcome: .skipped(.manualStepRequired))
    }
}
