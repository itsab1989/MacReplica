import AppKit
import MacReplicaCore
import SwiftUI

/// What the Tools screen shows. Nothing here runs during an inventory, backup or restore; every check starts when
/// the Tools screen opens or the user presses a button, and every change only after a confirmation.
struct ToolsState {
    var environment = ToolEnvironment.current
    var gatekeeper: GatekeeperStatus?
    var checkingGatekeeper = false
    var appReport: AppSecurityReport?
    var inspectingApp = false
    /// After “Open the app” for a blocked app: the app MacReplica waits for the user to approve.
    var awaitingApproval: URL?
    var history: [ToolHistoryEntry] = []

    var updates: UpdatePreferencesStatus?
    var support: MacOSSupportStatus?
    var checkingSupport = false
    /// A change the user is making in System Settings, waiting for “check again”.
    var pendingUpdateChange: PendingUpdateChange?
    /// The last checked result of an update change.
    var updateOutcome: ToolOutcome?

    /// Identifiers of the profiles installed for the whole Mac (`profiles -C`); nil if they could not be read.
    var installedProfiles: Set<String>?
    /// A profile MacReplica prepared, waiting for the user to install or remove it in Device Management.
    var pendingProfile: PendingProfile?
    var gatekeeperOutcome: ToolOutcome?
    var deferralOutcome: ToolOutcome?

    /// The quarantine mark MacReplica removed in this session (to put it back exactly).
    var removedQuarantine: RemovedQuarantine?
    var quarantineOutcome: ToolOutcome?

    var corners: CornerConfiguration?
    var cornerOutcome: ToolOutcome?
    /// The corner plugin (menus, popovers, Quick Look): requirements and whether it is installed.
    var plugin: CornerPlugin.Status?
    var pluginOutcome: ToolOutcome?
    var pluginBusy = false
}

struct RemovedQuarantine: Equatable {
    var app: URL
    var value: String
}

struct PendingProfile: Equatable {
    enum Action: String { case install, remove }
    var profile: ManagedProfile
    var action: Action
    /// Machine-readable state before, for the history.
    var before: String
}

/// The user changes the Software Update switches in System Settings (macOS asks for the administrator password
/// there); MacReplica remembers what was asked for and what was set before, and checks afterwards.
struct PendingUpdateChange: Equatable {
    var change: String
    var before: UpdateSettings
    var target: UpdateSettings
}

extension AppModel {
    var toolHistory: ToolHistoryStore { ToolHistoryStore(layout: services.layout) }

    var gatekeeperInspector: GatekeeperInspector {
        GatekeeperInspector(layout: services.layout, runner: services.runner, environment: tools.environment)
    }

    func openTools() {
        tools.environment = ToolEnvironment(macOSVersion: services.macOSVersion, architecture: services.architecture)
        tools.history = toolHistory.entries()
        screen = .tools
        refreshGatekeeper()
        refreshUpdates()
        refreshCorners()
    }

    // MARK: Profiles (Gatekeeper off, major-upgrade deferral)

    var profilesFolder: URL { services.layout.applicationSupport.appendingPathComponent("Profiles") }

    func refreshProfiles() async {
        tools.installedProfiles = await InstalledProfiles.read(layout: services.layout, runner: services.runner)
    }

    func isInstalled(_ profile: ManagedProfile) -> Bool { tools.installedProfiles?.contains(profile.identifier) == true }

