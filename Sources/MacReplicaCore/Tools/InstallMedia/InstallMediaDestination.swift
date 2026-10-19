import Foundation

/// A drive a bootable installer could be written to, as `diskutil` describes it.
///
/// Normally only whole removable or external physical drives are offered: external drives, and cards in a built-in
/// reader (which macOS calls internal but removable). The startup disk, internal disks, disk images, drives with a
/// Time Machine backup or a MacReplica backup and drives MacReplica or the installer itself run from are shown as
/// protected with the reason, and can never be chosen. As an expert option, an **empty, separate partition** of an
/// internal disk can be chosen; only that partition is erased (see `partitionProtections`).
public struct InstallMediaDrive: Equatable, Sendable, Identifiable {
    public struct Volume: Equatable, Sendable {
        public var device: String
        public var name: String
        public var mountPoint: String?
        public var uuid: String?
        public var content: String
        /// The partition's GPT identifier (`DiskUUID`): stays the same when the partition is erased or renumbered.
        public var partitionUUID: String?
        public var sizeBytes: Int64
        public init(device: String, name: String, mountPoint: String? = nil, uuid: String? = nil, content: String = "",
                    partitionUUID: String? = nil, sizeBytes: Int64 = 0) {
            self.device = device
            self.name = name
            self.mountPoint = mountPoint
            self.uuid = uuid
            self.content = content
            self.partitionUUID = partitionUUID
            self.sizeBytes = sizeBytes
        }
    }

    /// `disk4`.
    public var device: String
    /// `SanDisk Ultra` – what the drive calls itself.
    public var mediaName: String
    public var sizeBytes: Int64
    /// `USB`, `Thunderbolt`, `Secure Digital`, `Disk Image`, …
    public var busProtocol: String
    public var isInternal: Bool
    /// Removable media (a card in a built-in reader is internal but removable).
    public var isRemovable: Bool
    public var isVirtual: Bool
    public var isWritable: Bool
    public var volumes: [Volume]

    public init(device: String, mediaName: String, sizeBytes: Int64, busProtocol: String, isInternal: Bool, isRemovable: Bool = false,
                isVirtual: Bool, isWritable: Bool, volumes: [Volume]) {
        self.device = device
        self.mediaName = mediaName
        self.sizeBytes = sizeBytes
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isVirtual = isVirtual
        self.isWritable = isWritable
        self.volumes = volumes
    }

    public var id: String { device }

    /// What identifies this drive: if any of it differs right before erasing, MacReplica stops. Device numbers are
    /// reused when drives are plugged in and out, so the number alone is never enough.
    public var fingerprint: String {
        ([device, mediaName, String(sizeBytes), busProtocol] + volumes.map { "\($0.device)|\($0.uuid ?? "-")|\($0.partitionUUID ?? "-")|\($0.name)" })
            .joined(separator: ";")
    }

    /// Internal and not removable: the Mac's own disk. Only its empty partitions can be chosen, as an expert option.
    public var isFixedInternal: Bool { isInternal && !isRemovable }

