import Foundation
import Testing
@testable import MacReplicaCore

/// Cards in a built-in reader, and the expert option: an empty, separate partition of the Mac's internal disk.
/// Only that partition is erased – by its partition UUID, in the same administrator step as `createinstallmedia` –
/// and every other partition must be unchanged afterwards.
@Suite("Install media: cards and internal partitions")
struct InstallMediaPartitionTests {
    typealias Safety = InstallMediaSafetyTests
    static let gib: Int64 = 1_073_741_824

    /// disk0 as on a Mac with a spare partition: EFI, the APFS container, Recovery, an empty ExFAT partition, a
    /// partition with files, an unmounted one and a small empty one.
    static func internalDisk(_ s: Safety.Setup) throws {
        let volumes = s.layout.volumesRoot
        try s.sandbox.file("Volumes/SPARE/.fseventsd/x")
        try s.sandbox.file("Volumes/SPARE/System Volume Information/x")
        try s.sandbox.file("Volumes/Data/Report.pages")
        try s.sandbox.file("Volumes/Data/Photos/1.jpg")
        _ = try s.sandbox.folder("Volumes/Tiny")
        s.drives.add("disk0", info: FakeDrives.usbStick("disk0", name: "APPLE SSD AP2048Z", size: 2_000_000_000_000, isInternal: true, bus: "Apple Fabric"),
                     volumes: [("EFI", nil, "EFI"), ("", nil, "Apple_APFS"), ("", nil, "Apple_APFS_Recovery"),
                               ("SPARE", volumes.appendingPathComponent("SPARE").path, "Microsoft Basic Data"),
                               ("Data", volumes.appendingPathComponent("Data").path, "Apple_HFS"),
                               ("Hidden", nil, "Apple_HFS"),
                               ("Tiny", volumes.appendingPathComponent("Tiny").path, "Apple_HFS")])
        // The small partition really is small.
        s.drives.disks["disk0"]?.partitions[6]["Size"] = 4 * gib
        // The startup volume lives in an APFS container on disk0s2.
        s.drives.startupParent = "disk3"
        s.drives.startupStores = ["disk0s2"]
        s.drives.containers = [["DeviceIdentifier": "disk3", "Content": "Apple_APFS_Container", "APFSPhysicalStores": [["DeviceIdentifier": "disk0s2"]],
                                "APFSVolumes": [["DeviceIdentifier": "disk3s1", "VolumeName": "Macintosh HD", "MountPoint": "/"],
                                                ["DeviceIdentifier": "disk3s5", "VolumeName": "Data"]]]]
    }

