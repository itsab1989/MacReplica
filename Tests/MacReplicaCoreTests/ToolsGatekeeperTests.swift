import Foundation
import Testing
@testable import MacReplicaCore

/// Tool A reads the real outputs of macOS 27 (recorded on the maintainer's Mac, which has a hand-installed
/// “Disable Gatekeeper” profile) and never confuses one app's quarantine with the global Gatekeeper state.
@Suite("Tools: Gatekeeper")
struct ToolsGatekeeperTests {
    static let enrollmentNo = "Enrolled via DEP: No\nMDM enrollment: No\n"

    @Test func normalMac() {
        let status = GatekeeperInspector.interpret(spctl: "assessments enabled\n", csrutil: "System Integrity Protection status: enabled.\n",
                                                   enrollment: Self.enrollmentNo, controlProfile: nil, managedProfile: nil)
        #expect(status.assessments == .enabled)
        #expect(status.profile == GatekeeperStatus.ProfileSource.none)
        #expect(status.enrollment == .notEnrolled)
        #expect(status.sip == .enabled)
        #expect(status.summary == .normal)
        #expect(status.capability == .supported)
    }

    @Test func handInstalledProfileIsRecognised() {
        // `/Library/Managed Preferences/com.apple.systempolicy.control.plist` as written by a manual profile.
        let status = GatekeeperInspector.interpret(spctl: "assessments disabled\n", csrutil: "System Integrity Protection status: enabled.\n",
                                                   enrollment: Self.enrollmentNo,
                                                   controlProfile: ["_manualProfile": true, "EnableAssessment": false, "PayloadUUID": "X"],
                                                   managedProfile: nil)
        #expect(status.assessments == .disabled)
        #expect(status.profile == .manual)
        #expect(status.profileEnablesAssessment == false)
        #expect(status.summary == .disabledByProfile)
        // Only the user can remove a profile (System Settings › Device Management); MacReplica does not.
        #expect(status.capability == .requiresUserAction)
        #expect(!status.capability.allowsChange)
    }

    @Test func turnedOffByTheUserWithoutProfile() {
        let status = GatekeeperInspector.interpret(spctl: "assessments disabled", csrutil: nil, enrollment: Self.enrollmentNo,
                                                   controlProfile: nil, managedProfile: nil)
        #expect(status.summary == .disabledByUser)
        #expect(status.sip == .unknown)
    }

    @Test func organisationProfilesAreManagedExternally() {
        let mdm = GatekeeperInspector.interpret(spctl: "assessments enabled", csrutil: nil,
                                                enrollment: "Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\n",
                                                controlProfile: ["AllowIdentifiedDevelopers": true, "EnableAssessment": true], managedProfile: nil)
        #expect(mdm.profile == .deviceManagement)
        #expect(mdm.enrollment == .enrolled)
        #expect(mdm.summary == .managed)
        #expect(mdm.capability == .managedExternally)
        let noOverride = GatekeeperInspector.interpret(spctl: "assessments enabled", csrutil: nil, enrollment: Self.enrollmentNo,
                                                       controlProfile: nil, managedProfile: ["DisableOverride": true])
        #expect(noOverride.overrideDisabled)
        #expect(noOverride.summary == .managed)
    }

    @Test func unreadableStateIsReportedAsUnknown() {
        // `profiles` refuses with exit 0; spctl may not answer at all.
        let status = GatekeeperInspector.interpret(spctl: nil, csrutil: "System Integrity Protection status: unknown (Custom Configuration).",
                                                   enrollment: "profiles: this command requires root privileges", controlProfile: [:], managedProfile: nil)
        #expect(status.assessments == .unknown)
        #expect(status.enrollment == .unknown)
        #expect(status.sip == .unknown)
        #expect(status.summary == .unknown)
        #expect(status.capability == .unableToDetermine)
    }

