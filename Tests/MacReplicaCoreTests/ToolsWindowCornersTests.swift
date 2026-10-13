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
    static func status(build: String? = "26A434", sip: GatekeeperStatus.SIP = .disabled, bootArg: Bool? = true, ammonia: Bool = true) -> CornerPlugin.Status {
        CornerPlugin.Status(build: build, sip: sip, bootArgumentSet: bootArg, ammoniaInstalled: ammonia, installed: false, current: false)
    }

    @Test func readinessNamesTheFirstMissingStep() {
        #expect(Self.status().readiness == .ready)
        #expect(Self.status().capability == .requiresAdministrator)
        #expect(Self.status(build: "26B100").readiness == .untestedBuild)
        #expect(Self.status(build: nil).readiness == .untestedBuild)
        #expect(Self.status(build: "26B100").capability == .unsupportedOnThisVersion)
        #expect(Self.status(sip: .enabled).readiness == .sipOn)
        #expect(Self.status(sip: .unknown).readiness == .unknown)
        #expect(Self.status(bootArg: false).readiness == .bootArgumentMissing)
        #expect(Self.status(bootArg: nil).readiness == .unknown)
        #expect(Self.status(ammonia: false).readiness == .ammoniaMissing)
        #expect(Self.status(sip: .enabled).capability == .requiresUserAction)
    }

    @Test func bootArgumentIsReadFromNvram() {
        #expect(CornerPlugin.bootArgumentSet(nvramOutput: "boot-args\t-arm64e_preview_abi") == true)
        #expect(CornerPlugin.bootArgumentSet(nvramOutput: "boot-args\t-v amfi_get_out_of_my_way=1") == false)
        #expect(CornerPlugin.bootArgumentSet(nvramOutput: "nvram: Error getting variable - 'boot-args': (iokit/common) data was not found") == false)
        #expect(CornerPlugin.bootArgumentSet(nvramOutput: nil) == nil)
        #expect(CornerPlugin.currentBuild()?.isEmpty == false)
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
        let tweaks = URL(fileURLWithPath: "/private/var/ammonia/core/tweaks")
        #expect(PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("MacReplicaCorners.dylib")))
        #expect(PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("MacReplicaCorners.dylib.blacklist")))
        #expect(!PrivilegedOperation.isRemovablePlugin(tweaks.appendingPathComponent("OtherTweak.dylib")))
        #expect(!PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/private/var/ammonia/core/MacReplicaCorners.dylib")))
        #expect(!PrivilegedOperation.isRemovablePlugin(URL(fileURLWithPath: "/private/var/ammonia/core/tweaks/../fridagum.dylib")))
        #expect(throws: PrivilegedError.self) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.removePluginFile(URL(fileURLWithPath: "/etc/hosts"))], reason: "x")
        }
        let arguments = try AppleScriptPrivilegedExecutor.arguments(for: CornerPlugin.removeOperations(layout: .live()), reason: "x")
        #expect(arguments.contains("/bin/rm") && arguments.contains("/private/var/ammonia/core/tweaks/MacReplicaCorners.dylib"))
    }

    @Test func installCopiesBlacklistFirstAndRemoveTakesThePluginFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("MacReplica.app")
        #expect(CornerPlugin.installOperations(layout: .live(), appBundle: app) == nil)
        let plugin = app.appendingPathComponent("Contents/Library/CornerPlugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: plugin.appendingPathComponent(CornerPlugin.dylibName))
        try Data("/usr/\n".utf8).write(to: plugin.appendingPathComponent(CornerPlugin.blacklistName))
        var layout = SystemLayout.live()
        layout.ammoniaTweaks = folder.appendingPathComponent("ammonia/core/tweaks")
        let install = try #require(CornerPlugin.installOperations(layout: layout, appBundle: app))
        guard case .installFile(_, let first) = install[0] else { Issue.record("not an install"); return }
        #expect(first.lastPathComponent == CornerPlugin.blacklistName)
        guard case .removePluginFile(let removed) = CornerPlugin.removeOperations(layout: layout)[0] else { Issue.record("not a removal"); return }
        #expect(removed.lastPathComponent == CornerPlugin.dylibName)
        // Installing and removing through the executor used for simulated Macs; the status follows the files.
        try FileManager.default.createDirectory(at: layout.ammoniaTweaks, withIntermediateDirectories: true)
        try await DirectPrivilegedExecutor().run(install, reason: "test")
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        var status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(status.installed && status.current)
        #expect(status.bootArgumentSet == nil)
        try await DirectPrivilegedExecutor().run(CornerPlugin.removeOperations(layout: layout), reason: "test")
        status = await CornerPlugin.status(layout: layout, runner: runner, sip: .disabled, appBundle: app, build: "26A434")
        #expect(!status.installed)
        #expect(status.ammoniaInstalled)
    }
}
