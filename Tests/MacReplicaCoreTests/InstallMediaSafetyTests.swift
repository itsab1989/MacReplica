import Foundation
import Testing
@testable import MacReplicaCore

/// A scripted `diskutil`/`bless`/`codesign` for the installer tool: drives as plists, erase and the result of
/// `createinstallmedia` as changes to that state. No real disk is ever involved.
final class FakeDrives: @unchecked Sendable {
    struct Disk {
        var info: [String: Any]
        var partitions: [[String: Any]]
    }
    let lock = NSLock()
    var disks: [String: Disk] = [:]
    var containers: [[String: Any]] = []
    var startupParent = "disk3"
    var startupStores = ["disk0s2"]
    var volumesRoot: URL
    var eraseFails: String?
    var listFails = false
    var blessOutput = "finderinfo[0]:      2 => Blessed System Folder is /Volumes/Install macOS Sonoma/System/Library/CoreServices"
    var codesignFails = false
    private(set) var erased: [(device: String, name: String)] = []
    private(set) var erasedPartitions: [String] = []

    init(volumesRoot: URL) { self.volumesRoot = volumesRoot }

    static func usbStick(_ device: String = "disk4", name: String = "SanDisk Ultra", size: Int64 = 32_000_000_000, isInternal: Bool = false,
                         removable: Bool = false, virtual: Bool = false, writable: Bool = true, bus: String = "USB") -> [String: Any] {
        ["DeviceIdentifier": device, "MediaName": name, "TotalSize": size, "BusProtocol": bus, "Internal": isInternal, "RemovableMedia": removable,
         "VirtualOrPhysical": virtual ? "Virtual" : "Physical", "WritableMedia": writable, "WholeDisk": true]
    }

    func add(_ device: String, info: [String: Any], volumes: [(name: String, mount: String?, content: String)] = [], partitionSize: Int64 = 30_000_000_000) {
        disks[device] = Disk(info: info, partitions: volumes.enumerated().map { index, volume in
            var partition: [String: Any] = ["DeviceIdentifier": "\(device)s\(index + 1)", "VolumeName": volume.name, "Content": volume.content,
                                            "VolumeUUID": UUID().uuidString, "DiskUUID": UUID().uuidString, "Size": partitionSize]
            if let mount = volume.mount { partition["MountPoint"] = mount }
            return partition
        })
    }

    /// `diskutil eraseVolume JHFS+ <name> <partition UUID>`, as the administrator step runs it.
    func eraseVolume(_ argv: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard argv.count == 5, argv[1] == "eraseVolume", argv[2] == "JHFS+" else { throw PrivilegedError.failed("usage") }
        let name = argv[3], uuid = argv[4]
        for (device, disk) in disks {
            guard let index = disk.partitions.firstIndex(where: { $0["DiskUUID"] as? String == uuid }) else { continue }
            var partition = disk.partitions[index]
            if let old = partition["MountPoint"] as? String { try? FileManager.default.removeItem(atPath: old) }
            let mount = volumesRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            partition["VolumeName"] = name
            partition["Content"] = "Apple_HFS"
            partition["MountPoint"] = mount.path
            partition["VolumeUUID"] = UUID().uuidString
            disks[device]?.partitions[index] = partition
            erasedPartitions.append(uuid)
            return
        }
        throw PrivilegedError.failed("Could not find disk: \(uuid)")
    }