    /// Writes the profile and hands it to macOS; the user installs it in Device Management.
    func prepareProfile(_ profile: ManagedProfile) {
        let name: String
        let description: String
        switch profile {
        case .gatekeeperOff:
            name = l.t("tools.profile.gatekeeper.name")
            description = l.t("tools.profile.gatekeeper.description")
        case .deferMajorUpgrades(let days):
            name = l.t("tools.profile.deferral.name")
            description = l.t("tools.profile.deferral.description", days)
        }
        do {
            let file = try profile.write(to: profilesFolder, displayName: name, description: description)
            tools.pendingProfile = PendingProfile(profile: profile, action: .install, before: profileStateText(profile))
            if profile == .gatekeeperOff { tools.gatekeeperOutcome = nil } else { tools.deferralOutcome = nil }
            appLog.info("Tools: prepared profile \(profile.identifier)", component: .tools)
            // Opening the file makes macOS list it in Device Management (it is not installed yet).
            if services.simulationRoot == nil { NSWorkspace.shared.open(file) }
            openDeviceManagementSettings()
        } catch {
            notice = ProblemInfo(title: l.t("tools.profile.failed"), message: services.layout.redact(String(describing: error)), detail: nil)
        }
    }

    /// The user removes MacReplica's own profile in Device Management.
    func beginProfileRemoval(_ profile: ManagedProfile) {
        tools.pendingProfile = PendingProfile(profile: profile, action: .remove, before: profileStateText(profile))
        openDeviceManagementSettings()
    }

    private func profileStateText(_ profile: ManagedProfile) -> String {
        let installed = isInstalled(profile) ? 1 : 0
        switch profile {
        case .gatekeeperOff: return "profile=\(installed);" + (tools.gatekeeper?.historyText ?? "assessments=unknown")
        case .deferMajorUpgrades:
            return "profile=\(installed);deferralDays=\(ManagedProfileEffect.majorUpgradeDeferralDays(managedPreferences: services.layout.managedPreferences).map(String.init) ?? "none")"
        }
    }

    func cancelPendingProfile() { tools.pendingProfile = nil }

    /// Reads the real state again and records what actually happened.
    func finishPendingProfile() {
        guard let pending = tools.pendingProfile else { return }
        Task {
            await refreshProfiles()
            let present = isInstalled(pending.profile)
            let wanted = pending.action == .install
            var verification: ToolVerification
            var text: String
            switch pending.profile {
            case .gatekeeperOff:
                let status = await gatekeeperInspector.status()
                tools.gatekeeper = status
                if present != wanted {
                    verification = .failed
                    text = l.t(wanted ? "tools.profile.notInstalled" : "tools.profile.stillInstalled")
                } else if wanted {
                    verification = status.assessments == .disabled ? .verified : .failed
                    text = l.t(status.assessments == .disabled ? "tools.gatekeeper.profileOn.verified" : "tools.gatekeeper.profileOn.noEffect")
                } else {
                    verification = status.assessments == .enabled ? .verified : .partiallyVerified
                    text = l.t(status.assessments == .enabled ? "tools.gatekeeper.profileOff.verified" : "tools.gatekeeper.profileOff.stillOff")
                }
                tools.gatekeeperOutcome = ToolOutcome(verification: verification, stateAfter: text)
            case .deferMajorUpgrades(let days):
                let active = ManagedProfileEffect.majorUpgradeDeferralDays(managedPreferences: services.layout.managedPreferences)
                if present != wanted {
                    verification = .failed
                    text = l.t(wanted ? "tools.profile.notInstalled" : "tools.profile.stillInstalled")
                } else if wanted {
                    // The setting is in place; whether macOS holds back a newer version shows only if one exists.
                    let installers = (try? await services.runner.run(Command(executable: services.layout.softwareupdate, arguments: ["--list-full-installers"],
                                                                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: 120)))?.stdout ?? ""
                    let deferred = ManagedProfileEffect.newerMajorDeferred(installersOutput: installers, installedMajor: tools.environment.majorVersion)
                    if active != days { verification = .failed; text = l.t("tools.updates.deferral.noEffect") }
                    else if deferred == true { verification = .verified; text = l.t("tools.updates.deferral.verified", days) }
                    else { verification = .partiallyVerified; text = l.t("tools.updates.deferral.partly", days) }
                } else {
                    verification = active == nil ? .verified : .partiallyVerified
                    text = l.t(active == nil ? "tools.updates.deferral.profileGone" : "tools.updates.deferral.otherStillActive")
                }
                tools.deferralOutcome = ToolOutcome(verification: verification, stateAfter: text)
            }
            let change = "\(pending.profile == .gatekeeperOff ? "gatekeeper" : "updates.deferral").\(pending.action == .install ? "profileInstalled" : "profileRemoved")"
            // Recorded when something happened: verified, or the profile came or went (even with an unexpected effect).
            let wasPresent = pending.before.hasPrefix("profile=1")
            if verification != .failed || present != wasPresent {
                record(ToolHistoryEntry(tool: pending.profile == .gatekeeperOff ? "gatekeeper" : "updates", change: change, previousState: pending.before,
                                        resultingState: profileStateText(pending.profile), macOSVersion: tools.environment.macOSVersion,
                                        result: verification == .failed ? .failed : (verification == .verified ? .succeeded : .partial),
                                        verification: verification, revertAvailable: false))
            }
            if verification != .failed { tools.pendingProfile = nil }
        }
    }