    static func ok(_ out: String = "") -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }
    static func fail(_ code: Int32 = 3, _ err: String = "") -> CommandResult { CommandResult(exitCode: code, stdout: "", stderr: err) }

    @Test func gatekeeperOffMasksTheVerdictOfEveryApp() {
        let report = GatekeeperInspector.report(app: URL(fileURLWithPath: "/Applications/IINA.app"),
                                                quarantine: "0181;6acbc32e;Homebrew Cask;FEDB6031", verify: Self.ok(),
                                                details: "Authority=Developer ID Application: Hechen Li (67CQ77V27R)\nAuthority=Developer ID Certification Authority",
                                                notarized: Self.ok(),
                                                assess: "/Applications/IINA.app: accepted\nsource=Notarized Developer ID\noverride=security disabled\norigin=Developer ID Application: Hechen Li (67CQ77V27R)",
                                                findings: [])
        #expect(report.appName == "IINA")
        #expect(report.quarantined)
        #expect(report.quarantineAgent == "Homebrew Cask")
        #expect(report.signature == .valid)
        #expect(report.signer == "Developer ID Application: Hechen Li (67CQ77V27R)")
        #expect(report.notarized == true)
        #expect(report.verdict == .notAssessedGatekeeperOff)
        #expect(!report.approvedByUser)
        #expect(report.advice == .notChecked)
    }

    @Test func adviceFollowsTheAssessment() {
        let app = URL(fileURLWithPath: "/Applications/Tool.app")
        let downloaded = GatekeeperInspector.report(app: app, quarantine: "0083;1;Safari;U", verify: Self.ok(), details: "Authority=Developer ID Application: A (T)",
                                                    notarized: Self.ok(), assess: "/Applications/Tool.app: accepted\nsource=Notarized Developer ID", findings: [])
        #expect(downloaded.advice == .firstOpenAsks)
        let installed = GatekeeperInspector.report(app: app, quarantine: nil, verify: Self.ok(), details: "Authority=Apple", notarized: Self.ok(),
                                                   assess: "/Applications/Tool.app: accepted\nsource=Apple System", findings: [])
        #expect(installed.advice == .opensNormally)
        let adHoc = GatekeeperInspector.report(app: app, quarantine: "01c3;1;Safari;U", verify: Self.ok(), details: "Signature=adhoc\nTeamIdentifier=not set",
                                               notarized: Self.fail(), assess: "/Applications/Tool.app: rejected\nsource=no usable signature",
                                               findings: ["Adhoc Signed App (Warning)", "Notary Ticket Missing (Fatal)"])
        #expect(adHoc.signature == .adHoc)
        #expect(adHoc.notarized == false)
        #expect(adHoc.verdict == .rejected)
        #expect(adHoc.advice == .needsOpenAnyway)
        let approved = GatekeeperInspector.report(app: app, quarantine: "01c3;1;Safari;U", verify: Self.ok(), details: "Signature=adhoc",
                                                  notarized: Self.fail(), assess: "/Applications/Tool.app: accepted\noverride=user approved", findings: [])
        #expect(approved.approvedByUser)
        #expect(approved.advice == .opensNormally)
        let broken = GatekeeperInspector.report(app: app, quarantine: nil, verify: Self.fail(1, "a sealed resource is missing or invalid"),
                                                details: "Authority=Developer ID Application: A (T)", notarized: Self.fail(),
                                                assess: "/Applications/Tool.app: rejected", findings: [])
        #expect(broken.signature == .invalid)
        #expect(broken.advice == .damaged)
        let unsigned = GatekeeperInspector.report(app: app, quarantine: nil, verify: Self.fail(1), details: "/Applications/Tool.app: code object is not signed at all",
                                                  notarized: nil, assess: nil, findings: [])
        #expect(unsigned.signature == .unsigned)
        #expect(unsigned.notarized == nil)
        #expect(unsigned.verdict == .unknown)
        #expect(unsigned.advice == .needsOpenAnyway)
    }

    @Test func syspolicyCheckJSONIsReadDespiteExitZero() {
        let json = """
        Only one signature found...
        {"output":[{"SyspolicyCheckShortError":"Adhoc Signed App","SyspolicyCheckErrorLevel":"Warning"},{"SyspolicyCheckShortError":"Notary Ticket Missing","SyspolicyCheckErrorLevel":"Fatal"}]}
        """
        #expect(GatekeeperInspector.policyFindings(json) == ["Adhoc Signed App (Warning)", "Notary Ticket Missing (Fatal)"])
        #expect(GatekeeperInspector.policyFindings("not json").isEmpty)
    }

    @Test func quarantineIsReadFromTheAttribute() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Downloaded.app")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(GatekeeperInspector.quarantine(of: file) == nil)
        let value = "0083;6acbc32e;Safari;ABC"
        #expect(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        #expect(GatekeeperInspector.quarantine(of: file) == value)
    }
}
