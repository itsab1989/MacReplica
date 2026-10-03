import Foundation

/// A folder of application data the user explicitly chose to include.
public struct AppDataFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Path relative to the home folder, e.g. `Library/Application Support/Example Editor`
    /// (relative to `/Library` when `scope` is `.sharedLibrary`).
    public var relativePath: String
    /// Files inside the folder; `relativePath` of each file is relative to this folder.
    public var files: [FileRecord]
    /// Set when the folder was suggested by an application data profile.
    public var profile: AppDataProfileReference?
    /// Nil (backups of earlier versions) means the home folder.
    public var scope: AppDataScope?
    /// Files in the folder that came with the app (listed in the installer receipt) and were left out.
    public var shippedFilesLeftOut: Int?

    public init(id: String, name: String, relativePath: String, files: [FileRecord], profile: AppDataProfileReference? = nil,
                scope: AppDataScope? = nil, shippedFilesLeftOut: Int? = nil) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.files = files
        self.profile = profile
        self.scope = scope == .home ? nil : scope
        self.shippedFilesLeftOut = shippedFilesLeftOut
    }

    public var effectiveScope: AppDataScope { scope ?? .home }
    public var displayPath: String { effectiveScope == .home ? "~/" + relativePath : "/Library/" + relativePath }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum AppDataError: Error, Equatable, Sendable {
    case outsideHome
    case wholeHomeOrLibrary
    case sensitiveLocation(String)
    case notAFolder
    /// A `/Library` location that is not a provider's application folder.
    case notAProviderLocation
}

/// Collects files from a folder the user picked. MacReplica never copies all of
/// `~/Library`; only folders the user selected, and never credential stores.
public struct AppDataScanner: Sendable {
    public var layout: SystemLayout
    /// Upper limit for one folder, to avoid accidentally backing up huge caches.
    public var maxFolderSize: Int64

    public init(layout: SystemLayout, maxFolderSize: Int64 = 2_000_000_000) {
        self.layout = layout
        self.maxFolderSize = maxFolderSize
    }

    /// Locations that hold passwords, keys, cookies or personal communication.
    static let refusedLocations = ["Library/Keychains", ".ssh", ".gnupg", ".aws", ".kube", ".docker", "Library/Cookies", "Library/Mail",
                                   "Library/Messages", "Library/Safari", "Library/Accounts", "Library/IdentityServices",
                                   "Library/Group Containers/group.com.apple.notes", "Library/Application Support/AddressBook",
                                   "Library/Application Support/com.apple.TCC", "Library/Caches", "Library/Logs", ".Trash"]

    /// Individual files that look like secrets are skipped and listed as not included.
    static let refusedFilePatterns = [#"\.keychain(-db)?$"#, #"\.(pem|key|p12|pfx|cer|crt|der|kdbx|asc|gpg)$"#, #"^id_(rsa|dsa|ecdsa|ed25519)"#,
                                      #"(?i)^(cookies|login data|web data)(-journal)?$"#, #"(?i)(token|secret|credential|password)s?(\.|$)"#,
                                      #"^\.netrc$"#, #"^\.env(\..*)?$"#]

    public func validate(_ folder: URL) throws -> String {
        let home = layout.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else { throw AppDataError.outsideHome }
        let relative = String(path.dropFirst(home.count + 1))
        if ["Library", "Library/Application Support", "Library/Preferences", "Library/Containers", "Library/Group Containers"].contains(relative)
            || relative.isEmpty {
            throw AppDataError.wholeHomeOrLibrary
        }
        for refused in Self.refusedLocations where relative == refused || relative.hasPrefix(refused + "/") {
            throw AppDataError.sensitiveLocation(refused)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppDataError.notAFolder }
        return relative
    }

    /// Provider locations in `/Library` must be an application's own folder in Application Support
    /// (at least two levels below it), never Application Support itself or anything else in `/Library`.
    public func validateShared(_ folder: URL) throws -> String {
        let support = layout.sharedLibrary.appendingPathComponent("Application Support").standardizedFileURL.resolvingSymlinksInPath().path
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(support + "/"), path.dropFirst(support.count + 1).split(separator: "/").count >= 2 else {
            throw AppDataError.notAProviderLocation
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppDataError.notAFolder }
        let library = layout.sharedLibrary.standardizedFileURL.resolvingSymlinksInPath().path
        return String(path.dropFirst(library.count + 1))
    }

    static func isRefusedFile(_ name: String) -> Bool {
        refusedFilePatterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    /// - Parameter onlyFiles: restrict to these file names directly inside `folder` (for providers that list files).
    /// - Parameter shipped: paths relative to `folder` that came with the app (installer receipt); left out.
    public func scan(_ folder: URL, profile: AppDataProfileReference? = nil, onlyFiles: [String]? = nil, excluding: [String] = [],
                     scope: AppDataScope = .home, shipped: Set<String> = []) throws -> (folder: AppDataFolder, files: [ScannedFile], issues: [BackupIssue]) {
        let relative = scope == .home ? try validate(folder) : try validateShared(folder)
        var identity = scope == .home ? relative : "/Library/" + relative
        var shippedLeftOut = 0
        if let onlyFiles { identity += ":" + onlyFiles.joined(separator: ",") }
        let id = "appdata-" + String(Hashing.sha256Hex(of: Data(identity.utf8)).prefix(12))
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        var files: [ScannedFile] = []
        var issues: [BackupIssue] = []
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            guard let fileRelative = FileScanner.relativePath(of: url, below: base) else { continue }
            if let onlyFiles, !onlyFiles.contains(fileRelative) { continue }
            if !excluding.isEmpty, fileRelative.split(separator: "/").contains(where: { excluding.contains(String($0)) }) { continue }
            if shipped.contains(fileRelative) {
                shippedLeftOut += 1
                continue
            }
            if Self.isRefusedFile(url.lastPathComponent) {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .refusedSensitive))
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            if total + size > maxFolderSize {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .tooLarge))
                continue
            }
            guard let hash = try? Hashing.sha256Hex(ofFile: url) else {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .unreadable))
                continue
            }
            total += size
            let record = FileRecord(fileName: url.lastPathComponent, domain: scope == .home ? .user : .system, relativePath: fileRelative,
                                    originalPath: layout.displayPath(url), backupPath: "application-data/\(id)/\(fileRelative)",
                                    sha256: hash, size: size, modifiedAt: values.contentModificationDate)
            files.append(ScannedFile(url: url, record: record))
        }
        files.sort { $0.record.relativePath < $1.record.relativePath }
        // "Adobe Photoshop 2025 · Actions": app (version) and the real folder name, language independent.
        let name = profile.map { "\($0.appVersion ?? $0.appName) · \(base.lastPathComponent)" } ?? base.lastPathComponent
        let folderRecord = AppDataFolder(id: id, name: name, relativePath: relative, files: files.map(\.record), profile: profile,
                                         scope: scope, shippedFilesLeftOut: shippedLeftOut > 0 ? shippedLeftOut : nil)
        return (folderRecord, files, issues)
    }
}
