import Foundation

/// A drive a bootable installer could be written to, as `diskutil` describes it.
///
/// Only whole external physical drives are ever offered. The startup disk, internal disks, disk images, drives with
/// a Time Machine backup or a MacReplica backup and drives MacReplica or the installer itself run from are shown as
/// protected with the reason, and can never be chosen. Creating an installer on a partition of the internal disk is
/// deliberately not offered (see docs/USER_GUIDE.md, “Why not on the internal disk”).
public struct InstallMediaDrive: Equatable, Sendable, Identifiable {
    public struct Volume: Equatable, Sendable {
        public var device: String
        public var name: String
        public var mountPoint: String?
        public var uuid: String?
        public var content: String
        public init(device: String, name: String, mountPoint: String? = nil, uuid: String? = nil, content: String = "") {
            self.device = device
            self.name = name
            self.mountPoint = mountPoint
            self.uuid = uuid
            self.content = content
        }
    }

    /// `disk4`.
    public var device: String
    /// `SanDisk Ultra` – what the drive calls itself.
    public var mediaName: String
    public var sizeBytes: Int64
    /// `USB`, `Thunderbolt`, `Disk Image`, …
    public var busProtocol: String
    public var isInternal: Bool
    public var isVirtual: Bool
    public var isWritable: Bool
    public var volumes: [Volume]

    public init(device: String, mediaName: String, sizeBytes: Int64, busProtocol: String, isInternal: Bool, isVirtual: Bool,
                isWritable: Bool, volumes: [Volume]) {
        self.device = device
        self.mediaName = mediaName
        self.sizeBytes = sizeBytes
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.isVirtual = isVirtual
        self.isWritable = isWritable
        self.volumes = volumes
    }

    public var id: String { device }

    /// What identifies this drive: if any of it differs right before erasing, MacReplica stops. Device numbers are
    /// reused when drives are plugged in and out, so the number alone is never enough.
    public var fingerprint: String {
        ([device, mediaName, String(sizeBytes), busProtocol] + volumes.map { "\($0.device)|\($0.uuid ?? "-")|\($0.name)" }).joined(separator: ";")
    }

    /// Only `disk` followed by a number: what may be handed to `diskutil`.
    public static func isWholeDiskIdentifier(_ text: String) -> Bool {
        text.range(of: #"^disk[0-9]{1,3}$"#, options: .regularExpression) != nil
    }
}

/// Why a drive cannot be chosen. Each is shown next to the drive.
public enum DriveProtection: Equatable, Sendable {
    case startupDisk
    case internalDisk
    case diskImage
    case readOnly
    /// The drive holds a volume MacReplica must not erase (its own app, the installer, the home folder, a backup).
    case holdsProtectedVolume(String)
    case timeMachine(String)
    case tooSmall(required: Int64)
}

public struct DriveCandidate: Equatable, Sendable, Identifiable {
    public var drive: InstallMediaDrive
    public var protections: [DriveProtection]
    public var id: String { drive.id }
    public var isEligible: Bool { protections.isEmpty }
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

    public init(layout: SystemLayout, runner: CommandRunning, allowsDiskImages: Bool = false, protectedPaths: [URL] = []) {
        self.layout = layout
        self.runner = runner
        self.allowsDiskImages = allowsDiskImages
        self.protectedPaths = protectedPaths
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

    /// Every external drive with what protects it. `required` is the space the installer needs.
    public func scan(required: Int64) async throws -> [DriveCandidate] {
        let startup = try await startupDisks()
        let list = try await plist(["list", "-plist", "external"])
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
            candidates.append(DriveCandidate(drive: drive, protections: protections(of: drive, startup: startup, required: required)))
        }
        return candidates.sorted { $0.drive.device.localizedStandardCompare($1.drive.device) == .orderedAscending }
    }

    static func isAPFSContainer(_ entry: [String: Any]) -> Bool {
        ["Apple_APFS_Container", "EF57347C-0000-11AA-AA11-00306543ECAC"].contains(entry["Content"] as? String ?? "") || entry["APFSPhysicalStores"] != nil
    }

    static func drive(device: String, list: [String: Any], info: [String: Any]) -> InstallMediaDrive {
        var volumes: [InstallMediaDrive.Volume] = []
        for partition in (list["Partitions"] as? [[String: Any]] ?? []) + (list["APFSVolumes"] as? [[String: Any]] ?? []) {
            guard let id = partition["DeviceIdentifier"] as? String else { continue }
            volumes.append(.init(device: id, name: partition["VolumeName"] as? String ?? "", mountPoint: partition["MountPoint"] as? String,
                                 uuid: partition["VolumeUUID"] as? String, content: partition["Content"] as? String ?? ""))
        }
        return InstallMediaDrive(device: device, mediaName: (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? "",
                                 sizeBytes: (info["TotalSize"] as? NSNumber)?.int64Value ?? (list["Size"] as? NSNumber)?.int64Value ?? 0,
                                 busProtocol: info["BusProtocol"] as? String ?? "",
                                 // Unknown counts as internal: only what diskutil calls external is ever offered.
                                 isInternal: (info["Internal"] as? Bool) ?? true,
                                 isVirtual: (info["VirtualOrPhysical"] as? String) != "Physical",
                                 isWritable: (info["WritableMedia"] as? Bool) ?? false, volumes: volumes)
    }

    public func protections(of drive: InstallMediaDrive, startup: Set<String>, required: Int64) -> [DriveProtection] {
        var result: [DriveProtection] = []
        if startup.contains(drive.device) { result.append(.startupDisk) }
        if drive.isInternal { result.append(.internalDisk) }
        if drive.isVirtual && !allowsDiskImages { result.append(.diskImage) }
        if !drive.isWritable { result.append(.readOnly) }
        let home = layout.homeDirectory.standardizedFileURL.path
        let protected = protectedPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } + [home]
        for volume in drive.volumes {
            guard let mount = volume.mountPoint, !mount.isEmpty else { continue }
            if mount == "/" { result.append(.startupDisk); continue }
            if let path = protected.first(where: { $0 == mount || $0.hasPrefix(mount + "/") }) {
                result.append(.holdsProtectedVolume(volume.name.isEmpty ? layout.redact(path) : volume.name))
            }
            let root = URL(fileURLWithPath: mount)
            let backup = FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups.backupdb").path)
                || FileManager.default.fileExists(atPath: root.appendingPathComponent(".com.apple.timemachine.supported").path)
                || volume.content.lowercased().contains("backup")
            if backup { result.append(.timeMachine(volume.name)) }
            if Self.holdsMacReplicaBackup(root) { result.append(.holdsProtectedVolume(volume.name)) }
        }
        if drive.sizeBytes < required { result.append(.tooSmall(required: required)) }
        return result
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

    /// Reads the drive again right before erasing. Throws unless it is the same drive and still eligible.
    public func revalidate(_ confirmed: InstallMediaDrive, required: Int64) async throws -> InstallMediaDrive {
        let current = try await scan(required: required).first { $0.drive.device == confirmed.device }
        guard let current, current.drive.fingerprint == confirmed.fingerprint else { throw InstallMediaDriveError.driveChanged }
        guard current.isEligible else { throw InstallMediaDriveError.driveNotEligible(current.protections) }
        return current.drive
    }
}
