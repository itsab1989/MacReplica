import Foundation
import Testing
@testable import MacReplicaCore

/// The one-click Plugin Playground setup for the corner plugin: the pinned download is verified by checksum, and only
/// the loader's own fixed items can be removed with administrator rights.
@Suite("Corner plugin: Plugin Playground installer")
struct PluginLoaderTests {
    /// Serves one file for the pinned loader URL (host + path under `downloads/`), like the real local transport.
    static func transportRoot(for data: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try #require(LocalFetcher.file(for: PluginLoader.release.url, root: root))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return root
    }

    @Test func downloadIsAcceptedOnlyWithTheExpectedChecksum() async throws {
        let good = Data("the real plugin playground package".utf8)
        let pinned = PluginLoader.Release(version: "t", url: PluginLoader.release.url, sha256: Hashing.sha256Hex(of: good), size: Int64(good.count))
        let root = try Self.transportRoot(for: good)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await PluginLoader.downloadVerifiedPackage(pinned, transport: LocalDownloadTransport(root: root), work: root.appendingPathComponent("work"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Hashing.sha256Hex(ofFile: file) == pinned.sha256)

        // A tampered payload (any other bytes) is rejected and nothing is left behind.
        let badRoot = try Self.transportRoot(for: Data("tampered".utf8))
        defer { try? FileManager.default.removeItem(at: badRoot) }
        await #expect(throws: PluginLoader.InstallError.self) {
            _ = try await PluginLoader.downloadVerifiedPackage(pinned, transport: LocalDownloadTransport(root: badRoot), work: badRoot.appendingPathComponent("work"))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: badRoot.appendingPathComponent("work").path))?.isEmpty ?? true)
    }

    @Test func downloadCreatesAWorkFolderWhoseParentDoesNotExistYet() async throws {
        let good = Data("playground".utf8)
        let pinned = PluginLoader.Release(version: "t", url: PluginLoader.release.url, sha256: Hashing.sha256Hex(of: good), size: Int64(good.count))
        let root = try Self.transportRoot(for: good)
        defer { try? FileManager.default.removeItem(at: root) }
        // A nested work path whose intermediate folders do not exist: the download must still create them.
        let work = root.appendingPathComponent("a/b/c/work")
        let file = try await PluginLoader.downloadVerifiedPackage(pinned, transport: LocalDownloadTransport(root: root), work: work)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func productionReleaseChecksumIsPinnedAndWellFormed() {
        #expect(PluginLoader.release.sha256.count == 64)
        #expect(PluginLoader.release.sha256.allSatisfy { $0.isHexDigit })
        #expect(PluginLoader.release.url.scheme == "https")
        #expect(PluginLoader.release.url.host == "github.com")
        #expect(PluginLoader.release.url.path.contains("CoreBedtime/playground"))
        #expect(PluginLoader.release.size > 0)
    }

    @Test func onlyTheLoadersOwnItemsCanBeRemovedAsRoot() throws {
        for ok in [PluginLoader.daemonPlist, PluginLoader.app, PluginLoader.installRoot, PluginLoader.logs] {
            #expect(PrivilegedOperation.isRemovableLoaderItem(ok))
        }
        for no in ["/System/Library/LaunchDaemons/com.apple.x.plist", "/opt/pluginplayground/tweaks", "/opt/pluginplayground/../etc", "/Applications/Safari.app"] {
            #expect(!PrivilegedOperation.isRemovableLoaderItem(URL(fileURLWithPath: no)))
        }
        #expect(throws: PrivilegedError.self) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.removeSystemItem(URL(fileURLWithPath: "/etc/hosts"))], reason: "x")
        }
    }

    @Test func undoArgvIsExactlyTheFixedRemovals() throws {
        let argv = try AppleScriptPrivilegedExecutor.arguments(for: PluginLoader.uninstallOperations(), reason: "Undo")
        let joined = argv.joined(separator: " ")
        #expect(joined.contains("/bin/rm -rf /Library/LaunchDaemons/com.pluginplayground.grant.plist"))
        #expect(joined.contains("/bin/rm -rf /Applications/Plugin Playground.app"))
        #expect(joined.contains("/bin/rm -rf /opt/pluginplayground"))
        #expect(joined.contains("/bin/rm -rf /var/log/pluginplayground"))
        // Playground persists no boot-args / library-validation change, so undo never touches nvram or defaults.
        for forbidden in ["nvram", "DisableLibraryValidation", "/bin/sh", "/bin/bash", "sudo", "osascript", "pkgutil", "launchctl"] {
            #expect(!joined.contains(forbidden))
        }
        // With a receipt, forgetting exactly the loader's package is the last step (it fails when there is none).
        let withReceipt = PluginLoader.uninstallOperations(receiptPresent: true)
        #expect(withReceipt.last == .forgetLoaderReceipt)
        #expect(withReceipt.dropLast() == PluginLoader.uninstallOperations()[...])
        #expect(PrivilegedOperation.forgetLoaderReceipt.argv == ["/usr/sbin/pkgutil", "--forget", "com.pluginplayground.core"])
        #expect(PrivilegedOperation.forgetLoaderReceipt.paths.isEmpty)
    }

    @Test func receiptIsReadWithPkgutil() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var layout = SystemLayout.live()
        for (exit, expected) in [(Int32(0), Bool?.some(true)), (1, false)] {
            layout.pkgutil = try CornerPluginSetupTests.standIn("pkgutil-\(exit)", exit: exit, in: folder).path
            let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [layout.pkgutil]), baseEnvironment: [:])
            #expect(await PluginLoader.receiptPresent(layout: layout, runner: runner) == expected)
        }
        let refusing = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        #expect(await PluginLoader.receiptPresent(layout: layout, runner: refusing) == nil)
    }

    @Test func uninstallIsTolerantOfMissingItemsInTheSimulation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The real absolute paths are allow-listed; running the uninstall when they are absent simply does nothing.
        // Never on a Mac that really has the loader: this would delete it (or fail half-way on permissions).
        let realItems = [PluginLoader.daemonPlist, PluginLoader.app, PluginLoader.installRoot, PluginLoader.logs]
        if !realItems.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try await DirectPrivilegedExecutor().run(PluginLoader.uninstallOperations(), reason: "test")
        }
        await #expect(throws: PrivilegedError.self) {
            try await DirectPrivilegedExecutor().run([.removeSystemItem(root)], reason: "test")
        }
    }
}
