import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Boundary cases found by mutation testing.
@Suite("Semantic versions and release parsing")
struct VersionEdgeTests {
    private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    @Test func numericPreReleaseIdentifiersSortBeforeAlphanumericOnes() {
        #expect(v("1.0.0-1") < v("1.0.0-alpha"))
        #expect(!(v("1.0.0-alpha") < v("1.0.0-1")))
        #expect(v("1.0.0-alpha.2") < v("1.0.0-alpha.10"), "numeric identifiers compare as numbers")
        #expect(v("1.0.0-alpha.beta") < v("1.0.0-beta"))
    }

    @Test func equalityIgnoresPrefixAndBuildMetadata() {
        #expect(v("1.2.3") == v("v1.2.3+build.7"))
        #expect(v("1.2.3-rc.1") == v("1.2.3-rc.1"))
        #expect(v("1.2.3") != v("1.2.4"))
        #expect(v("1.2.3-rc.1") != v("1.2.3"))
        #expect(!(v("1.2.3") < v("1.2.3")))
    }

    @Test func emptyComponentsAreRejected() {
        #expect(SemanticVersion("1.0..0") == nil)
        #expect(SemanticVersion("1..0.0") == nil)
        #expect(SemanticVersion("1.0.0-alpha..1") == nil)
        #expect(SemanticVersion("1.0.0-.alpha") == nil)
        #expect(SemanticVersion("1.0.0-alpha.1")?.prerelease == ["alpha", "1"])
    }

    @Test func releasesWithoutPreReleaseFlagAreStableUnlessTheVersionSaysOtherwise() throws {
        let json = """
        [{"tag_name": "v1.4.0", "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.4.0"},
         {"tag_name": "v1.5.0-beta.1", "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.5.0-beta.1"}]
        """
        let releases = try GitHubReleaseFetcher.parse(Data(json.utf8))
        #expect(releases.map(\.isPrerelease) == [false, true])
    }
}

@Suite("Backup verification details")
struct VerificationEdgeTests {
    @Test func everyFileIsCountedOnceAndExtraFilesAreChecked() async throws {
        let sandbox = try Sandbox("verify-count")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let layout = try TestEnvironment.sourceMac(Sandbox("verify-count-layout")).1.layout
        let sums = try String(contentsOf: backup.appendingPathComponent(BackupWriter.checksumsPath), encoding: .utf8)
        let records = Set(manifest.allFileRecords.map(\.backupPath))
        let extra = sums.split(whereSeparator: \.isNewline).map { String($0.split(separator: " ", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
            .filter { !records.contains($0) && $0 != ManifestIO.fileName && $0 != ManifestIO.checksumFileName }
        #expect(!extra.isEmpty, "instructions and reports are listed in SHA256SUMS")
        let report = BackupVerifier(layout: layout).verify(backupAt: backup)
        #expect(report.isIntact)
        #expect(report.checkedFiles == records.count + extra.count)
    }

    @Test func changesOutsideTheManifestAreDetected() async throws {
        let sandbox = try Sandbox("verify-extra")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        let layout = try TestEnvironment.sourceMac(Sandbox("verify-extra-layout")).1.layout
        try Data("changed".utf8).write(to: backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"))
        try FileManager.default.removeItem(at: backup.appendingPathComponent("reports/inventory.html"))
        let report = BackupVerifier(layout: layout).verify(backupAt: backup)
        #expect(report.issues.contains(.hashMismatch("restore/RESTORE_INSTRUCTIONS.html")))
        #expect(report.issues.contains(.fileMissing("reports/inventory.html")))
    }

    @Test func aWrongSizeIsReportedOnceNotAlsoAsWrongContent() async throws {
        let sandbox = try Sandbox("verify-size")
        let (backup, _) = try await TestEnvironment.makeBackup(sandbox)
        let layout = try TestEnvironment.sourceMac(Sandbox("verify-size-layout")).1.layout
        try Data("short".utf8).write(to: backup.appendingPathComponent("fonts/system/ExampleMono.ttc"))
        let issues = BackupVerifier(layout: layout).verify(backupAt: backup).issues
        #expect(issues.filter { $0 == .sizeMismatch("fonts/system/ExampleMono.ttc") || $0 == .hashMismatch("fonts/system/ExampleMono.ttc") }
                == [.sizeMismatch("fonts/system/ExampleMono.ttc")])
    }
}

@Suite("Safe clean-up details")
struct CleanupEdgeTests {
    private var cleaner: SafeCleaner { SafeCleaner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser) }

    @Test func linksToProtectedLocationsAreRefusedAsProtected() throws {
        let sandbox = try Sandbox("cleanup-link")
        let link = sandbox.url.appendingPathComponent("link-to-temp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(throws: CleanupError.protectedLocation(link.standardizedFileURL.path)) {
            try cleaner.validateOwnedFolder(link, kind: .temporary)
        }
    }

    @Test func topLevelPathsAreAlwaysProtected() {
        #expect(throws: CleanupError.protectedLocation("/macreplica-nonexistent")) {
            try cleaner.validateOwnedFolder(URL(fileURLWithPath: "/macreplica-nonexistent"), kind: .temporary)
        }
        #expect(throws: CleanupError.notFound("/macreplica-nonexistent/child")) {
            try cleaner.validateOwnedFolder(URL(fileURLWithPath: "/macreplica-nonexistent/child"), kind: .temporary)
        }
    }

