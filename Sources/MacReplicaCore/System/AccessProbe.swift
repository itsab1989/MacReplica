import Foundation

/// The outcome of looking at one location during the inventory.
public enum AccessStatus: String, Codable, Sendable {
    /// Read successfully.
    case scanned
    /// The location does not exist on this Mac (nothing to back up).
    case notFound
    /// macOS did not allow MacReplica to read it.
    case noPermission
    /// It exists, but MacReplica cannot use it (for example a broken Homebrew installation).
    case unsupported

    public init(from decoder: Decoder) throws {
        self = AccessStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unsupported
    }
}

public enum AccessArea: String, Codable, Sendable, CaseIterable {
    case applications, userFonts, systemFonts, userColorProfiles, systemColorProfiles, homebrew, appStore, python, applicationData

    public init(from decoder: Decoder) throws {
        self = AccessArea(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .applicationData
    }
}

/// What happened when a location was scanned, so the inventory never silently omits anything.
public struct LocationAccess: Codable, Equatable, Sendable {
    public var area: AccessArea
    /// Display path (home written as `~`), or a tool name.
    public var location: String
    public var status: AccessStatus

    public init(area: AccessArea, location: String, status: AccessStatus) {
        self.area = area
        self.location = location
        self.status = status
    }
}

/// Checks whether a folder can be read, without asking for any permission.
///
/// MacReplica never requests Full Disk Access on its own. If macOS blocks a
/// location, it is reported as `noPermission` and the user can decide to grant
/// access in System Settings.
public enum AccessProbe {
    public static func status(of folder: URL) -> AccessStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            // A folder inside a protected location may look missing; check the parent's readability.
            return .notFound
        }
        guard isDirectory.boolValue else { return .unsupported }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return .scanned
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return .noPermission }
            if let posix = error.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain,
               posix.code == Int(EPERM) || posix.code == Int(EACCES) {
                return .noPermission
            }
            return .unsupported
        }
    }

    /// The System Settings pane where the user can grant Full Disk Access, if they want to.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
