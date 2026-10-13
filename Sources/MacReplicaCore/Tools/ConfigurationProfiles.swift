import Foundation

/// Configuration profiles MacReplica can prepare on the user's explicit request. MacReplica cannot install or remove
/// a profile itself: since macOS 11 only the user can, in System Settings › General › Device Management (macOS asks
/// for the administrator password). MacReplica writes the file, opens it (macOS then lists it there), and checks
/// afterwards what really changed. It only ever touches profiles with its own identifiers.
public enum ManagedProfile: Sendable, Equatable {
    /// `com.apple.systempolicy.control`, `EnableAssessment = false`: Gatekeeper checks no app at all.
    case gatekeeperOff
    /// `com.apple.applicationaccess`, `forceDelayedMajorSoftwareUpdates` + delay: a new major macOS version is
    /// offered only `days` after its release (1–90). Each release starts its own period.
    case deferMajorUpgrades(days: Int)

    public static let gatekeeperIdentifier = "io.github.itsab1989.MacReplica.gatekeeper"
    public static let deferralIdentifier = "io.github.itsab1989.MacReplica.defer-major-upgrades"
    public static let deferralRange = 1...90

    public var identifier: String {
        switch self {
        case .gatekeeperOff: return Self.gatekeeperIdentifier
        case .deferMajorUpgrades: return Self.deferralIdentifier
        }
    }

    public var fileName: String {
        switch self {
        case .gatekeeperOff: return "MacReplica-Gatekeeper-off.mobileconfig"
        case .deferMajorUpgrades: return "MacReplica-Defer-major-upgrades.mobileconfig"
        }
    }

    /// Fixed UUIDs per identifier, so a second file for the same profile replaces the first instead of adding one.
    private var uuids: (profile: String, payload: String) {
        switch self {
        case .gatekeeperOff: return ("6B1F0C52-4C0E-4E57-9A7B-2E0A6C1D7A01", "6B1F0C52-4C0E-4E57-9A7B-2E0A6C1D7A02")
        case .deferMajorUpgrades: return ("6B1F0C52-4C0E-4E57-9A7B-2E0A6C1D7B01", "6B1F0C52-4C0E-4E57-9A7B-2E0A6C1D7B02")
        }
    }

    /// The profile as a property list. `displayName` and `description` are shown by System Settings.
    public func propertyList(displayName: String, description: String) throws -> [String: Any] {
        var payload: [String: Any] = [
            "PayloadIdentifier": identifier + ".payload",
            "PayloadUUID": uuids.payload,
            "PayloadVersion": 1,
        ]
        switch self {
        case .gatekeeperOff:
            payload["PayloadType"] = "com.apple.systempolicy.control"
            payload["EnableAssessment"] = false
        case .deferMajorUpgrades(let days):
            guard Self.deferralRange.contains(days) else { throw ProfileError.invalidDays }
            payload["PayloadType"] = "com.apple.applicationaccess"
            payload["forceDelayedMajorSoftwareUpdates"] = true
            payload["enforcedSoftwareUpdateMajorOSDeferredInstallDelay"] = days
        }
        return [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuids.profile,
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadOrganization": "MacReplica",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]
    }

    /// Writes the `.mobileconfig` (XML, unsigned) into `folder` and returns its location.
    public func write(to folder: URL, displayName: String, description: String) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList(displayName: displayName, description: description),
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

public enum ProfileError: Error, Equatable {
    case invalidDays
    case unsupported
}

/// Which profiles are installed for the whole Mac: `profiles -C` lists their identifiers without administrator rights
/// (`_computerlevel[1] attribute: profileIdentifier: com.example`).
public enum InstalledProfiles {
    public static func identifiers(fromProfilesOutput output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "profileIdentifier: ") else { return nil }
            let identifier = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return identifier.isEmpty ? nil : identifier
        })
    }

    public static func read(layout: SystemLayout, runner: CommandRunning) async -> Set<String>? {
        guard let result = try? await runner.run(Command(executable: layout.profiles, arguments: ["-C"],
                                                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: 30)),
              !result.combinedOutput.contains("requires root") else { return nil }
        return identifiers(fromProfilesOutput: result.stdout)
    }
}

/// Where deferring a major upgrade with a hand-installed profile works without holding back security updates.
public enum MajorUpgradeDeferralSupport: String, Sendable {
    /// macOS 13 – 15.7.4: the major deferral is separate from minor and security updates.
    case available
    /// macOS 26: deprecated by Apple but still a separate major-upgrade period.
    case availableDeprecated
    /// macOS 15.7.5 and later 15.x: one deferral period for all updates – it would also delay security updates.
    case wouldDelaySecurityUpdates
    /// macOS 27 and later: removed; only supervised device management can defer.
    case removed
    case olderThanSupported

    public static func forVersion(_ environment: ToolEnvironment) -> MajorUpgradeDeferralSupport {
        let major = environment.majorVersion
        if major >= 27 { return .removed }
        if major == 26 { return .availableDeprecated }
        if major == 15, environment.isAtLeast("15.7.5") { return .wouldDelaySecurityUpdates }
        if major >= 13 { return .available }
        return .olderThanSupported
    }

    public var canInstall: Bool { self == .available || self == .availableDeprecated }

    public var capability: ToolCapability {
        switch self {
        case .available: return .supportedWithRestrictions
        case .availableDeprecated: return .experimental
        case .wouldDelaySecurityUpdates, .removed, .olderThanSupported: return .unsupportedOnThisVersion
        }
    }
}

/// What the managed preferences say a profile actually changed (world-readable, no administrator rights).
public enum ManagedProfileEffect {
    /// The deferral MacReplica (or anyone) set, as macOS sees it: days, or nil if no deferral is active.
    public static func majorUpgradeDeferralDays(managedPreferences: URL) -> Int? {
        guard let values = GatekeeperInspector.readPlist(managedPreferences.appendingPathComponent("com.apple.applicationaccess.plist")),
              (values["forceDelayedMajorSoftwareUpdates"] as? Bool) == true else { return nil }
        return values["enforcedSoftwareUpdateMajorOSDeferredInstallDelay"] as? Int ?? 30
    }

    /// `Deferred: YES` in `softwareupdate --list-full-installers` for a newer major version: the deferral is in effect.
    public static func newerMajorDeferred(installersOutput: String, installedMajor: Int) -> Bool? {
        var sawNewer = false
        for line in installersOutput.split(separator: "\n") {
            guard let range = line.range(of: "Version: ") else { continue }
            let major = Int(line[range.upperBound...].prefix { $0.isNumber }) ?? 0
            guard major > installedMajor else { continue }
            sawNewer = true
            if line.contains("Deferred: YES") { return true }
        }
        return sawNewer ? false : nil
    }
}
