import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The tester clicked Start Restore several times because nothing showed that the check before the restore was
/// running, and the progress was quiet for minutes while apps downloaded (2026-11-03, TEST1111-004/005).
@Suite("Starting a restore and following it", .serialized)
struct RestoreStartAndProgressTests {
    @Test("One check and one restore at a time, however often Start is clicked")
    func startGate() {
        var gate = RestoreStartGate()
        var ok = gate.beginCheck()
        #expect(ok)
        ok = gate.beginCheck()
        #expect(!ok, "a second click during the check is ignored")
        ok = gate.beginRestore()
        #expect(ok)
        #expect(!gate.checking, "starting the restore ends the check")
        ok = gate.beginRestore()
        #expect(!ok, "never two restores at once")
        ok = gate.beginCheck()
        #expect(!ok, "no new check while the restore runs")
        gate.endRestore()
        ok = gate.beginCheck()
        #expect(ok)
        gate.endCheck()
        #expect(!gate.checking && !gate.restoring)
        ok = gate.beginRestore()
        #expect(ok, "resuming starts a restore without a check")
    }

    func context(_ name: String) async throws -> (Sandbox, URL, Manifest, SimulationRoot, SimulationEnvironment) {
        let sandbox = try Sandbox("start-progress-\(name)")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let bin = fresh.url.appendingPathComponent("opt/homebrew/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/brew"), to: bin.appendingPathComponent("brew"))
        return (sandbox, backup, manifest, fresh, target)
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    @Test("The check before the restore reports its progress, step by step up to the total")
    func dryRunReportsProgress() async throws {
        let (sandbox, backup, manifest, _, target) = try await context("dry-run")
        let selection = RestoreSelection(components: [.brewCasks, .applications, .fonts])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let seen = Box<(Int, Int)>()
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .dryRun(plan: plan, selection: selection) { checked, total in seen.add((checked, total)) }
        #expect(seen.all.map(\.0) == Array(1...plan.items.count))
        #expect(seen.all.allSatisfy { $0.1 == plan.items.count })
        #expect(entries.count == plan.items.count)
        withExtendedLifetime(sandbox) {}
    }

    @Test("The definitions of all casks are read in one Homebrew call, not one per cask")
    func dryRunReadsCasksTogether() async throws {
        let (sandbox, backup, manifest, fresh, target) = try await context("batch")
        try fresh.setFlag("brew/casks/pixel-forge", true, content: "2.4.1")
        try fresh.setFlag("brew/casks/nimbus-notes", true, content: "3.2.2")
        let selection = RestoreSelection(components: [.brewCasks, .applications])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let tokens = plan.items.filter { $0.kind == .cask }.map(\.identifier)
        #expect(tokens.count >= 2)
        _ = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .dryRun(plan: plan, selection: selection)
        let infoCalls = fresh.calls().filter { $0.hasPrefix("brew info --json=v2 --cask") }
        #expect(infoCalls == ["brew info --json=v2 --cask " + tokens.sorted().joined(separator: " ")], "\(infoCalls)")
        withExtendedLifetime(sandbox) {}
    }

    @Test("Several definitions are read by token and by full token")
    func parsesSeveralCasks() {
        let json = #"{"casks":[{"token":"a","full_token":"a","artifacts":[{"app":["A.app"]}]},{"token":"c","full_token":"u/t/c","artifacts":[{"pkg":["C.pkg"]}]}]}"#
        let all = HomebrewClient.parseAllCaskContents(Data(json.utf8))
        #expect(all["a"]?.appNames == ["A.app"])
        #expect(all["c"]?.packages == ["C.pkg"])
        #expect(all["u/t/c"]?.packages == ["C.pkg"])
        #expect(HomebrewClient.parseAllCaskContents(Data("[]".utf8)).isEmpty)
    }

    @Test("Homebrew's output reaches the progress screen, without the home folder")
    func outputIsForwardedRedacted() async throws {
        let (sandbox, backup, manifest, fresh, target) = try await context("output")
        var selection = RestoreSelection(components: [.brewCasks, .applications])
        selection.caskAppFolder = .currentUser
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let events = Box<RestoreEvent>()
        _ = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: backup.path, selection: selection, itemIDs: plan.items.map(\.id))) { events.add($0) }
        let lines = events.all.compactMap { event -> (String, String)? in
            if case .output(let id, let line) = event { return (id, line) }
            return nil
        }
        #expect(lines.contains { $0.0 == "cask:pixel-forge" && $0.1 == "==> Moving App 'Pixel Forge.app' to '~/Applications/Pixel Forge.app'" }, "\(lines)")
        #expect(lines.contains { $0.0 == "cask:pixel-forge" && $0.1 == "==> Installing Cask pixel-forge" })
        let home = target.layout.homeDirectory.path
        #expect(!lines.contains { $0.1.contains(home) || $0.1.contains(fresh.url.path) })
        #expect(!lines.contains { $0.1.trimmingCharacters(in: .whitespaces).isEmpty })
        withExtendedLifetime(sandbox) {}
    }
}
