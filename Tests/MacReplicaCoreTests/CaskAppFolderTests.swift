import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The tester's wish (2026-11-03, TEST1111-002): Homebrew apps in the user's own `~/Applications` instead of the shared
/// Applications folder. Homebrew supports this per install (`--appdir`, checked with Homebrew 7.0.12: the folder is
/// created when missing, and Homebrew remembers it for uninstalling).
@Suite("Where Homebrew installs the apps of casks", .serialized)
struct CaskAppFolderTests {
    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
        let fresh: SimulationRoot
        let target: SimulationEnvironment
    }

    func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox("cask-folder-\(name)")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let bin = fresh.url.appendingPathComponent("opt/homebrew/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/brew"), to: bin.appendingPathComponent("brew"))
        return Context(sandbox: sandbox, backup: backup, manifest: manifest, fresh: fresh, target: target)
    }

    func restore(_ c: Context, folder: CaskAppFolder) async -> RestoreSession {
        var selection = RestoreSelection(components: [.brewCasks, .applications, .brewFormulae])
        selection.caskAppFolder = folder
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        return await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    var userApps: (Context) -> URL { { $0.target.layout.homeDirectory.appendingPathComponent("Applications") } }

    @Test("'Only me': casks are installed into ~/Applications and verified there; formulae are not affected")
    func currentUserFolder() async throws {
        let c = try await context("user")
        let session = await restore(c, folder: .currentUser)
        let folder = userApps(c).path
        #expect(session.results["cask:pixel-forge"]?.outcome == .succeeded, "\(session.results["cask:pixel-forge"]?.outcome.label ?? "-")")
        #expect(c.fresh.calls().contains("brew install --cask pixel-forge --appdir=\(folder)"))
        #expect(FileManager.default.fileExists(atPath: userApps(c).appendingPathComponent("Pixel Forge.app/Contents/Info.plist").path))
        #expect(!FileManager.default.fileExists(atPath: c.target.layout.applicationFolders[0].appendingPathComponent("Pixel Forge.app").path))
        #expect(!c.fresh.calls().contains { $0.hasPrefix("brew install --formula") && $0.contains("--appdir") })
        #expect(c.fresh.calls().contains { $0.hasPrefix("brew install --formula") }, "the backup has formulae")
    }

    @Test("Default: Homebrew's own Applications folder, no --appdir")
    func defaultFolder() async throws {
        let c = try await context("default")
        let session = await restore(c, folder: .allUsers)
        #expect(session.results["cask:pixel-forge"]?.outcome == .succeeded)
        #expect(c.fresh.calls().contains("brew install --cask pixel-forge"))
        #expect(!c.fresh.calls().contains { $0.contains("--appdir") })
    }

    @Test("A cask reinstalled because its app was missing goes to the chosen folder too")
    func reinstallUsesChosenFolder() async throws {
        let c = try await context("reinstall")
        try c.fresh.setFlag("brew/casks/pixel-forge", true, content: "2.4.1")
        let session = await restore(c, folder: .currentUser)
        #expect(session.results["cask:pixel-forge"]?.outcome == .succeeded)
        #expect(c.fresh.calls().contains("brew reinstall --cask pixel-forge --appdir=\(userApps(c).path)"))
        #expect(FileManager.default.fileExists(atPath: userApps(c).appendingPathComponent("Pixel Forge.app").path))
    }

    @Test("An app already in the shared folder is not installed a second time into ~/Applications")
    func noSecondCopy() async throws {
        let c = try await context("existing")
        let shared = c.target.layout.applicationFolders[0].appendingPathComponent("Pixel Forge.app")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.pixelforge", "CFBundleShortVersionString": "2.4.1"],
                                           format: .xml, options: 0).write(to: shared.appendingPathComponent("Contents/Info.plist"))
        let session = await restore(c, folder: .currentUser)
        #expect(session.results["cask:pixel-forge"]?.outcome == .alreadyPresent)
        #expect(!FileManager.default.fileExists(atPath: userApps(c).appendingPathComponent("Pixel Forge.app").path))
    }

    @Test("The choice is saved with the session; older sessions and unknown values mean the shared folder")
    func codable() throws {
        var selection = RestoreSelection()
        selection.caskAppFolder = .currentUser
        let decoded = try JSONDecoder().decode(RestoreSelection.self, from: JSONEncoder().encode(selection))
        #expect(decoded.caskAppFolder == .currentUser)
        #expect(try JSONDecoder().decode(RestoreSelection.self, from: Data("{}".utf8)).caskAppFolder == .allUsers)
        #expect(try JSONDecoder().decode(RestoreSelection.self, from: Data(#"{"caskAppFolder":"elsewhere"}"#.utf8)).caskAppFolder == .allUsers)
    }

    @Test("Only absolute, plain paths are passed as --appdir")
    func appFolderValidation() throws {
        try HomebrewClient.validateAppFolder("/Users/someone/Applications")
        for bad in ["Applications", "-x", "/Users/a/../b", "/Users/a\nb", ""] {
            #expect(throws: HomebrewError.self) { try HomebrewClient.validateAppFolder(bad) }
        }
    }
}