    func xml(_ object: Any) -> String {
        String(decoding: try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
    }

    func handle(_ command: Command, layout: SystemLayout) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        let args = command.arguments
        if command.executable == layout.bless { return CommandResult(exitCode: 0, stdout: blessOutput, stderr: "") }
        if command.executable == layout.codesign {
            return codesignFails ? CommandResult(exitCode: 3, stdout: "", stderr: "a sealed resource is missing or invalid") : CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        guard command.executable == layout.diskutil else { return CommandResult(exitCode: 127, stdout: "", stderr: "unexpected \(command.executable)") }
        switch args.first {
        case "info" where args.last == "/":
            return CommandResult(exitCode: 0, stdout: xml(["ParentWholeDisk": startupParent, "MountPoint": "/",
                                                            "APFSPhysicalStores": startupStores.map { ["APFSPhysicalStore": $0] }]), stderr: "")
        case "info":
            guard let disk = disks[args.last ?? ""] else { return CommandResult(exitCode: 1, stdout: "", stderr: "Could not find disk") }
            return CommandResult(exitCode: 0, stdout: xml(disk.info), stderr: "")
        case "list":
            if listFails { return CommandResult(exitCode: 1, stdout: "", stderr: "Unable to list disks") }
            let wanted = args.count >= 3 && args[2] != "external" ? args[2] : nil
            var entries: [[String: Any]] = disks.filter { wanted == nil || $0.key == wanted }.map { device, disk in
                ["DeviceIdentifier": device, "Content": "GUID_partition_scheme", "Size": disk.info["TotalSize"] ?? 0, "Partitions": disk.partitions]
            }
            if wanted == nil { entries += containers }
            return CommandResult(exitCode: 0, stdout: xml(["AllDisksAndPartitions": entries]), stderr: "")
        case "eraseDisk":
            if let eraseFails { return CommandResult(exitCode: 1, stdout: "Started erase on \(args[4])", stderr: eraseFails) }
            let name = args[2], device = args[4]
            erased.append((device, name))
            let mount = volumesRoot.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            disks[device]?.partitions = [["DeviceIdentifier": "\(device)s1", "Content": "EFI", "VolumeName": "EFI"],
                                         ["DeviceIdentifier": "\(device)s2", "Content": "Apple_HFS", "VolumeName": name, "MountPoint": mount.path,
                                          "VolumeUUID": UUID().uuidString]]
            return CommandResult(exitCode: 0, stdout: "Finished erase on \(device)", stderr: "")
        default:
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected diskutil \(args)")
        }
    }

    /// What `createinstallmedia` leaves: the volume renamed to the installer's name, the app and the startup files.
    func createInstallMedia(_ argv: [String], installerName: String, appVersion: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = argv.firstIndex(of: "--volume"), argv.contains("--nointeraction") else { throw PrivilegedError.failed("usage") }
        let volume = URL(fileURLWithPath: argv[index + 1])
        let fm = FileManager.default
        let renamed = volumesRoot.appendingPathComponent(installerName)
        try fm.moveItem(at: volume, to: renamed)
        // createinstallmedia erases the volume: the marker is gone.
        for item in try fm.contentsOfDirectory(atPath: renamed.path) { try fm.removeItem(at: renamed.appendingPathComponent(item)) }
        let app = renamed.appendingPathComponent("\(installerName).app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": appVersion], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try fm.createDirectory(at: renamed.appendingPathComponent("System/Library/CoreServices"), withIntermediateDirectories: true)
        try Data("efi".utf8).write(to: renamed.appendingPathComponent("System/Library/CoreServices/boot.efi"))
        for (device, disk) in disks where disk.partitions.contains(where: { $0["MountPoint"] as? String == volume.path }) {
            disks[device]?.partitions = disk.partitions.map { partition in
                var partition = partition
                if partition["MountPoint"] as? String == volume.path { partition["VolumeName"] = installerName; partition["MountPoint"] = renamed.path }
                return partition
            }
        }
    }
}

final class PrivilegedRecorder: PrivilegedExecuting, @unchecked Sendable {
    let lock = NSLock()
    var calls: [[PrivilegedOperation]] = []
    let inner: PrivilegedExecuting
    init(_ inner: PrivilegedExecuting) { self.inner = inner }
    func run(_ operations: [PrivilegedOperation], reason: String) async throws {
        lock.withLock { calls.append(operations) }
        try await inner.run(operations, reason: reason)
    }
}

@Suite("Install media: drives, administrator steps and the creation flow")
struct InstallMediaSafetyTests {
    struct Setup {
        let sandbox: Sandbox
        let layout: SystemLayout
        let drives: FakeDrives
        let runner: ScriptedRunner
        var scanner: InstallMediaDriveScanner
    }

    static func setup(_ name: String) throws -> Setup {
        let sandbox = try Sandbox(name)
        var layout = toolchainLayout(sandbox)
        layout.diskutil = sandbox.url.appendingPathComponent("tools/diskutil").path
        layout.bless = sandbox.url.appendingPathComponent("tools/bless").path
        layout.volumesRoot = try sandbox.folder("Volumes")
        let drives = FakeDrives(volumesRoot: layout.volumesRoot)
        let captured = layout
        let runner = ScriptedRunner { drives.handle($0, layout: captured) }
        return Setup(sandbox: sandbox, layout: layout, drives: drives, runner: runner,
                     scanner: InstallMediaDriveScanner(layout: layout, runner: runner))
    }

    static let gib: Int64 = 1_073_741_824

    // MARK: Drives

