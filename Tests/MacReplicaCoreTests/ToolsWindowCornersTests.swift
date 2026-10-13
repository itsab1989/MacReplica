import Foundation
import Testing
@testable import MacReplicaCore

/// Tool C works only on a file store here: the tests never touch this Mac's global preferences.
@Suite("Tools: window corners")
struct ToolsWindowCornersTests {
    static func tool(_ version: String = "27.0.1") -> (WindowCornersTool, FileGlobalPreferenceStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileGlobalPreferenceStore(file: folder.appendingPathComponent(".GlobalPreferences.plist"))
        return (WindowCornersTool(store: store, environment: ToolEnvironment(macOSVersion: version, architecture: .arm64)), store, folder)
    }

    @Test func offeredOnlyFrom26_4() {
        #expect(WindowCornersTool.capability(ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64)) == .experimental)
        #expect(WindowCornersTool.capability(ToolEnvironment(macOSVersion: "26.4", architecture: .x86_64)) == .experimental)
        #expect(WindowCornersTool.capability(ToolEnvironment(macOSVersion: "26.3.1", architecture: .arm64)) == .unsupportedOnThisVersion)
        #expect(WindowCornersTool.capability(ToolEnvironment(macOSVersion: "15.7", architecture: .arm64)) == .unsupportedOnThisVersion)
        let (old, _, folder) = Self.tool("26.1")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WindowCornersError.unsupported) { try old.apply(.uniform(10, surfaces: [.windows])) }
    }

    @Test func uniformRadiusGoesToEveryChosenSurfaceOnly() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(tool.state().isSystemDefault)
        let chosen: Set<CornerSurface> = [.windows, .utilityPanels, .quickLook, .buttons]
        let result = try tool.apply(.uniform(7, surfaces: chosen))
        #expect(result.outcome == .partiallyVerified)
        #expect(result.before.values.isEmpty)
        #expect(store.value("NSConvolutionOverride1") as? Int == 7)
        #expect(store.value("NSConvolutionOverride2") as? Int == 7)
        #expect(store.value("MacReplicaQuickLookCornerRadius") as? Int == 7)
        #expect(store.value("MacReplicaRoundedButtons") as? Bool == true)
        // Surfaces left out stay macOS's own.
        #expect(store.value("MacReplicaMenuCornerRadius") == nil)
        #expect(store.value("MacReplicaPopoverCornerRadius") == nil)
        #expect(store.value("MacReplicaToolbarCornerRadius") == nil)
        #expect(result.after.radius(.menus) == .system)
        #expect(result.after.needsPlugin)
        #expect(!CornerConfiguration.uniform(7, surfaces: [.windows, .utilityPanels]).needsPlugin)
    }

    @Test func surfacesCanHaveTheirOwnRadius() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = CornerConfiguration(radii: [.windows: .radius(10), .menus: .radius(4), .popovers: .radius(12), .toolbars: .radius(6)])
        let result = try tool.apply(configuration)
        #expect(result.after.radius(.windows) == .radius(10))
        #expect(result.after.radius(.menus) == .radius(4))
        #expect(result.after.radius(.popovers) == .radius(12))
        #expect(result.after.radius(.toolbars) == .radius(6))
        #expect(result.after.radius(.quickLook) == .system)
        #expect(store.value("MacReplicaToolbarCornerRadius") as? Int == 6)
        #expect(tool.state() == tool.normalized(configuration))
    }

    @Test func revertWritesBackEveryKeyExactlyAsItWas() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Set by hand before (e.g. `defaults write -g NSConvolutionOverride1 -int 7`), plus a value AppKit ignores.
        try store.set("NSConvolutionOverride1", 7)
        try store.set("NSConvolutionOverride2", "0")
        try store.set("NSGlassMenusEnabled", false)
        let before = tool.snapshot()
        #expect(before.values["NSConvolutionOverride1"] == "int:7")
        #expect(before.values["NSConvolutionOverride2"] == "string:0")
        #expect(before.values["NSGlassMenusEnabled"] == "bool:0")
        #expect(tool.state().classicMenus)
        // The history keeps the snapshot; the revert uses it later.
        let text = before.historyText
        _ = try tool.apply(.uniform(12, surfaces: Set(CornerSurface.allCases)))
        #expect(store.value("NSGlassMenusEnabled") == nil)
        let restored = try #require(CornerSnapshot(historyText: text))
        let back = try tool.restore(restored)
        #expect(back.outcome == .partiallyVerified)
        #expect(store.value("NSConvolutionOverride1") as? Int == 7)
        #expect(store.value("NSConvolutionOverride2") as? String == "0")
        #expect(store.value("NSGlassMenusEnabled") as? Bool == false)
        #expect(store.value("MacReplicaMenuCornerRadius") == nil)
        #expect(store.value("MacReplicaRoundedButtons") == nil)
    }

    @Test func macOSDefaultRemovesEverything() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try tool.apply(CornerConfiguration(radii: [.windows: .radius(4)], roundedButtons: true, classicMenus: true))
        #expect(store.value("NSGlassMenusEnabled") as? Bool == false)
        _ = try tool.apply(CornerConfiguration())
        for key in CornerSnapshot.keys { #expect(store.value(key) == nil, "\(key)") }
        #expect(tool.state().isSystemDefault)
        #expect(tool.snapshot().historyText.isEmpty)
    }

    @Test func storedValuesAreInterpretedLikeAppKit() {
        #expect(CornerSetting(stored: nil) == .system)
        #expect(CornerSetting(stored: 0) == .system)
        #expect(CornerSetting(stored: "x") == .system)
        #expect(CornerSetting(stored: "12") == .radius(12))
        #expect(CornerSetting(stored: 9.6) == .radius(10))
        #expect(CornerSetting(historyText: "system") == .system)
        #expect(CornerSetting(historyText: "0") == nil)
        #expect(CornerSnapshot(historyText: "Unknown=int:1") == nil)
        #expect(CornerSnapshot(historyText: "")?.values.isEmpty == true)
        #expect(MenuAppearance(stored: "NO") == .classic)
        #expect(MenuAppearance(stored: 1) == .glass)
        #expect(MenuAppearance(stored: nil) == .glass)
    }

    @Test func radiusOutsideTheRangeIsRefused() {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WindowCornersError.invalidRadius) { try tool.apply(.uniform(1, surfaces: [.windows])) }
        #expect(throws: WindowCornersError.invalidRadius) { try tool.apply(CornerConfiguration(radii: [.popovers: .radius(25)])) }
        #expect(store.value("NSConvolutionOverride1") == nil)
        #expect(tool.systemRadius == 16)
        #expect(CornerSurface.allCases.filter(\.needsPlugin) == [.menus, .popovers, .quickLook, .toolbars, .buttons])
    }
}

