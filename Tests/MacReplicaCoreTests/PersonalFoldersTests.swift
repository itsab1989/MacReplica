import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// "Your own folders": folders of the user's own files, each on its own, without a size limit, restored as
/// their own group. Never the home folder as a whole or ~/Library; a backup that does not fit is refused.
@Suite("Your own folders", .serialized)
struct PersonalFoldersTests {
    func write(_ text: String, _ path: String, in root: SimulationRoot) throws {
        let url = root.url.appendingPathComponent("home/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func onlyFoldersOutsideLibraryAndWithoutALimit() throws {
        let sandbox = try Sandbox("personal-validate")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try write(String(repeating: "x", count: 4000), "Documents/Projects/Report.pages", in: root)
        try write("photo", "Pictures/Brand/Logo.png", in: root)
        try write("secret", "Documents/Projects/id_ed25519", in: root)
        var scanner = AppDataScanner(layout: source.layout, maxFolderSize: 100)
        let home = source.layout.homeDirectory
        // Application data keeps its limit; own folders have none.
        #expect(try scanner.scan(home.appendingPathComponent("Documents/Projects")).issues.contains { $0.reason == .tooLarge })
        let scan = try scanner.scanPersonal(home.appendingPathComponent("Documents/Projects"))
        #expect(scan.folder.isPersonal && scan.folder.id.hasPrefix("personal-"))
        #expect(scan.files.map(\.record.relativePath) == ["Report.pages"], "no limit; secrets are still left out")
        #expect(scan.issues.map(\.reason) == [.refusedSensitive])
        #expect(try scanner.scanPersonal(home.appendingPathComponent("Documents")).files.count == 1)
        scanner.maxFolderSize = 100
        #expect(throws: AppDataError.wholeHomeOrLibrary) { try scanner.scanPersonal(home) }
        #expect(throws: AppDataError.insideLibrary) { try scanner.scanPersonal(home.appendingPathComponent("Library")) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/X"), withIntermediateDirectories: true)
        #expect(throws: AppDataError.insideLibrary) { try scanner.scanPersonal(home.appendingPathComponent("Library/Application Support/X")) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        #expect(throws: AppDataError.sensitiveLocation(".ssh")) { try scanner.scanPersonal(home.appendingPathComponent(".ssh")) }
        #expect(throws: AppDataError.outsideHome) { try scanner.scanPersonal(sandbox.url) }
    }

    @Test func ownFoldersAreBackedUpAndRestoredAsTheirOwnGroup() async throws {
        let sandbox = try Sandbox("personal-roundtrip")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try write("chapter one", "Documents/Novel/Chapter 1.txt", in: root)
        try write("chapter two", "Documents/Novel/Drafts/Chapter 2.txt", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Documents/Novel"))
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let manifest = try ManifestIO.read(from: outcome.url)
        #expect(manifest.applicationData.first { $0.id == scan.folder.id }?.isPersonal == true, "kept in the manifest")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)

        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.personalFolders]))
        let item = try #require(plan.items.first { $0.id == "appdata:\(scan.folder.id)" })
        #expect(item.component == .personalFolders)
        #expect(!RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData]))
            .items.contains { $0.id == item.id }, "not part of application data")
        #expect(RestoreComponent.defaultSelection.contains(.personalFolders), "backed up, so preselected for the restore")

        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: RestoreSelection(components: [.personalFolders]), itemIDs: plan.items.map(\.id)),
                 onEvent: { _ in })
        #expect(session.results[item.id]?.outcome == .succeeded)
        let restored = fresh.url.appendingPathComponent("home/Documents/Novel/Drafts/Chapter 2.txt")
        #expect((try? String(contentsOf: restored, encoding: .utf8)) == "chapter two")
    }

    @Test func aBackupThatDoesNotFitIsRefusedBeforeAnythingIsWritten() async throws {
        let sandbox = try Sandbox("personal-space")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try write("big", "Movies/Film.mov", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        var scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Movies"))
        scan.files[0].record.size = 1 << 60 // stands for a folder far larger than any drive
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        let parent = try sandbox.folder("backups")
        #expect(throws: (any Error).self) {
            try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
                .write(inventory, into: parent, log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        }
        do {
            _ = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
                .write(inventory, into: parent, log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        } catch BackupError.notEnoughSpace(let needed, let available) {
            #expect(needed > available && available > 0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty, "no partial backup is left behind")
        #expect(BackupWriter.estimatedSize(of: inventory) >= 1 << 60)
    }
}