    @Test func onlyExternalPhysicalWritableDrivesAreEligible() async throws {
        let s = try Self.setup("drives")
        let mount = { (name: String) in s.layout.volumesRoot.appendingPathComponent(name).path }
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [("STICK", mount("STICK"), "Apple_HFS")])
        s.drives.add("disk5", info: FakeDrives.usbStick("disk5", isInternal: true))
        s.drives.add("disk6", info: FakeDrives.usbStick("disk6", virtual: true, bus: "Disk Image"))
        s.drives.add("disk7", info: FakeDrives.usbStick("disk7", writable: false))
        s.drives.add("disk8", info: FakeDrives.usbStick("disk8", size: 8 * Self.gib))
        s.drives.add("disk0", info: FakeDrives.usbStick("disk0"))
        // Unknown internal flag: treated as internal.
        var unknown = FakeDrives.usbStick("disk9"); unknown.removeValue(forKey: "Internal")
        s.drives.add("disk9", info: unknown)
        let candidates = try await s.scanner.scan(required: 16 * Self.gib)
        let byDevice = Dictionary(uniqueKeysWithValues: candidates.map { ($0.drive.device, $0.protections) })
        #expect(byDevice["disk4"] == [])
        // The Mac's own disks are not offered as a whole (only their empty partitions, as the expert option).
        #expect(byDevice["disk5"] == nil)
        #expect(byDevice["disk6"] == [.diskImage])
        #expect(byDevice["disk7"] == [.readOnly])
        #expect(byDevice["disk8"] == [.tooSmall(required: 16 * Self.gib)])
        #expect(byDevice["disk0"] == [.startupDisk])
        #expect(byDevice["disk9"] == nil)
        #expect(candidates.filter(\.isEligible).map(\.drive.device) == ["disk4"])
        #expect(candidates.first { $0.id == "disk4" }?.drive.mediaName == "SanDisk Ultra")

        var tests = s.scanner
        tests.allowsDiskImages = true
        #expect(try await tests.scan(required: 0).first { $0.id == "disk6" }?.isEligible == true)
    }

