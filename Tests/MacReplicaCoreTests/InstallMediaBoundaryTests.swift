import Foundation
import Testing
@testable import MacReplicaCore

/// Boundaries and fallbacks of the installer tool that the mutation run showed untested.
@Suite("Install media: boundaries and fallbacks")
struct InstallMediaBoundaryTests {
    typealias Safety = InstallMediaSafetyTests
    static let now = Date(timeIntervalSince1970: 1_792_400_000)

    // MARK: Catalog

    @Test func versionsSortByNumberWhateverTheirBuilds() {
        func su(_ version: String, _ build: String) -> MacOSRelease {
            MacOSRelease(name: "macOS Tahoe", major: "26", version: version, build: build, source: .softwareUpdate, provenance: "")
        }
        // The builds sort the other way round than the versions.
        let catalog = MacOSInstallerCatalog(releases: [su("26.7", "25Z9"), su("26.10", "25A1"), su("26.7.1", "25B1")])
        #expect(catalog.grouped.first?.releases.map(\.version) == ["26.10", "26.7.1", "26.7"])
        // Same version twice: the newer build first.
        let twice = MacOSInstallerCatalog(releases: [su("26.7", "25G1"), su("26.7", "25G9")])
        #expect(twice.grouped.first?.releases.map(\.build) == ["25G9", "25G1"])
    }

    @Test func softwareUpdateComesFirstAndNamesTheGroup() {
        let page = MacOSRelease(name: "macOS 27", major: "27", source: .appStore(id: 1, url: "macappstores://apps.apple.com/app/id1?mt=12"), provenance: "")
        // No build either, so only the source can decide the order.
        let su = MacOSRelease(name: "macOS 27 Golden Gate", major: "27", version: "27", build: nil, source: .softwareUpdate, provenance: "")
        for releases in [[page, su], [su, page]] {
            let group = MacOSInstallerCatalog(releases: releases).grouped[0]
            #expect(group.releases.first?.source == .softwareUpdate)
            #expect(group.name == "macOS 27 Golden Gate")
        }
        // The newest Software Update entry names the group.
        let older = MacOSRelease(name: "macOS 27 Beta", major: "27", version: "27.0", build: "26A1", source: .softwareUpdate, provenance: "")
        let newer = MacOSRelease(name: "macOS 27 Golden Gate", major: "27", version: "27.0.1", build: "26A2", source: .softwareUpdate, provenance: "")
        #expect(MacOSInstallerCatalog(releases: [older, newer, page]).grouped[0].name == "macOS 27 Golden Gate")
        // Without Software Update the page's name is used.
        #expect(MacOSInstallerCatalog(releases: [page]).grouped.first?.name == "macOS 27")
    }

    @Test func onlyAFullAnswerOfAReasonableSizeIsRead() throws {
        #expect(try MacOSInstallerCatalogLoader.page(status: 200, data: Data("<html/>".utf8)) == "<html/>")
        #expect(throws: MacOSInstallerCatalogError.pageUnavailable("HTTP 404")) { try MacOSInstallerCatalogLoader.page(status: 404, data: Data()) }
        #expect(throws: MacOSInstallerCatalogError.self) { try MacOSInstallerCatalogLoader.page(status: 200, data: Data(count: 5_000_000)) }
        #expect(try MacOSInstallerCatalogLoader.page(status: 200, data: Data(count: 4_999_999)).count == 4_999_999)
    }

    @Test func theCacheFolderIsCreatedWhenMissing() async throws {
        let sandbox = try Sandbox("cache-deep")
        let cache = sandbox.url.appendingPathComponent("a/b/c/catalog.json")
        let output = InstallMediaCatalogTests.softwareUpdate
        let loader = MacOSInstallerCatalogLoader(layout: toolchainLayout(sandbox), runner: ScriptedRunner { _ in
            CommandResult(exitCode: 0, stdout: output, stderr: "")
        }, cacheFile: cache) { _ in "" }
        let catalog = await loader.refresh(now: Self.now)
        #expect(!catalog.releases.isEmpty)
        #expect(loader.cached() == catalog)
    }

    // MARK: Drives

    @Test func boundariesOfDrives() async throws {
        let s = try Safety.setup("drive-bounds")
        var unknownWritable = FakeDrives.usbStick("disk4")
        unknownWritable.removeValue(forKey: "WritableMedia")
        s.drives.add("disk4", info: unknownWritable)
        s.drives.add("disk5", info: FakeDrives.usbStick("disk5", size: 20_000_000_000))
        // A synthesized container that names no physical store is still not a drive.
        s.drives.containers = [["DeviceIdentifier": "disk6", "Content": "Apple_APFS_Container", "APFSVolumes": []]]
        let byID = Dictionary(uniqueKeysWithValues: try await s.scanner.scan(required: 20_000_000_000).map { ($0.id, $0.protections) })
        // Unknown writability counts as read-only.
        #expect(byID["disk4"] == [.readOnly])
        // Exactly the required size is enough.
        #expect(byID["disk5"] == [])
        #expect(byID["disk6"] == nil)
    }