    // MARK: Window corners

    var cornerTool: WindowCornersTool {
        // A simulated Mac keeps the setting in its own sandbox: trying the tool there never changes this Mac.
        let store: GlobalPreferenceStore
        if let root = services.simulationRoot {
            store = FileGlobalPreferenceStore(file: root.appendingPathComponent("home/Library/Preferences/.GlobalPreferences.plist"))
        } else {
            store = LiveGlobalPreferenceStore()
        }
        return WindowCornersTool(store: store, environment: tools.environment)
    }

    func refreshCorners() {
        tools.corners = cornerTool.state()
        refreshPlugin()
    }

    var revertibleCornerChange: CornerSnapshot? {
        guard let entry = toolHistory.lastRevertibleChange(tool: "windowCorners"), let text = entry.previousState else { return nil }
        return CornerSnapshot(historyText: text)
    }

    /// Writes the chosen corners for all surfaces at once; the history keeps the exact previous values of every key.
    func applyCorners(_ configuration: CornerConfiguration, change: String) {
        do {
            let result = try cornerTool.apply(configuration)
            tools.corners = result.after
            tools.cornerOutcome = ToolOutcome(verification: result.outcome,
                                              stateAfter: l.t(result.outcome == .failed ? "tools.corners.outcome.failed" : "tools.corners.outcome.written"),
                                              restart: .relaunchApps)
            let after = cornerTool.snapshot()
            record(ToolHistoryEntry(tool: "windowCorners", change: change, previousState: result.before.historyText, resultingState: after.historyText,
                                    macOSVersion: tools.environment.macOSVersion, result: result.outcome == .failed ? .failed : .succeeded,
                                    verification: result.outcome, revertAvailable: result.before != after))
        } catch {
            tools.cornerOutcome = ToolOutcome(verification: .failed, stateAfter: l.t("tools.corners.outcome.failed"))
        }
    }

    func revertCorners() {
        guard let previous = revertibleCornerChange else { return }
        do {
            let before = cornerTool.snapshot()
            let result = try cornerTool.restore(previous)
            tools.corners = cornerTool.state()
            tools.cornerOutcome = ToolOutcome(verification: result.outcome,
                                              stateAfter: l.t(result.outcome == .failed ? "tools.corners.outcome.failed" : "tools.corners.outcome.restored"),
                                              restart: .relaunchApps)
            record(ToolHistoryEntry(tool: "windowCorners", change: "windowCorners.revert", previousState: before.historyText,
                                    resultingState: result.after.historyText, macOSVersion: tools.environment.macOSVersion,
                                    result: result.outcome == .failed ? .failed : .succeeded, verification: result.outcome, revertAvailable: false))
        } catch {
            tools.cornerOutcome = ToolOutcome(verification: .failed, stateAfter: l.t("tools.corners.outcome.failed"))
        }
    }

    // MARK: Corner plugin (advanced)