    @Test func aCardInTheBuiltInReaderIsARemovableDrive() async throws {
        let s = try Safety.setup("card")
        // What the maintainer's Mac reports for an SD card: internal (built-in reader) but removable.
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4", name: "Built In SDXC Reader", size: 252_500_000_000, isInternal: true, removable: true,
                                                       bus: "Secure Digital"),
                     volumes: [("EOS_DIGITAL", nil, "Windows_NTFS")])
        try Self.internalDisk(s)
        let candidates = try await s.scanner.scan(required: 16 * Self.gib)
        #expect(candidates.map(\.id) == ["disk4"])
        #expect(candidates.first?.isEligible == true)
        #expect(candidates.first?.drive.isRemovable == true)
    }

    @Test func onlyEmptySeparatePartitionsOfTheInternalDiskAreOffered() async throws {
        let s = try Safety.setup("partitions")
        try Self.internalDisk(s)
        var scanner = s.scanner
        scanner.includeInternalPartitions = true
        let candidates = try await scanner.scan(required: 16 * Self.gib)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.protections) })
        #expect(candidates.allSatisfy { $0.isPartition })
        // The whole disk and the container's APFS volumes are never candidates.
        #expect(byID["disk0"] == nil && byID["disk3s1"] == nil && byID["disk3s5"] == nil)
        #expect(byID["disk0s1"] == [.systemPartition])
        #expect(byID["disk0s2"] == [.apfsVolume])
        #expect(byID["disk0s3"] == [.apfsVolume])
        #expect(byID["disk0s4"] == [])
        #expect(byID["disk0s5"] == [.notEmpty(2)])
        #expect(byID["disk0s6"] == [.notMounted])
        #expect(byID["disk0s7"] == [.tooSmall(required: 16 * Self.gib)])
        #expect(candidates.filter(\.isEligible).map(\.id) == ["disk0s4"])
        // Without the expert option the internal disk does not appear at all.
        #expect(try await s.scanner.scan(required: 0).isEmpty)
    }

    @Test func unknownFormatsAndPartitionsWithoutAnIdentifierAreRefused() throws {
        let s = try Safety.setup("formats")
        let drive = InstallMediaDrive(device: "disk0", mediaName: "SSD", sizeBytes: 1, busProtocol: "", isInternal: true, isVirtual: false, isWritable: true, volumes: [])
        func volume(_ content: String, uuid: String? = "2A23C4B2-74FE-4573-896B-B8F0D2EC3440") -> InstallMediaDrive.Volume {
            .init(device: "disk0s4", name: "X", mountPoint: nil, content: content, partitionUUID: uuid, sizeBytes: 1)
        }
        #expect(s.scanner.partitionProtections(of: volume("Linux Filesystem"), on: drive, startup: [], required: 0) == [.unsupportedFormat("Linux Filesystem")])
        #expect(s.scanner.partitionProtections(of: volume("Apple_Boot"), on: drive, startup: [], required: 0) == [.systemPartition])
        #expect(s.scanner.partitionProtections(of: volume("Apple_HFS", uuid: nil), on: drive, startup: [], required: 0) == [.systemPartition])
        #expect(s.scanner.partitionProtections(of: volume("Apple_HFS", uuid: "not-a-uuid"), on: drive, startup: [], required: 0) == [.systemPartition])
        #expect(s.scanner.partitionProtections(of: volume("Apple_HFS"), on: drive, startup: [], required: 0) == [.notMounted])
        var readOnly = drive
        readOnly.isWritable = false
        #expect(s.scanner.partitionProtections(of: volume("Apple_HFS"), on: readOnly, startup: [], required: 0) == [.readOnly])
        #expect(InstallMediaDrive.isPartitionUUID("2A23C4B2-74FE-4573-896B-B8F0D2EC3440"))
        #expect(!InstallMediaDrive.isPartitionUUID("2a23c4b2-74fe-4573-896b-b8f0d2ec3440"))
        #expect(!InstallMediaDrive.isPartitionUUID("disk0s4"))
    }

    static func partitionFlow(_ name: String) async throws -> (Safety.Flow, DriveCandidate) {
        let flow = try await Safety.flow(name) { s in try internalDisk(s) }
        var creator = flow.creator
        creator.scanner.includeInternalPartitions = true
        let candidate = try #require(try await creator.scanner.scan(required: flow.report.requiredBytes).first { $0.id == "disk0s4" })
        return (Safety.Flow(setup: flow.setup, creator: creator, recorder: flow.recorder, report: flow.report, drive: flow.drive), candidate)
    }

    @Test func onlyThePartitionIsErasedAndEverythingElseStays() async throws {
        let (f, spare) = try await Self.partitionFlow("partition-happy")
        let stages = Safety.Stages()
        let result = try await f.creator.create(installer: f.report, on: spare, stage: stages.add)
        #expect(stages.all == [.checkingInstaller, .checkingDrive, .erasingAndCreating, .verifying])
        // No whole-disk erase, ever; one administrator step: the partition by its UUID, then createinstallmedia.
        #expect(f.setup.runner.commands.allSatisfy { $0.arguments.first != "eraseDisk" })
        #expect(f.recorder.calls.count == 1)
        let steps = Array(f.recorder.calls[0].drop { if case .eraseVolumeForInstaller = $0 { return false }; return true })
        #expect(f.recorder.calls[0].contains(.verifyInstallerTool(f.report.createInstallMedia!)))
        guard steps.count == 2, case .eraseVolumeForInstaller(let uuid, let name) = steps[0],
              case .createInstallMedia(_, let volume, _) = steps[1] else { Issue.record("steps"); return }
        #expect(uuid == spare.partition?.partitionUUID)
        #expect(volume.lastPathComponent == name && PrivilegedOperation.isInstallMediaVolumeName(name))
        #expect(f.setup.drives.erasedPartitions == [uuid])
        #expect(result.verification == .verified)
        #expect(result.checks.first?.item == .otherPartitionsUntouched)
        #expect(result.checks.allSatisfy { $0.passed })
        // The partition with files is still there with its files.
        #expect(FileManager.default.fileExists(atPath: f.setup.layout.volumesRoot.appendingPathComponent("Data/Report.pages").path))
        #expect(await f.creator.wasErased(spare))
    }

    @Test func aChangedDiskStopsBeforeTheAdministratorStep() async throws {
        // Another partition changed (renamed) after the user confirmed.
        let (f, spare) = try await Self.partitionFlow("partition-changed")
        f.setup.drives.disks["disk0"]?.partitions[4]["VolumeName"] = "Data 2"
        await #expect(throws: InstallMediaError.drive(.driveChanged)) { try await f.creator.create(installer: f.report, on: spare, stage: { _ in }) }
        #expect(f.recorder.calls.isEmpty)
        #expect(!(await f.creator.wasErased(spare)))

        // Something was put on the partition meanwhile.
        let (g, spare2) = try await Self.partitionFlow("partition-filled")
        try g.setup.sandbox.file("Volumes/SPARE/new.txt")
        await #expect(throws: InstallMediaError.drive(.driveNotEligible([.notEmpty(1)]))) {
            try await g.creator.create(installer: g.report, on: spare2, stage: { _ in })
        }
        #expect(g.recorder.calls.isEmpty)
    }

    @Test func aPasswordCancelLeavesThePartitionUntouched() async throws {
        struct Denying: PrivilegedExecuting { func run(_ operations: [PrivilegedOperation], reason: String) async throws { throw PrivilegedError.denied } }
        let (f, spare) = try await Self.partitionFlow("partition-denied")
        var creator = f.creator
        creator.privileged = Denying()
        await #expect(throws: InstallMediaError.passwordDenied) { try await creator.create(installer: f.report, on: spare, stage: { _ in }) }
        #expect(!(await creator.wasErased(spare)))
        #expect(f.setup.drives.erasedPartitions.isEmpty)
    }

    @Test func aPartitionIsErasedOnlyRightBeforeCreateinstallmediaOnItsName() throws {
        let uuid = "2A23C4B2-74FE-4573-896B-B8F0D2EC3440"
        let tool = URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia")
        let erase = PrivilegedOperation.eraseVolumeForInstaller(partitionUUID: uuid, name: "MRINSTALL-0A1B2C3D")
        let create = PrivilegedOperation.createInstallMedia(tool: tool, volume: URL(fileURLWithPath: "/Volumes/MRINSTALL-0A1B2C3D"), applicationPath: nil)
        #expect(erase.argv == ["/usr/sbin/diskutil", "eraseVolume", "JHFS+", "MRINSTALL-0A1B2C3D", uuid])
        let verify = PrivilegedOperation.verifyInstallerTool(tool)
        let arguments = try AppleScriptPrivilegedExecutor.arguments(for: [verify, erase, create], reason: "r")
        #expect(Array(arguments.suffix(11)) == ["5", "/usr/sbin/diskutil", "eraseVolume", "JHFS+", "MRINSTALL-0A1B2C3D", uuid,
                                                "4", tool.path, "--volume", "/Volumes/MRINSTALL-0A1B2C3D", "--nointeraction"])
        // Never on its own, never followed by something else, never for another name, never a disk or a made-up identifier.
        #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [erase], reason: "r") }
        #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [erase, .createFolder(URL(fileURLWithPath: "/tmp/x"))], reason: "r") }
        let other = PrivilegedOperation.createInstallMedia(tool: tool, volume: URL(fileURLWithPath: "/Volumes/MRINSTALL-FFFFFFFF"), applicationPath: nil)
        #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [verify, erase, other], reason: "r") }
        for bad in [PrivilegedOperation.eraseVolumeForInstaller(partitionUUID: "disk0", name: "MRINSTALL-0A1B2C3D"),
                    .eraseVolumeForInstaller(partitionUUID: uuid, name: "Macintosh HD")] {
            #expect(!bad.isAllowed())
            #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [verify, bad, create], reason: "r") }
        }
    }

    /// Found with the real SD card: reading the card made macOS ask for permission, and the scan waited forever.
    /// A look that does not finish in time protects the drive instead of hanging.
    @Test func aLookThatMacOSHoldsBackProtectsTheDriveInsteadOfHanging() {
        let started = Date()
        let late: Int? = InstallMediaDriveScanner.withTimeout(0.2) { Thread.sleep(forTimeInterval: 2); return 1 }
        #expect(late == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(InstallMediaDriveScanner.withTimeout(2) { 7 } == 7)
    }
}
