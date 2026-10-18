import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The Launchpad layout from inventory to restore: recorded with the backup, arranged as the last step of the
/// restore, and arranged again once apps that were still being installed are there.
@Suite("Launchpad backup and restore", .serialized)
struct LaunchpadRestoreTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let page = ["com.example.nimbusnotes", "com.example.pixelforge"]
    static let folder = ["com.example.quillwriter", "com.example.ledgerlite", "com.example.studiomixer"]

    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
    }

    func backup(_ name: String, exclude: Set<String> = []) async throws -> Context {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .sourceMac)
        try SyntheticLaunchpad.create(at: source.state.appendingPathComponent("launchpad/db/db"), apps: Self.page, folder: Self.folder)
        let environment = try source.environment
        var inventory = try await TestEnvironment.inventory(environment).run()
        inventory.excludeApplications(Set(inventory.manifest.applications.filter { exclude.contains($0.bundleIdentifier ?? "") }.map(\.id)))
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        return Context(sandbox: sandbox, backup: outcome.url, manifest: try ManifestIO.read(from: outcome.url))
    }

    /// A new Mac whose Dock lists `apps` in its default arrangement.
    func target(_ c: Context, apps: [String], macOS: String = "14.8.9") throws -> (SimulationRoot, RestoreEnvironment, URL) {
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        let db = try SyntheticLaunchpad.create(at: fresh.state.appendingPathComponent("launchpad/db/db"), apps: apps)
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.macOSVersion = macOS
        environment.launchpadSettleTimeout = 0
        return (fresh, environment, db)
    }

    func run(_ plan: RestorePlan, _ environment: RestoreEnvironment, _ c: Context, session: RestoreSession? = nil) async -> RestoreSession {
        let selection = RestoreSelection(components: [.launchpad])
        return await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: session ?? RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    func layout(_ db: URL, _ c: Context) throws -> LaunchpadLayout {
        try LaunchpadStore(database: db).read(macOSVersion: "14.8.9", work: c.sandbox.url.appendingPathComponent("work"))
    }

    @Test func theLayoutIsRecordedAndArrangedAsTheLastStep() async throws {
        let c = try await backup("launchpad-e2e")
        let recorded = try #require(c.manifest.launchpadLayout, "recorded with the backup")
        #expect(recorded.pages == [[.app(Self.page[0]), .app(Self.page[1]), .folder(name: "Other", pages: [Self.folder])]])
        #expect(recorded.macOSVersion == "15.1.0")
        let report = ReportBuilder(localizer: TestEnvironment.english).inventoryReport(c.manifest)
        #expect(report.contains("Launchpad layout") && report.contains("Quill Writer, Ledger Lite, Studio Mixer"), "the report keeps it as a reference")

        let (fresh, environment, db) = try target(c, apps: Self.folder + Self.page + ["com.apple.Safari"])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.applications, .launchpad]))
        #expect(plan.items.last?.id == RestoreItem.launchpadID, "after every app")
        let launchpadOnly = RestorePlan(items: plan.items.filter { $0.kind == .launchpadLayout }, manualApps: [])
        let session = await run(launchpadOnly, environment, c)
        #expect(session.results[RestoreItem.launchpadID]?.outcome == .succeeded)
        #expect(try layout(db, c).pages == recorded.pages + [[.app("com.apple.Safari")]], "apps that were not in the layout follow")
        let signals = (try? String(contentsOf: fresh.state.appendingPathComponent("dock-signals"), encoding: .utf8)) ?? ""
        #expect(signals == "\(SIGSTOP)\n\(SIGKILL)\n", "the Dock is paused while writing, then reloads without saving")

        // Already arranged: nothing is changed again.
        let again = await run(launchpadOnly, environment, c)
        #expect(again.results[RestoreItem.launchpadID]?.outcome == .succeeded)
        let dry = await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .dryRun(plan: launchpadOnly, selection: RestoreSelection(components: [.launchpad]))
        #expect(dry.first?.prediction == .alreadyPresent(version: nil))
    }

    @Test func appsLeftOutOfTheBackupLeaveTheLayout() async throws {
        let c = try await backup("launchpad-exclude", exclude: ["com.example.ledgerlite", "com.example.nimbusnotes"])
        #expect(c.manifest.launchpadLayout?.pages == [[.app("com.example.pixelforge"),
                                                      .folder(name: "Other", pages: [["com.example.quillwriter", "com.example.studiomixer"]])]])
        #expect(LaunchpadLayout(pages: [[.folder(name: "Solo", pages: [["a"]])]], macOSVersion: "14").removing(["a"]).pages.isEmpty,
                "a folder (and page) that becomes empty is left out")
    }

    /// The tester's macOS 14 Mac: Launchpad exists, but its database was not found when the step ran. That is not
    /// “Launchpad does not exist on this macOS”: the step waits, says what to do, and arranges Launchpad on Continue.
    @Test func aMissingDatabaseOnAMacOSWithLaunchpadWaitsAndIsArrangedOnContinue() async throws {
        let c = try await backup("launchpad-no-db")
        let (_, environment, db) = try target(c, apps: Self.folder + Self.page)
        let kept = db.deletingLastPathComponent().appendingPathComponent("db.aside")
        try FileManager.default.moveItem(at: db, to: kept)
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        let dry = await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .dryRun(plan: plan, selection: RestoreSelection(components: [.launchpad]))
        #expect(dry.first?.prediction == .willSkip(.launchpadDatabaseMissing))
        let first = await run(plan, environment, c)
        let outcome = first.results[RestoreItem.launchpadID]?.outcome
        #expect(outcome == .skipped(.launchpadDatabaseMissing))
        #expect(outcome?.isOpen == true, "waits for Continue instead of being closed")
        #expect(first.status == .inProgress)
        #expect(!FileManager.default.fileExists(atPath: db.path), "nothing is created in the Dock's place")
        let text = TestEnvironment.english.outcomeText(outcome ?? .succeeded)
        #expect(!text.contains("does not exist"))

        try FileManager.default.moveItem(at: kept, to: db)
        let resumed = await run(plan, environment, c, session: first)
        #expect(resumed.results[RestoreItem.launchpadID]?.outcome == .succeeded)
        #expect(try layout(db, c).pages == c.manifest.launchpadLayout?.pages)
    }

    /// A session saved by 1.1.2 holds “Launchpad does not exist on this macOS” for macOS 14. Continuing it checks again.
    @Test func aStaleNotAvailableResultIsReopenedOnlyWhereLaunchpadExists() async throws {
        var stale = RestoreSession(backupPath: "", selection: RestoreSelection(components: [.launchpad]), itemIDs: [RestoreItem.launchpadID, "x"])
        stale.results[RestoreItem.launchpadID] = ItemResult(itemID: RestoreItem.launchpadID, outcome: .skipped(.launchpadNotAvailable))
        stale.results["x"] = ItemResult(itemID: "x", outcome: .succeeded)
        stale.status = .completed
        let reopened = stale.reopeningStaleLaunchpadResult(macOSVersion: "14.8.9")
        #expect(reopened.results[RestoreItem.launchpadID] == nil && reopened.status == .inProgress)
        #expect(reopened.results["x"]?.outcome == .succeeded)
        #expect(stale.reopeningStaleLaunchpadResult(macOSVersion: "26.1") == stale, "true on macOS 26: unchanged")
        var arranged = stale
        arranged.results[RestoreItem.launchpadID] = ItemResult(itemID: RestoreItem.launchpadID, outcome: .succeeded)
        #expect(arranged.reopeningStaleLaunchpadResult(macOSVersion: "14.8.9") == arranged)

        let c = try await backup("launchpad-stale")
        let (_, environment, db) = try target(c, apps: Self.folder + Self.page)
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        var saved = RestoreSession(backupPath: "", selection: RestoreSelection(components: [.launchpad]), itemIDs: plan.items.map(\.id))
        saved.results[RestoreItem.launchpadID] = ItemResult(itemID: RestoreItem.launchpadID, outcome: .skipped(.launchpadNotAvailable))
        let continued = await run(plan, environment, c, session: saved)
        #expect(continued.results[RestoreItem.launchpadID]?.outcome == .succeeded)
        #expect(try layout(db, c).pages == c.manifest.launchpadLayout?.pages)
    }

    @Test func theLogSaysWhatStatReportsAlongTheDatabasePathWithoutAnyPath() throws {
        let sandbox = try Sandbox("launchpad-report")
        let user = try sandbox.folder("0")
        let store = LaunchpadStore(database: user.appendingPathComponent("com.apple.dock.launchpad/db/db"))
        let missing = String(cString: strerror(ENOENT))
        #expect(store.locationReport() == "user folder: ok; com.apple.dock.launchpad: \(missing); db folder: \(missing) [-]; database file: \(missing)")
        #expect(!store.accessDenied)
        let db = user.appendingPathComponent("com.apple.dock.launchpad/db")
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        try Data().write(to: db.appendingPathComponent("db-wal"))
        #expect(store.locationReport() == "user folder: ok; com.apple.dock.launchpad: ok; db folder: ok [db-wal]; database file: \(missing)")
        try Data().write(to: db.appendingPathComponent("db"))
        #expect(store.locationReport().hasSuffix("[db, db-wal]; database file: ok"))
        #expect(!store.locationReport().contains(sandbox.url.path))

        // A folder the process may not search: the file is there, but stat is refused (EACCES) – reported as access denied.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: db.path) }
        #expect(store.accessDenied)
        #expect(store.locationReport().hasSuffix("database file: \(String(cString: strerror(EACCES)))"))
    }

    @Test func refusedAccessIsReportedAsSuchAndWaits() async throws {
        let c = try await backup("launchpad-denied")
        let (_, environment, db) = try target(c, apps: Self.folder + Self.page)
        let folder = db.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        let session = await run(plan, environment, c)
        let outcome = session.results[RestoreItem.launchpadID]?.outcome
        #expect(outcome == .skipped(.launchpadAccessDenied))
        #expect(outcome?.isOpen == true)
    }

    /// `lsof -Fn` of the Dock on macOS 14.8.9 (GitHub runner, 2026-10-18): the database is found, not its -wal/-shm.
    @Test func theDatabaseTheDockHasOpenIsFoundInLsofOutput() {
        let output = """
        p681
        n/private/var/folders/s6/abc/0/com.apple.dock.launchpad/db/db-shm
        n/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
        n/private/var/folders/s6/abc/0/com.apple.dock.launchpad/db/db
        n/private/var/folders/s6/abc/0/com.apple.dock.launchpad/db/db-wal
        """
        #expect(LaunchpadStore.openDatabase(inLsofOutput: output)?.path == "/private/var/folders/s6/abc/0/com.apple.dock.launchpad/db/db")
        #expect(LaunchpadStore.openDatabase(inLsofOutput: "p681\nn/private/var/folders/x/0/com.apple.dock.launchpad/db/db-wal\n") == nil)
        #expect(LaunchpadStore.openDatabase(inLsofOutput: "") == nil)
        // Found wherever the Dock keeps it (seen on macOS 14.8.9 with the folder moved while the Dock had it open).
        #expect(LaunchpadStore.openDatabase(inLsofOutput: "n/private/var/folders/s6/abc/0/com.apple.dock.launchpad.elsewhere/db/db-shm\n"
                                            + "n/private/var/folders/s6/abc/0/com.apple.dock.launchpad.elsewhere/db/db\n")?.lastPathComponent == "db")
        #expect(LaunchpadStore.openDatabase(inLsofOutput: "n/Users/x/Library/Caches/other/db/db\n") == nil, "not a Launchpad folder")
        let store = LaunchpadStore(database: URL(fileURLWithPath: "/private/var/folders/b/0/com.apple.dock.launchpad/db/db"),
                                   computedDatabase: URL(fileURLWithPath: "/var/folders/a/0/com.apple.dock.launchpad/db/db"))
        #expect(store.sourceReport.contains("/private/var/folders/b/0/") && store.sourceReport.contains("/var/folders/a/0/"))
        #expect(LaunchpadStore(database: store.database).sourceReport == "database in the user's folder")
    }

    /// `ps -A -o pid=,uid=,comm=`: only Docks, with their user ID (seen on macOS 14.8.9: "1755/uid 501").
    @Test func runningDocksAreListedWithTheirUser() {
        let output = """
          1 0 /sbin/launchd
        1755 501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
        1900 501 /Applications/Dockside.app/Contents/MacOS/Docksidekick
        2001 502 Dock
        """
        #expect(LaunchpadStore.dockProcesses(inPsOutput: output) == ["1755/uid 501", "2001/uid 502"])
        #expect(LaunchpadStore.dockProcesses(inPsOutput: "") == [])
        // In tests MacReplica runs as the user at the screen.
        #expect(LaunchpadStore.runsAsLoggedInUser)
        let report = LaunchpadStore.userReport()
        #expect(report.contains("MacReplica uid \(getuid())") && !report.contains(NSUserName()) && !report.contains(NSHomeDirectory()))
    }

    @Test func switchedOffOrWithoutLaunchpadNothingIsChanged() async throws {
        let c = try await backup("launchpad-off")
        #expect(!RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.applications]))
            .items.contains { $0.kind == .launchpadLayout }, "the component can be switched off")
        var selection = RestoreSelection(components: [.launchpad])
        selection.excludedItemIDs = [RestoreItem.launchpadID]
        #expect(RestorePlanner().plan(manifest: c.manifest, selection: selection).items.isEmpty)

        let (_, environment, db) = try target(c, apps: Self.page, macOS: "26.1")
        let before = try layout(db, c)
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        let session = await run(plan, environment, c)
        #expect(session.results[RestoreItem.launchpadID]?.outcome == .skipped(.launchpadNotAvailable))
        #expect(session.results[RestoreItem.launchpadID]?.outcome.isOpen == false)
        #expect(try layout(db, c) == before)
    }

    @Test func appsStillBeingInstalledGetTheirPlaceWhenTheRestoreContinues() async throws {
        let c = try await backup("launchpad-waiting")
        let (fresh, environment, db) = try target(c, apps: Self.page + ["com.example.quillwriter", "com.example.ledgerlite"])
        var plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        let mixer = RestoreItem(id: "manual:studiomixer", kind: .manualApp, title: "Studio Mixer", identifier: "/Applications/Studio Mixer.app",
                                bundleIdentifier: "com.example.studiomixer", appBundleNames: ["Studio Mixer.app"], component: .applications)
        plan.items.insert(mixer, at: 0)
        let first = await run(plan, environment, c)
        #expect(first.results[mixer.id]?.outcome.isOpen == true)
        #expect(first.results[RestoreItem.launchpadID]?.outcome == .skipped(.launchpadWaitingForApps(count: 1)))
        #expect(first.results[RestoreItem.launchpadID]?.outcome.isOpen == true, "offered again when the restore continues")
        #expect(try layout(db, c).pages.first == [.app(Self.page[0]), .app(Self.page[1]),
                                                  .folder(name: "Other", pages: [["com.example.quillwriter", "com.example.ledgerlite"]])],
                "arranged right away with the apps that are there")

        // The user installs the app; the Dock lists it on its last page.
        try SimulationBuilder.makeSyntheticApp(name: "Studio Mixer", bundleID: "com.example.studiomixer", version: "11.4",
                                               in: fresh.url.appendingPathComponent("Applications"))
        try SyntheticLaunchpad.addApp("com.example.studiomixer", to: db)
        let resumed = await run(plan, environment, c, session: first)
        #expect(resumed.results[RestoreItem.launchpadID]?.outcome == .succeeded)
        #expect(try layout(db, c).pages == c.manifest.launchpadLayout?.pages)
    }

    /// The Dock lists a newly installed app after a moment: the step waits for apps this restore installed
    /// (up to the settle time) before arranging, so they get their recorded place.
    @Test func waitsForTheDockToListAppsThisRestoreInstalled() async throws {
        let c = try await backup("launchpad-settle")
        var (_, environment, db) = try target(c, apps: Self.page + ["com.example.quillwriter", "com.example.ledgerlite"])
        environment.launchpadSettleTimeout = 40
        var plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.launchpad]))
        let mixer = RestoreItem(id: "cask:studio-mixer", kind: .cask, title: "Studio Mixer", identifier: "studio-mixer",
                                bundleIdentifier: "com.example.studiomixer", appBundleNames: ["Studio Mixer.app"], component: .brewCasks)
        // Application data of an app is not an installation: it never makes Launchpad wait.
        var data = RestoreItem(id: "appdata:x", kind: .applicationData, title: "Data", identifier: "~/x", bundleIdentifier: "com.example.pixelforge")
        data.component = .applicationData
        plan.items.insert(contentsOf: [mixer, data], at: 0)
        var session = RestoreSession(backupPath: "", selection: RestoreSelection(components: [.launchpad]), itemIDs: plan.items.map(\.id))
        session.results[mixer.id] = ItemResult(itemID: mixer.id, outcome: .succeeded)
        session.results[data.id] = ItemResult(itemID: data.id, outcome: .skipped(.applicationNotInstalled(name: "Data")))
        let started = Date()
        let database = db
        let added = Flag()
        // Its own thread, so a busy test run cannot delay the simulated Dock.
        Thread {
            Thread.sleep(forTimeInterval: 1.5)
            for _ in 0..<20 where !added.value {
                if (try? SyntheticLaunchpad.addApp("com.example.studiomixer", to: database)) != nil { added.value = true } else { Thread.sleep(forTimeInterval: 0.2) }
            }
        }.start()
        let result = await run(plan, environment, c, session: session)
        #expect(added.value, "the simulated Dock listed the app")
        #expect(result.results[RestoreItem.launchpadID]?.outcome == .succeeded, "nothing of this restore is still waiting")
        #expect(Date().timeIntervalSince(started) < 30, "it stops waiting as soon as the Dock lists the app")
        #expect(try layout(db, c).pages.first == c.manifest.launchpadLayout?.pages.first, "the app the Dock listed late is in its folder")
    }
}
