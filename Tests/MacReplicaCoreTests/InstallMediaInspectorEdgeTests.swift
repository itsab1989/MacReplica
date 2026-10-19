import Foundation
import Testing
@testable import MacReplicaCore

/// What the installer check and the final verification do when a tool cannot run or answers unexpectedly: never a
/// pass without evidence.
@Suite("Install media: checks without evidence")
struct InstallMediaInspectorEdgeTests {
    struct Broken: Error {}

    /// A runner whose codesign, bless and the tool itself cannot be started at all.
    final class Unstartable: CommandRunning, @unchecked Sendable {
        let layout: SystemLayout
        let fallback: ScriptedRunner
        init(layout: SystemLayout, fallback: ScriptedRunner) { self.layout = layout; self.fallback = fallback }
        func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            if command.executable == layout.codesign || command.executable == layout.bless { throw Broken() }
            return try await fallback.run(command, onOutputLine: onOutputLine)
        }
    }

    static func sonomaApp(_ sandbox: Sandbox, payloadBytes: Int = 50_000) throws -> URL {
        let app = try sandbox.folder("Applications/Install macOS Sonoma.app")
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleDisplayName</key><string>Install macOS Sonoma</string>\
        <key>CFBundleShortVersionString</key><string>19.8.62</string></dict></plist>
        """)
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/SharedSupport/SharedSupport.dmg", String(repeating: "x", count: payloadBytes))
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia", "#!/bin/sh\n", executable: true)
        return app
    }

    @Test func codesignThatCannotRunMeansNotSigned() async throws {
        let sandbox = try Sandbox("nocodesign")
        let layout = toolchainLayout(sandbox)
        let app = try Self.sonomaApp(sandbox)
        let runner = Unstartable(layout: layout, fallback: ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "") })
        let inspector = InstallerInspector(layout: layout, runner: runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        let report = await inspector.inspect(app)
        #expect(!report.signedByApple)
        #expect(report.signatureDetail == "codesign could not be run")
        // The size is what the files really take up (never negative, never zero for a real file).
        #expect(report.sizeBytes >= 50_000)
        #expect(report.requiredBytes == report.sizeBytes + 2 * 1_073_741_824)
    }

    @Test func theMacOSVersionComesFromTheInstallersOwnImage() async throws {
        let sandbox = try Sandbox("sharedsupport")
        let layout = toolchainLayout(sandbox)
        let app = try Self.sonomaApp(sandbox)
        let image = app.appendingPathComponent("Contents/SharedSupport/SharedSupport.dmg").path
        let mount = try sandbox.folder("mnt")
        // The layout of the real 14.8.9 image (one asset); a second asset is never read.
        try sandbox.file("mnt/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Assets</key><array>
        <dict><key>OSVersion</key><string>14.8.9</string><key>Build</key><string>23J631</string></dict>
        <dict><key>OSVersion</key><string>99.0</string><key>Build</key><string>X</string></dict>
        </array></dict></plist>
        """)
        final class State: @unchecked Sendable { var attached = false }
        let state = State()
        let runner = ScriptedRunner { command in
            if command.executable == layout.codesign { return CommandResult(exitCode: 0, stdout: "", stderr: "") }
            if command.executable == layout.hdiutil {
                switch command.arguments.first {
                case "attach":
                    state.attached = true
                    return CommandResult(exitCode: 0, stdout: """
                    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
                    <dict><key>dev-entry</key><string>/dev/disk9</string><key>mount-point</key><string>\(mount.path)</string></dict></array></dict></plist>
                    """, stderr: "")
                case "info":
                    let images = state.attached ? "<dict><key>image-path</key><string>\(image)</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk9</string></dict></array></dict>" : ""
                    return CommandResult(exitCode: 0, stdout: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>images</key><array>\(images)</array></dict></plist>", stderr: "")
                case "detach":
                    state.attached = false
                    return CommandResult(exitCode: 0, stdout: "", stderr: "")
                default: break
                }
            }
            return CommandResult(exitCode: 0, stdout: "--volume\n--nointeraction\n--downloadassets", stderr: "")
        }
        let inspector = InstallerInspector(layout: layout, runner: runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        let report = await inspector.inspect(app)
        #expect(report.macOSVersion == "14.8.9")
        #expect(report.build == "23J631")
        // Attached read-only and hidden, and detached again.
        let attach = try #require(runner.commands.first { $0.arguments.first == "attach" })
        #expect(attach.arguments.contains("-readonly") && attach.arguments.contains("-nobrowse"))
        #expect(runner.commands.contains { $0.arguments.first == "detach" })
        #expect(!state.attached)
    }

    @Test func verificationNeedsEvidenceForEveryCheck() async throws {
        let f = try await InstallMediaSafetyTests.flow("verify-evidence")
        _ = try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in })
        // codesign and bless cannot be started: the drive is not called verified.
        var creator = f.creator
        creator.runner = Unstartable(layout: f.setup.layout, fallback: f.setup.runner)
        let result = await creator.verify(drive: f.drive, installer: f.report)
        #expect(result.verification == .failed)
        #expect(result.checks.first { $0.item == .signature }?.passed == false)
        #expect(result.checks.first { $0.item == .signature }?.detail == "codesign could not be run")
        #expect(result.checks.first { $0.item == .blessed }?.passed == false)

        // An installer volume that is not mounted cannot be checked.
        let disk = try #require(f.setup.drives.disks["disk4"])
        f.setup.drives.disks["disk4"]?.partitions = disk.partitions.map { var p = $0; p.removeValue(forKey: "MountPoint"); return p }
        let unmounted = await f.creator.verify(drive: f.drive, installer: f.report)
        #expect(unmounted.verification == .failed)
        #expect(unmounted.checks.map(\.item) == [.volumeOnDrive])
    }
}