    /// Only `disk` followed by a number: what may be handed to `diskutil`.
    public static func isWholeDiskIdentifier(_ text: String) -> Bool {
        text.range(of: #"^disk[0-9]{1,3}$"#, options: .regularExpression) != nil
    }

    /// A GPT partition identifier as diskutil prints it.
    public static func isPartitionUUID(_ text: String) -> Bool {
        text.range(of: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#, options: .regularExpression) != nil
    }
}

/// Why a drive or partition cannot be chosen. Each is shown next to it.
public enum DriveProtection: Equatable, Sendable {
    case startupDisk
    case internalDisk
    case diskImage
    case readOnly
    /// The drive holds a volume MacReplica must not erase (its own app, the installer, the home folder, a backup).
    case holdsProtectedVolume(String)
    case timeMachine(String)
    case tooSmall(required: Int64)
    // Partitions of an internal disk (expert option):
    /// APFS volumes share their container's space with the Mac's own data; MacReplica never erases one.
    case apfsVolume
    /// EFI, Recovery, boot helpers and other partitions macOS needs.
    case systemPartition
    case unsupportedFormat(String)
    /// Not mounted, so MacReplica cannot see whether it is empty.
    case notMounted
    /// Holds this many visible items.
    case notEmpty(Int)
    /// macOS has not (yet) let MacReplica look inside this volume (a privacy question may be waiting).
    case notReadable(String)
}

public struct DriveCandidate: Equatable, Sendable, Identifiable {
    public var drive: InstallMediaDrive
    /// The partition to erase, for the expert option; nil for the whole drive.
    public var partition: InstallMediaDrive.Volume?
    public var protections: [DriveProtection]

    public init(drive: InstallMediaDrive, partition: InstallMediaDrive.Volume? = nil, protections: [DriveProtection]) {
        self.drive = drive
        self.partition = partition
        self.protections = protections
    }

    public var id: String { partition?.device ?? drive.id }
    public var isEligible: Bool { protections.isEmpty }
    public var isPartition: Bool { partition != nil }
}

public enum InstallMediaDriveError: Error, Equatable, Sendable {
    case listFailed(String)
    /// The drive is no longer the one the user confirmed (unplugged, replaced or changed).
    case driveChanged
    case driveNotEligible([DriveProtection])
}

/// Finds drives with `diskutil` (read-only: `list`, `info`).
public struct InstallMediaDriveScanner: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    /// Disk images may be targets only for MacReplica's own tests of the real `createinstallmedia`; the app never sets it.
    public var allowsDiskImages: Bool
    /// Mount points of volumes that must survive: MacReplica itself, the installer, the last backup.
    public var protectedPaths: [URL]
    /// Expert option: also list the partitions of internal disks (only empty, separate ones can be chosen).
    public var includeInternalPartitions: Bool
    /// For MacReplica's own tests on a disk image: treat its partitions like those of an internal disk.
    public var partitionsOfDiskImages: Bool

    public init(layout: SystemLayout, runner: CommandRunning, allowsDiskImages: Bool = false, protectedPaths: [URL] = [],
                includeInternalPartitions: Bool = false, partitionsOfDiskImages: Bool = false) {
        self.layout = layout
        self.runner = runner
        self.allowsDiskImages = allowsDiskImages
        self.protectedPaths = protectedPaths
        self.includeInternalPartitions = includeInternalPartitions
        self.partitionsOfDiskImages = partitionsOfDiskImages
    }

    func plist(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await runner.run(Command(executable: layout.diskutil, arguments: arguments, timeout: 60))
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InstallMediaDriveError.listFailed(layout.redact(ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout, maxLines: 2)))
        }
        return plist
    }

    /// The whole disks the startup volume lives on (`/` → its APFS container → the physical store's whole disk).
    func startupDisks() async throws -> Set<String> {
        let root = try await plist(["info", "-plist", "/"])
        var disks = Set<String>()
        if let parent = root["ParentWholeDisk"] as? String { disks.insert(parent) }
        for store in root["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
            if let device = store["APFSPhysicalStore"] as? String { disks.insert(Self.wholeDisk(of: device)) }
        }
        return disks
    }

    /// `disk0s2` → `disk0`.
    static func wholeDisk(of device: String) -> String {
        guard let match = device.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return device }
        return String(device[match])
    }

    /// Every drive that could hold an installer, with what protects it. `required` is the space the installer needs.
    /// Internal, non-removable disks are not offered as a whole; with the expert option their partitions are listed.
    public func scan(required: Int64) async throws -> [DriveCandidate] {
        let startup = try await startupDisks()
        // All disks: a card in a built-in reader is listed as internal, so `list external` would miss it.
        let list = try await plist(["list", "-plist"])
        let entries = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        // An APFS container is listed as a disk of its own (“synthesized”); its volumes belong to the drive it lives on.
        var containerVolumes: [String: [String: Any]] = [:]
        for entry in entries where Self.isAPFSContainer(entry) {
            for store in entry["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
                guard let device = store["DeviceIdentifier"] as? String else { continue }
                var merged = containerVolumes[Self.wholeDisk(of: device), default: [:]]
                merged["APFSVolumes"] = (merged["APFSVolumes"] as? [[String: Any]] ?? []) + (entry["APFSVolumes"] as? [[String: Any]] ?? [])
                containerVolumes[Self.wholeDisk(of: device)] = merged
            }
        }
        var candidates: [DriveCandidate] = []
        for entry in entries where !Self.isAPFSContainer(entry) {
            guard let device = entry["DeviceIdentifier"] as? String, InstallMediaDrive.isWholeDiskIdentifier(device) else { continue }
            let info = try await plist(["info", "-plist", device])
            var listed = entry
            listed["APFSVolumes"] = (entry["APFSVolumes"] as? [[String: Any]] ?? []) + (containerVolumes[device]?["APFSVolumes"] as? [[String: Any]] ?? [])
            let drive = Self.drive(device: device, list: listed, info: info)
            let partitionsHere = drive.isVirtual ? partitionsOfDiskImages : (includeInternalPartitions && drive.isFixedInternal)
            if partitionsHere {
                for partition in drive.volumes where Self.isPartition(partition, of: drive) {
                    candidates.append(DriveCandidate(drive: drive, partition: partition,
                                                     protections: partitionProtections(of: partition, on: drive, startup: startup, required: required)))
                }
                continue
            }
            if drive.isFixedInternal && !drive.isVirtual { continue }
            candidates.append(DriveCandidate(drive: drive, protections: protections(of: drive, startup: startup, required: required)))
        }
        return candidates.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func isAPFSContainer(_ entry: [String: Any]) -> Bool {
        ["Apple_APFS_Container", "EF57347C-0000-11AA-AA11-00306543ECAC"].contains(entry["Content"] as? String ?? "") || entry["APFSPhysicalStores"] != nil
    }

    /// A partition of this disk itself (`disk0s4`), not an APFS volume of a container on it (`disk3s1`).
    static func isPartition(_ volume: InstallMediaDrive.Volume, of drive: InstallMediaDrive) -> Bool {
        volume.device.range(of: "^\(drive.device)s[0-9]+$", options: .regularExpression) != nil
    }

    static func drive(device: String, list: [String: Any], info: [String: Any]) -> InstallMediaDrive {
        var volumes: [InstallMediaDrive.Volume] = []
        for partition in (list["Partitions"] as? [[String: Any]] ?? []) + (list["APFSVolumes"] as? [[String: Any]] ?? []) {
            guard let id = partition["DeviceIdentifier"] as? String else { continue }
            volumes.append(.init(device: id, name: partition["VolumeName"] as? String ?? "", mountPoint: partition["MountPoint"] as? String,
                                 uuid: partition["VolumeUUID"] as? String, content: partition["Content"] as? String ?? "",
                                 partitionUUID: partition["DiskUUID"] as? String, sizeBytes: (partition["Size"] as? NSNumber)?.int64Value ?? 0))
        }
        return InstallMediaDrive(device: device, mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? "",
                                 sizeBytes: (info["TotalSize"] as? NSNumber)?.int64Value ?? (list["Size"] as? NSNumber)?.int64Value ?? 0,
                                 busProtocol: info["BusProtocol"] as? String ?? "",
                                 // Unknown counts as internal and not removable: such a disk is never offered whole.
                                 isInternal: (info["Internal"] as? Bool) ?? true,
                                 isRemovable: (info["RemovableMedia"] as? Bool) ?? false,
                                 // Apple's internal SSDs report “Unknown” (macOS 27, Apple Fabric); only “Virtual” is a disk image.
                                 isVirtual: (info["VirtualOrPhysical"] as? String) == "Virtual" || (info["BusProtocol"] as? String) == "Disk Image",
                                 isWritable: (info["WritableMedia"] as? Bool) ?? false, volumes: volumes)
    }

    public func protections(of drive: InstallMediaDrive, startup: Set<String>, required: Int64) -> [DriveProtection] {
        var result: [DriveProtection] = []
        if startup.contains(drive.device) { result.append(.startupDisk) }
        if drive.isFixedInternal { result.append(.internalDisk) }
        if drive.isVirtual && !allowsDiskImages { result.append(.diskImage) }
        if !drive.isWritable { result.append(.readOnly) }
        for volume in drive.volumes { result += contentProtections(of: volume) }
        if drive.sizeBytes < required { result.append(.tooSmall(required: required)) }
        return result
    }

    /// How long a look inside a volume may take. Reading a card or another user's folder can make macOS ask the
    /// user for permission, and the read waits until it is answered (seen with an SD card on macOS 27).
    public var lookTimeout: TimeInterval = 5

    /// Runs a file-system look with a time limit; nil if it did not finish (the waiting read finishes on its own
    /// thread once macOS answers).
    static func withTimeout<T>(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> T) -> T? {
        let box = TimeoutBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            let value = body()
            box.lock.withLock { box.value = value }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.lock.withLock { box.value }
    }

    /// What a mounted volume holds that must never be erased.
    func contentProtections(of volume: InstallMediaDrive.Volume) -> [DriveProtection] {
        guard let mount = volume.mountPoint, !mount.isEmpty else { return [] }
        if mount == "/" { return [.startupDisk] }
        let name = volume.name.isEmpty ? volume.device : volume.name
        let root = URL(fileURLWithPath: mount)
        guard let found = Self.withTimeout(lookTimeout, {
            (backupdb: FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups.backupdb").path),
             timeMachine: FileManager.default.fileExists(atPath: root.appendingPathComponent(".com.apple.timemachine.supported").path),
             macReplica: Self.holdsMacReplicaBackup(root))
        }) else { return [.notReadable(name)] }
        var result: [DriveProtection] = []
        let home = layout.homeDirectory.standardizedFileURL.path
        let protected = protectedPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } + [home]
        if let path = protected.first(where: { $0 == mount || $0.hasPrefix(mount + "/") }) {
            result.append(.holdsProtectedVolume(volume.name.isEmpty ? layout.redact(path) : volume.name))
        }
        if found.backupdb || found.timeMachine || volume.content.lowercased().contains("backup") { result.append(.timeMachine(volume.name)) }
        if found.macReplica { result.append(.holdsProtectedVolume(volume.name)) }
        return result
    }

    /// Partition formats that can be separate, plain partitions; `createinstallmedia` replaces them with Mac OS
    /// Extended. Everything APFS, and every partition macOS needs, is refused.
    static let plainPartitionContents: Set<String> = ["Apple_HFS", "Apple_HFSX", "Microsoft Basic Data", "Windows_FAT_32", "DOS_FAT_32",
                                                      "Windows_FAT_16", "DOS_FAT_16", "Windows_NTFS", "ExFAT"]
    static let systemPartitionContents: Set<String> = ["EFI", "Apple_Boot", "Apple_APFS_Recovery", "Apple_KernelCoreDump", "Apple_CoreStorage",
                                                       "Apple_partition_map", "Apple_Free", "Microsoft Reserved", "Windows Recovery"]

    /// Expert option: only an empty, separate, plain partition that holds nothing MacReplica protects.
    public func partitionProtections(of partition: InstallMediaDrive.Volume, on drive: InstallMediaDrive, startup: Set<String>,
                                     required: Int64) -> [DriveProtection] {
        var result: [DriveProtection] = []
        if partition.content.hasPrefix("Apple_APFS") { result.append(.apfsVolume) }
        else if Self.systemPartitionContents.contains(partition.content) { result.append(.systemPartition) }
        else if !Self.plainPartitionContents.contains(partition.content) { result.append(.unsupportedFormat(partition.content)) }
        if drive.isVirtual && !allowsDiskImages { result.append(.diskImage) }
        if !drive.isWritable { result.append(.readOnly) }
        if partition.partitionUUID.map(InstallMediaDrive.isPartitionUUID) != true, result.isEmpty { result.append(.systemPartition) }
        guard result.isEmpty else { return result }
        guard let mount = partition.mountPoint, !mount.isEmpty else { return [.notMounted] }
        result += contentProtections(of: partition)
        let folder = URL(fileURLWithPath: mount)
        guard let visible = Self.withTimeout(lookTimeout, { Self.visibleItems(in: folder) }) else {
            return result + [.notReadable(partition.name.isEmpty ? partition.device : partition.name)]
        }
        if visible > 0 { result.append(.notEmpty(visible)) }
        if partition.sizeBytes < required { result.append(.tooSmall(required: required)) }
        return result
    }

    /// Items a user put there: everything except the hidden bookkeeping macOS and Windows create on every volume.
    static func visibleItems(in folder: URL) -> Int {
        let ignored: Set<String> = ["System Volume Information", "$RECYCLE.BIN", "Desktop DB", "Desktop DF"]
        // An unreadable folder counts as not empty.
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 1 }
        return items.filter { !$0.hasPrefix(".") && !ignored.contains($0) }.count
    }

    /// A MacReplica backup directly on the volume or one folder down (`MacReplica Backup/MacReplica-Backup-…`).
    static func holdsMacReplicaBackup(_ root: URL) -> Bool {
        let fm = FileManager.default
        func hasBackup(_ folder: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).contains {
                $0.hasPrefix("MacReplica-Backup-") && fm.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("manifest.json").path)
            }
        }
        if hasBackup(root) { return true }
        for child in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !child.hasPrefix(".") {
            if hasBackup(root.appendingPathComponent(child)) { return true }
            for grandchild in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(child).path)) ?? [] where grandchild.hasPrefix("MacReplica") {
                if hasBackup(root.appendingPathComponent(child).appendingPathComponent(grandchild)) { return true }
            }
        }
        return false
    }

    /// Reads the drive again right before erasing. Throws unless it is the same drive (and the same partition) and
    /// still eligible.
    public func revalidate(_ confirmed: DriveCandidate, required: Int64) async throws -> DriveCandidate {
        let current = try await scan(required: required).first { $0.id == confirmed.id }
        guard let current, current.drive.fingerprint == confirmed.drive.fingerprint, current.partition == confirmed.partition else {
            throw InstallMediaDriveError.driveChanged
        }
        guard current.isEligible else { throw InstallMediaDriveError.driveNotEligible(current.protections) }
        return current
    }

    /// The whole-drive form, as before.
    public func revalidate(_ confirmed: InstallMediaDrive, required: Int64) async throws -> InstallMediaDrive {
        try await revalidate(DriveCandidate(drive: confirmed, protections: []), required: required).drive
    }
}

/// The result of a look that may outlive its time limit.
private final class TimeoutBox<T>: @unchecked Sendable {
    var value: T?
    let lock = NSLock()
}
