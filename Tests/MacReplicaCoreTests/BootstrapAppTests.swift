import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// MacReplica puts a copy of itself into every backup, so the restore can start on a freshly installed Mac without a
/// download. Only an intact copy is added; the user's data never depends on it.
@Suite("MacReplica in the backup")
struct BootstrapAppTests {
    static func signedApp(in sandbox: Sandbox, version: String = "1.0.5") throws -> URL {
        let folder = try sandbox.folder("self")
        try SimulationBuilder.makeSyntheticApp(name: "MacReplica", bundleID: "io.github.itsab1989.MacReplica", version: version, in: folder)
        let app = folder.appendingPathComponent("MacReplica.app")
        try OwnInstallerTests.run("/usr/bin/codesign", ["-s", "-", "--force", app.path])
        return app
    }

    @Test func aVerifiedCopyOfMacReplicaGoesIntoTheBackup() async throws {
        let sandbox = try Sandbox("bootstrap-copy")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let app = try Self.signedApp(in: sandbox)
        let inventory = try await TestEnvironment.inventory(source).run()
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory), selfCopy: app)
        let manifest = try ManifestIO.read(from: outcome.url)
        let record = try #require(manifest.bootstrapApp)
        #expect(record.path == "MacReplica.app" && record.version == "1.0.5" && record.isUniversal && record.teamIdentifier == nil)
        #expect(record.runs(on: .x86_64) && record.runs(on: .arm64))
        let copy = outcome.url.appendingPathComponent("MacReplica.app")
        #expect(BundleInspection.hasValidSignature(copy, teamIdentifier: nil), "the copy keeps its signature")
        let sums = try String(contentsOf: outcome.url.appendingPathComponent("checksums/SHA256SUMS"), encoding: .utf8)
        #expect(sums.contains("  MacReplica.app/Contents/Info.plist"), "every file of the copy is checksummed")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
        let readme = try String(contentsOf: outcome.url.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.hasPrefix("MacReplica 1.0.5 is in this backup (runs on Apple silicon and Intel)."))
        #expect(readme.contains("Open Anyway") && readme.contains("https://github.com/itsab1989/MacReplica/releases"))
        let guide = try String(contentsOf: outcome.url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("Drag MacReplica.app from the backup folder into Applications"))
    }

    @Test func aDamagedOrMissingAppNeverStopsTheBackup() async throws {
        let sandbox = try Sandbox("bootstrap-damaged")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let app = try Self.signedApp(in: sandbox)
        // Changed after signing: the signature no longer matches, so no copy is made.
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources-extra.txt"))
        try Data("x".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let inventory = try await TestEnvironment.inventory(source).run()
        let writer = BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
        let log = LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory)
        let damaged = try writer.write(inventory, into: try sandbox.folder("backups"), log: log, selfCopy: app)
        #expect(damaged.manifest.bootstrapApp == nil && !FileManager.default.fileExists(atPath: damaged.url.appendingPathComponent("MacReplica.app").path))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: damaged.url).isIntact)
        // Not running from an app bundle (command-line tools, tests): nothing is copied.
        let none = try writer.write(inventory, into: try sandbox.folder("backups2"), log: log, selfCopy: sandbox.url)
        #expect(none.manifest.bootstrapApp == nil)
        #expect(BootstrapAppRecord(path: "MacReplica.app", version: "1", build: nil, architectures: [.arm64], teamIdentifier: nil).runs(on: .x86_64) == false)
    }
}