    var appBundleURL: URL { Bundle.main.bundleURL }

    func refreshPlugin() {
        Task { tools.plugin = await readPluginStatus() }
    }

    /// Reads the real state of every requirement (nothing is changed). A simulated Mac tells its own build (stand-in),
    /// so every requirement can be shown on screen.
    func readPluginStatus() async -> CornerPlugin.Status {
        let sip: GatekeeperStatus.SIP
        if let known = tools.gatekeeper?.sip { sip = known } else { sip = await gatekeeperInspector.status().sip }
        var build = CornerPlugin.currentBuild()
        if services.simulationRoot != nil, let simulated = defaults.string(forKey: "stagingMacOSBuild") { build = simulated }
        return await CornerPlugin.status(layout: services.layout, runner: services.runner, sip: sip, appBundle: appBundleURL,
                                         build: build, architecture: tools.environment.architecture,
                                         activeHere: CornerPlugin.loadedInThisProcess())
    }

    /// One click, after the user allowed debugging in recoveryOS themselves: does exactly the steps the status shows as
    /// missing – download and verify the pinned Plugin Playground, install it, install MacReplica's plugin, save the
    /// loader's "Disable arm64e (PAC)" setting, set up and start its background service – in one administrator prompt.
    /// Afterwards every step is checked against the real state; nothing counts as done because a command returned.
    /// Running it again only repeats what is still missing.
    func setUpCornerPluginOneClick() {
        tools.pluginBusy = true
        tools.pluginOutcome = nil
        Task {
            let before = await readPluginStatus()
            tools.plugin = before
            let steps = before.missingSteps
            let operation = String(UUID().uuidString.prefix(8))
            appLog.info("Tools: corner setup \(operation) started on \(tools.environment.macOSVersion) (\(before.build ?? "?")), "
                        + "\(before.diagnostics), steps \(steps.map(\.rawValue).joined(separator: ","))", component: .tools)
            guard !steps.isEmpty else {
                tools.pluginBusy = false
                tools.pluginOutcome = ToolOutcome(verification: before.readiness == .ready ? .verified : .notVerified,
                                                  stateAfter: l.t("tools.plugin.next.\(before.readiness.rawValue)"))
                return
            }
            let work = services.layout.caches.appendingPathComponent("PluginLoaderDownload")
            defer { try? FileManager.default.removeItem(at: work) }
            var package: URL?
            if steps.contains(.installLoader) {
                do {
                    package = try await PluginLoader.downloadVerifiedPackage(transport: services.downloadTransport, work: work)
                } catch {
                    tools.pluginBusy = false
                    let checksum: Bool
                    if case PluginLoader.InstallError.checksumMismatch = error { checksum = true } else { checksum = false }
                    tools.pluginOutcome = ToolOutcome(verification: .failed,
                                                      stateAfter: l.t(checksum ? "tools.plugin.oneClick.checksum" : "tools.plugin.oneClick.download"),
                                                      partialNote: l.t("tools.plugin.setup.nothingChanged"))
                    appLog.warning("Tools: corner setup \(operation) download failed: \(services.layout.redact(String(describing: error)))", component: .tools)
                    return
                }
            }
            var failure: String?
            var cancelled = false
            do {
                let operations = try PluginLoader.setupOperations(steps, layout: services.layout, appBundle: appBundleURL,
                                                                  package: package, staging: work.appendingPathComponent("staging"))
                try await services.privileged.run(operations, reason: l.t("tools.plugin.oneClick.reason"))
            } catch PrivilegedError.denied {
                cancelled = true
            } catch PluginLoader.InstallError.pluginMissingInApp {
                failure = l.t("tools.plugin.missingInApp")
            } catch {
                failure = services.layout.redact(String(describing: error))
            }
            // The injector needs a moment after launchd starts the service; wait up to five seconds for it.
            var after = await readPluginStatus()
            if steps.contains(.startService), !cancelled {
                for _ in 0..<10 where after.injectorRunning != true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    after = await readPluginStatus()
                }
            }
            tools.plugin = after
            tools.pluginBusy = false
            tools.pluginOutcome = setupOutcome(steps: steps, after: after, failure: failure, cancelled: cancelled)
            appLog.info("Tools: corner setup \(operation) finished: \(after.diagnostics), cancelled \(cancelled), "
                        + "error \(failure ?? "none")", component: .tools)
            let result: ToolHistoryEntry.Result = cancelled ? .cancelled : (after.readiness == .ready ? .succeeded : (steps.contains { done($0, after) } ? .partial : .failed))
            record(ToolHistoryEntry(tool: "cornerPlugin", change: "windowCorners.oneClickSetUp", previousState: before.diagnostics,
                                    resultingState: after.diagnostics, macOSVersion: tools.environment.macOSVersion, result: result,
                                    verification: after.readiness == .ready ? .verified : .failed, revertAvailable: false))
        }
    }

    /// Whether a setup step's result is visible in the real state.
    private func done(_ step: CornerPlugin.SetupStep, _ status: CornerPlugin.Status) -> Bool {
        switch step {
        case .installLoader: return status.loaderInstalled
        case .installPlugin: return status.installed && status.current
        case .savePACSetting: return status.pacStrippingOn
        case .installService: return status.serviceInstalled
        case .startService: return status.serviceLoaded == true && status.injectorRunning == true
        }
    }

    /// The result of a setup run: one checked line per step, what is still missing and what to do next.
    private func setupOutcome(steps: [CornerPlugin.SetupStep], after: CornerPlugin.Status, failure: String?, cancelled: Bool) -> ToolOutcome {
        let lines = steps.map { (done($0, after) ? "✓ " : "✗ ") + l.t("tools.plugin.step.\($0.rawValue)") }
        let doneAny = steps.contains { done($0, after) }
        if after.readiness == .ready {
            let text = l.t("tools.plugin.setup.verified") + "\n" + lines.joined(separator: "\n") + "\n" + l.t("tools.plugin.next.ready")
            return ToolOutcome(verification: .verified, stateAfter: text, restart: .relaunchApps)
        }
        var text = l.t(cancelled ? "tools.plugin.cancelled" : "tools.plugin.setup.incomplete")
        if let failure { text += "\n" + l.t("tools.plugin.failed", failure) }
        if !cancelled { text += "\n" + lines.joined(separator: "\n") }
        if after.readiness == .injectorNotRunning, let exit = after.serviceLastExit { text += "\n" + l.t("tools.plugin.setup.lastExit", exit) }
        text += "\n" + l.t("tools.plugin.next.\(after.readiness.rawValue)")
        let note = l.t(doneAny ? "tools.plugin.setup.partial" : "tools.plugin.setup.nothingChanged")
        return ToolOutcome(verification: cancelled ? .notVerified : .failed, stateAfter: text, partialNote: cancelled ? nil : note)
    }

    /// One click to reverse everything MacReplica did: remove the plugin and uninstall the Plugin Playground loader.
    /// Playground persists no boot argument or library-validation change, so nothing else has to be reset. The running
    /// injector is left alone until the restart (stopping it from outside can crash launchd); the user restarts and turns
    /// System Integrity Protection back on in recoveryOS afterwards (MacReplica never changes SIP).
    func undoCornerPluginOneClick() {
        tools.pluginBusy = true
        tools.pluginOutcome = nil
        Task {
            let before = await readPluginStatus()
            var failure: String?
            do {
                // The real package database only: a simulated Mac's loader was never installed with `installer`.
                let receipt = services.simulationRoot == nil ? await PluginLoader.receiptPresent(layout: services.layout, runner: services.runner) == true : false
                try await services.privileged.run(CornerPlugin.removeOperations(layout: services.layout) + PluginLoader.uninstallOperations(receiptPresent: receipt),
                                                  reason: l.t("tools.plugin.undo.reason"))
            } catch PrivilegedError.denied {
                failure = l.t("tools.plugin.cancelled")
            } catch {
                failure = l.t("tools.plugin.failed", services.layout.redact(String(describing: error)))
            }
            let after = await readPluginStatus()
            tools.plugin = after
            tools.pluginBusy = false
            let removed = !after.installed && !after.loaderInstalled && !after.serviceInstalled
            var text = failure ?? l.t(removed ? "tools.plugin.undo.done" : "tools.plugin.notConfirmed")
            if removed { text += "\n" + l.t(after.injectorRunning == true ? "tools.plugin.undo.stillRunning" : "tools.plugin.undo.rebootSIP") }
            tools.pluginOutcome = ToolOutcome(verification: removed ? .verified : .failed, stateAfter: text, restart: removed ? .restart : .none)
            appLog.info("Tools: corner undo finished: \(after.diagnostics)", component: .tools)
            if failure == nil || removed {
                record(ToolHistoryEntry(tool: "cornerPlugin", change: "windowCorners.oneClickUndo", previousState: before.diagnostics,
                                        resultingState: after.diagnostics, macOSVersion: tools.environment.macOSVersion,
                                        result: removed ? .succeeded : .failed, verification: removed ? .verified : .failed, revertAvailable: false))
            }
        }
    }

    // MARK: Update preferences

    var updateInspector: UpdatePreferencesInspector {
        var folder: URL? = nil
        // A simulated Mac may bring its own Software Update settings; otherwise this Mac's are shown (read-only).
        if let root = services.simulationRoot?.appendingPathComponent("Library/Preferences"),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("com.apple.SoftwareUpdate.plist").path) { folder = root }
        return UpdatePreferencesInspector(layout: services.layout, runner: services.runner, preferencesFolder: folder)
    }

    func refreshUpdates() {
        let status = updateInspector.status()
        tools.updates = status
        appLog.info("Tools: Software Update \(status.settings?.historyText ?? "unreadable"), managed \(status.managed)", component: .tools)
    }

    /// Asks Apple's servers which macOS versions this Mac can install (read-only).
    func checkMacOSSupport() {
        tools.checkingSupport = true
        Task {
            let support = await updateInspector.supportStatus(installedVersion: tools.environment.macOSVersion)
            tools.support = support
            tools.checkingSupport = false
            appLog.info("Tools: macOS support \(support.support.rawValue), latest for this major \(support.latestForThisMajor ?? "?")", component: .tools)
        }
    }

    /// Starts a guided change: remembers the current switches, opens Software Update settings.
    func beginUpdateChange(_ change: String, target: UpdateSettings) {
        refreshUpdates()
        guard let before = tools.updates?.settings else { return }
        tools.updateOutcome = nil
        tools.pendingUpdateChange = PendingUpdateChange(change: change, before: before, target: target)
        openSoftwareUpdateSettings()
    }

    /// The previous state of the last change MacReplica guided, if it was not undone yet.
    var revertibleUpdateChange: (entry: ToolHistoryEntry, previous: UpdateSettings)? {
        guard let entry = toolHistory.lastRevertibleChange(tool: "updates"), let text = entry.previousState,
              let previous = UpdateSettings(historyText: text) else { return nil }
        return (entry, previous)
    }

    /// Reads the switches again and records what really changed.
    func finishUpdateChange() {
        guard let pending = tools.pendingUpdateChange else { return }
        refreshUpdates()
        guard let after = tools.updates?.settings else {
            tools.updateOutcome = ToolOutcome(verification: .notVerified, stateAfter: l.t("tools.updates.unreadable"))
            return
        }
        let missing = after.differences(to: pending.target)
        let changed = after != pending.before
        let verification: ToolVerification = missing.isEmpty ? .verified : .failed
        let result: ToolHistoryEntry.Result = missing.isEmpty ? .succeeded : (changed ? .partial : .failed)
        tools.updateOutcome = ToolOutcome(verification: verification,
                                          stateAfter: missing.isEmpty ? l.t("tools.updates.outcome.done")
                                                                      : l.t("tools.updates.outcome.missing", missing.map { l.t("tools.updates.item.\($0.rawValue)") }.joined(separator: ", ")))
        tools.pendingUpdateChange = missing.isEmpty ? nil : pending
        if changed || missing.isEmpty {
            record(ToolHistoryEntry(tool: "updates", change: pending.change, previousState: pending.before.historyText, resultingState: after.historyText,
                                    macOSVersion: tools.environment.macOSVersion, result: result, verification: verification,
                                    revertAvailable: pending.change != "updates.revert" && changed))
        }
    }

    func cancelUpdateChange() {
        tools.pendingUpdateChange = nil
    }

    func openSoftwareUpdateSettings() {
        if let url = URL(string: UpdateSettingsLinks.softwareUpdate) { NSWorkspace.shared.open(url) }
    }

    func refreshGatekeeper() {
        tools.checkingGatekeeper = true
        Task {
            let status = await gatekeeperInspector.status()
            tools.gatekeeper = status
            await refreshProfiles()
            tools.checkingGatekeeper = false
            appLog.info("Tools: Gatekeeper \(status.historyText), SIP \(status.sip.rawValue), enrollment \(status.enrollment.rawValue)", component: .tools)
        }
    }

    /// The user picks one app; MacReplica only reads it.
    func chooseAppToInspect() {
        let url: URL
        if services.simulationRoot != nil, defaults.bool(forKey: "stagingSkipPanels"), let path = defaults.string(forKey: "stagingInspectApp") {
            url = URL(fileURLWithPath: path)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = l.t("tools.gatekeeper.choose.message")
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        inspectApp(url)
    }

    func inspectApp(_ url: URL) {
        tools.inspectingApp = true
        tools.appReport = nil
        tools.quarantineOutcome = nil
        if tools.removedQuarantine?.app != url { tools.removedQuarantine = nil }
        Task {
            let report = await gatekeeperInspector.inspect(app: url)
            tools.appReport = report
            tools.inspectingApp = false
            appLog.info("Tools: inspected an app: signature \(report.signature.rawValue), notarized \(report.notarized.map(String.init) ?? "?"), verdict \(report.verdict.rawValue), quarantined \(report.quarantined)", component: .tools)
        }
    }

    /// Apple's route for one blocked app: open it once (macOS shows its warning), then “Open Anyway” in
    /// Privacy & Security. MacReplica opens both and checks the app again afterwards; it never removes the
    /// quarantine attribute or changes Gatekeeper itself.
    func startOpenAnyway() {
        guard let report = tools.appReport else { return }
        let url = URL(fileURLWithPath: report.path)
        tools.awaitingApproval = url
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.openSecuritySettings()
            }
        }
    }

    /// Re-checks the app after the user approved it and records the verified result.
    func finishOpenAnyway() {
        guard let url = tools.awaitingApproval, let before = tools.appReport else { return }
        tools.inspectingApp = true
        Task {
            let after = await gatekeeperInspector.inspect(app: url)
            tools.appReport = after
            tools.inspectingApp = false
            tools.awaitingApproval = nil
            let verification: ToolVerification
            switch after.verdict {
            case .notAssessedGatekeeperOff: verification = .notVerified
            case .accepted where after.approvedByUser || after.advice == .opensNormally: verification = .verified
            default: verification = after.advice == .opensNormally ? .verified : .failed
            }
            record(ToolHistoryEntry(tool: "gatekeeper", change: "gatekeeper.openAnyway", previousState: before.advice.rawValue,
                                    resultingState: after.advice.rawValue, macOSVersion: tools.environment.macOSVersion,
                                    result: verification == .failed ? .failed : .succeeded, verification: verification, revertAvailable: false))
        }
    }

    /// Opens the chosen app now. If Gatekeeper blocks it, macOS shows its own warning (and “Open Anyway” becomes
    /// available in Privacy & Security).
    func openInspectedApp() {
        guard let report = tools.appReport else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: report.path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        appLog.info("Tools: opened the inspected app on request", component: .tools)
    }

    /// Removes the quarantine mark from the one app the user chose (after the confirmation in the view) and checks
    /// the app again.
    func removeQuarantineFromInspectedApp() {
        guard let report = tools.appReport else { return }
        let url = URL(fileURLWithPath: report.path)
        do {
            let previous = try QuarantineEditor.remove(from: url, report: report)
            tools.removedQuarantine = RemovedQuarantine(app: url, value: previous)
            reinspectAfterQuarantineChange(url, change: "gatekeeper.quarantineRemoved", wantQuarantined: false)
        } catch {
            tools.quarantineOutcome = ToolOutcome(verification: .failed, stateAfter: quarantineFailureText(error))
        }
    }

    func restoreQuarantineOfInspectedApp() {
        guard let removed = tools.removedQuarantine else { return }
        do {
            try QuarantineEditor.restore(removed.value, to: removed.app)
            tools.removedQuarantine = nil
            reinspectAfterQuarantineChange(removed.app, change: "gatekeeper.quarantineRestored", wantQuarantined: true)
        } catch {
            tools.quarantineOutcome = ToolOutcome(verification: .failed, stateAfter: quarantineFailureText(error))
        }
    }

    private func quarantineFailureText(_ error: Error) -> String {
        switch error as? QuarantineEditor.Failure {
        case .damaged: return l.t("tools.gatekeeper.quarantine.damaged")
        case .systemLocation, .notAnApp: return l.t("tools.gatekeeper.quarantine.notAllowed")
        case .notQuarantined: return l.t("tools.gatekeeper.quarantine.none")
        case .notWritable(let reason): return l.t("tools.gatekeeper.quarantine.notWritable", reason)
        case nil: return services.layout.redact(String(describing: error))
        }
    }

    private func reinspectAfterQuarantineChange(_ url: URL, change: String, wantQuarantined: Bool) {
        let before = tools.appReport
        tools.inspectingApp = true
        Task {
            let after = await gatekeeperInspector.inspect(app: url)
            tools.appReport = after
            tools.inspectingApp = false
            let verification: ToolVerification = after.quarantined == wantQuarantined ? .verified : .failed
            tools.quarantineOutcome = ToolOutcome(verification: verification,
                                                  stateAfter: l.t(wantQuarantined ? "tools.gatekeeper.quarantine.restored" : "tools.gatekeeper.quarantine.removed"))
            // The history names no path: the app's name and the state are enough.
            record(ToolHistoryEntry(tool: "gatekeeper", change: change,
                                    previousState: "app=\(after.appName);quarantined=\(before?.quarantined == true ? 1 : 0)",
                                    resultingState: "app=\(after.appName);quarantined=\(after.quarantined ? 1 : 0)",
                                    macOSVersion: tools.environment.macOSVersion, result: verification == .verified ? .succeeded : .failed,
                                    verification: verification, revertAvailable: false))
        }
    }

    func openSecuritySettings() {
        if let url = URL(string: SecuritySettingsLinks.securitySection), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: SecuritySettingsLinks.privacySecurity) { NSWorkspace.shared.open(url) }
    }

    func openDeviceManagementSettings() {
        if let url = URL(string: SecuritySettingsLinks.deviceManagement) { NSWorkspace.shared.open(url) }
    }

    func record(_ entry: ToolHistoryEntry) {
        do { try toolHistory.append(entry) } catch {
            appLog.warning("Tools: history not written: \(services.layout.redact(String(describing: error)))", component: .tools)
        }
        tools.history = toolHistory.entries()
        appLog.info("Tools: \(entry.change) \(entry.result.rawValue), verification \(entry.verification.rawValue)", component: .tools)
    }
}
