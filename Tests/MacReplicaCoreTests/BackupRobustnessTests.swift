import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Reproduces the beta tester's failed backup (MacReplica 1.0.4, 2026-10-13): Word was open, so its lock file
/// `~$Normal.dotm` sat next to the Normal template; the verifier refused the name and the whole backup was removed.
/// A file the backup cannot hold must be left out with a reason – never cost the whole backup.
@Suite("Backup robustness")
struct BackupRobustnessTests {
    static func write(_ text: String, _ relative: String, in root: SimulationRoot) throws {
        let url = root.url.appendingPathComponent("home").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func officeLockFilesNeverStopTheBackup() async throws {
        let sandbox = try Sandbox("robust-office-lock")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addWorkflowAppData()
        let templates = "Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized"
        try Self.write("owner", "\(templates)/~$Normal.dotm", in: root)
        let result = try await TestEnvironment.inventory(source).run()
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let office = try #require(outcome.manifest.applicationData.first { $0.profile?.provider == "microsoft-office" && $0.profile?.category == "officeTemplates" })
        #expect(Set(office.files.map(\.relativePath)) == ["Normal.dotm", "Letter.dotx"], "Word's lock file is a temporary file, never copied")
        #expect(!outcome.manifest.backupIssues.contains { $0.path.contains("~$") }, "and not reported as a problem either")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
    }

    @Test func aNameTheBackupCannotHoldIsLeftOutWithAReason() async throws {
        let sandbox = try Sandbox("robust-names")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try Self.write("kept", "Documents/Notes/Plan.txt", in: root)
        try Self.write("tilde", "Documents/Notes/~draft.txt", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Documents/Notes"))
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let folder = try #require(outcome.manifest.applicationData.first { $0.id == scan.folder.id })
        #expect(folder.files.map(\.relativePath) == ["Plan.txt"])
        let issue = try #require(outcome.manifest.backupIssues.first { $0.path.hasSuffix("~draft.txt") })
        #expect(issue.detail == .unsupportedName && issue.reason == .unreadable, "readable by MacReplica 1.0.4 too")
        #expect(!outcome.isComplete, "a file that was selected but is missing makes the backup partial")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact, "the rest of the backup is kept and verified")
    }

    @Test func filesRemovedAfterTheScanAreReportedAsGone() async throws {
        let sandbox = try Sandbox("robust-removed")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try Self.write("one", "Projects/Calibration/notes.txt", in: root)
        try Self.write("two", "Projects/Calibration/settings.ini", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let folder = source.layout.homeDirectory.appendingPathComponent("Projects/Calibration")
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(folder)
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        // The user deletes the folder between the scan and saving the backup.
        try FileManager.default.removeItem(at: folder)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let gone = outcome.manifest.backupIssues.filter { $0.path.hasPrefix("~/Projects/Calibration/") }
        #expect(gone.count == 2 && gone.allSatisfy { $0.detail == .missing }, "“no longer there”, not “unreadable”")
        #expect(TestEnvironment.english.backupIssueText(gone[0]) != TestEnvironment.english.backupIssueText(BackupIssue(path: "x", reason: .unreadable)))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
    }
}