    @Test func danglingLinksInsideAnOwnedFolderCanBeRemoved() throws {
        let sandbox = try Sandbox("cleanup-dangling")
        let link = sandbox.url.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: sandbox.url.appendingPathComponent("gone").path)
        try cleaner.removeFile(link, inOwnedFolder: sandbox.url, kind: .temporary)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(throws: CleanupError.notFound(sandbox.url.appendingPathComponent("missing").standardizedFileURL.path)) {
            try cleaner.removeFile(sandbox.url.appendingPathComponent("missing"), inOwnedFolder: sandbox.url, kind: .temporary)
        }
    }

    @Test func relativePathLengthLimit() {
        #expect(PathSafety.isSafeRelativePath(String(repeating: "a", count: 1024)))
        #expect(!PathSafety.isSafeRelativePath(String(repeating: "a", count: 1025)))
    }

    @Test func temporaryWorkspaceCreatesParentsAndReportsCleanupHonestly() throws {
        let sandbox = try Sandbox("cleanup-workspace")
        let workspace = try TemporaryWorkspace(parent: sandbox.url.appendingPathComponent("a/b"), cleaner: cleaner)
        #expect(FileManager.default.fileExists(atPath: workspace.url.path))
        // Removed by someone else: nothing left, so the clean-up counts as done.
        try FileManager.default.removeItem(at: workspace.url)
        #expect(workspace.cleanup())

        let foreign = try TemporaryWorkspace(parent: sandbox.url, cleaner: cleaner)
        try FileManager.default.removeItem(at: foreign.url.appendingPathComponent(OwnershipMarker.fileName))
        #expect(!foreign.cleanup(), "a folder without MacReplica's marker is not removed")
        #expect(FileManager.default.fileExists(atPath: foreign.url.path))
    }
}

@Suite("Sessions and administrator operations")
struct SessionAndPrivilegeEdgeTests {
    @Test func theMostRecentUnfinishedSessionIsOffered() throws {
        let sandbox = try Sandbox("sessions-order")
        let store = SessionStore(folder: sandbox.url.appendingPathComponent("Sessions"), homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        var older = RestoreSession(backupPath: "~/old", selection: RestoreSelection(), itemIDs: ["a"])
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = RestoreSession(backupPath: "~/new", selection: RestoreSelection(), itemIDs: ["a"])
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(older)
        try store.save(newer)
        #expect(store.unfinishedSession()?.backupPath == "~/new")
        #expect(store.allSessions().map(\.backupPath) == ["~/new", "~/old"])
    }

    @Test func cancellingThePasswordDialogIsReportedAsDenied() async throws {
        for message in ["execution error: User canceled. (-128)", "user canceled", "error -128"] {
            let runner = ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: message) }
            let executor = AppleScriptPrivilegedExecutor(runner: runner)
            await #expect(throws: PrivilegedError.denied) {
                try await executor.run([.createFolder(URL(fileURLWithPath: "/Library/Fonts/Sub"))], reason: "test")
            }
        }
        let failing = AppleScriptPrivilegedExecutor(runner: ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "disk full") })
        await #expect(throws: PrivilegedError.failed("disk full")) {
            try await failing.run([.createFolder(URL(fileURLWithPath: "/Library/Fonts/Sub"))], reason: "test")
        }
    }

    @Test func directExecutorCreatesNestedFolders() async throws {
        let sandbox = try Sandbox("direct-nested")
        let nested = sandbox.url.appendingPathComponent("a/b/c")
        try await DirectPrivilegedExecutor().run([.createFolder(nested)], reason: "test")
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }
}

@Suite("Credential provider details")
struct CredentialEdgeTests {
    @Test func passphraseMinimumIsInclusive() throws {
        let minimum = String(repeating: "p", count: CredentialVault.minimumPassphraseLength)
        let file = CredentialFile(name: "x", permissions: 0o600, contents: Data("synthetic".utf8))
        let sealed = try CredentialVault.seal([file], passphrase: minimum, iterations: 100_000)
        #expect(try CredentialVault.open(sealed, passphrase: minimum) == [file])
        #expect(throws: CredentialError.passphraseTooShort) {
            try CredentialVault.seal([file], passphrase: String(minimum.dropLast()), iterations: 100_000)
        }
    }

    @Test func exportedPermissionsNeverIncludeOthersAndNeverLockTheOwnerOut() throws {
        let sandbox = try Sandbox("credential-permissions")
        var layout = SystemLayout.live()
        layout.homeDirectory = sandbox.url
        let provider = FileCredentialProvider(id: "test", files: [".a", ".b", "../outside"], evidence: [])
        for (name, mode) in [(".a", 0o644), (".b", 0o400)] {
            let file = try sandbox.write("synthetic", to: name)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        _ = try sandbox.write("synthetic", to: "../outside-\(UUID().uuidString)")
        #expect(provider.detect(layout: layout) == [".a", ".b"], "unsafe paths are never read")
        let exported = Dictionary(uniqueKeysWithValues: try provider.export(layout: layout).map { ($0.name, $0.permissions) })
        #expect(exported == [".a": 0o600, ".b": 0o400])
        let portable = CredentialProviders.all.allSatisfy { $0.isPortable }
        #expect(portable)
    }
}

