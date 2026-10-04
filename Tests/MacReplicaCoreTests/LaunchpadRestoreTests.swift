import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The Launchpad layout from inventory to restore: recorded with the backup, arranged as the last step of the
/// restore, and arranged again once apps that were still being installed are there.
@Suite("Launchpad backup and restore", .serialized)
struct LaunchpadRestoreTests {
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
        environment.launchpadSettleTimeout = 20
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { try? SyntheticLaunchpad.addApp("com.example.studiomixer", to: database) }
        let result = await run(plan, environment, c, session: session)
        #expect(result.results[RestoreItem.launchpadID]?.outcome == .succeeded, "nothing of this restore is still waiting")
        #expect(Date().timeIntervalSince(started) < 15, "it stops waiting as soon as the Dock lists the app")
        #expect(try layout(db, c).pages.first == c.manifest.launchpadLayout?.pages.first, "the app the Dock listed late is in its folder")
    }
}
