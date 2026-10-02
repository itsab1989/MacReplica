import Foundation

/// Rules for paths that come from a backup and are therefore untrusted.
public enum PathSafety {
    /// True for a plain relative path such as `Family/Font-Bold.otf`:
    /// not absolute, no `..` or `.` components, no `~`, no empty components, no control characters.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Joins `relative` to `base` and confirms the result stays inside `base`.
    public static func resolve(_ relative: String, inside base: URL) -> URL? {
        guard isSafeRelativePath(relative) else { return nil }
        let candidate = base.appendingPathComponent(relative).standardizedFileURL
        let basePath = base.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }
}

/// The marker MacReplica writes into every folder it creates and may later delete.
public struct OwnershipMarker: Codable, Equatable, Sendable {
    public static let fileName = ".macreplica-owned"

    public enum Kind: String, Codable, Sendable {
        case backup, temporary, session, simulation
    }

    public var kind: Kind
    public var id: String
    public var createdAt: Date

    public init(kind: Kind, id: String = UUID().uuidString, createdAt: Date = Date()) {
        self.kind = kind
        self.id = id
        self.createdAt = createdAt
    }

    public func write(into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from folder: URL) -> OwnershipMarker? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(OwnershipMarker.self, from: data)
    }
}

public enum CleanupError: Error, Equatable, Sendable {
    case protectedLocation(String)
    case notFound(String)
    case notADirectory(String)
    case symbolicLink(String)
    case notOwnedByMacReplica(String)
    case unexpectedContent(String)
    case outsideOwnedFolder(String)
}

/// Deletes only what MacReplica created itself.
///
/// Before anything is removed the cleaner checks that the path is absolute, exists,
/// is a real folder (not a symbolic link), is not a well-known personal or system
/// location, and carries an ownership marker of the expected kind. There is no
/// code path that deletes an arbitrary folder.
public struct SafeCleaner: Sendable {
    public var homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    var protectedPaths: Set<String> {
        let home = homeDirectory.standardizedFileURL.path
        var paths: Set<String> = ["/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/tmp",
                                  "/var", "/etc", "/usr", "/bin", "/sbin", "/opt", "/opt/homebrew", "/usr/local",
                                  "/private/tmp", "/private/var"]
        paths.insert(home)
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Applications", "Movies", "Music", "Pictures", "Public",
                       "Library/Fonts", "Library/ColorSync", "Library/ColorSync/Profiles", "Library/Application Support",
                       "Library/Caches", "Library/Logs", "Library/Preferences"] {
            paths.insert(homeDirectory.appendingPathComponent(folder).standardizedFileURL.path)
        }
        paths.insert(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        return paths
    }

    /// Validates everything `removeOwnedFolder` checks, without deleting.
    public func validateOwnedFolder(_ folder: URL, kind: OwnershipMarker.Kind) throws {
        guard folder.isFileURL, folder.path.hasPrefix("/") else { throw CleanupError.protectedLocation(folder.path) }
        let standardized = folder.standardizedFileURL
        let path = standardized.path
        let resolved = standardized.resolvingSymlinksInPath().path
        if protectedPaths.contains(path) || protectedPaths.contains(resolved) || path.split(separator: "/").count < 2 {
            throw CleanupError.protectedLocation(path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw CleanupError.notFound(path) }
        let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw CleanupError.symbolicLink(path) }
        guard isDirectory.boolValue else { throw CleanupError.notADirectory(path) }
        guard let marker = OwnershipMarker.read(from: standardized), marker.kind == kind else {
            throw CleanupError.notOwnedByMacReplica(path)
        }
    }

    /// Removes a folder that MacReplica created, after validating it.
    public func removeOwnedFolder(_ folder: URL, kind: OwnershipMarker.Kind) throws {
        try validateOwnedFolder(folder, kind: kind)
        try FileManager.default.removeItem(at: folder.standardizedFileURL)
    }

    /// Removes a single file inside a MacReplica-owned folder.
    public func removeFile(_ file: URL, inOwnedFolder folder: URL, kind: OwnershipMarker.Kind) throws {
        try validateOwnedFolder(folder, kind: kind)
        let base = folder.standardizedFileURL.path + "/"
        let target = file.standardizedFileURL
        guard target.path.hasPrefix(base), target.lastPathComponent != OwnershipMarker.fileName else {
            throw CleanupError.outsideOwnedFolder(target.path)
        }
        let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard FileManager.default.fileExists(atPath: target.path) || values?.isSymbolicLink == true else {
            throw CleanupError.notFound(target.path)
        }
        try FileManager.default.removeItem(at: target)
    }

    /// Removes the oldest MacReplica-owned subfolders of `parent` beyond `keep`.
    /// Folders without a matching marker are never touched.
    public func pruneOwnedFolders(in parent: URL, kind: OwnershipMarker.Kind, keep: Int) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return [] }
        let owned = items.compactMap { url -> (URL, Date)? in
            guard let marker = OwnershipMarker.read(from: url), marker.kind == kind else { return nil }
            return (url, marker.createdAt)
        }.sorted { $0.1 > $1.1 }
        var removed: [URL] = []
        for (url, _) in owned.dropFirst(max(keep, 0)) {
            if (try? removeOwnedFolder(url, kind: kind)) != nil { removed.append(url) }
        }
        return removed
    }
}

/// A temporary folder that removes itself, also when the work fails.
public final class TemporaryWorkspace: @unchecked Sendable {
    public let url: URL
    private let cleaner: SafeCleaner
    private let lock = NSLock()
    private var removed = false

    public init(parent: URL = FileManager.default.temporaryDirectory, prefix: String = "MacReplica",
                cleaner: SafeCleaner = SafeCleaner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)) throws {
        let folder = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try OwnershipMarker(kind: .temporary).write(into: folder)
        self.url = folder
        self.cleaner = cleaner
    }

    @discardableResult
    public func cleanup() -> Bool {
        lock.withLock {
            guard !removed else { return true }
            do {
                try cleaner.removeOwnedFolder(url, kind: .temporary)
                removed = true
            } catch {
                removed = !FileManager.default.fileExists(atPath: url.path)
            }
            return removed
        }
    }

    deinit { cleanup() }
}