/// The corner plugin: requirements, its two files only, and the same tested builds as the plugin source.
@Suite("Tools: corner plugin")
struct ToolsCornerPluginTests {
    static func status(build: String? = "26A434", debugging: Bool? = true, loaderInstalled: Bool = true, loaderEnabled: Bool = true,
                       installed: Bool = false, current: Bool = false) -> CornerPlugin.Status {
        CornerPlugin.Status(build: build, sip: .disabled, debuggingAllowed: debugging, loaderInstalled: loaderInstalled,
                            loaderEnabled: loaderEnabled, installed: installed, current: current)
    }

    @Test func readinessNamesTheFirstMissingStep() {
        #expect(Self.status().readiness == .ready)
        #expect(Self.status().capability == .requiresAdministrator)
        #expect(Self.status(build: "26B100").readiness == .untestedBuild)
        #expect(Self.status(build: nil).readiness == .untestedBuild)
        #expect(Self.status(build: "26B100").capability == .unsupportedOnThisVersion)
        #expect(Self.status(debugging: false).readiness == .sipFullyOn)
        #expect(Self.status(debugging: nil).readiness == .unknown)
        #expect(Self.status(loaderInstalled: false).readiness == .loaderMissing)
        #expect(Self.status(loaderEnabled: false).readiness == .loaderNotEnabled)
        #expect(Self.status(debugging: false).capability == .requiresUserAction)
        #expect(Self.status(loaderInstalled: false).capability == .requiresUserAction)
    }

    @Test func debuggingAllowedIsReadFromCsrutil() {
        #expect(CornerPlugin.debuggingAllowed(csrutilOutput: "System Integrity Protection status: disabled.") == true)
        #expect(CornerPlugin.debuggingAllowed(csrutilOutput: "System Integrity Protection status: enabled.") == false)
        // `csrutil enable --without debug` leaves a custom configuration with debugging allowed.
        #expect(CornerPlugin.debuggingAllowed(csrutilOutput: "System Integrity Protection status: enabled (Custom Configuration).\n\tDebugging Restrictions: disabled") == true)
        #expect(CornerPlugin.debuggingAllowed(csrutilOutput: "status: enabled (Custom Configuration).\n\tDebugging Restrictions: enabled") == false)
        #expect(CornerPlugin.debuggingAllowed(csrutilOutput: nil) == nil)
        #expect(CornerPlugin.currentBuild()?.isEmpty == false)
    }

