@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import IOKit

// Kept apart from DisplayProfiles.swift on purpose: this is the only code that reads and changes the real
// Mac's display settings (ColorSync, IOKit). Tests and the simulation use SimulatedDisplayColorManager, so
// this file is outside mutation testing and is verified manually in the real app (docs/MUTATION_TESTING.md).

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
