import Foundation
import Testing
@testable import MacReplicaCore

/// Boundaries of the Tools modules that the mutation run showed untested.
@Suite("Tools: edge cases")
struct ToolsEdgeTests {
    @Test func managementNeedsAProfileNotJustEnrolment() {
        let enrolledNoProfile = GatekeeperInspector.interpret(spctl: "assessments enabled", csrutil: nil, enrollment: "MDM enrollment: Yes",
                                                              controlProfile: nil, managedProfile: nil)
        #expect(enrolledNoProfile.enrollment == .enrolled)
        #expect(enrolledNoProfile.summary == .normal, "an enrolled Mac whose Gatekeeper is not set by a profile is not reported as managed")
        let enrolledManual = GatekeeperInspector.interpret(spctl: "assessments disabled", csrutil: nil, enrollment: "MDM enrollment: Yes",
                                                           controlProfile: ["_manualProfile": true, "EnableAssessment": false], managedProfile: nil)
        #expect(enrolledManual.summary == .managed)
        #expect(!GatekeeperStatus(assessments: .enabled).overrideDisabled)
        // DisableOverride from a hand-installed profile vs. from device management.
        let manualOverride = GatekeeperInspector.interpret(spctl: "assessments enabled", csrutil: nil, enrollment: nil, controlProfile: nil,
                                                           managedProfile: ["DisableOverride": true, "_manualProfile": true])
        #expect(manualOverride.profile == .manual)
        let mdmOverride = GatekeeperInspector.interpret(spctl: "assessments enabled", csrutil: nil, enrollment: nil, controlProfile: nil,
                                                        managedProfile: ["DisableOverride": true])
        #expect(mdmOverride.profile == .deviceManagement)
    }

    @Test func unknownVerdictFallsBackToSignatureAndNotarisation() {
        let app = URL(fileURLWithPath: "/Applications/Tool.app")
        func report(valid: Bool, notarized: Bool?) -> AppSecurityReport {
            GatekeeperInspector.report(app: app, quarantine: nil,
                                       verify: CommandResult(exitCode: valid ? 0 : 1, stdout: "", stderr: ""),
                                       details: "Authority=Developer ID Application: A (T)",
                                       notarized: notarized.map { CommandResult(exitCode: $0 ? 0 : 3, stdout: "", stderr: "") },
                                       assess: nil, findings: [])
        }
        #expect(report(valid: true, notarized: true).advice == .opensNormally)
        #expect(report(valid: true, notarized: false).advice == .needsOpenAnyway)
        #expect(report(valid: true, notarized: nil).advice == .needsOpenAnyway)
        #expect(report(valid: false, notarized: true).advice == .damaged)
    }

    @Test func quarantineAgentWithEmptyFields() {
        let app = URL(fileURLWithPath: "/Applications/Tool.app")
        func agent(_ value: String) -> String? {
            GatekeeperInspector.report(app: app, quarantine: value, verify: nil, details: nil, notarized: nil, assess: nil, findings: []).quarantineAgent
        }
        #expect(agent("0083;;Safari;U") == "Safari", "an empty time field keeps the agent in third place")
        #expect(agent("0083;1;;U") == nil)
        #expect(agent("0083;1") == nil)
        #expect(agent("0083;1;Mail") == "Mail")
    }

    @Test func emptyQuarantineAttributeIsNoMark() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("x")
        try Data().write(to: file)
        #expect(setxattr(file.path, "com.apple.quarantine", "", 0, 0, 0) == 0)
        #expect(GatekeeperInspector.quarantine(of: file) == nil)
    }

    @Test func systemFoldersAreRefusedOneByOne() {
        for path in ["/System/Applications/Calculator.app", "/usr/local/Tool.app", "/Library/Apple/System/Thing.app"] {
            #expect(throws: QuarantineEditor.Failure.systemLocation) { try QuarantineEditor.check(URL(fileURLWithPath: path), report: nil) }
        }
        #expect(throws: Never.self) { try QuarantineEditor.check(URL(fileURLWithPath: "/Applications/Tool.app"), report: nil) }
    }

    @Test func aFailedRemovalLeavesTheAppMarked() throws {
        let value = "0083;6acbc32e;Safari;ABC"
        let (folder, app) = try ToolsGatekeeperTests.bundle(quarantine: value)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Tool").path)
            try? FileManager.default.removeItem(at: folder)
        }
        // The inner file cannot be changed: removing its mark fails after the bundle's mark was already removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Tool").path)
        do {
            _ = try QuarantineEditor.remove(from: app, report: nil)
            // Some file systems allow it anyway; then the whole bundle is unmarked, which is also consistent.
            #expect(GatekeeperInspector.quarantine(of: app) == nil)
        } catch QuarantineEditor.Failure.notWritable {
            #expect(GatekeeperInspector.quarantine(of: app) == value, "the bundle gets its mark back when not everything could be changed")
        }
    }

    @Test func supportStatusIgnoresUnreadableVersions() {
        #expect(MacOSSupportStatus.evaluate(installedVersion: "garbage", installers: ["27.0", "26.7"]).support == .unknown)
        // An unparsable installer version is not a major version “0” that would hide the end of support.
        #expect(MacOSSupportStatus.evaluate(installedVersion: "15.1", installers: ["27.0", "26.7", "beta"]).support == .likelyEnded)
    }

    @Test func profilesRefusedWithoutRootIsUnknown() async {
        struct Refusing: CommandRunning {
            func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
                CommandResult(exitCode: 0, stdout: "", stderr: "profiles: this command requires root privileges")
            }
        }
        struct Listing: CommandRunning {
            func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
                CommandResult(exitCode: 0, stdout: "_computerlevel[1] attribute: profileIdentifier: com.example.x\n", stderr: "")
            }
        }
        #expect(await InstalledProfiles.read(layout: .live(), runner: Refusing()) == nil)
        #expect(await InstalledProfiles.read(layout: .live(), runner: Listing()) == ["com.example.x"])
    }
}

