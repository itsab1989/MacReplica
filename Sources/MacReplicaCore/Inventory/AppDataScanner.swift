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
    /// A folder of the user's own files (documents, pictures, projects …) chosen in "Your own folders":
    /// no size limit, restored as its own group. Nil for application data.
    public var personal: Bool?

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
    public var isPersonal: Bool { personal == true }
    public var displayPath: String {
        switch effectiveScope {
        case .home: return "~/" + relativePath
        case .sharedLibrary: return "/Library/" + relativePath
        case .usersShared: return "/Users/Shared/" + relativePath
        }
    }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum AppDataError: Error, Equatable, Sendable {
    case outsideHome
    case wholeHomeOrLibrary
    case sensitiveLocation(String)
    case notAFolder
    /// A `/Library` location that is not a provider's application folder.
    case notAProviderLocation
    /// "Your own folders" are folders of the home folder outside `~/Library` (application data has its own section).
    case insideLibrary
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

    /// Settings folders inside refused locations that a provider may read: Mail's settings (signatures, rules,
    /// smart mailboxes), never its mailboxes or accounts.
    static let providerExceptions = [#"^Library/Mail/V[0-9]+/MailData(/Signatures)?$"#]

    /// Individual files that look like secrets are skipped and listed as not included.
    static let refusedFilePatterns = [#"\.keychain(-db)?$"#, #"\.(pem|key|p12|pfx|cer|crt|der|kdbx|asc|gpg)$"#, #"^id_(rsa|dsa|ecdsa|ed25519)"#,
                                      #"(?i)^(cookies|login data|web data)(-journal)?$"#, #"(?i)(token|secret|credential|password)s?(\.|$)"#,
                                      #"^\.netrc$"#, #"^\.env(\..*)?$"#]

    /// - Parameter allowBroadFolder: a provider names exact files (e.g. `kritarc` directly in `~/Library/Preferences`):
    ///   the folder may be one that is too broad to copy as a whole, because only those files are read.
    public func validate(_ folder: URL, allowProviderExceptions: Bool = false, allowBroadFolder: Bool = false) throws -> String {
        let home = layout.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else { throw AppDataError.outsideHome }
        let relative = String(path.dropFirst(home.count + 1))
        if (["Library", "Library/Application Support", "Library/Preferences", "Library/Containers", "Library/Group Containers"].contains(relative)
            && !allowBroadFolder) || relative.isEmpty {
            throw AppDataError.wholeHomeOrLibrary
        }
        let providerException = allowProviderExceptions && Self.providerExceptions.contains { relative.range(of: $0, options: .regularExpression) != nil }
        for refused in Self.refusedLocations where (relative == refused || relative.hasPrefix(refused + "/")) && !providerException {
            throw AppDataError.sensitiveLocation(refused)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppDataError.notAFolder }
        return relative
    }

    /// A folder for "Your own folders": inside the home folder, not the home folder itself, nothing in
    /// `~/Library` (application data is chosen in its own section) and no sensitive location.
    public func validatePersonal(_ folder: URL) throws -> String {
        let home = layout.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else { throw path == home ? AppDataError.wholeHomeOrLibrary : AppDataError.outsideHome }
        let relative = String(path.dropFirst(home.count + 1))
        if relative == "Library" || relative.hasPrefix("Library/") { throw AppDataError.insideLibrary }
        for refused in Self.refusedLocations where relative == refused || relative.hasPrefix(refused + "/") {
            throw AppDataError.sensitiveLocation(refused)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppDataError.notAFolder }
        return relative
    }

    /// Scans one of the user's own folders: like application data, but without a size limit.
    public func scanPersonal(_ folder: URL) throws -> (folder: AppDataFolder, files: [ScannedFile], issues: [BackupIssue]) {
        _ = try validatePersonal(folder)
        var scanner = self
        scanner.maxFolderSize = .max
        var result = try scanner.scan(folder, personalFolder: true)
        result.folder.personal = true
        return result
    }

    /// The file is an iCloud placeholder (its contents are not on this Mac). Reading it would download it, so it is left out.
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
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

    /// Provider locations in `/Users/Shared` must be a folder below it, never `/Users/Shared` itself.
    public func validateUsersShared(_ folder: URL) throws -> String {
        let shared = layout.usersShared.standardizedFileURL.resolvingSymlinksInPath().path
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(shared + "/") else { throw AppDataError.notAProviderLocation }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppDataError.notAFolder }
        return String(path.dropFirst(shared.count + 1))
    }

    /// Stands for the home folder in backed-up text files of providers that store absolute home paths.
    public static let homePlaceholder = "{{MACREPLICA_HOME}}"
    static let homePlaceholderKey = "homePlaceholder"

    /// The file with this Mac's home path replaced by the placeholder; nil if it is not text, too large or
    /// contains no home path.
    func withHomePlaceholder(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count < 8_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        let home = layout.homeDirectory.standardizedFileURL.path
        guard text.contains(home + "/") || text.hasSuffix(home) || text.contains(home + "\"") || text.contains(home + "\n") else { return nil }
        return Data(text.replacingOccurrences(of: home, with: Self.homePlaceholder).utf8)
    }

    static func isRefusedFile(_ name: String) -> Bool {
        refusedFilePatterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    /// - Parameter onlyFiles: restrict to these file names directly inside `folder` (for providers that list files).
    /// - Parameter shipped: paths relative to `folder` that came with the app (installer receipt); left out.
    public func scan(_ folder: URL, profile: AppDataProfileReference? = nil, onlyFiles: [String]? = nil, excluding: [String] = [],
                     scope: AppDataScope = .home, shipped: Set<String> = [], rewritesHomeFolder: Bool = false,
                     allowProviderExceptions: Bool = false, personalFolder: Bool = false)
        throws -> (folder: AppDataFolder, files: [ScannedFile], issues: [BackupIssue]) {
        let relative: String
        switch scope {
        case .home where personalFolder: relative = try validatePersonal(folder)
        case .home: relative = try validate(folder, allowProviderExceptions: allowProviderExceptions,
                                            allowBroadFolder: allowProviderExceptions && onlyFiles != nil)
        case .sharedLibrary: relative = try validateShared(folder)
        case .usersShared: relative = try validateUsersShared(folder)
        }
        var identity: String
        switch scope {
        case .home: identity = relative
        case .sharedLibrary: identity = "/Library/" + relative
        case .usersShared: identity = "/Users/Shared/" + relative
        }
        var shippedLeftOut = 0
        if let onlyFiles { identity += ":" + onlyFiles.joined(separator: ",") }
        let id = (personalFolder ? "personal-" : "appdata-") + String(Hashing.sha256Hex(of: Data(identity.utf8)).prefix(12))
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
            // Finder's translations of folder names, not user data.
            if fileRelative.split(separator: "/").contains(".localized") { continue }
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
            if Self.isDataless(url) {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .notDownloaded))
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            if total + size > maxFolderSize {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .tooLarge))
                continue
            }
            let converted = rewritesHomeFolder ? withHomePlaceholder(url) : nil
            guard let hash = converted.map({ Hashing.sha256Hex(of: $0) }) ?? (try? Hashing.sha256Hex(ofFile: url)) else {
                issues.append(BackupIssue(path: layout.displayPath(url), reason: .unreadable))
                continue
            }
            total += size
            var record = FileRecord(fileName: url.lastPathComponent, domain: scope == .home ? .user : .system, relativePath: fileRelative,
                                    originalPath: layout.displayPath(url), backupPath: "application-data/\(id)/\(fileRelative)",
                                    sha256: hash, size: converted.map { Int64($0.count) } ?? size, modifiedAt: values.contentModificationDate)
            if converted != nil { record.metadata[Self.homePlaceholderKey] = "1" }
            files.append(ScannedFile(url: url, record: record, contents: converted))
        }
        files.sort { $0.record.relativePath < $1.record.relativePath }
        // "Adobe Photoshop 2025 · Actions": app (version) and the real folder name, language independent.
        let name = profile.map { "\($0.appVersion ?? $0.appName) · \(base.lastPathComponent)" } ?? base.lastPathComponent
        let folderRecord = AppDataFolder(id: id, name: name, relativePath: relative, files: files.map(\.record), profile: profile,
                                         scope: scope, shippedFilesLeftOut: shippedLeftOut > 0 ? shippedLeftOut : nil)
        return (folderRecord, files, issues)
    }
}
