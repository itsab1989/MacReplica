@preconcurrency import ColorSync
import CoreGraphics
import CryptoKit
import Foundation
import IOKit

/// A display as ColorSync knows it on this Mac.
public struct DisplayDevice: Equatable, Sendable {
    /// ColorSync's device ID for the display (the same value as `CGDisplayCreateUUIDFromDisplayID`).
    public var uuid: String
    public var name: String?
    /// True for a Mac's built-in display; nil when unknown (the display is not connected).
    public var isBuiltIn: Bool?
    public var isConnected: Bool
    /// The profile the user assigned (System Settings › Displays › Color profile), if any.
    public var customProfile: URL?

    public init(uuid: String, name: String? = nil, isBuiltIn: Bool? = nil, isConnected: Bool = true, customProfile: URL? = nil) {
        self.uuid = uuid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isConnected = isConnected
        self.customProfile = customProfile
    }
}

/// Reads and sets display profile assignments. The live implementation uses Apple's public ColorSync
/// device API in the current user's scope; tests and the simulation use a file-based stand-in.
public protocol DisplayColorManaging: Sendable {
    /// Displays ColorSync knows, connected or not.
    func displays() -> [DisplayDevice]
    /// Assigns `profile` to the display (current user only). Returns what ColorSync reports afterwards.
    func assign(_ profile: URL, toDisplay uuid: String) -> Bool
    /// The Mac's hardware identifier (`IOPlatformUUID`); only ever stored as a salted hash.
    func platformIdentifier() -> String?
}

/// Identifiers that let a later restore recognise the same Mac and the same displays without storing them:
/// only salted SHA-256 values are written to the backup.
public struct HardwareKeys: Codable, Equatable, Hashable, Sendable {
    /// Random per backup, so the values cannot be compared across backups.
    public var salt: String
    /// Salted hash of the Mac's hardware identifier; nil if it could not be read.
    public var macKey: String?

    public init(salt: String, macKey: String?) {
        self.salt = salt
        self.macKey = macKey
    }

    public static func make(platformIdentifier: String?) -> HardwareKeys {
        let salt = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return HardwareKeys(salt: salt, macKey: platformIdentifier.map { key(salt: salt, value: $0) })
    }