    @Test func drivesHoldingBackupsOrMacReplicaAreProtected() async throws {
        let s = try Self.setup("protected")
        let volumes = s.layout.volumesRoot
        try s.sandbox.file("Volumes/TM/Backups.backupdb/x")
        try s.sandbox.file("Volumes/Backup/Backup/MacReplica Backup/MacReplica-Backup-2026-10-15-2234/manifest.json", "{}")
        try s.sandbox.file("Volumes/Work/MacReplica.app/Contents/Info.plist")
        try s.sandbox.file("Volumes/Plain/readme.txt")
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [("TM", volumes.appendingPathComponent("TM").path, "Apple_HFS")])
        s.drives.add("disk5", info: FakeDrives.usbStick("disk5"), volumes: [("Backup", volumes.appendingPathComponent("Backup").path, "Apple_HFS")])
        s.drives.add("disk6", info: FakeDrives.usbStick("disk6"), volumes: [("Work", volumes.appendingPathComponent("Work").path, "Apple_HFS")])
        s.drives.add("disk7", info: FakeDrives.usbStick("disk7"), volumes: [("Plain", volumes.appendingPathComponent("Plain").path, "Apple_HFS"),
                                                                             ("Time Machine", nil, "Apple_APFS")])
        s.drives.add("disk8", info: FakeDrives.usbStick("disk8"), volumes: [("Root", "/", "Apple_HFS")])
        var scanner = s.scanner
        scanner.protectedPaths = [volumes.appendingPathComponent("Work/MacReplica.app")]
        let candidates = try await scanner.scan(required: 0)
        let byDevice = Dictionary(uniqueKeysWithValues: candidates.map { ($0.drive.device, $0.protections) })
        #expect(byDevice["disk4"] == [.timeMachine("TM")])
        #expect(byDevice["disk5"] == [.holdsProtectedVolume("Backup")])
        #expect(byDevice["disk6"] == [.holdsProtectedVolume("Work")])
        // A volume that is not mounted cannot be looked into; it is erased with the drive (and listed in the confirmation).
        #expect(byDevice["disk7"] == [])
        #expect(byDevice["disk8"] == [.startupDisk])
    }

    @Test func apfsVolumesCountForTheDriveTheyLiveOn() async throws {
        let s = try Self.setup("apfs")
        try s.sandbox.file("Volumes/Time Machine/.com.apple.timemachine.supported")
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [("", nil, "Apple_APFS")])
        s.drives.containers = [["DeviceIdentifier": "disk5", "Content": "Apple_APFS_Container", "APFSPhysicalStores": [["DeviceIdentifier": "disk4s1"]],
                                "APFSVolumes": [["DeviceIdentifier": "disk5s1", "VolumeName": "Time Machine",
                                                 "MountPoint": s.layout.volumesRoot.appendingPathComponent("Time Machine").path]]]]
        let candidates = try await s.scanner.scan(required: 0)
        #expect(candidates.map(\.drive.device) == ["disk4"])
        #expect(candidates.first?.protections == [.timeMachine("Time Machine")])
        #expect(candidates.first?.drive.volumes.map(\.device) == ["disk4s1", "disk5s1"])
    }

    @Test func theStartupDiskIsFoundThroughItsAPFSStore() async throws {
        let s = try Self.setup("startup")
        // Started up from an external drive: the drive is external, but it is the startup disk.
        s.drives.startupParent = "disk9"
        s.drives.startupStores = ["disk4s2"]
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"))
        #expect(try await s.scanner.scan(required: 0).first?.protections == [.startupDisk])
        #expect(InstallMediaDriveScanner.wholeDisk(of: "disk12s2s1") == "disk12")
        #expect(InstallMediaDrive.isWholeDiskIdentifier("disk4"))
        #expect(!InstallMediaDrive.isWholeDiskIdentifier("disk4s1"))
        #expect(!InstallMediaDrive.isWholeDiskIdentifier("/dev/disk4"))
        #expect(!InstallMediaDrive.isWholeDiskIdentifier("disk4; rm"))
    }

    @Test func aDriveThatChangedIsNeverErased() async throws {
        let s = try Self.setup("revalidate")
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [("STICK", nil, "Apple_HFS")])
        let confirmed = try #require(try await s.scanner.scan(required: 0).first?.drive)
        #expect(try await s.scanner.revalidate(confirmed, required: 0) == confirmed)
        // Unplugged and another drive got the same number.
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4", name: "Photos SSD", size: 2_000_000_000_000), volumes: [("Photos", nil, "Apple_HFS")])
        await #expect(throws: InstallMediaDriveError.driveChanged) { try await s.scanner.revalidate(confirmed, required: 0) }
        // Gone.
        s.drives.disks = [:]
        await #expect(throws: InstallMediaDriveError.driveChanged) { try await s.scanner.revalidate(confirmed, required: 0) }
        // Same drive, but now too small for the installer chosen afterwards.
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [])
        let again = try #require(try await s.scanner.scan(required: 0).first?.drive)
        await #expect(throws: InstallMediaDriveError.driveNotEligible([.tooSmall(required: 64 * Self.gib)])) {
            try await s.scanner.revalidate(again, required: 64 * Self.gib)
        }
    }

    // MARK: Administrator steps

    @Test func theAdministratorStepsReachOnlyTheErasedVolumeAndApplesTool() throws {
        let tool = URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia")
        let volume = URL(fileURLWithPath: "/Volumes/MRINSTALL-0A1B2C3D")
        let marker = volume.appendingPathComponent(".MacReplicaInstallTarget-\(UUID().uuidString)")
        #expect(PrivilegedOperation.isInstallMediaTool(tool))
        #expect(!PrivilegedOperation.isInstallMediaTool(URL(fileURLWithPath: "/Users/x/Install macOS Sonoma.app/Contents/Resources/createinstallmedia")))
        #expect(!PrivilegedOperation.isInstallMediaTool(URL(fileURLWithPath: "/Applications/Evil.app/Contents/Resources/createinstallmedia")))
        #expect(!PrivilegedOperation.isInstallMediaTool(URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app/Contents/Resources/sh")))
        #expect(!PrivilegedOperation.isInstallMediaTool(URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app/Contents/Resources/../../../../bin/createinstallmedia")))
        #expect(PrivilegedOperation.isInstallMediaVolume(volume))
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/Volumes/Backup")))
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/")))
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/Volumes/x/MRINSTALL-0A1B2C3D")))
        #expect(!PrivilegedOperation.isInstallMediaVolume(URL(fileURLWithPath: "/Volumes/MRINSTALL-0a1b2c3d")))
        #expect(PrivilegedOperation.isInstallMediaMarker(marker))
        #expect(!PrivilegedOperation.isInstallMediaMarker(URL(fileURLWithPath: "/Volumes/Backup/.MacReplicaInstallTarget-\(UUID().uuidString)")))
        #expect(!PrivilegedOperation.isInstallMediaMarker(volume.appendingPathComponent("marker")))

        let create = PrivilegedOperation.createInstallMedia(tool: tool, volume: volume, applicationPath: nil)
        #expect(create.argv == [tool.path, "--volume", volume.path, "--nointeraction"])
        let older = PrivilegedOperation.createInstallMedia(tool: tool, volume: volume, applicationPath: URL(fileURLWithPath: "/Applications/Install macOS Sonoma.app"))
        #expect(older.argv.suffix(2) == ["--applicationpath", "/Applications/Install macOS Sonoma.app"])
        #expect(!PrivilegedOperation.createInstallMedia(tool: tool, volume: volume, applicationPath: URL(fileURLWithPath: "/Applications/Other.app")).isAllowed())

        let arguments = try AppleScriptPrivilegedExecutor.arguments(for: [.requireInstallMediaMarker(marker), create], reason: "r")
        #expect(arguments.suffix(9) == ["3", "/bin/test", "-f", marker.path, "4", tool.path, "--volume", volume.path, "--nointeraction"])
        // Never without the marker check of the same volume right before it.
        #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [create], reason: "r") }
        let otherMarker = URL(fileURLWithPath: "/Volumes/MRINSTALL-FFFFFFFF/.MacReplicaInstallTarget-\(UUID().uuidString)")
        #expect(throws: PrivilegedError.self) { try AppleScriptPrivilegedExecutor.arguments(for: [.requireInstallMediaMarker(otherMarker), create], reason: "r") }
        #expect(throws: PrivilegedError.self) {
            try AppleScriptPrivilegedExecutor.arguments(for: [.requireInstallMediaMarker(marker), .createFolder(URL(fileURLWithPath: "/tmp/x")), create], reason: "r")
        }
        #expect(throws: PrivilegedError.self) {
            try AppleScriptPrivilegedExecutor.arguments(for: [.createInstallMedia(tool: tool, volume: URL(fileURLWithPath: "/Volumes/Backup"), applicationPath: nil)], reason: "r")
        }
    }

    // MARK: The creation flow

    struct Flow {
        let setup: Setup
        let creator: InstallMediaCreator
        let recorder: PrivilegedRecorder
        let report: InstallerAppReport
        let drive: InstallMediaDrive
    }

    static func flow(_ name: String, prepare: (Setup) throws -> Void = { _ in }) async throws -> Flow {
        let s = try setup(name)
        let app = try s.sandbox.folder("Applications/Install macOS Sonoma.app")
        let tool = try s.sandbox.file("Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia", "#!/bin/sh\n", executable: true)
        s.drives.add("disk4", info: FakeDrives.usbStick("disk4"), volumes: [("STICK", nil, "Apple_HFS")])
        try prepare(s)
        let drives = s.drives
        let direct = DirectPrivilegedExecutor(toolRunner: { argv in
                                                  if argv.count > 1, argv[1] == "eraseVolume" { try drives.eraseVolume(argv) }
                                                  else { try drives.createInstallMedia(argv, installerName: "Install macOS Sonoma", appVersion: "19.8.9") } },
                                              volumesRoot: s.layout.volumesRoot, applicationFolders: s.layout.applicationFolders)
        let recorder = PrivilegedRecorder(direct)
        let inspector = InstallerInspector(layout: s.layout, runner: s.runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        let creator = InstallMediaCreator(layout: s.layout, runner: s.runner, privileged: recorder, scanner: s.scanner, inspector: inspector)
        let report = InstallerAppReport(app: app, displayName: "Install macOS Sonoma", appVersion: "19.8.9", macOSVersion: "14.8.9", build: "23J631",
                                        sizeBytes: 13 * gib, createInstallMedia: tool, supportsNoInteraction: true, toolArchitectures: [.arm64, .x86_64],
                                        signedByApple: true, hasInstallerPayload: true)
        let drive = try #require(try await s.scanner.scan(required: report.requiredBytes).first?.drive)
        return Flow(setup: s, creator: creator, recorder: recorder, report: report, drive: drive)
    }

    final class Stages: @unchecked Sendable {
        let lock = NSLock()
        var all: [InstallMediaStage] = []
        func add(_ stage: InstallMediaStage) { lock.withLock { all.append(stage) } }
    }

    @Test func aConfirmedDriveBecomesAVerifiedInstaller() async throws {
        let f = try await Self.flow("happy")
        let stages = Stages()
        let result = try await f.creator.create(installer: f.report, on: f.drive, stage: stages.add)
        #expect(stages.all == [.checkingInstaller, .checkingDrive, .erasing, .creating, .verifying])
        #expect(f.setup.drives.erased.count == 1)
        let erase = try #require(f.setup.runner.commands.first { $0.arguments.first == "eraseDisk" })
        #expect(erase.arguments.prefix(2) == ["eraseDisk", "JHFS+"])
        #expect(erase.arguments.suffix(2) == ["GPT", "disk4"])
        #expect(PrivilegedOperation.isInstallMediaVolumeName(erase.arguments[2]))
        #expect(f.recorder.calls.count == 1)
        guard case .requireInstallMediaMarker(let marker) = f.recorder.calls[0][0],
              case .createInstallMedia(_, let volume, let applicationPath) = f.recorder.calls[0][1] else { Issue.record("steps"); return }
        #expect(volume.lastPathComponent == erase.arguments[2])
        #expect(marker.deletingLastPathComponent().path == volume.path)
        #expect(applicationPath == nil)
        #expect(result.verification == .verified)
        #expect(result.checks.allSatisfy { $0.passed })
        #expect(result.volume?.lastPathComponent == "Install macOS Sonoma")
        // The real diskutil, sudo or a shell are never involved.
        #expect(f.setup.runner.commands.allSatisfy { $0.executable != "/usr/sbin/diskutil" && $0.executable != "/bin/sh" })
    }

    @Test func aSwappedDriveStopsBeforeAnythingIsErased() async throws {
        let f = try await Self.flow("swapped")
        f.setup.drives.add("disk4", info: FakeDrives.usbStick("disk4", name: "Photos SSD"), volumes: [("Photos", nil, "Apple_HFS")])
        await #expect(throws: InstallMediaError.drive(.driveChanged)) { try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in }) }
        #expect(f.setup.drives.erased.isEmpty)
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func aFailedEraseIsNotRetriedAndNeedsNoPassword() async throws {
        let f = try await Self.flow("erasefail")
        f.setup.drives.eraseFails = "Error: -69877: Couldn't open device"
        await #expect(throws: InstallMediaError.eraseFailed("Started erase on disk4\nError: -69877: Couldn't open device")) {
            try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in })
        }
        #expect(f.setup.runner.commands.filter { $0.arguments.first == "eraseDisk" }.count == 1)
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func passwordCancelAndToolFailureAreReportedOnce() async throws {
        struct Denying: PrivilegedExecuting { let error: PrivilegedError
            func run(_ operations: [PrivilegedOperation], reason: String) async throws { throw error } }
        for (error, expected) in [(PrivilegedError.denied, InstallMediaError.passwordDenied),
                                  (.failed("Making disk bootable...\nThe bless of the installer disk failed."), .createFailed("Making disk bootable...\nThe bless of the installer disk failed."))] {
            let f = try await Self.flow("denied")
            var creator = f.creator
            let recorder = PrivilegedRecorder(Denying(error: error))
            creator.privileged = recorder
            await #expect(throws: expected) { try await creator.create(installer: f.report, on: f.drive, stage: { _ in }) }
            #expect(recorder.calls.count == 1)
            #expect(f.setup.drives.erased.count == 1)
        }
    }

    @Test func anUnusableInstallerStopsBeforeTheDriveIsTouched() async throws {
        let f = try await Self.flow("unusable")
        var report = f.report
        report.signedByApple = false
        report.signatureDetail = "code has no resources but signature indicates they must be present"
        report.supportsNoInteraction = false
        report.toolArchitectures = [.x86_64]
        report.hasInstallerPayload = false
        await #expect(throws: InstallMediaError.installerUnusable([.notSignedByApple(report.signatureDetail), .toolNeedsInteraction, .needsRosetta, .payloadMissing])) {
            try await f.creator.create(installer: report, on: f.drive, stage: { _ in })
        }
        report.createInstallMedia = nil
        report.signedByApple = true
        await #expect(throws: InstallMediaError.installerUnusable([.noCreateInstallMedia])) { try await f.creator.create(installer: report, on: f.drive, stage: { _ in }) }
        #expect(f.setup.runner.commands.allSatisfy { $0.arguments.first != "eraseDisk" })
    }

    @Test func aSimulatedMacNeverUsesTheRealDiskutil() async throws {
        let f = try await Self.flow("realdiskutil")
        var creator = f.creator
        creator.layout.diskutil = "/usr/sbin/diskutil"
        await #expect(throws: InstallMediaError.self) { try await creator.create(installer: f.report, on: f.drive, stage: { _ in }) }
        #expect(f.setup.drives.erased.isEmpty)
    }

    @Test func aDriveWithoutTheInstallerFailsVerification() async throws {
        let f = try await Self.flow("verify")
        // createinstallmedia "succeeded" but left nothing.
        var drive = f.drive
        drive.volumes = []
        let result = await f.creator.verify(drive: drive, installer: f.report)
        #expect(result.verification == .failed)
        #expect(result.checks.map(\.item) == [.volumeOnDrive])

        _ = try await f.creator.create(installer: f.report, on: f.drive, stage: { _ in })
        f.setup.drives.codesignFails = true
        #expect(await f.creator.verify(drive: f.drive, installer: f.report).verification == .failed)
        f.setup.drives.codesignFails = false
        f.setup.drives.blessOutput = "bless: For Apple Silicon Macs, the 'info' option is only supported for external devices."
        let unblessed = await f.creator.verify(drive: f.drive, installer: f.report)
        #expect(unblessed.verification == .partiallyVerified)
        var newer = f.report
        newer.appVersion = "19.9"
        #expect(await f.creator.verify(drive: f.drive, installer: newer).verification == .failed)
    }

    @Test func olderInstallersAreGivenTheirOwnPath() async throws {
        let f = try await Self.flow("older")
        var report = f.report
        report.needsApplicationPath = true
        _ = try await f.creator.create(installer: report, on: f.drive, stage: { _ in })
        guard case .createInstallMedia(_, _, let applicationPath) = f.recorder.calls.first?.last else { Issue.record("no create"); return }
        #expect(applicationPath == report.app)
    }

    // MARK: Download

    @Test func downloadProgressAndFailures() async throws {
        #expect(InstallMediaCreator.downloadPercent(in: "Installing: 45.0%") == 45)
        #expect(InstallMediaCreator.downloadPercent(in: "Downloading: 3%") == 3)
        #expect(InstallMediaCreator.downloadPercent(in: "Installing: 145.0%") == 100)
        #expect(InstallMediaCreator.downloadPercent(in: "Scanning for 14.8.9 installer") == nil)

        let s = try Self.setup("download")
        let release = MacOSRelease(name: "macOS Sonoma", major: "14", version: "14.8.9", build: "23J631", source: .softwareUpdate, provenance: "")
        let inspector = InstallerInspector(layout: s.layout, runner: s.runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        func creator(_ answer: @escaping @Sendable (Command) -> CommandResult) -> (InstallMediaCreator, ScriptedRunner) {
            let runner = ScriptedRunner(handler: answer)
            return (InstallMediaCreator(layout: s.layout, runner: runner, privileged: DirectPrivilegedExecutor(), scanner: s.scanner, inspector: inspector), runner)
        }
        let (failing, _) = creator { _ in CommandResult(exitCode: 0, stdout: "Install failed with error: Update not found", stderr: "") }
        await #expect(throws: InstallMediaError.downloadFailed("Install failed with error: Update not found")) { try await failing.download(release, progress: { _ in }) }
        let (missing, runner) = creator { _ in CommandResult(exitCode: 0, stdout: "Install finished successfully", stderr: "") }
        await #expect(throws: InstallMediaError.installerNotFound("Install macOS Sonoma.app")) { try await missing.download(release, progress: { _ in }) }
        #expect(runner.commands.first?.arguments == ["--fetch-full-installer", "--full-installer-version", "14.8.9"])
        try s.sandbox.file("Applications/Install macOS Sonoma.app/Contents/Info.plist", "<plist/>")
        #expect(try await missing.download(release, progress: { _ in }).lastPathComponent == "Install macOS Sonoma.app")
        var page = release
        page.source = .appStore(id: 1, url: "macappstores://apps.apple.com/app/id1?mt=12")
        await #expect(throws: InstallMediaError.self) { try await missing.download(page, progress: { _ in }) }
        var hostile = release
        hostile.version = "14.8.9 --catalog x"
        await #expect(throws: InstallMediaError.self) { try await missing.download(hostile, progress: { _ in }) }
    }

    @Test func progressRedrawnWithCarriageReturnsArrivesLineByLine() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/printf"]), baseEnvironment: [:])
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } } }
        let lines = Lines()
        _ = try await runner.run(Command(executable: "/usr/bin/printf", arguments: ["Scanning\\n\\rInstalling: 1.0%%\\rInstalling: 2.0%%\\r\\nDone\\n"]), onOutputLine: lines.add)
        #expect(lines.all == ["Scanning", "", "Installing: 1.0%", "Installing: 2.0%", "Done"])
    }

    /// Found on screen: the download's percentage only appeared at the end, because the output was read in 64 KB
    /// blocks. Lines must arrive while the tool still runs.
    @Test func outputLinesArriveWhileTheToolRuns() async throws {
        let sandbox = try Sandbox("live-output")
        let tool = try sandbox.file("slowtool", "#!/bin/bash\nprintf 'Installing: 1.0%%\\r'\nsleep 2\nprintf 'Installing: 2.0%%\\r'\n", executable: true)
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [tool.path]), baseEnvironment: [:])
        final class Arrivals: @unchecked Sendable { let lock = NSLock(); var all: [(String, Date)] = []
            func add(_ line: String) { lock.withLock { all.append((line, Date())) } } }
        let arrivals = Arrivals()
        let started = Date()
        _ = try await runner.run(Command(executable: tool.path), onOutputLine: arrivals.add)
        let first = try #require(arrivals.all.first { $0.0 == "Installing: 1.0%" })
        #expect(first.1.timeIntervalSince(started) < 1.5)
        #expect(arrivals.all.map(\.0) == ["Installing: 1.0%", "Installing: 2.0%"])
    }

    /// The installer check asks codesign for Apple's signature on the tool (strict) and on the app (not strict:
    /// Apple's installer apps use resource rules `--strict` rejects), runs the tool only after its signature passed,
    /// and reads its options from what it prints.
    @Test func theInstallerCheckUsesApplesRequirementAndTheToolsOwnUsage() async throws {
        let sandbox = try Sandbox("inspect")
        let layout = toolchainLayout(sandbox)
        let app = try sandbox.folder("Applications/Install macOS Sonoma.app")
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleDisplayName</key><string>Install macOS Sonoma</string>\
        <key>CFBundleShortVersionString</key><string>19.8.62</string></dict></plist>
        """)
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/SharedSupport/InstallInfo.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>System Image Info</key><dict><key>version</key><string>14.8.9</string></dict></dict></plist>
        """)
        try sandbox.file("Applications/Install macOS Sonoma.app/Contents/SharedSupport/SharedSupport.dmg", "x")
        let tool = try sandbox.file("Applications/Install macOS Sonoma.app/Contents/Resources/createinstallmedia", "#!/bin/sh\n", executable: true)
        final class Answers: @unchecked Sendable { var toolSigned = true; var usage = "--volume\n--nointeraction\n--downloadassets" }
        let answers = Answers()
        let runner = ScriptedRunner { command in
            if command.executable == layout.codesign {
                let ok = command.arguments.last == tool.path ? answers.toolSigned : true
                return CommandResult(exitCode: ok ? 0 : 1, stdout: "", stderr: ok ? "" : "invalid signature (code or signature have been modified)")
            }
            if command.executable == tool.path { return CommandResult(exitCode: 0, stdout: answers.usage, stderr: "") }
            return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
        let inspector = InstallerInspector(layout: layout, runner: runner, environment: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64), hasRosetta: false)
        let report = await inspector.inspect(app)
        let signatureChecks = runner.commands.filter { $0.executable == layout.codesign }.map(\.arguments)
        #expect(signatureChecks == [["--verify", "--strict", "-R=" + InstallerInspector.appleRequirement, tool.path],
                                    ["--verify", "--no-strict", "-R=" + InstallerInspector.appleRequirement, app.path]])
        #expect(InstallerInspector.appleRequirement == #"anchor apple or (anchor apple generic and certificate leaf[subject.O] = "Apple Inc.")"#)
        #expect(runner.commands.filter { $0.executable == tool.path }.map(\.arguments) == [[]])
        #expect(report.signedByApple && report.supportsNoInteraction && !report.needsApplicationPath)
        #expect(report.macOSVersion == "14.8.9" && report.appVersion == "19.8.62" && report.displayName == "Install macOS Sonoma")
        #expect(inspector.problems(of: report) == [])

        // High Sierra and older: --applicationpath without --downloadassets.
        answers.usage = "--volume\n--applicationpath\n--nointeraction"
        #expect(await inspector.inspect(app).needsApplicationPath)
        // A tool that is not Apple's is never run.
        answers.toolSigned = false
        let before = runner.commands.filter { $0.executable == tool.path }.count
        let tampered = await inspector.inspect(app)
        #expect(runner.commands.filter { $0.executable == tool.path }.count == before)
        #expect(!tampered.signedByApple && !tampered.supportsNoInteraction)
        #expect(tampered.signatureDetail.hasPrefix("createinstallmedia: "))
        #expect(inspector.installer(for: MacOSRelease(name: "macOS Sonoma", major: "14", source: .softwareUpdate, provenance: ""))?.lastPathComponent == "Install macOS Sonoma.app")
        #expect(inspector.installer(for: MacOSRelease(name: "macOS Tahoe", major: "26", source: .softwareUpdate, provenance: "")) == nil)
    }
}
