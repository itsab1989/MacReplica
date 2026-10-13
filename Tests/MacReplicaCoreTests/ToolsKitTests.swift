import Foundation
import Testing
@testable import MacReplicaCore

/// The shared parts of the Tools section: versions, which states allow a button, and the history.
@Suite("Tools: shared")
struct ToolsKitTests {
    @Test func versionsCompareNumerically() {
        let env = ToolEnvironment(macOSVersion: "26.10", architecture: .x86_64)
        #expect(env.majorVersion == 26)
        #expect(env.isAtLeast("26.4"))
        #expect(env.isAtLeast("26.10"))
        #expect(!env.isAtLeast("26.11"))
        #expect(!env.isAtLeast("27"))
        #expect(ToolEnvironment(macOSVersion: "garbage", architecture: .arm64).majorVersion == 0)
        #expect(ToolEnvironment.current.majorVersion >= 13)
    }

    @Test func onlyStatesMacReplicaCanActOnShowAButton() {
        let acting: Set<ToolCapability> = [.supported, .supportedWithRestrictions, .experimental, .requiresAdministrator]
        for capability in ToolCapability.allCases {
            #expect(capability.allowsChange == acting.contains(capability), "\(capability)")
        }
    }

    static func store() -> (ToolHistoryStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ToolHistoryStore(file: folder.appendingPathComponent("tools-history.json"), limit: 3), folder)
    }

    static func entry(_ tool: String, _ change: String, result: ToolHistoryEntry.Result = .succeeded, revert: Bool = true,
                      previous: String? = "p") -> ToolHistoryEntry {
        ToolHistoryEntry(tool: tool, change: change, previousState: previous, resultingState: "r", macOSVersion: "27.0.1",
                         result: result, verification: .verified, revertAvailable: revert)
    }

    @Test func historyIsKeptShortAndRoundTrips() throws {
        let (store, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(store.entries().isEmpty)
        for index in 1...4 { try store.append(Self.entry("updates", "updates.apply.\(index)")) }
        let entries = store.entries()
        #expect(entries.map(\.change) == ["updates.apply.2", "updates.apply.3", "updates.apply.4"])
        #expect(entries.last?.macOSVersion == "27.0.1")
        #expect(entries.last?.verification == .verified)
        // A broken file is an empty history, not a crash.
        try Data("{".utf8).write(to: store.file)
        #expect(store.entries().isEmpty)
    }

    @Test func revertTargetsTheLastUndoneChangeOfThatToolOnly() throws {
        let (store, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.append(Self.entry("windowCorners", "windowCorners.apply", previous: "first"))
        try store.append(Self.entry("updates", "updates.apply.recommended", previous: "u"))
        #expect(store.lastRevertibleChange(tool: "windowCorners")?.previousState == "first")
        // A failed attempt or one without a way back is skipped; a partial one counts.
        try store.append(Self.entry("windowCorners", "windowCorners.apply", result: .failed, previous: "failed"))
        #expect(store.lastRevertibleChange(tool: "windowCorners")?.previousState == "first")
        try store.append(Self.entry("windowCorners", "windowCorners.apply", result: .partial, previous: "partial"))
        #expect(store.lastRevertibleChange(tool: "windowCorners")?.previousState == "partial")
        // After a successful revert nothing is left to revert.
        try store.append(Self.entry("windowCorners", "windowCorners.revert", revert: false))
        #expect(store.lastRevertibleChange(tool: "windowCorners") == nil)
        #expect(store.lastRevertibleChange(tool: "gatekeeper") == nil)
    }

    @Test func historyLivesInApplicationSupport() {
        let layout = SystemLayout.live()
        #expect(ToolHistoryStore(layout: layout).file == layout.applicationSupport.appendingPathComponent("tools-history.json"))
        #expect(ToolHistoryStore(layout: layout).limit == 200)
    }
}