    @Test func boundariesOfPartitions() throws {
        let s = try Safety.setup("partition-bounds")
        _ = try s.sandbox.folder("Volumes/P")
        let partition = InstallMediaDrive.Volume(device: "disk5s2", name: "P", mountPoint: s.layout.volumesRoot.appendingPathComponent("P").path,
                                                 content: "Apple_HFS", partitionUUID: "2A23C4B2-74FE-4573-896B-B8F0D2EC3440", sizeBytes: 100)
        let image = InstallMediaDrive(device: "disk5", mediaName: "Disk Image", sizeBytes: 100, busProtocol: "Disk Image", isInternal: false,
                                      isVirtual: true, isWritable: true, volumes: [partition])
        // A disk image's partition is refused unless MacReplica's own tests allow disk images.
        #expect(s.scanner.partitionProtections(of: partition, on: image, startup: [], required: 100) == [.diskImage])
        var tests = s.scanner
        tests.allowsDiskImages = true
        // Exactly the required size is enough; one byte more is not.
        #expect(tests.partitionProtections(of: partition, on: image, startup: [], required: 100) == [])
        #expect(tests.partitionProtections(of: partition, on: image, startup: [], required: 101) == [.tooSmall(required: 101)])
    }

    @Test func whatCountsAsEmptyAndAsABackup() throws {
        let sandbox = try Sandbox("empty-and-backup")
        try sandbox.file("v/.hidden")
        try sandbox.file("v/System Volume Information/x")
        try sandbox.file("v/$RECYCLE.BIN/x")
        #expect(InstallMediaDriveScanner.visibleItems(in: sandbox.url.appendingPathComponent("v")) == 0)
        try sandbox.file("v/notes.txt")
        #expect(InstallMediaDriveScanner.visibleItems(in: sandbox.url.appendingPathComponent("v")) == 1)
        #expect(InstallMediaDriveScanner.visibleItems(in: sandbox.url.appendingPathComponent("missing")) == 1)

        // A folder that only looks like a backup (no manifest) is not one; a manifest in another folder is not either.
        try sandbox.file("b/MacReplica-Backup-2026-10-15/readme.txt")
        try sandbox.file("b/Other/manifest.json")
        #expect(!InstallMediaDriveScanner.holdsMacReplicaBackup(sandbox.url.appendingPathComponent("b")))
        try sandbox.file("b/MacReplica-Backup-2026-10-15/manifest.json")
        #expect(InstallMediaDriveScanner.holdsMacReplicaBackup(sandbox.url.appendingPathComponent("b")))
    }

    // MARK: Installer

