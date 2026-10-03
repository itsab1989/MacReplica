import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Backup verification", .serialized)
struct VerificationTests {
    @Test func intactBackupPasses() async throws {
        let sandbox = try Sandbox("verify-ok")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        let report = BackupVerifier(layout: .live()).verify(backupAt: backup)
        #expect(report.isIntact && report.isUsable)
        #expect(report.issues.isEmpty)
        #expect(report.damagedFiles.isEmpty)
    }

    @Test func detectsMissingWrongSizeAndChangedFiles() async throws {
        let sandbox = try Sandbox("verify-damage")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("fonts/user/ExampleSerif.ttf"))
        try Data("short".utf8).write(to: backup.appendingPathComponent("fonts/system/ExampleMono.ttc"))
        let profile = backup.appendingPathComponent("icc_profiles/user/Example Studio Display.icc")
        var bytes = try Data(contentsOf: profile)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: profile)
        let report = BackupVerifier(layout: .live()).verify(backupAt: backup)
        #expect(report.issues.contains(.fileMissing("fonts/user/ExampleSerif.ttf")))
        #expect(report.issues.contains(.sizeMismatch("fonts/system/ExampleMono.ttc")))
        #expect(report.issues.contains(.hashMismatch("icc_profiles/user/Example Studio Display.icc")))
        #expect(!report.isIntact)
        #expect(report.isUsable, "damaged files do not make the whole backup unusable")
        #expect(report.damagedFiles.count == 3)
    }

    @Test func changedManifestIsFatal() async throws {
        let sandbox = try Sandbox("verify-manifest")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        let url = backup.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Pixel Forge", with: "Pixel Fraud")
        try Data(text.utf8).write(to: url)
        let report = BackupVerifier(layout: .live()).verify(backupAt: backup)
        #expect(report.issues.contains(.checksumMismatch))
        #expect(!report.isUsable)
    }

    @Test func missingChecksumIsToleratedButReported() async throws {
        let sandbox = try Sandbox("verify-nochecksum")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("manifest.json.sha256"))
        let report = BackupVerifier(layout: .live()).verify(backupAt: backup)
        #expect(report.issues == [.checksumMissing])
        #expect(report.isIntact && report.isUsable)
    }

    @Test func unreadableAndFutureManifests() throws {
        let sandbox = try Sandbox("verify-bad")
        let verifier = BackupVerifier(layout: .live())
        #expect(verifier.verify(backupAt: sandbox.url).issues == [.manifestUnreadable("manifest.json not found")])
        try Data("{broken".utf8).write(to: sandbox.url.appendingPathComponent("manifest.json"))
        #expect(!verifier.verify(backupAt: sandbox.url).isUsable)
        try Data(#"{"manifest_version": 7}"#.utf8).write(to: sandbox.url.appendingPathComponent("manifest.json"))
        let report = verifier.verify(backupAt: sandbox.url)
        #expect(report.issues.contains(.unsupportedVersion(found: 7, supported: Manifest.currentVersion)))
        #expect(report.manifest == nil)
    }

    @Test func pathsEscapingTheBackupAreRefused() throws {
        let sandbox = try Sandbox("verify-escape")
        let evil = FileRecord(fileName: "x", domain: .user, relativePath: "../../.ssh/authorized_keys", originalPath: "~/x",
                              backupPath: "../outside", sha256: "00", size: 1)
        let manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64, fonts: [evil])
        try ManifestIO.write(manifest, to: sandbox.url)
        let report = BackupVerifier(layout: .live()).verify(backupAt: sandbox.url)
        #expect(report.issues == [.unsafePath("../outside")])
        #expect(report.damagedFiles == ["../outside"])
    }

    @Test func unreadableOrChangedFilesProduceAMarkedPartialBackup() async throws {
        let sandbox = try Sandbox("writer-partial")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        // A file that disappears between scan and copy, and one that changes.
        let vanished = result.fonts[0]
        let changed = result.fonts[1]
        try FileManager.default.removeItem(at: vanished.url)
        try Data("changed".utf8).write(to: changed.url)
        let parent = try sandbox.folder("out")
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: parent, log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        #expect(!outcome.isComplete)
        #expect(outcome.manifest.backupIssues == [BackupIssue(path: vanished.record.originalPath, reason: .unreadable),
                                                   BackupIssue(path: changed.record.originalPath, reason: .changedDuringBackup)])
        #expect(!outcome.manifest.fonts.contains { $0.backupPath == vanished.record.backupPath || $0.backupPath == changed.record.backupPath })
        // The rest is complete and verifies cleanly; the gaps are written into the manifest and the instructions.
        let report = BackupVerifier(layout: source.layout).verify(backupAt: outcome.url)
        #expect(report.isIntact)
        #expect(report.manifest?.backupIssues.count == 2)
        let guide = try String(contentsOf: outcome.url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("2 items could not be included"))
        #expect(outcome.totalSize > 0 && outcome.fileCount > 10)
    }

    @Test func backupWriterRefusesUnwritableDestinationAndUsesUniqueNames() async throws {
        let sandbox = try Sandbox("writer-names")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let writer = BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
        let log = LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory)
        #expect(throws: BackupError.self) { _ = try writer.write(result, into: URL(fileURLWithPath: "/System"), log: log) }
        let parent = try sandbox.folder("out")
        let first = try writer.write(result, into: parent, log: log).url
        let second = try writer.write(result, into: parent, log: log).url
        #expect(first != second)
        #expect(second.lastPathComponent == first.lastPathComponent + "-2")
        #expect(OwnershipMarker.read(from: first)?.kind == .backup)
        let logText = try String(contentsOf: first.appendingPathComponent("logs/inventory.log"), encoding: .utf8)
        #expect(logText.contains("Backup verified"))
        #expect(BackupWriter.folderName(for: Date(timeIntervalSince1970: 0)).hasPrefix("MacReplica-Backup-1970-01-01"))
    }
}