    public static func key(salt: String, value: String) -> String {
        SHA256.hash(data: Data((salt + "|" + value.uppercased()).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func key(for value: String) -> String { Self.key(salt: salt, value: value) }

    /// Whether the backup was made on this Mac. Nil when either side has no hardware identifier.
    public func isSameMac(platformIdentifier: String?) -> Bool? {
        guard let macKey, let platformIdentifier else { return nil }
        return macKey == key(for: platformIdentifier)
    }
}

/// The profile a display used on the old Mac.
public struct DisplayProfileAssignment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum ProfileSource: String, Codable, Sendable {
        /// A profile file in the user's or the shared ColorSync folder; it is part of the backup.
        case backedUp
        /// A profile macOS itself provides (`/System/Library/ColorSync/Profiles`), assigned by path.
        case macOS
    }

    public var id: String { displayKey }
    /// Salted hash of the display's ColorSync ID (see `HardwareKeys`).
    public var displayKey: String
    /// The display's name as macOS shows it, e.g. "Studio Display".
    public var displayName: String?
    public var isBuiltIn: Bool?
    public var source: ProfileSource
    /// For backed-up profiles: the profile's `FileRecord.id` (e.g. `user/Calibrated.icc`) and checksum.
    public var profileFileID: String?
    public var profileSHA256: String?
    /// For macOS profiles: the path below `/System/Library/ColorSync/Profiles`.
    public var macOSProfile: String?
    public var profileDescription: String?

    public init(displayKey: String, displayName: String?, isBuiltIn: Bool?, source: ProfileSource, profileFileID: String? = nil,
                profileSHA256: String? = nil, macOSProfile: String? = nil, profileDescription: String? = nil) {
        self.displayKey = displayKey
        self.displayName = displayName
        self.isBuiltIn = isBuiltIn
        self.source = source
        self.profileFileID = profileFileID
        self.profileSHA256 = profileSHA256
        self.macOSProfile = macOSProfile
        self.profileDescription = profileDescription
    }

    // "profileSha256" so that the snake_case manifest key round-trips.
    private enum CodingKeys: String, CodingKey {
        case displayKey, displayName, isBuiltIn, source, profileFileID = "profileFileId", profileSHA256 = "profileSha256", macOSProfile = "macOsProfile"
        case profileDescription
    }
}

/// Finds the profile assignments worth keeping: user-assigned profiles that are either in the backup or
/// provided by macOS. Factory assignments and macOS-generated display profiles are left out — macOS
/// creates those itself on every Mac.
public enum DisplayProfileScanner {
    public static func assignments(displays: [DisplayDevice], profiles: [FileRecord], layout: SystemLayout,
                                   keys: HardwareKeys) -> [DisplayProfileAssignment] {
        var result: [DisplayProfileAssignment] = []
        for display in displays {
            guard let url = display.customProfile?.standardizedFileURL else { continue }
            let path = layout.displayPath(url)
            var assignment = DisplayProfileAssignment(displayKey: keys.key(for: display.uuid), displayName: display.name,
                                                      isBuiltIn: display.isBuiltIn, source: .backedUp)
            if let record = profiles.first(where: { $0.originalPath == path }) {
                guard record.origin != .displayGenerated else { continue }
                assignment.profileFileID = record.id
                assignment.profileSHA256 = record.sha256
                assignment.profileDescription = record.profile?.description
            } else if let relative = FileScanner.relativePath(of: url, below: layout.macOSColorProfiles) {
                assignment.source = .macOS
                assignment.macOSProfile = relative
            } else {
                continue
            }
            if !result.contains(where: { $0.displayKey == assignment.displayKey }) { result.append(assignment) }
        }
        return result
    }
}

/// ColorSync on this Mac. Reading uses `ColorSyncIterateDeviceProfiles` and `ColorSyncDeviceCopyDeviceInfo`;
/// assigning uses `ColorSyncDeviceSetCustomProfiles` in the current user's scope — the same setting
/// System Settings › Displays › Color profile changes.
public struct LiveDisplayColorManager: DisplayColorManaging {
    public init() {}

    private final class Collector { var devices: [String: DisplayDevice] = [:] }

    public func displays() -> [DisplayDevice] {
        let collector = Collector()
        ColorSyncIterateDeviceProfiles({ info, context in
            guard let context, let info = info as? [String: Any],
                  info[kColorSyncDeviceClass.takeUnretainedValue() as String] as? String == kColorSyncDisplayDeviceClass.takeUnretainedValue() as String,
                  let id = info[kColorSyncDeviceID.takeUnretainedValue() as String] else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            let uuid = CFUUIDCreateString(nil, (id as! CFUUID)) as String
            let name = info[kColorSyncDeviceDescription.takeUnretainedValue() as String] as? String
            if collector.devices[uuid] == nil { collector.devices[uuid] = DisplayDevice(uuid: uuid, name: name, isConnected: false) }
            return true
        }, Unmanaged.passUnretained(collector).toOpaque())
        // Connected displays: built-in flag, and present even before ColorSync lists them.
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids.prefix(Int(count)) {
            let uuid = CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()) as String
            var device = collector.devices[uuid] ?? DisplayDevice(uuid: uuid)
            device.isConnected = true
            device.isBuiltIn = CGDisplayIsBuiltin(id) != 0
            collector.devices[uuid] = device
        }
        for (uuid, device) in collector.devices {
            var updated = device
            updated.customProfile = Self.customProfile(uuid: uuid)
            collector.devices[uuid] = updated
        }
        return collector.devices.values.sorted { $0.uuid < $1.uuid }
    }

    static func customProfile(uuid: String) -> URL? {
        guard let id = CFUUIDCreateFromString(nil, uuid as CFString),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), id)?.takeRetainedValue() as? [String: Any],
              let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] else { return nil }
        let value = custom["1"] ?? custom[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] ?? custom.values.first
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(fileURLWithPath: string) }
        return nil
    }

    public func assign(_ profile: URL, toDisplay uuid: String) -> Bool {
        guard let id = CFUUIDCreateFromString(nil, uuid as CFString) else { return false }
        let info: [String: Any] = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: profile as CFURL,
                                   kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser]
        guard ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), id, info as CFDictionary) else { return false }
        return Self.customProfile(uuid: uuid)?.standardizedFileURL.resolvingSymlinksInPath() == profile.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func platformIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

/// A stand-in for tests and the simulation: displays and assignments in `<root>/state/colorsync.json`.
public struct SimulatedDisplayColorManager: DisplayColorManaging {
    public struct State: Codable {
        public struct Display: Codable {
            public var uuid: String
            public var name: String?
            public var builtIn: Bool?
            public var connected: Bool
            public var profile: String?

            public init(uuid: String, name: String?, builtIn: Bool?, connected: Bool, profile: String?) {
                self.uuid = uuid
                self.name = name
                self.builtIn = builtIn
                self.connected = connected
                self.profile = profile
            }
        }
        public var platform: String?
        public var displays: [Display]
        public var refuseAssignments: Bool?

        public init(platform: String?, displays: [Display], refuseAssignments: Bool?) {
            self.platform = platform
            self.displays = displays
            self.refuseAssignments = refuseAssignments
        }
    }

    public var file: URL

    public init(file: URL) { self.file = file }

    public func load() -> State? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public func displays() -> [DisplayDevice] {
        (load()?.displays ?? []).map {
            DisplayDevice(uuid: $0.uuid, name: $0.name, isBuiltIn: $0.builtIn, isConnected: $0.connected,
                          customProfile: $0.profile.map { URL(fileURLWithPath: $0) })
        }
    }

    public func assign(_ profile: URL, toDisplay uuid: String) -> Bool {
        guard var state = load(), state.refuseAssignments != true,
              let index = state.displays.firstIndex(where: { $0.uuid == uuid && $0.connected }) else { return false }
        state.displays[index].profile = profile.path
        guard let data = try? JSONEncoder().encode(state), (try? data.write(to: file, options: .atomic)) != nil else { return false }
        return true
    }

    public func platformIdentifier() -> String? { load()?.platform }
}

extension SystemLayout {
    /// The ColorSync access for this layout: always the simulated one inside a simulation or test sandbox,
    /// so tests never read or change the real Mac's display settings.
    public var displayColorManager: DisplayColorManaging {
        if let root = simulationRoot { return SimulatedDisplayColorManager(file: root.appendingPathComponent("state/colorsync.json")) }
        return LiveDisplayColorManager()
    }
}