    @Test func statusFallsBackToTheSipArgumentWhenCsrutilCannotBeRead() async throws {
        // A runner whose csrutil cannot be read: status must fall back to the sip value it was given.
        var layout = SystemLayout.live()
        layout.csrutil = "/nonexistent/csrutil"
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disabled = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(disabled.debuggingAllowed == true)
        let enabled = await CornerPlugin.status(layout: layout, runner: runner, sip: .enabled, appBundle: app, build: "26A434")
        #expect(enabled.debuggingAllowed == false)
        let unknown = await CornerPlugin.status(layout: layout, runner: runner, sip: .unknown, appBundle: app, build: "26A434")
        #expect(unknown.debuggingAllowed == nil)
    }

    @Test func testedBuildsMatchThePluginSource() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extras/CornerPlugin/MacReplicaCorners.m")
        let text = try String(contentsOf: source, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("#define TESTED_BUILDS") })
        let builds = Set(line.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) })
        #expect(builds == CornerPlugin.testedBuilds)
        // The keys the plugin reads are the ones the tool writes.
        for surface in CornerSurface.allCases where surface.needsPlugin { #expect(text.contains("@\"\(surface.key)\""), "\(surface)") }
    }

    @Test func onlyItsOwnTwoFilesCanBeRemoved() throws {
        let tweaks = URL(fileURLWithPath: "/opt/pluginplayground/tweaks")
        #expect(PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("MacReplicaCorners.dylib")))
        #expect(PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("MacReplicaCorners.dylib.options")))
        #expect(!PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("OtherTweak.dylib")))
        #expect(!PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/opt/pluginplayground/MacReplicaCorners.dylib")))
        #expect(!PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/opt/pluginplayground/tweaks/../bin/fangs")))
        #expect(throws: PrivilegedError.self) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.removePluginFile(URL(fileURLWithPath: "/etc/hosts"))], reason: "x")
        }
        let arguments = try AppleScriptPrivilegedExecutor.arguments(for: CornerPlugin.removeOperations(layout: .live()), reason: "x")
        #expect(arguments.contains("/bin/rm") && arguments.contains("/opt/pluginplayground/tweaks/MacReplicaCorners.dylib"))
    }

    @Test func installCopiesOptionsFirstAndRemoveTakesThePluginFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("MacReplica.app")
        #expect(CornerPlugin.installOperations(layout: .live(), appBundle: app) == nil)
        let plugin = app.appendingPathComponent("Contents/Library/CornerPlugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: plugin.appendingPathComponent(CornerPlugin.dylibName))
        try Data("<plist/>\n".utf8).write(to: plugin.appendingPathComponent(CornerPlugin.optionsName))
        var layout = SystemLayout.live()
        layout.pluginTweaks = folder.appendingPathComponent("pluginplayground/tweaks")
        layout.pluginLoaderBin = folder.appendingPathComponent("pluginplayground/bin")
        layout.pluginLoaderDaemon = folder.appendingPathComponent("grant.plist")
        let install = try #require(CornerPlugin.installOperations(layout: layout, appBundle: app))
        guard case .installFile(_, let first) = install[0] else { Issue.record("not an install"); return }
        #expect(first.lastPathComponent == CornerPlugin.optionsName)
        guard case .removePluginFile(let removed) = CornerPlugin.removeOperations(layout: layout)[0] else { Issue.record("not a removal"); return }
        #expect(removed.lastPathComponent == CornerPlugin.dylibName)
        // Installing and removing through the executor used for simulated Macs; the status follows the files.
        try FileManager.default.createDirectory(at: layout.pluginTweaks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.pluginLoaderBin, withIntermediateDirectories: true)
        try Data().write(to: layout.pluginLoaderDaemon)
        try await DirectPrivilegedExecutor().run(install, reason: "test")
        // A csrutil stand-in that reports debugging allowed, so status reads it.
        let csr = folder.appendingPathComponent("csrutil")
        try "#!/bin/bash\necho \"System Integrity Protection status: disabled.\"\n".write(to: csr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: csr.path)
        layout.csrutil = csr.path
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [csr.path]), baseEnvironment: [:])
        var status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(status.installed && status.current)
        #expect(status.loaderInstalled && status.loaderEnabled)
        #expect(status.debuggingAllowed == true)
        #expect(status.readiness == .ready)
        try await DirectPrivilegedExecutor().run(CornerPlugin.removeOperations(layout: layout), reason: "test")
        status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(!status.installed)
        #expect(status.loaderInstalled)
    }
}
