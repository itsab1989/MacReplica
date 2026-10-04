import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Launchpad layout")
struct LaunchpadTests {
    @Test func readsPagesFoldersAndTheirApps() throws {
        let sandbox = try Sandbox("launchpad-read")
        let db = try SyntheticLaunchpad.create(at: sandbox.url.appendingPathComponent("db/db"),
                                               apps: ["com.apple.Safari", "com.apple.mail"], folder: ["com.apple.Calculator", "com.apple.Chess"])
        let layout = try LaunchpadStore(database: db).read(macOSVersion: "14.8.9", work: sandbox.url.appendingPathComponent("work"))
        #expect(layout.pages == [[.app("com.apple.Safari"), .app("com.apple.mail"),
                                  .folder(name: "Other", pages: [["com.apple.Calculator", "com.apple.Chess"]])]])
        #expect(layout.folderNames == ["Other"] && layout.appCount == 4)
        #expect(!FileManager.default.fileExists(atPath: sandbox.url.appendingPathComponent("work/launchpad.db").path), "the copy is removed")
    }

    /// A fresh macOS (default arrangement, no own folders): the recorded layout is rebuilt from the Dock's own app entries.
    @Test func rebuildsTheRecordedLayoutOnAFreshArrangement() throws {
        let sandbox = try Sandbox("launchpad-apply")
        let installed = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.Calculator", "com.apple.Chess", "com.example.NewApp"]
        let db = try SyntheticLaunchpad.create(at: sandbox.url.appendingPathComponent("db/db"), apps: installed)
        let before = SyntheticLaunchpad.appRows(db)
        let recorded = LaunchpadLayout(pages: [
            [.folder(name: "Work", pages: [["com.apple.mail", "com.apple.Notes"]]), .app("com.apple.Safari"), .app("com.example.NotInstalled")],
            [.folder(name: "Spiele & Tools", pages: [["com.apple.Chess"], ["com.apple.Calculator"]])],
        ], macOSVersion: "14.8.9")
        let placed = try LaunchpadStore(database: db).apply(recorded)
        #expect(placed == 5, "every recorded app that is installed here")
        #expect(SyntheticLaunchpad.appRows(db) == before, "the Dock's app entries are moved, never deleted")
        #expect(SyntheticLaunchpad.containersWithoutGroupRow(db) == 0, "like the Dock, every page and folder has its groups row")
        let after = try LaunchpadStore(database: db).read(macOSVersion: "14.8.9", work: sandbox.url.appendingPathComponent("work"))
        #expect(recorded.matches(after, installed: Set(installed)))
        #expect(after.pages.count == 3, "the two recorded pages, then the apps that were not in the layout")
        #expect(after.pages.last == [.app("com.example.NewApp")])
        #expect(after.folderNames == ["Work", "Spiele & Tools"], "folder names, including characters that need quoting")
        // Applying again gives the same arrangement (idempotent).
        try LaunchpadStore(database: db).apply(recorded)
        #expect(try LaunchpadStore(database: db).read(macOSVersion: "14.8.9", work: sandbox.url.appendingPathComponent("work")) == after)
    }

    /// Copies with the same bundle identifier (two Xcode versions) have an entry each; a Mac with fewer copies
    /// than recorded gets the ones it has, in the recorded places.
    @Test func severalCopiesOfAnAppKeepTheirPlaces() throws {
        let sandbox = try Sandbox("launchpad-copies")
        let db = try SyntheticLaunchpad.create(at: sandbox.url.appendingPathComponent("db/db"),
                                               apps: ["com.apple.dt.Xcode", "com.apple.Safari", "com.apple.dt.Xcode"])
        let recorded = LaunchpadLayout(pages: [
            [.folder(name: "Dev", pages: [["com.apple.dt.Xcode"]]), .app("com.apple.Safari")],
            [.app("com.apple.dt.Xcode"), .app("com.apple.dt.Xcode")],
        ], macOSVersion: "14.8.9")
        #expect(try LaunchpadStore(database: db).apply(recorded) == 3)
        let after = try LaunchpadStore(database: db).read(macOSVersion: "15.7", work: sandbox.url.appendingPathComponent("work"))
        #expect(after.pages == [[.folder(name: "Dev", pages: [["com.apple.dt.Xcode"]]), .app("com.apple.Safari")], [.app("com.apple.dt.Xcode")]])
        #expect(recorded.matches(after, installed: after.appEntryCounts), "the third recorded copy is not on this Mac")
        #expect(!recorded.matches(after, installed: ["com.apple.dt.Xcode": 3, "com.apple.Safari": 1]))
    }

    @Test func launchpadExistsOnlyUpToMacOS15() {
        #expect(LaunchpadLayout.isSupported(macOSVersion: "13.7"))
        #expect(LaunchpadLayout.isSupported(macOSVersion: "14.8.9"))
        #expect(LaunchpadLayout.isSupported(macOSVersion: "15.7"))
        #expect(!LaunchpadLayout.isSupported(macOSVersion: "26.0"))
        #expect(!LaunchpadLayout.isSupported(macOSVersion: "27.0.1"))
        #expect(throws: LaunchpadError.databaseMissing) { try LaunchpadStore(database: URL(fileURLWithPath: "/nonexistent/db")).apply(LaunchpadLayout(pages: [], macOSVersion: "14")) }
    }

    /// Apps that were not in the layout fill further pages of 35, in their previous order.
    @Test func appsNotInTheLayoutFillFurtherPages() throws {
        let sandbox = try Sandbox("launchpad-overflow")
        let extra = (1...40).map { "com.example.app\(String(format: "%02d", $0))" }
        let db = try SyntheticLaunchpad.create(at: sandbox.url.appendingPathComponent("db/db"), apps: ["com.apple.Safari"] + extra,
                                               folder: ["com.apple.Notes"])
        let recorded = LaunchpadLayout(pages: [[.folder(name: "Mine", pages: [["com.apple.Safari"], [], ["com.apple.Notes"]])]], macOSVersion: "14")
        #expect(try LaunchpadStore(database: db).apply(recorded) == 2)
        let after = try LaunchpadStore(database: db).read(macOSVersion: "14", work: sandbox.url.appendingPathComponent("work"))
        #expect(after.pages.map(\.count) == [1, 35, 5])
        #expect(after.pages[0] == [.folder(name: "Mine", pages: [["com.apple.Safari"], ["com.apple.Notes"]])], "empty folder pages are dropped")
        #expect(after.pages[1].first == .app(extra[0]) && after.pages[2].last == .app(extra[39]), "previous order kept")
        #expect(after.appEntryCounts["com.apple.Notes"] == 1 && after.appEntryCounts[extra[0]] == 1 && after.appEntryCounts.count == 42)
        #expect(after.appCount == 42)
        #expect(recorded.matches(after, installed: after.appEntryCounts))
        #expect(!LaunchpadLayout(pages: [[.folder(name: "Other name", pages: [["com.apple.Safari", "com.apple.Notes"]])]], macOSVersion: "14")
            .matches(after, installed: after.appEntryCounts), "a different folder name is a difference")
    }
}
