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
        #expect(!ToolCapability.unsupportedOnThisVersion.allowsChange)
        let (old, _, folder) = Self.tool("26.1")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WindowCornersError.unsupported) { try old.apply(windows: .radius(10), utilityPanels: .system) }
    }

    @Test func applyReadsBackAndRevertRestoresAbsence() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(tool.state() == CornerState(windows: .system, utilityPanels: .system))
        let result = try tool.apply(windows: .radius(7), utilityPanels: .radius(7))
        #expect(result.before.windows == .system)
        #expect(result.after.windows == .radius(7))
        // The setting reads back, but the windows change only in apps started afterwards: partly checked.
        #expect(result.outcome == .partiallyVerified)
        #expect(store.value(WindowCornerKey.windows) as? Int == 7)
        let back = try tool.restore(result.before)
        #expect(back.outcome == .partiallyVerified)
        // “Not set” stays “not set”, not 0 or 16.
        #expect(store.value(WindowCornerKey.windows) == nil)
        #expect(store.value(WindowCornerKey.utilityPanels) == nil)
    }

    @Test func revertWritesBackTheExactPreviousValue() throws {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A value set before by hand (e.g. `defaults write -g NSConvolutionOverride1 -int 7`) and one AppKit ignores.
        try store.set(WindowCornerKey.windows, 7)
        try store.set(WindowCornerKey.utilityPanels, "0")
        let before = tool.state()
        #expect(before.windows == .radius(7))
        #expect(before.utilityPanels == .system)
        #expect(before.rawUtilityPanels == "string:0")
        let text = before.historyText
        let result = try tool.apply(windows: .radius(10), utilityPanels: .system)
        #expect(result.after.windows == .radius(10))
        // The history keeps the previous state; the revert uses it after a relaunch of MacReplica.
        let restored = try #require(CornerState(historyText: text))
        _ = try tool.restore(restored)
        #expect(store.value(WindowCornerKey.windows) as? Int == 7)
        #expect(store.value(WindowCornerKey.utilityPanels) as? String == "0")
    }

    @Test func storedValuesAreInterpretedLikeAppKit() {
        #expect(CornerSetting(stored: nil) == .system)
        #expect(CornerSetting(stored: 0) == .system)
        #expect(CornerSetting(stored: "x") == .system)
        #expect(CornerSetting(stored: "12") == .radius(12))
        #expect(CornerSetting(stored: 9.6) == .radius(10))
        #expect(CornerSetting(historyText: "system") == .system)
        #expect(CornerSetting(historyText: "0") == nil)
        #expect(CornerState(historyText: "garbage") == nil)
    }

    @Test func radiusOutsideTheRangeIsRefused() {
        let (tool, store, folder) = Self.tool()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: WindowCornersError.invalidRadius) { try tool.apply(windows: .radius(1), utilityPanels: .system) }
        #expect(throws: WindowCornersError.invalidRadius) { try tool.apply(windows: .radius(7), utilityPanels: .radius(99)) }
        #expect(store.value(WindowCornerKey.windows) == nil)
        #expect(tool.systemRadius == 16)
    }
}
