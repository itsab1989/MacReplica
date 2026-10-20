import Foundation
import Testing
@testable import MacReplicaCore

/// 1.1.10: installers already on the Mac – using them, choosing one from elsewhere (copied into Applications), moving
/// one to the Trash – and locking an installer for root before `createinstallmedia` runs.
@Suite("Install media: installers on this Mac")
struct InstallerFilesTests {
    static func installer(_ sandbox: Sandbox, _ folder: String = "Applications", name: String = "Install macOS Sonoma",
                          identifier: String = "com.apple.InstallAssistant.macOSSonoma") throws -> URL {
        let app = try sandbox.folder("\(folder)/\(name).app")
        try sandbox.file("\(folder)/\(name).app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(identifier)</string>\
        <key>CFBundleDisplayName</key><string>\(name)</string></dict></plist>
        """)
        try sandbox.file("\(folder)/\(name).app/Contents/SharedSupport/SharedSupport.dmg", String(repeating: "x", count: 4096))
        return app
    }

    struct Setup {
        let sandbox: Sandbox
        let layout: SystemLayout
        let recorder: PrivilegedRecorder
        var files: InstallerFiles
    }

    static func setup(_ name: String, runner: CommandRunning? = nil) throws -> Setup {
        let sandbox = try Sandbox(name)
        let layout = toolchainLayout(sandbox)
        let recorder = PrivilegedRecorder(DirectPrivilegedExecutor(applicationFolders: layout.applicationFolders,
                                                                   trash: layout.homeDirectory.appendingPathComponent(".Trash")))
        let process = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        return Setup(sandbox: sandbox, layout: layout, recorder: recorder,
                     files: InstallerFiles(layout: layout, runner: runner ?? process, privileged: recorder))
    }

    @Test func onlyApplesInstallersCount() throws {
        let sandbox = try Sandbox("apple-installer")
        #expect(InstallerFiles.isAppleInstaller(try Self.installer(sandbox)))
        #expect(InstallerFiles.isAppleInstaller(try Self.installer(sandbox, name: "Install OS X Mountain Lion", identifier: "com.apple.InstallAssistant.MountainLion")))
        #expect(!InstallerFiles.isAppleInstaller(try Self.installer(sandbox, name: "Install Evil", identifier: "com.example.installer")))
        #expect(!InstallerFiles.isAppleInstaller(try sandbox.folder("Applications/Install Empty.app")))
    }

    @Test func lockedMeansRootsAloneAsSoftwareUpdateLeavesIt() throws {
        let sandbox = try Sandbox("locked")
        // Files the test creates belong to the user.
        #expect(!InstallerFiles.isLockedForRoot(try Self.installer(sandbox)))
        // A system app: root's, writable only by root.
        #expect(InstallerFiles.isLockedForRoot(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    @Test func anInstallerOnThisMacBecomesItsOwnEntry() {
        let report = InstallerAppReport(app: URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app"), displayName: "Install macOS Sonoma",
                                        macOSVersion: "14.8.9", build: "23J631", sizeBytes: 13_676_683_264)
        let release = InstallerFiles.release(from: report)
        #expect(release.name == "macOS Sonoma" && release.major == "14" && release.version == "14.8.9" && release.build == "23J631")
        #expect(release.source == .onThisMac(path: "/Applications/Install macOS Sonoma.app"))
        #expect(release.installerAppName == "Install macOS Sonoma.app")
        let arm = ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64)
        #expect(MacOSInstallerCatalog.suitability(of: release, on: arm) == .onThisMac)
        let catalina = InstallerFiles.release(from: InstallerAppReport(app: URL(fileURLWithPath: "/Applications/Install macOS Catalina.app"),
                                                                       displayName: "Install macOS Catalina", macOSVersion: "10.15.7"))
        #expect(catalina.major == "10.15")
        #expect(MacOSInstallerCatalog.suitability(of: catalina, on: arm) == .intelMacsOnly)
        #expect(InstallerFiles.release(from: InstallerAppReport(app: URL(fileURLWithPath: "/x/Install Y.app"), displayName: "Y")).major == "?")
    }

    @Test func anInstallerOfTheUserGoesToTheTrashWithoutPassword() async throws {
        let s = try Self.setup("trash-user")
        let app = try Self.installer(s.sandbox)
        try await s.files.moveToTrash(app)
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.fileExists(atPath: s.files.trash.appendingPathComponent("Install macOS Sonoma.app/Contents/Info.plist").path))
        #expect(s.recorder.calls.isEmpty)
        // A second one of the same name gets a free name in the Trash.
        let again = try Self.installer(s.sandbox)
        try await s.files.moveToTrash(again)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: s.files.trash.path).filter { $0.hasPrefix("Install macOS Sonoma") }
        #expect(trashed.count == 2)
    }

    @Test func softwareUpdatesInstallerGoesToTheTrashWithThePassword() async throws {
        var s = try Self.setup("trash-root")
        s.files.movableByUser = { _ in false }
        let app = try Self.installer(s.sandbox)
        try await s.files.moveToTrash(app)
        guard s.recorder.calls.count == 1, case .trashInstaller(let moved, let destination) = s.recorder.calls[0].first else { Issue.record("\(s.recorder.calls)"); return }
        #expect(moved.path == app.path)
        #expect(destination.path == s.files.trash.appendingPathComponent("Install macOS Sonoma.app").path)
        #expect(!FileManager.default.fileExists(atPath: app.path))

        // The password dialog cancelled: nothing moved, said so.
        struct Denying: PrivilegedExecuting { func run(_ operations: [PrivilegedOperation], reason: String) async throws { throw PrivilegedError.denied } }
        let kept = try Self.installer(s.sandbox)
        var denied = s.files
        denied.privileged = Denying()
        await #expect(throws: InstallerFilesError.passwordDenied) { try await denied.moveToTrash(kept) }
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func onlyApplesInstallersInApplicationsCanBeTrashed() async throws {
        let s = try Self.setup("trash-refused")
        let other = try Self.installer(s.sandbox, name: "Install Evil", identifier: "com.example.installer")
        await #expect(throws: InstallerFilesError.notAnInstaller) { try await s.files.moveToTrash(other) }
        let elsewhere = try Self.installer(s.sandbox, "Downloads")
        await #expect(throws: InstallerFilesError.notAnInstaller) { try await s.files.moveToTrash(elsewhere) }
        #expect(FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test func theAdministratorStepsForInstallersAreNarrow() throws {
        let app = URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app")
        let trash = URL(fileURLWithPath: "/Users/me/.Trash")
        #expect(PrivilegedOperation.lockInstallerOwner(app).argv == ["/usr/sbin/chown", "-R", "root:wheel", app.path])
        #expect(PrivilegedOperation.lockInstallerPermissions(app).argv == ["/bin/chmod", "-R", "go-w", app.path])
        let tool = app.appendingPathComponent("Contents/Resources/createinstallmedia")
        #expect(PrivilegedOperation.verifyInstallerTool(tool).argv == ["/usr/bin/codesign", "--verify", "--strict", "-R=" + InstallerInspector.appleRequirement, tool.path])
        let move = PrivilegedOperation.trashInstaller(app: app, destination: trash.appendingPathComponent("Install macOS Sonoma.app"))
        #expect(move.argv == ["/bin/mv", app.path, "/Users/me/.Trash/Install macOS Sonoma.app"])
        #expect(move.isAllowed(trash: trash))
        // Only `Install ….app` directly in Applications, only into the Trash, never a climb out of either.
        for bad in [PrivilegedOperation.trashInstaller(app: URL(fileURLWithPath: "/Applications/Safari.app"), destination: trash.appendingPathComponent("Install x.app")),
                    .trashInstaller(app: app, destination: URL(fileURLWithPath: "/Users/me/Desktop/Install macOS Sonoma.app")),
                    .trashInstaller(app: app, destination: trash.appendingPathComponent("evil")),
                    .trashInstaller(app: URL(fileURLWithPath: "/Applications/../Applications/Install macOS Sonoma.app"), destination: trash.appendingPathComponent("Install x.app")),
                    .lockInstallerOwner(URL(fileURLWithPath: "/Users/me/Downloads/Install macOS Sonoma.app")),
                    .lockInstallerPermissions(URL(fileURLWithPath: "/Applications")),
                    .verifyInstallerTool(URL(fileURLWithPath: "/usr/bin/true"))] {
            #expect(!bad.isAllowed(trash: trash), "\(bad)")
        }
        #expect(!PrivilegedOperation.isTrashedInstaller(URL(fileURLWithPath: "/Users/me/.Trash/../Install x.app"), trash: trash))
    }

    @Test func createinstallmediaRunsOnlyAfterTheInstallerIsLockedAndChecked() async throws {
        let f = try await InstallMediaSafetyTests.flow("lock-chain")
        // The user's own copy: locked first.
        _ = try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in })
        let tool = try #require(f.report.createInstallMedia)
        #expect(f.recorder.calls[0].prefix(3) == [.lockInstallerOwner(f.report.app), .lockInstallerPermissions(f.report.app), .verifyInstallerTool(tool)])
        // Already root's (as from Software Update): only checked again.
        let g = try await InstallMediaSafetyTests.flow("lock-chain-root")
        var creator = g.creator
        creator.isLockedForRoot = { _ in true }
        _ = try await creator.create(installer: g.report, on: g.drive, stage: { _ in })
        #expect(g.recorder.calls[0].first == .verifyInstallerTool(try #require(g.report.createInstallMedia)))
        #expect(!g.recorder.calls[0].contains { if case .lockInstallerOwner = $0 { return true }; return false })
        // The check as root fails: createinstallmedia does not run and the failure is reported.
        let h = try await InstallMediaSafetyTests.flow("lock-chain-tampered")
        h.setup.drives.codesignFails = true
        await #expect(throws: InstallMediaError.self) { try await h.creator.create(installer: h.report, on: h.drive, stage: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: h.setup.layout.volumesRoot.appendingPathComponent("Install macOS Sonoma").path))
    }

    @Test func aChosenInstallerIsCopiedIntoApplications() async throws {
        let s = try Self.setup("copy")
        let source = try Self.installer(s.sandbox, "Downloads")
        let copied = try await s.files.copyIntoApplications(source)
        #expect(copied.path == s.files.applications.appendingPathComponent("Install macOS Sonoma.app").path)
        #expect(InstallerFiles.isAppleInstaller(copied))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original stays")
        // Already there: not overwritten.
        await #expect(throws: InstallerFilesError.alreadyInApplications("Install macOS Sonoma.app")) { try await s.files.copyIntoApplications(source) }
        // Not Apple's: refused.
        let other = try Self.installer(s.sandbox, "Downloads", name: "Install Other", identifier: "com.example.x")
        await #expect(throws: InstallerFilesError.notAnInstaller) { try await s.files.copyIntoApplications(other) }
    }

    @Test func aCopyNeedsRoomAndMustArriveWhole() async throws {
        var s = try Self.setup("copy-space")
        let source = try Self.installer(s.sandbox, "Downloads")
        let needed = InstallerInspector.allocatedSize(of: source) + 1_073_741_824
        s.files.freeSpace = { _ in needed - 1 }
        // From another drive: the space is checked.
        s.files.sameVolume = { _, _ in false }
        await #expect(throws: InstallerFilesError.notEnoughSpace(needed: needed, available: needed - 1)) { try await s.files.copyIntoApplications(source) }
        #expect(!FileManager.default.fileExists(atPath: s.files.applications.appendingPathComponent("Install macOS Sonoma.app").path))
        s.files.freeSpace = { _ in needed }
        // ditto fails halfway: the partial copy is removed.
        let layout = s.layout
        s.files.runner = ScriptedRunner { _ in
            try? FileManager.default.createDirectory(at: layout.applicationFolders[0].appendingPathComponent("Install macOS Sonoma.app/Contents"),
                                                     withIntermediateDirectories: true)
            return CommandResult(exitCode: 1, stdout: "", stderr: "ditto: No space left on device")
        }
        await #expect(throws: InstallerFilesError.copyFailed("ditto: No space left on device")) { try await s.files.copyIntoApplications(source) }
        #expect(!FileManager.default.fileExists(atPath: s.files.applications.appendingPathComponent("Install macOS Sonoma.app").path))
    }

    @Test func whatTheUserCanMoveAndWhereCopiesGo() throws {
        let sandbox = try Sandbox("movable")
        let app = try Self.installer(sandbox)
        #expect(InstallerFiles.isMovableByUser(app))
        // The user's installer in a folder the user may not change: not movable without the password.
        let folder = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(!InstallerFiles.isMovableByUser(app))
        // Root's, in a folder the user may change (the user's own home): not movable either.
        #expect(!InstallerFiles.isMovableByUser(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        // Copies go into the first Applications folder.
        var layout = toolchainLayout(sandbox)
        layout.applicationFolders = [sandbox.url.appendingPathComponent("Applications"), sandbox.url.appendingPathComponent("home/Applications")]
        let files = InstallerFiles(layout: layout, runner: ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }, privileged: DirectPrivilegedExecutor())
        #expect(files.applications.path == sandbox.url.appendingPathComponent("Applications").path)
    }

    @Test func onTheSameDiskACopyNeedsNoSpace() async throws {
        var s = try Self.setup("copy-clone")
        let source = try Self.installer(s.sandbox, "Downloads")
        #expect(InstallerFiles.isSameVolume(source, s.files.applications))
        // Another volume (devfs).
        #expect(!InstallerFiles.isSameVolume(source, URL(fileURLWithPath: "/dev")))
        s.files.freeSpace = { _ in 0 }
        let copied = try await s.files.copyIntoApplications(source)
        #expect(InstallerFiles.isAppleInstaller(copied))
    }
}