@Suite("Cleanup")
struct CleanupTests {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var cleaner: SafeCleaner { SafeCleaner(homeDirectory: home) }

    @Test func refusesProtectedLocations() {
        for path in ["/", "/Applications", "/Library", "/System", "/Users", home.path, home.appendingPathComponent("Desktop").path,
                     home.appendingPathComponent("Documents").path, home.appendingPathComponent("Library/Fonts").path,
                     FileManager.default.temporaryDirectory.path, "/opt/homebrew"] {
            #expect(throws: CleanupError.self, "\(path) must be protected") {
                try cleaner.validateOwnedFolder(URL(fileURLWithPath: path), kind: .temporary)
            }
        }
    }

    @Test func refusesFoldersWithoutMatchingMarker() throws {
        let sandbox = try Sandbox("cleanup-marker")
        let plain = try sandbox.folder("plain")
        #expect(throws: CleanupError.notOwnedByMacReplica(plain.standardizedFileURL.path)) { try cleaner.removeOwnedFolder(plain, kind: .temporary) }
        let backup = try sandbox.folder("backup")
        try OwnershipMarker(kind: .backup).write(into: backup)
        #expect(throws: CleanupError.notOwnedByMacReplica(backup.standardizedFileURL.path)) { try cleaner.removeOwnedFolder(backup, kind: .temporary) }
        try Data("{not json".utf8).write(to: plain.appendingPathComponent(OwnershipMarker.fileName))
        #expect(throws: CleanupError.self) { try cleaner.removeOwnedFolder(plain, kind: .temporary) }
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func refusesSymlinksFilesAndMissingPaths() throws {
        let sandbox = try Sandbox("cleanup-link")
        let target = try sandbox.folder("target")
        try OwnershipMarker(kind: .temporary).write(into: target)
        let link = sandbox.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: CleanupError.symbolicLink(link.standardizedFileURL.path)) { try cleaner.removeOwnedFolder(link, kind: .temporary) }
        let file = try sandbox.write("x", to: "file.txt")
        #expect(throws: CleanupError.notADirectory(file.standardizedFileURL.path)) { try cleaner.removeOwnedFolder(file, kind: .temporary) }
        let missing = sandbox.url.appendingPathComponent("missing")
        #expect(throws: CleanupError.notFound(missing.standardizedFileURL.path)) { try cleaner.removeOwnedFolder(missing, kind: .temporary) }
        #expect(throws: CleanupError.self) { try cleaner.removeOwnedFolder(URL(string: "https://example.com/x")!, kind: .temporary) }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func removesOwnedFoldersAndFilesInside() throws {
        let sandbox = try Sandbox("cleanup-ok")
        let owned = try sandbox.folder("owned")
        try OwnershipMarker(kind: .temporary).write(into: owned)
        let inner = try sandbox.write("x", to: "owned/sub/file.txt")
        try cleaner.removeFile(inner, inOwnedFolder: owned, kind: .temporary)
        #expect(!FileManager.default.fileExists(atPath: inner.path))
        let outside = try sandbox.write("y", to: "outside.txt")
        #expect(throws: CleanupError.outsideOwnedFolder(outside.standardizedFileURL.path)) {
            try cleaner.removeFile(outside, inOwnedFolder: owned, kind: .temporary)
        }
        #expect(throws: CleanupError.self) {
            try cleaner.removeFile(owned.appendingPathComponent(OwnershipMarker.fileName), inOwnedFolder: owned, kind: .temporary)
        }
        try cleaner.removeOwnedFolder(owned, kind: .temporary)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func pruningKeepsNewestAndIgnoresForeignFolders() throws {
        let sandbox = try Sandbox("cleanup-prune")
        for index in 0..<4 {
            let folder = try sandbox.folder("s\(index)")
            try OwnershipMarker(kind: .session, createdAt: Date(timeIntervalSince1970: Double(index))).write(into: folder)
        }
        let foreign = try sandbox.folder("user-data")
        let removed = cleaner.pruneOwnedFolders(in: sandbox.url, kind: .session, keep: 2)
        #expect(Set(removed.map(\.lastPathComponent)) == ["s0", "s1"])
        #expect(FileManager.default.fileExists(atPath: sandbox.url.appendingPathComponent("s3").path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func temporaryWorkspaceRemovesItselfAlsoOnError() throws {
        let sandbox = try Sandbox("cleanup-workspace")
        var path: String
        do {
            let workspace = try TemporaryWorkspace(parent: sandbox.url)
            path = workspace.url.path
            try Data("download".utf8).write(to: workspace.url.appendingPathComponent("Homebrew.pkg"))
            #expect(workspace.cleanup())
            #expect(workspace.cleanup(), "second cleanup is harmless")
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        func failingWork() throws -> String {
            let workspace = try TemporaryWorkspace(parent: sandbox.url)
            defer { workspace.cleanup() }
            path = workspace.url.path
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(throws: CocoaError.self) { _ = try failingWork() }
        #expect(!FileManager.default.fileExists(atPath: path))
        do { let workspace = try TemporaryWorkspace(parent: sandbox.url); path = workspace.url.path }
        #expect(!FileManager.default.fileExists(atPath: path), "deinit cleans up")
    }

    @Test func logPruningOnlyTouchesMacReplicaLogs() throws {
        let sandbox = try Sandbox("cleanup-logs")
        let folder = try sandbox.folder("logs")
        for index in 0..<5 {
            let file = try sandbox.write("x", to: "logs/restore-2026010\(index)-120000.log")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 1000)], ofItemAtPath: file.path)
        }
        let foreign = try sandbox.write("keep", to: "logs/notes.log")
        let foreign2 = try sandbox.write("keep", to: "logs/restore-final.txt")
        LogStore.pruneLogs(in: folder, keep: 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(remaining == ["notes.log", "restore-20260103-120000.log", "restore-20260104-120000.log", "restore-final.txt"])
        #expect(FileManager.default.fileExists(atPath: foreign.path) && FileManager.default.fileExists(atPath: foreign2.path))
    }

    @Test func sessionStoreRemovesOnlyOwnedSessions() throws {
        let sandbox = try Sandbox("cleanup-sessions")
        let store = SessionStore(folder: sandbox.url.appendingPathComponent("Sessions"), homeDirectory: home)
        let session = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: ["a"])
        try store.save(session)
        #expect(store.load(id: session.id) == session)
        try store.remove(id: session.id)
        #expect(store.load(id: session.id) == nil)
        var bad = session
        bad.id = "../../escape"
        #expect(throws: CleanupError.self) { try store.save(bad) }
        #expect(throws: CleanupError.self) { try store.remove(id: "missing") }
    }
}