@Suite("Application data scanner details")
struct AppDataScannerEdgeTests {
    @Test func sizeLimitIsInclusiveAndSymbolicLinksAreSkipped() throws {
        let sandbox = try Sandbox("appdata-limit")
        var layout = SystemLayout.live()
        layout.homeDirectory = sandbox.url
        let folder = try sandbox.folder("Library/Application Support/Example")
        for name in ["a.txt", "b.txt", "c.txt"] { _ = try sandbox.write("0123456789", to: "Library/Application Support/Example/\(name)") }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: folder.appendingPathComponent("a.txt"))
        let scan = try AppDataScanner(layout: layout, maxFolderSize: 20).scan(folder)
        // Two 10-byte files fill the 20-byte limit exactly; the third does not fit; links are not followed.
        #expect(scan.files.count == 2)
        #expect(scan.files.map(\.record.relativePath) == scan.files.map(\.record.relativePath).sorted())
        #expect(Set(scan.files.map(\.record.relativePath)).isSubset(of: ["a.txt", "b.txt", "c.txt"]))
        #expect(scan.issues.map(\.reason) == [.tooLarge])
        let refused = scan.issues.first.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(refused.map { !scan.files.map(\.record.relativePath).contains($0) } == true)
    }
}

@Suite("Command runner details")
struct CommandRunnerEdgeTests {
    private func runner(_ allowed: Set<String>) -> ProcessCommandRunner {
        ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: allowed), baseEnvironment: ["PATH": "/usr/bin:/bin"])
    }

    @Test func outputStreamsAreKeptApartAndCombinedReadably() async throws {
        let result = try await runner(["/bin/sh"]).run(Command(executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; printf tail"]))
        #expect(result.stdout == "out\ntail")
        #expect(result.stderr == "err\n")
        #expect(result.combinedOutput == "out\ntail\nerr\n")
        #expect(CommandResult(exitCode: 0, stdout: "only", stderr: "").combinedOutput == "only")
        #expect(!CommandResult(exitCode: 0, stdout: "", stderr: "").timedOut)
    }

    @Test func lastLineWithoutNewlineIsDelivered() async throws {
        final class Lines: @unchecked Sendable { var values: [String] = []; let lock = NSLock() }
        let lines = Lines()
        _ = try await runner(["/usr/bin/printf"]).run(Command(executable: "/usr/bin/printf", arguments: ["a\\nb"])) { line in
            lines.lock.withLock { lines.values.append(line) }
        }
        #expect(lines.lock.withLock { lines.values } == ["a", "b"])
    }

    @Test func environmentEntriesAreValidated() {
        let policy = CommandPolicy(allowedExecutables: ["/bin/echo"])
        #expect(throws: CommandError.invalidArgument("A=B")) { try policy.validate(Command(executable: "/bin/echo", environment: ["A=B": "x"])) }
        #expect(throws: CommandError.invalidArgument("KEY")) { try policy.validate(Command(executable: "/bin/echo", environment: ["KEY": "a\0b"])) }
        #expect(throws: Never.self) { try policy.validate(Command(executable: "/bin/echo", environment: ["KEY": "value"])) }
    }

    @Test func zeroTimeoutMeansNoTimeout() async throws {
        let result = try await runner(["/bin/sleep"]).run(Command(executable: "/bin/sleep", arguments: ["0.2"], timeout: 0))
        #expect(result.succeeded)
        #expect(!result.timedOut)
    }
}

@Suite("Path resolution regressions")
struct PathResolutionTests {
    /// Folders chosen in the file panel can arrive as `/private/tmp/…` or `/private/var/…`.
    @Test func baseBehindThePrivateSymlinkResolvesNewFiles() throws {
        let sandbox = try Sandbox("private-base")
        let privateBase = URL(fileURLWithPath: "/private" + sandbox.url.standardizedFileURL.path)
        try #require(FileManager.default.fileExists(atPath: privateBase.path))
        let resolved = try #require(PathSafety.resolve("fonts/user/New.otf", inside: privateBase))
        #expect(resolved.lastPathComponent == "New.otf")
        #expect(PathSafety.resolve("../escape", inside: privateBase) == nil)
    }

    @Test func backupIntoAFolderBehindThePrivateSymlinkSucceeds() async throws {
        let sandbox = try Sandbox("private-backup")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let parent = URL(fileURLWithPath: "/private" + (try sandbox.folder("out")).standardizedFileURL.path)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: parent, log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
    }
}
