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
    }

    func refreshGatekeeper() {
        tools.checkingGatekeeper = true
        Task {
            let status = await gatekeeperInspector.status()
            tools.gatekeeper = status
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