    @Test func installerDetailsReadFromTheToolAndTheFolder() async throws {
        let sandbox = try Sandbox("inspector-details")
        let layout = toolchainLayout(sandbox)
        // Only `Install ….app` folders with an Info.plist are installers.
        try sandbox.file("Applications/Safari.app/Contents/Info.plist", "<plist/>")
        try sandbox.file("Applications/Install notes.txt", "x")
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Info.plist", "<plist/>")
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia", "#!/bin/sh\n", executable: true)
        final class Usage: @unchecked Sendable { var text = "--volume\n--nointeraction" }
        let usage = Usage()
        let runner = ScriptedRunner { command in
            command.executable == layout.codesign ? CommandResult(exitCode: 0, stdout: "", stderr: "") : CommandResult(exitCode: 0, stdout: usage.text, stderr: "")
        }
        let inspector = InstallerInspector(layout: layout, runner: runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        #expect(inspector.installedInstallers().map(\.lastPathComponent) == ["Install macOS Sonoma.app"])
        let app = inspector.installedInstallers()[0]
        // Neither option named: no --applicationpath.
        #expect(!(await inspector.inspect(app)).needsApplicationPath)
        usage.text = "--volume\n--applicationpath\n--nointeraction\n--downloadassets"
        #expect(!(await inspector.inspect(app)).needsApplicationPath)
        // A report that never went through the check is not Apple's.
        let unchecked = InstallerAppReport(app: app, displayName: "Install macOS Sonoma")
        #expect(inspector.problems(of: unchecked).first == .notSignedByApple(""))
    }

    // MARK: Administrator steps

    @Test func writingAnInstallerMayTakeHours() async throws {
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
        let executor = AppleScriptPrivilegedExecutor(runner: runner)
        let volume = URL(fileURLWithPath: "/Volumes/MRINSTALL-0A1B2C3D")
        let tool = URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia")
        try await executor.run([.requireInstallMediaMarker(volume.appendingPathComponent(".MacReplicaInstallTarget-\(UUID().uuidString)")),
                                .createInstallMedia(tool: tool, volume: volume, applicationPath: nil)], reason: "r")
        try await executor.run([.createFolder(URL(fileURLWithPath: "/Library/Fonts/x"))], reason: "r")
        #expect(runner.commands.map(\.timeout) == [TimeInterval(3 * 3600), TimeInterval(1800)])
        // A volume path that climbs out of /Volumes is never an installer volume.
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/Volumes/../Volumes/MRINSTALL-0A1B2C3D")))
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/Volumes/MRINSTALL-0A1B2C3D/..")))
    }

    @Test func aLeadingEmptyLineIsKept() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/printf"]), baseEnvironment: [:])
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } } }
        let lines = Lines()
        _ = try await runner.run(Command(executable: "/usr/bin/printf", arguments: ["\\nX\\n"]), onOutputLine: lines.add)
        #expect(lines.all == ["", "X"])
    }

    // MARK: After a failure

    @Test func wasTheDriveErased() async throws {
        let (f, spare) = try await InstallMediaPartitionTests.partitionFlow("was-erased")
        let partition = try #require(spare.partition)
        #expect(!(await f.creator.wasErased(spare)))
        // Only the format changed, or only the name: erased either way.
        let index = try #require(f.setup.drives.disks["disk0"]?.partitions.firstIndex { $0["DiskUUID"] as? String == partition.partitionUUID })
        f.setup.drives.disks["disk0"]?.partitions[index]["Content"] = "Apple_HFS"
        #expect(await f.creator.wasErased(spare))
        f.setup.drives.disks["disk0"]?.partitions[index]["Content"] = partition.content
        f.setup.drives.disks["disk0"]?.partitions[index]["VolumeName"] = "MRINSTALL-12345678"
        #expect(await f.creator.wasErased(spare))
        // The partition is gone, or the disk cannot be read: assume the worst.
        f.setup.drives.disks["disk0"]?.partitions.remove(at: index)
        #expect(await f.creator.wasErased(spare))
        // diskutil cannot list the disk at all.
        f.setup.drives.listFails = true
        #expect(await f.creator.wasErased(spare))
    }

    @Test func aDiskImagesPartitionsAreListedInsteadOfTheImage() async throws {
        let s = try Safety.setup("image-partitions")
        _ = try s.sandbox.folder("Volumes/SPARE")
        s.drives.add("disk5", info: FakeDrives.usbStick("disk5", virtual: true, bus: "Disk Image"),
                     volumes: [("KEEP", nil, "Apple_HFS"), ("SPARE", s.layout.volumesRoot.appendingPathComponent("SPARE").path, "Microsoft Basic Data")])
        var tests = s.scanner
        tests.allowsDiskImages = true
        tests.partitionsOfDiskImages = true
        let candidates = try await tests.scan(required: 0)
        #expect(candidates.map(\.id) == ["disk5s1", "disk5s2"])
        #expect(candidates.allSatisfy { $0.isPartition })
    }

    @Test func anUnreadableDiskConfirmsNothing() async throws {
        let (f, spare) = try await InstallMediaPartitionTests.partitionFlow("unreadable-alone")
        // A disk that has only the target partition: before and after would both be “no other partitions”.
        let partition = try #require(spare.partition)
        let alone = InstallMediaDrive(device: "disk9", mediaName: "SSD", sizeBytes: 1, busProtocol: "", isInternal: true, isVirtual: false,
                                      isWritable: true, volumes: [partition])
        let result = await f.creator.verify(drive: alone, partition: partition, installer: f.report)
        #expect(result.checks.first { $0.item == .otherPartitionsUntouched }?.passed == false)
    }

    @Test func anUnmountedInstallerVolumeIsNotReplacedByAnotherVolume() async throws {
        let f = try await Safety.flow("unmounted-installer")
        _ = try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in })
        // The installer volume is not mounted, but the EFI partition is.
        let volumesRoot = f.setup.layout.volumesRoot.path
        let changed = (f.setup.drives.disks["disk4"]?.partitions ?? []).map { partition in
            var partition = partition
            if partition["VolumeName"] as? String == "EFI" { partition["MountPoint"] = volumesRoot }
            else { partition.removeValue(forKey: "MountPoint") }
            return partition
        }
        f.setup.drives.disks["disk4"]?.partitions = changed
        let result = await f.creator.verify(drive: f.drive, installer: f.report)
        #expect(result.verification == .failed)
        #expect(result.checks.map(\.item) == [.volumeOnDrive])
    }

    @Test func otherPartitionsCannotBeConfirmedWithoutReadingTheDisk() async throws {
        let (f, spare) = try await InstallMediaPartitionTests.partitionFlow("unreadable-after")
        f.setup.drives.disks = [:]
        let result = await f.creator.verify(drive: spare.drive, partition: spare.partition, installer: f.report)
        #expect(result.checks.first { $0.item == .otherPartitionsUntouched }?.passed == false)
        #expect(result.verification == .failed)
    }
}
