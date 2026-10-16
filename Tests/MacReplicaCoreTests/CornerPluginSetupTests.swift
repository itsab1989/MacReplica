import Foundation
import Testing
@testable import MacReplicaCore

/// The automatic corner-plugin setup: the real state is probed (launchd, the injector, the loader's settings), only the
/// missing steps run, a half-finished run continues where it stopped, and the daemon MacReplica writes is exactly the
/// one Plugin Playground's own app writes.
@Suite("Corner plugin: automatic setup")
struct CornerPluginSetupTests {
    /// An executable stand-in that prints `stdout` and exits with `exit` – or, with `marker`, exits 0 only while that
    /// file exists (a simulated daemon that runs after it was started).
    static func standIn(_ name: String, exit: Int32, stdout: String = "", marker: URL? = nil, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        var script = "#!/bin/bash\nprintf '%b' '\(stdout)'\n"
        if let marker { script += "[ -e '\(marker.path)' ] && exit 0\n" }
        script += "exit \(exit)\n"
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// A temporary Mac: this copy of MacReplica with its plugin, the loader's folders and stand-ins for csrutil/launchctl/pgrep.
    struct Fixture {
        var folder: URL
        var app: URL
        var layout: SystemLayout
        var runner: ProcessCommandRunner
        var marker: URL

        init(launchctlExit: Int32 = 113, launchctlOutput: String = "") throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            app = folder.appendingPathComponent("MacReplica.app")
            let bundled = app.appendingPathComponent("Contents/Library/CornerPlugin")
            try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
            try Data("dylib".utf8).write(to: bundled.appendingPathComponent(CornerPlugin.dylibName))
            try Data("<plist/>\n".utf8).write(to: bundled.appendingPathComponent(CornerPlugin.optionsName))
            marker = folder.appendingPathComponent("state/running")
            layout = SystemLayout.live()
            layout.pluginTweaks = folder.appendingPathComponent("opt/pluginplayground/tweaks")
            layout.pluginLoaderBin = folder.appendingPathComponent("opt/pluginplayground/bin")
            layout.pluginLoaderOptions = folder.appendingPathComponent("opt/pluginplayground/current.options")
            layout.pluginLoaderDaemon = folder.appendingPathComponent("Library/LaunchDaemons/com.pluginplayground.grant.plist")
            layout.pluginLoaderLogs = folder.appendingPathComponent("var/log/pluginplayground")
            let tools = folder.appendingPathComponent("tools")
            layout.csrutil = try standIn("csrutil", exit: 0, stdout: "System Integrity Protection status: unknown (Custom Configuration).\\n\\tDebugging Restrictions: disabled\\n", in: tools).path
            layout.launchctl = try standIn("launchctl", exit: launchctlExit, stdout: launchctlOutput, marker: marker, in: tools).path
            layout.pgrep = try standIn("pgrep", exit: 1, marker: marker, in: tools).path
            runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [layout.csrutil, layout.launchctl, layout.pgrep]), baseEnvironment: [:])
        }

        func status() async -> CornerPlugin.Status {
            await CornerPlugin.status(layout: layout, runner: runner, sip: .unknown, appBundle: app, build: "26A434", architecture: .arm64)
        }

        /// Installs the "package" (the loader's two programs) and starts the service by creating the marker.
        func executor(serviceFails: Bool = false) -> DirectPrivilegedExecutor {
            let bin = layout.pluginLoaderBin
            let marker = self.marker
            return DirectPrivilegedExecutor(packageInstaller: { _ in
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: bin.deletingLastPathComponent().appendingPathComponent("tweaks"), withIntermediateDirectories: true)
                for tool in ["grant", "fangs"] {
                    try Data().write(to: bin.appendingPathComponent(tool))
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(tool).path)
                }
            }, serviceStarter: { _ in
                if serviceFails { throw PrivilegedError.failed("bootstrap failed") }
                try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: marker)
            })
        }

        func setUp(_ steps: [CornerPlugin.SetupStep], executor: DirectPrivilegedExecutor) async throws {
            let package = folder.appendingPathComponent("PluginPlayground.pkg")
            try Data().write(to: package)
            try FileManager.default.createDirectory(at: layout.pluginLoaderDaemon.deletingLastPathComponent(), withIntermediateDirectories: true)
            let operations = try PluginLoader.setupOperations(steps, layout: layout, appBundle: app, package: package,
                                                              staging: folder.appendingPathComponent("staging"))
            try await executor.run(operations, reason: "test")
        }
    }

    @Test func probesMapExitCodesAndUnknowns() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var layout = SystemLayout.live()
        layout.pluginTweaks = folder.appendingPathComponent("tweaks")
        layout.pluginLoaderBin = folder.appendingPathComponent("bin")
        for (launchctl, pgrep, loaded, running) in [(Int32(0), Int32(0), Bool?.some(true), Bool?.some(true)),
                                                    (113, 1, false, false),
                                                    (5, 2, nil, nil)] {
            layout.launchctl = try Self.standIn("launchctl-\(launchctl)", exit: launchctl, in: folder).path
            layout.pgrep = try Self.standIn("pgrep-\(pgrep)", exit: pgrep, in: folder).path
            let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [layout.launchctl, layout.pgrep]), baseEnvironment: [:])
            let status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: folder, build: "26A434")
            #expect(status.serviceLoaded == loaded)
            #expect(status.injectorRunning == running)
        }
        // Tools that cannot run at all: unknown, never "running".
        let refusing = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        let status = await CornerPlugin.status(layout: layout, runner: refusing, sip: .disabled, appBundle: folder, build: "26A434")
        #expect(status.serviceLoaded == nil && status.injectorRunning == nil)
        #expect(!status.loaderInstalled, "an empty bin folder is not an installed loader")
        // `activeHere` defaults to false and is only true when the caller passes it (the app checks its own images).
        #expect(!status.activeHere)
    }

    @Test func lastExitIsReadFromLaunchctl() {
        #expect(PluginLoader.lastExit(launchctlPrint: "system/x = {\n\tstate = waiting\n\tlast exit code = 1\n}") == "1")
        #expect(PluginLoader.lastExit(launchctlPrint: "\tlast exit code = 78: EX_CONFIG\n") == "78: EX_CONFIG")
        #expect(PluginLoader.lastExit(launchctlPrint: "state = running") == nil)
    }

    @Test func serviceDefinitionIsPluginPlaygroundsOwn() throws {
        // configurator/Services/PPDaemonStatus.m (Plugin Playground 1.1.0), `addPlist`.
        let definition = PluginLoader.serviceDefinition(layout: .live())
        #expect(definition["Label"] as? String == "com.pluginplayground.grant")
        #expect(definition["ProgramArguments"] as? [String] == ["/opt/pluginplayground/bin/grant"])
        #expect(definition["RunAtLoad"] as? Bool == true)
        #expect(definition["KeepAlive"] as? Bool == true)
        #expect(definition["StandardOutPath"] as? String == "/var/log/pluginplayground/grant.log")
        #expect(definition["StandardErrorPath"] as? String == "/var/log/pluginplayground/grant.err")
        #expect(definition.count == 6)
        #expect(SystemLayout.live().pluginLoaderDaemon == PluginLoader.daemonPlist)
        #expect(SystemLayout.live().pluginLoaderOptions.path == "/opt/pluginplayground/current.options")
        #expect(SystemLayout.live().pluginLoaderLogs == PluginLoader.logs)
    }

    @Test func pacSettingKeepsEveryOtherChoiceOfTheUser() throws {
        func read(_ data: Data) throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let existing = try PropertyListSerialization.data(fromPropertyList: ["disablePAC": false, "pauseInjection": true,
                                                                             "globalBlacklist": ["Terminal"], "custom": 3],
                                                          format: .xml, options: 0)
        let merged = try read(PluginLoader.optionsWithPACStripping(existing: existing))
        #expect(merged["disablePAC"] as? Bool == true)
        #expect(merged["pauseInjection"] as? Bool == true)
        #expect(merged["globalBlacklist"] as? [String] == ["Terminal"])
        #expect(merged["custom"] as? Int == 3)
        #expect(merged["useLegacyAmmonia"] as? Bool == false)
        for start in [nil, Data("not a plist".utf8)] {
            let fresh = try read(PluginLoader.optionsWithPACStripping(existing: start))
            #expect(fresh["disablePAC"] as? Bool == true)
            #expect(fresh["pauseInjection"] as? Bool == false)
            #expect(fresh["useLegacyAmmonia"] as? Bool == false)
            #expect((fresh["globalBlacklist"] as? [String])?.isEmpty == true)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("current.options")
        #expect(!PluginLoader.pacStrippingOn(optionsFile: file), "a missing file means off – what the injector assumes")
        try existing.write(to: file)
        #expect(!PluginLoader.pacStrippingOn(optionsFile: file))
        try PluginLoader.optionsWithPACStripping(existing: existing).write(to: file)
        #expect(PluginLoader.pacStrippingOn(optionsFile: file))
        try Data("garbage".utf8).write(to: file)
        #expect(!PluginLoader.pacStrippingOn(optionsFile: file))
    }

    @Test func onlyTheLoadersDaemonCanBeStarted() throws {
        let daemon = PluginLoader.daemonPlist
        #expect(PrivilegedOperation.startLoaderService(daemon).argv == ["/bin/launchctl", "bootstrap", "system", daemon.path])
        #expect(PrivilegedOperation.isLoaderService(daemon))
        #expect(PrivilegedOperation.isLoaderService(URL(fileURLWithPath: "/sim/Library/LaunchDaemons/com.pluginplayground.grant.plist")))
        #expect(!PrivilegedOperation.isLoaderService(URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.other.plist")))
        #expect(!PrivilegedOperation.isLoaderService(URL(fileURLWithPath: "/tmp/../Library/LaunchDaemons/com.pluginplayground.grant.plist")))
        #expect(!PrivilegedOperation.isLoaderService(URL(fileURLWithPath: "/Library/LaunchDaemons/com.pluginplayground.grant.plist/..")))
        #expect(!PrivilegedOperation.isLoaderService(URL(string: "https://example.com/Library/LaunchDaemons/com.pluginplayground.grant.plist")!))
        let arguments = try AppleScriptPrivilegedExecutor.arguments(for: [.startLoaderService(daemon)], reason: "x")
        #expect(Array(arguments.suffix(5)) == ["4", "/bin/launchctl", "bootstrap", "system", daemon.path])
        #expect(throws: PrivilegedError.self) {
            try AppleScriptPrivilegedExecutor.arguments(for: [.startLoaderService(URL(fileURLWithPath: "/Library/LaunchDaemons/evil.plist"))], reason: "x")
        }
    }

    @Test func operationsFollowTheStepsInOrder() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let package = fixture.folder.appendingPathComponent("p.pkg")
        let staging = fixture.folder.appendingPathComponent("staging")
        let all = try PluginLoader.setupOperations(CornerPlugin.SetupStep.allCases, layout: fixture.layout, appBundle: fixture.app,
                                                   package: package, staging: staging)
        #expect(all.count == 7)
        #expect(all[0] == .installPackage(package))
        #expect(all[3] == .installFile(source: staging.appendingPathComponent("current.options"), destination: fixture.layout.pluginLoaderOptions))
        #expect(all[4] == .createFolder(fixture.layout.pluginLoaderLogs))
        #expect(all[5] == .installFile(source: staging.appendingPathComponent("com.pluginplayground.grant.plist"), destination: fixture.layout.pluginLoaderDaemon))
        #expect(all[6] == .startLoaderService(fixture.layout.pluginLoaderDaemon))
        #expect(try PluginLoader.setupOperations([.startService], layout: fixture.layout, appBundle: fixture.app, package: nil, staging: staging)
                == [.startLoaderService(fixture.layout.pluginLoaderDaemon)])
        #expect(throws: PluginLoader.InstallError.downloadFailed("no package")) {
            try PluginLoader.setupOperations([.installLoader], layout: fixture.layout, appBundle: fixture.app, package: nil, staging: staging)
        }
        #expect(throws: PluginLoader.InstallError.pluginMissingInApp) {
            try PluginLoader.setupOperations([.installPlugin], layout: fixture.layout, appBundle: fixture.folder, package: nil, staging: staging)
        }
    }

    @Test func cleanSetupEndsVerifiedAndARepeatDoesNothing() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let before = await fixture.status()
        #expect(before.readiness == .loaderMissing)
        #expect(before.missingSteps == CornerPlugin.SetupStep.allCases)
        try await fixture.setUp(before.missingSteps, executor: fixture.executor())
        let after = await fixture.status()
        #expect(after.readiness == .ready)
        #expect(after.loaderEnabled && after.pacStrippingOn && after.installed && after.current)
        #expect(after.missingSteps.isEmpty, "running the setup again changes nothing")
        let written = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.layout.pluginLoaderDaemon), format: nil) as? [String: Any])
        #expect(written["Label"] as? String == PluginLoader.serviceLabel)
        #expect(FileManager.default.fileExists(atPath: fixture.layout.pluginLoaderLogs.path))
    }

    @Test func aFailedStartKeepsTheFinishedStepsAndOnlyThatStepIsRetried() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let steps = await fixture.status().missingSteps
        await #expect(throws: PrivilegedError.failed("bootstrap failed")) {
            try await fixture.setUp(steps, executor: fixture.executor(serviceFails: true))
        }
        let halfway = await fixture.status()
        #expect(halfway.readiness == .serviceMissing, "a daemon file launchd never loaded is not an enabled loader")
        #expect(!halfway.loaderEnabled)
        #expect(halfway.missingSteps == [.startService])
        try await fixture.setUp(halfway.missingSteps, executor: fixture.executor())
        #expect(await fixture.status().readiness == .ready)
    }

    @Test func theReportedStateNeedsTheServiceAndThePACSetting() async throws {
        // Loader and plugin installed by the 1.1.0 setup, Plugin Playground's own "Install" and "Save" never clicked.
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try await fixture.setUp([.installLoader, .installPlugin], executor: fixture.executor())
        let status = await fixture.status()
        #expect(status.readiness == .serviceMissing)
        #expect(!status.loaderEnabled)
        #expect(status.missingSteps == [.savePACSetting, .installService, .startService])
    }

    @Test func aStuckInjectorAsksForARestartAndShowsTheExitCode() async throws {
        let fixture = try Fixture(launchctlExit: 0, launchctlOutput: "\\tstate = waiting\\n\\tlast exit code = 1\\n")
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try await fixture.setUp([.installLoader, .installPlugin, .savePACSetting, .installService], executor: fixture.executor())
        let status = await fixture.status()
        #expect(status.serviceLoaded == true && status.injectorRunning == false)
        #expect(status.readiness == .injectorNotRunning)
        #expect(status.serviceLastExit == "1")
        #expect(status.missingSteps.isEmpty, "MacReplica never restarts a loaded injector itself")
    }

    @Test func undoLeavesARunningInjectorAloneUntilTheRestart() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try await fixture.setUp(CornerPlugin.SetupStep.allCases, executor: fixture.executor())
        // The loader's fixed paths are outside the fixture, so remove the fixture's copies the way the undo does.
        try await fixture.executor().run(CornerPlugin.removeOperations(layout: fixture.layout), reason: "test")
        for item in [fixture.layout.pluginLoaderDaemon, fixture.layout.pluginLoaderBin.deletingLastPathComponent()] {
            try FileManager.default.removeItem(at: item)
        }
        let status = await fixture.status()
        #expect(status.readiness == .removedPendingRestart)
        #expect(status.capability == .requiresUserAction)
        #expect(status.missingSteps.isEmpty)
        #expect(!PluginLoader.uninstallOperations().contains { if case .startLoaderService = $0 { return true } else { return false } })
    }
}
