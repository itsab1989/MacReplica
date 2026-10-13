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

    var corners: CornerState?
    var cornerOutcome: ToolOutcome?
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
    }

    var revertibleCornerChange: CornerState? {
        guard let entry = toolHistory.lastRevertibleChange(tool: "windowCorners"), let text = entry.previousState else { return nil }
        return CornerState(historyText: text)
    }

    func applyCorners(windows: CornerSetting, utilityPanels: CornerSetting, change: String) {
        do {
            let result = try cornerTool.apply(windows: windows, utilityPanels: utilityPanels)
            tools.corners = result.after
            tools.cornerOutcome = ToolOutcome(verification: result.outcome,
                                              stateAfter: l.t(result.outcome == .failed ? "tools.corners.outcome.failed" : "tools.corners.outcome.written"),
                                              restart: .relaunchApps)
            record(ToolHistoryEntry(tool: "windowCorners", change: change, previousState: result.before.historyText, resultingState: result.after.historyText,
                                    macOSVersion: tools.environment.macOSVersion, result: result.outcome == .failed ? .failed : .succeeded,
                                    verification: result.outcome, revertAvailable: result.before != result.after))
        } catch {
            tools.cornerOutcome = ToolOutcome(verification: .failed, stateAfter: l.t("tools.corners.outcome.failed"))
        }
    }

    func revertCorners() {
        guard let previous = revertibleCornerChange else { return }
        do {
            let before = cornerTool.state()
            let result = try cornerTool.restore(previous)
            tools.corners = result.after
            tools.cornerOutcome = ToolOutcome(verification: result.outcome,
                                              stateAfter: l.t(result.outcome == .failed ? "tools.corners.outcome.failed" : "tools.corners.outcome.restored"),
                                              restart: .relaunchApps)
            record(ToolHistoryEntry(tool: "windowCorners", change: "windowCorners.revert", previousState: before.historyText, resultingState: result.after.historyText,
                                    macOSVersion: tools.environment.macOSVersion, result: result.outcome == .failed ? .failed : .succeeded,
                                    verification: result.outcome, revertAvailable: false))
        } catch {
            tools.cornerOutcome = ToolOutcome(verification: .failed, stateAfter: l.t("tools.corners.outcome.failed"))
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