@Suite("Tools: corner edge cases")
struct ToolsCornerEdgeTests {
    @Test func zeroIsMacOSsOwnRadius() {
        #expect(CornerSetting(stored: "0") == .system)
        #expect(CornerSetting(stored: 0.0) == .system)
        #expect(CornerSetting(stored: "1") == .radius(1))
        #expect(CornerSetting(stored: 0.6) == .radius(1))
    }

    @Test func defaultAndPluginNeedLookAtEverySurface() {
        #expect(CornerConfiguration().isSystemDefault)
        #expect(!CornerConfiguration(roundedButtons: true).isSystemDefault)
        #expect(!CornerConfiguration(classicMenus: true).isSystemDefault)
        #expect(!CornerConfiguration(radii: [.windows: .radius(5)]).isSystemDefault)
        #expect(CornerConfiguration(roundedButtons: true).needsPlugin, "the button shape alone needs the plugin")
        #expect(CornerConfiguration(radii: [.toolbars: .radius(5)]).needsPlugin)
        #expect(!CornerConfiguration(radii: [.windows: .radius(5), .utilityPanels: .radius(5)], classicMenus: true).needsPlugin)
        #expect(!CornerConfiguration(radii: [.menus: .system]).needsPlugin)
    }

    @Test func buttonSwitchIsReadAsBooleanOrNumber() throws {
        let (tool, store, folder) = ToolsWindowCornersTests.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!tool.state().roundedButtons)
        try store.set("MacReplicaRoundedButtons", 1)
        #expect(tool.state().roundedButtons)
        try store.set("MacReplicaRoundedButtons", 0)
        #expect(!tool.state().roundedButtons)
        try store.set("MacReplicaRoundedButtons", true)
        #expect(tool.state().roundedButtons)
        try store.set("MacReplicaRoundedButtons", false)
        #expect(!tool.state().roundedButtons)
    }

    @Test func pluginNeedsBothFilesEverywhere() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("MacReplica.app")
        let bundled = app.appendingPathComponent("Contents/Library/CornerPlugin")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: bundled.appendingPathComponent(CornerPlugin.dylibName))
        #expect(CornerPlugin.bundled(in: app) == nil, "without its blacklist the plugin is never offered")
        var layout = SystemLayout.live()
        layout.ammoniaTweaks = folder.appendingPathComponent("ammonia/core/tweaks")
        try FileManager.default.createDirectory(at: layout.ammoniaTweaks, withIntermediateDirectories: true)
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        var status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(!status.installed && !status.current)
        try Data("dylib".utf8).write(to: layout.ammoniaTweaks.appendingPathComponent(CornerPlugin.dylibName))
        status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(!status.installed, "a plugin without its blacklist does not count as installed")
        #expect(!status.current)
    }

    @Test func removalRefusesPathsWithParentSteps() {
        #expect(!PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/etc/../private/var/ammonia/core/tweaks/MacReplicaCorners.dylib")))
        #expect(PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/private/var/ammonia/core/tweaks/MacReplicaCorners.dylib")))
    }

    @Test func locatorLooksAtMostOneFolderDownByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ApplicationLocatorTests.app("Deep/Er/X.app", id: "com.x", in: root)
        try ApplicationLocatorTests.app("Suite/Y.app", id: "com.y", in: root)
        #expect(ApplicationLocator.find(names: ["Deep/Er/X.app"], bundleIdentifier: nil, in: [root]) == nil)
        #expect(ApplicationLocator.find(names: ["Suite/Y.app"], bundleIdentifier: nil, in: [root]) != nil)
    }
}
