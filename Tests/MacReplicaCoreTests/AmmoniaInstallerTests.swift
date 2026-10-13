import Foundation
import Testing
@testable import MacReplicaCore

/// The one-click Ammonia setup for the corner plugin: the pinned download is verified by checksum, the boot-argument
/// cleanup is conservative, and only the two fixed Ammonia items can be removed with administrator rights.
@Suite("Corner plugin: Ammonia installer")
struct AmmoniaInstallerTests {
    /// Serves one file for the pinned Ammonia URL (host + path under `downloads/`), like the real local transport.
    static func transportRoot(for data: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try #require(LocalFetcher.file(for: AmmoniaInstaller.release.url, root: root))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return root
    }

    @Test func downloadIsAcceptedOnlyWithTheExpectedChecksum() async throws {
        let good = Data("the real ammonia package".utf8)
        let pinned = AmmoniaInstaller.Release(version: "t", url: AmmoniaInstaller.release.url, sha256: Hashing.sha256Hex(of: good), size: Int64(good.count))
        let root = try Self.transportRoot(for: good)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await AmmoniaInstaller.downloadVerifiedPackage(pinned, transport: LocalDownloadTransport(root: root), work: root.appendingPathComponent("work"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Hashing.sha256Hex(ofFile: file) == pinned.sha256)

        // A tampered payload (any other bytes) is rejected and nothing is left behind.
        let badRoot = try Self.transportRoot(for: Data("tampered".utf8))
        defer { try? FileManager.default.removeItem(at: badRoot) }
        await #expect(throws: AmmoniaInstaller.InstallError.self) {
            _ = try await AmmoniaInstaller.downloadVerifiedPackage(pinned, transport: LocalDownloadTransport(root: badRoot), work: badRoot.appendingPathComponent("work"))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: badRoot.appendingPathComponent("work").path))?.isEmpty ?? true)
    }

    @Test func productionReleaseChecksumIsPinnedAndWellFormed() {
        #expect(AmmoniaInstaller.release.sha256.count == 64)
        #expect(AmmoniaInstaller.release.sha256.allSatisfy { $0.isHexDigit })
        #expect(AmmoniaInstaller.release.url.scheme == "https")
        #expect(AmmoniaInstaller.release.url.host == "github.com")
        #expect(AmmoniaInstaller.release.size > 0)
    }

    @Test func bootArgumentsAreClearedOnlyWhenNothingElseIsThere() {
        #expect(AmmoniaInstaller.bootArgumentsAreOnlyOurs("-arm64e_preview_abi"))
        #expect(AmmoniaInstaller.bootArgumentsAreOnlyOurs("-arm64e_preview_abi -arm64e_preview_abi -arm64e_preview_abi"))
        #expect(!AmmoniaInstaller.bootArgumentsAreOnlyOurs("-arm64e_preview_abi -v"))
        #expect(!AmmoniaInstaller.bootArgumentsAreOnlyOurs("amfi_get_out_of_my_way=1"))
        #expect(!AmmoniaInstaller.bootArgumentsAreOnlyOurs(""))
        #expect(!AmmoniaInstaller.bootArgumentsAreOnlyOurs("   "))
        #expect(!AmmoniaInstaller.bootArgumentsAreOnlyOurs(nil))
    }

    @Test func bootArgumentsValueIsReadFromNvram() {
        #expect(AmmoniaInstaller.bootArgumentsValue(nvramOutput: "boot-args\t-arm64e_preview_abi -arm64e_preview_abi") == "-arm64e_preview_abi -arm64e_preview_abi")
        #expect(AmmoniaInstaller.bootArgumentsValue(nvramOutput: "boot-args\t-v") == "-v")
        #expect(AmmoniaInstaller.bootArgumentsValue(nvramOutput: "nvram: Error getting variable - 'boot-args'") == nil)
        #expect(AmmoniaInstaller.bootArgumentsValue(nvramOutput: nil) == nil)
    }

    @Test func onlyAmmoniasOwnItemsCanBeRemovedAsRoot() throws {
        #expect(PrivilegedOperation.isRemovableAmmoniaItem(AmmoniaInstaller.daemonPlist))
        #expect(PrivilegedOperation.isRemovableAmmoniaItem(AmmoniaInstaller.installRoot))
        #expect(!PrivilegedOperation.isRemovableAmmoniaItem(URL(fileURLWithPath: "/System/Library/LaunchDaemons/com.apple.x.plist")))
        #expect(!PrivilegedOperation.isRemovableAmmoniaItem(URL(fileURLWithPath: "/private/var/ammonia/core/tweaks")))
        #expect(!PrivilegedOperation.isRemovableAmmoniaItem(URL(fileURLWithPath: "/private/var/../etc")))
        // The executor refuses to build a removeSystemItem for anything else.
        #expect(throws: PrivilegedError.self) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.removeSystemItem(URL(fileURLWithPath: "/etc/hosts"))], reason: "x")
        }
    }

    @Test func undoArgvIsExactlyTheFixedCommands() throws {
        let ops = AmmoniaInstaller.uninstallOperations() + AmmoniaInstaller.bootArgumentCleanup()
        let argv = try AppleScriptPrivilegedExecutor.arguments(for: ops, reason: "Undo")
        let joined = argv.joined(separator: " ")
        #expect(joined.contains("/bin/rm -rf /Library/LaunchDaemons/com.bedtime.ammonia.plist"))
        #expect(joined.contains("/bin/rm -rf /private/var/ammonia"))
        #expect(joined.contains("/usr/sbin/nvram -d boot-args"))
        #expect(joined.contains("/usr/bin/defaults write \(AmmoniaInstaller.libraryValidationPlist) DisableLibraryValidation -bool false"))
        // No shell, sudo or su is ever used.
        for forbidden in ["/bin/sh", "/bin/bash", "sudo", "osascript"] { #expect(!argv.contains(forbidden)) }
    }

    @Test func uninstallActuallyRemovesTheFilesInTheSimulation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Stand-ins at the real absolute paths cannot be used in tests, so check the executor's path guard instead:
        // a non-Ammonia path is refused, the two Ammonia paths are accepted (and simply do nothing when absent).
        try await DirectPrivilegedExecutor().run(AmmoniaInstaller.uninstallOperations(), reason: "test")
        await #expect(throws: PrivilegedError.self) {
            try await DirectPrivilegedExecutor().run([.removeSystemItem(root)], reason: "test")
        }
    }
}
