import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The whole installer flow on a simulated Mac with the real process runner and the real administrator-step
/// checks: catalog, download, inspection, drives, erase, `createinstallmedia` and verification. The stand-ins work
/// on folders inside the simulated Mac; no real disk is involved.
@Suite("Install media: simulated Mac end to end")
struct InstallMediaIntegrationTests {
    struct Mac {
        let sandbox: Sandbox
        let root: SimulationRoot
        let simulation: SimulationEnvironment
        var layout: SystemLayout { simulation.layout }
        var creator: InstallMediaCreator {
            let runner = simulation.makeRunner()
            let inspector = InstallerInspector(layout: layout, runner: runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64),
                                               hasRosetta: false)
            return InstallMediaCreator(layout: layout, runner: runner, privileged: simulation.makePrivilegedExecutor(),
                                       scanner: InstallMediaDriveScanner(layout: layout, runner: runner), inspector: inspector)
        }
    }

    static func mac(_ name: String) throws -> Mac {
        let sandbox = try Sandbox(name)
        let (root, _) = try TestEnvironment.freshMac(sandbox)
        try root.addInstallMedia()
        return Mac(sandbox: sandbox, root: root, simulation: try root.environment)
    }

    static let sonoma = MacOSRelease(name: "macOS Sonoma", major: "14", version: "14.8.9", build: "23J631", source: .softwareUpdate, provenance: "")

    @Test func fromTheCatalogToAVerifiedDrive() async throws {
        let mac = try Self.mac("im-e2e")
        #expect(mac.layout.diskutil.hasPrefix(mac.root.url.path))
        let page = mac.root.url.appendingPathComponent("install-media/apple-102662.html")
        let loader = MacOSInstallerCatalogLoader(layout: mac.layout, runner: mac.simulation.makeRunner(),
                                                 cacheFile: mac.layout.caches.appendingPathComponent("installers.json")) { _ in
            try String(contentsOf: page, encoding: .utf8)
        }
        let catalog = await loader.refresh()
        #expect(catalog.grouped.prefix(4).map(\.major) == ["27", "26", "15", "14"])
        #expect(catalog.grouped.last?.major == "10.7")

        let creator = mac.creator
        final class Percents: @unchecked Sendable { let lock = NSLock(); var all: [Double] = []
            func add(_ p: Double?) { if let p { lock.withLock { all.append(p) } } } }
        let percents = Percents()
        let app = try await creator.download(Self.sonoma, progress: percents.add)
        #expect(app.lastPathComponent == "Install macOS Sonoma.app")
        #expect(percents.all.first == 0 && percents.all.last == 100 && percents.all.count == 11)

        let report = await creator.inspector.inspect(app)
        #expect(report.macOSVersion == "14.8.9")
        #expect(report.signedByApple)
        #expect(report.supportsNoInteraction)
        #expect(!report.needsApplicationPath)
        #expect(creator.inspector.problems(of: report) == [])

        let drives = try await creator.scanner.scan(required: report.requiredBytes)
        // disk7 is a card in the built-in reader (internal but removable); disk8, the Mac's own second SSD, is not
        // offered as a whole.
        #expect(drives.map(\.id) == ["disk4", "disk5", "disk6", "disk7"])
        #expect(drives[3].isEligible && drives[3].drive.isRemovable)
        #expect(drives[0].isEligible)
        #expect(drives[1].protections == [.holdsProtectedVolume("Backup")])
        #expect(drives[2].protections == [.tooSmall(required: report.requiredBytes)])

        let result = try await creator.create(installer: report, on: drives[0].drive, stage: { _ in })
        #expect(result.verification == .verified)
        #expect(result.volume?.lastPathComponent == "Install macOS Sonoma")
        #expect(FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("Install macOS Sonoma/Install macOS Sonoma.app/Contents/Info.plist").path))
        // The old volume of the stick is gone; the backup drive and the small stick are untouched.
        #expect(!FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("STICK").path))
        #expect(FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("Backup/MacReplica Backup").path))
        #expect(FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("KINGSTON").path))
        let calls = try String(contentsOf: mac.root.url.appendingPathComponent("state/calls.log"), encoding: .utf8)
        #expect(calls.components(separatedBy: "diskutil eraseDisk").count == 2)
        #expect(calls.contains("diskutil eraseDisk JHFS+ MRINSTALL-"))
        #expect(calls.contains(" GPT disk4"))
        #expect(!calls.contains("eraseDisk JHFS+ MRINSTALL-") || !calls.contains("GPT disk5"))
    }

    @Test func eachFailureStopsWhereItHappens() async throws {
        // A swapped drive: nothing erased.
        let swapped = try Self.mac("im-swap")
        let app1 = try await swapped.creator.download(Self.sonoma, progress: { _ in })
        let report1 = await swapped.creator.inspector.inspect(app1)
        let stick1 = try #require(try await swapped.creator.scanner.scan(required: report1.requiredBytes).first)
        try swapped.root.swapDrive("disk4")
        await #expect(throws: InstallMediaError.drive(.driveChanged)) { try await swapped.creator.create(installer: report1, on: stick1.drive, stage: { _ in }) }
        #expect(FileManager.default.fileExists(atPath: swapped.layout.volumesRoot.appendingPathComponent("Photos").path))

        // createinstallmedia fails: reported once, the drive is left erased (said so in the app), nothing retried.
        let failing = try Self.mac("im-createfail")
        let app2 = try await failing.creator.download(Self.sonoma, progress: { _ in })
        let report2 = await failing.creator.inspector.inspect(app2)
        let stick2 = try #require(try await failing.creator.scanner.scan(required: report2.requiredBytes).first)
        try failing.root.setFlag("createinstallmedia-fails", true, content: "The bless of the installer disk failed.")
        do {
            _ = try await failing.creator.create(installer: report2, on: stick2.drive, stage: { _ in })
            Issue.record("expected a failure")
        } catch InstallMediaError.createFailed(let detail) {
            #expect(detail.contains("The bless of the installer disk failed."))
        }
        let calls = try String(contentsOf: failing.root.url.appendingPathComponent("state/calls.log"), encoding: .utf8)
        #expect(calls.components(separatedBy: "createinstallmedia --volume").count == 2)

        // An installer whose signature fails is refused before the drive is touched.
        let unsigned = try Self.mac("im-unsigned")
        let app3 = try await unsigned.creator.download(Self.sonoma, progress: { _ in })
        try unsigned.root.setFlag("unsigned", true)
        let report3 = await unsigned.creator.inspector.inspect(app3)
        #expect(!report3.signedByApple)
        let stick3 = try #require(try await unsigned.creator.scanner.scan(required: report3.requiredBytes).first)
        await #expect(throws: InstallMediaError.self) { try await unsigned.creator.create(installer: report3, on: stick3.drive, stage: { _ in }) }
        #expect(FileManager.default.fileExists(atPath: unsigned.layout.volumesRoot.appendingPathComponent("STICK").path))

        // Software Update offline.
        let offline = try Self.mac("im-offline")
        try offline.root.setFlag("offline", true)
        await #expect(throws: InstallMediaError.self) { try await offline.creator.download(Self.sonoma, progress: { _ in }) }
    }

    /// The expert option end to end on the simulated Mac: only the empty partition of its internal SSD is erased.
    @Test func anEmptyInternalPartitionBecomesAnInstaller() async throws {
        let mac = try Self.mac("im-partition")
        var creator = mac.creator
        creator.scanner.includeInternalPartitions = true
        let app = try await creator.download(Self.sonoma, progress: { _ in })
        let report = await creator.inspector.inspect(app)
        let candidates = try await creator.scanner.scan(required: report.requiredBytes)
        let spare = try #require(candidates.first { $0.id == "disk8s2" })
        #expect(spare.isPartition && spare.isEligible)
        let result = try await creator.create(installer: report, on: spare, stage: { _ in })
        #expect(result.verification == .verified)
        #expect(result.checks.contains { $0.item == .otherPartitionsUntouched && $0.passed })
        let calls = try String(contentsOf: mac.root.url.appendingPathComponent("state/calls.log"), encoding: .utf8)
        #expect(calls.contains("diskutil eraseVolume JHFS+ MRINSTALL-"))
        #expect(!calls.contains("eraseDisk"))
        // The other drives are untouched.
        #expect(FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("STICK").path))
        #expect(FileManager.default.fileExists(atPath: mac.layout.volumesRoot.appendingPathComponent("EOS_DIGITAL/DCIM/100CANON/IMG_0001.JPG").path))
    }

    /// 1.1.10 on the simulated Mac: an installer chosen from Downloads is copied into Applications, used from there
    /// (locked and checked again as root inside the administrator step), and moved to the Trash afterwards.
    @Test func aChosenInstallerIsCopiedUsedAndTrashed() async throws {
        let mac = try Self.mac("im-local")
        let creator = mac.creator
        let downloaded = try await creator.download(Self.sonoma, progress: { _ in })
        // The user had the installer in Downloads instead.
        let downloads = mac.layout.homeDirectory.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let chosen = downloads.appendingPathComponent(downloaded.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: chosen)
        #expect(creator.inspector.installedInstallers().isEmpty)

        let files = InstallerFiles(layout: mac.layout, runner: mac.simulation.makeRunner(), privileged: mac.simulation.makePrivilegedExecutor())
        let copied = try await files.copyIntoApplications(chosen)
        #expect(creator.inspector.installedInstallers().map(\.lastPathComponent) == ["Install macOS Sonoma.app"])
        let report = await creator.inspector.inspect(copied)
        let release = InstallerFiles.release(from: report)
        #expect(release.source == .onThisMac(path: copied.path) && release.version == "14.8.9")

        let stick = try #require(try await creator.scanner.scan(required: report.requiredBytes).first)
        let result = try await creator.create(installer: report, on: stick.drive, stage: { _ in })
        #expect(result.verification == .verified)
        let calls = try String(contentsOf: mac.root.url.appendingPathComponent("state/calls.log"), encoding: .utf8)
        // The signature was checked again (the simulated root step uses the codesign stand-in) before the tool ran.
        let check = try #require(calls.range(of: "codesign --verify --strict -R=anchor apple", options: .backwards))
        let run = try #require(calls.range(of: "createinstallmedia --volume", options: .backwards))
        #expect(check.lowerBound < run.lowerBound)

        try await files.moveToTrash(copied)
        #expect(creator.inspector.installedInstallers().isEmpty)
        #expect(FileManager.default.fileExists(atPath: mac.layout.homeDirectory.appendingPathComponent(".Trash/Install macOS Sonoma.app").path))
    }
}
