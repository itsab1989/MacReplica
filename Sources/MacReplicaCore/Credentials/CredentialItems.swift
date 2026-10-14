import Foundation

/// The kinds of credential MacReplica distinguishes. Each has its own policy (`CredentialPolicy`): whether the file
/// can be preserved, how it is restored and what the user still needs to use it.
public enum CredentialCategory: String, Codable, Sendable, CaseIterable {
    /// SSH, PEM or PKCS #12 private keys.
    case privateKey
    /// The public half of a key pair (SSH or OpenPGP), kept with its private key.
    case publicKey
    /// Certificates (public; the matching private key is a separate item).
    case certificate
    /// OpenPGP keys and keyrings.
    case pgpKey
    /// Encrypted password databases (KeePass/KeePassXC, Password Safe).
    case passwordDatabase
    /// A key file that opens a password database together with (or instead of) its master password.
    case passwordDatabaseKeyFile
    /// An unencrypted export of a password manager.
    case passwordManagerExport
    /// Recovery codes, recovery keys, emergency kits.
    case recoveryMaterial
    /// Command-line logins stored as files (AWS, Git, npm, Kubernetes, Terraform, SSH configuration).
    case applicationCredential
    /// `.env`, `.netrc` and similar files with secrets.
    case secretsFile
    /// A file the user chose that MacReplica does not recognise further.
    case otherSecret

    public init(_ kind: SensitiveKind) {
        switch kind {
        case .privateKey: self = .privateKey
        case .certificate: self = .certificate
        case .pgpKey: self = .pgpKey
        case .passwordDatabase: self = .passwordDatabase
        case .keePassKeyFile: self = .passwordDatabaseKeyFile
        case .passwordManagerExport: self = .passwordManagerExport
        case .recoveryMaterial: self = .recoveryMaterial
        case .secretsFile: self = .secretsFile
        case .nameSuggestsSecret, .keychain, .browserData: self = .otherSecret
        }
    }

    /// The category of a file: from what it looks like, corrected by the format read from its header (a `.pub` file named
    /// like a private key is a public key).
    public static func of(kind: SensitiveKind?, format: String?, provider: String? = nil) -> CredentialCategory {
        if format == "OpenSSH public key" || format == "OpenPGP public key" { return .publicKey }
        if provider != nil, kind != .privateKey { return .applicationCredential }
        return kind.map(CredentialCategory.init) ?? .otherSecret
    }
}

/// What the user still needs after the file is back, so nobody mistakes "file restored" for "credential usable".
public enum CredentialPrerequisite: String, Codable, Sendable, CaseIterable {
    /// The database's master password (and its key file, if one is used).
    case masterPassword
    /// A key file opens its database only together with the database's master password.
    case withMasterPassword
    /// The key's own passphrase, if it has one.
    case keyPassphrase
    /// A certificate alone is not an identity: its private key must be preserved as well.
    case matchingPrivateKey
    /// Import the export into the password manager, then delete it.
    case importIntoApp
    /// Keep it somewhere safe; it is the way back into an account.
    case storeSafely
    /// The service may have expired or revoked the login; sign in again if it fails.
    case mayNeedSignIn
}

/// The policy for a category: preserved as an encrypted file (never in plain text) and restored to where it was.
public enum CredentialPolicy {
    public static func prerequisites(_ category: CredentialCategory) -> [CredentialPrerequisite] {
        switch category {
        case .privateKey: return [.keyPassphrase]
        case .publicKey: return []
        case .certificate: return [.matchingPrivateKey]
        case .pgpKey: return [.keyPassphrase]
        case .passwordDatabase: return [.masterPassword]
        case .passwordDatabaseKeyFile: return [.withMasterPassword]
        case .passwordManagerExport: return [.importIntoApp]
        case .recoveryMaterial: return [.storeSafely]
        case .applicationCredential: return [.mayNeedSignIn]
        case .secretsFile, .otherSecret: return []
        }
    }

    /// Kinds MacReplica never copies as files: they do not work on another Mac, and there are supported ways to move
    /// them (see `CredentialGuidance`).
    public static func isCopyable(_ kind: SensitiveKind) -> Bool { kind != .keychain && kind != .browserData }

    /// Permissions a restored file gets: public keys, certificates and `known_hosts` may stay readable by others (never
    /// writable); everything secret is for its owner only, whatever the source permissions were.
    public static func restoredPermissions(_ mode: Int, item: CredentialSelectionItem) -> Int {
        let isPublic = item.category == .certificate || item.category == .publicKey || item.fileName == "known_hosts"
        let kept = mode & (isPublic ? 0o755 : 0o700)
        return kept & 0o600 == 0 ? 0o600 : kept
    }
}

/// Why a credential could not be added or preserved.
public enum CredentialProblem: String, Codable, Sendable {
    /// A macOS keychain: only the Passwords app or Keychain Access can move its items.
    case keychainNotCopyable
    /// Browser password or cookie database: encrypted with a key of this Mac, or a live session.
    case browserStoreNotCopyable
    /// The file is in iCloud and not downloaded.
    case notDownloaded
    case unreadable
    case missing
    case changedDuringBackup
    /// No encryption was set up (should not happen: the backup asks for it first).
    case noEncryptionKey
    case encryptionFailed
    /// A folder chosen in the credential picker had nothing recognisable as a credential.
    case nothingRecognised
}

/// A credential file chosen for the encrypted part of the backup. Lives in the inventory until the backup is written.
public struct CredentialSelectionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var category: CredentialCategory
    public var kind: SensitiveKind?
    /// For files of a credential provider (`ssh`, `aws` …).
    public var provider: String?
    public var fileName: String
    /// Where it is now (display path, home written as `~`).
    public var originalPath: String
    /// The format as read from the header (e.g. `KDBX 4.1`, `OpenSSH private key`); nil if not recognised.
    public var format: String?
    public var size: Int64

    public init(id: String, category: CredentialCategory, kind: SensitiveKind?, provider: String? = nil, fileName: String,
                originalPath: String, format: String?, size: Int64) {
        self.id = id
        self.category = category
        self.kind = kind
        self.provider = provider
        self.fileName = fileName
        self.originalPath = originalPath
        self.format = format
        self.size = size
    }

    /// Stable identity from the file's real location: the same file chosen twice is one item, two files with the same
    /// name in different folders are two.
    public static func identity(of url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return "cred-" + Hashing.sha256Hex(of: Data(path.utf8)).prefix(16)
    }
}

/// Manifest entry for one credential item. Never contains secrets: no contents, no plain hash.
public struct CredentialItemRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Encrypted, decrypted again and compared with the original: the backup copy is intact.
        case encryptedBackupVerified
        /// Could not be preserved (`problem` says why); the backup is partial.
        case failed
    }

    public var id: String
    public var category: CredentialCategory
    public var kind: SensitiveKind?
    public var provider: String?
    public var fileName: String
    public var originalPath: String
    /// Where it is restored: below the home folder (preferred), or an absolute location outside it (another volume).
    public var homeRelativePath: String?
    public var absolutePath: String?
    public var format: String?
    public var size: Int64
    public var status: Status
    public var problem: CredentialProblem?
    /// Location of the encrypted file in the backup, its size and SHA-256 (integrity without the key).
    public var encryptedPath: String?
    public var encryptedSize: Int64?
    public var encryptedSha256: String?
    /// Keyed HMAC-SHA256 of the contents (see `CredentialKeyring.contentHMAC`); reveals nothing without the key.
    public var contentHmac: String?
    /// Restored as the same file in the same place; what the user still needs is in `prerequisites`.
    public var restoreStrategy: String
    public var prerequisites: [CredentialPrerequisite]
    /// The credential is usable only after a step by the user (import, master password …).
    public var manualActionRequired: Bool

    public init(id: String, category: CredentialCategory, kind: SensitiveKind?, provider: String?, fileName: String, originalPath: String,
                homeRelativePath: String?, absolutePath: String?, format: String?, size: Int64, status: Status, problem: CredentialProblem? = nil) {
        self.id = id
        self.category = category
        self.kind = kind
        self.provider = provider
        self.fileName = fileName
        self.originalPath = originalPath
        self.homeRelativePath = homeRelativePath
        self.absolutePath = absolutePath
        self.format = format
        self.size = size
        self.status = status
        self.problem = problem
        restoreStrategy = "copyToOriginalLocation"
        prerequisites = CredentialPolicy.prerequisites(category)
        manualActionRequired = !prerequisites.isEmpty
    }

    public var isPreserved: Bool { status == .encryptedBackupVerified && encryptedPath != nil }
}

/// The encryption of a backup's credential store, as recorded in the manifest (no key material).
public struct CredentialStoreRecord: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var keysPath: String
    public var algorithm: String
    /// How the store can be opened: `passphrase`, `recoveryKey`.
    public var unlockMethods: [String]
    public var keyId: String
}

/// The header formats MacReplica recognises, read from the first bytes only (contents are never interpreted further).
public enum CredentialFormat {
    public static func describe(_ url: URL, kind: SensitiveKind?) -> String? {
        if let header = KeePassHeader.read(url) { return header.format }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }
        if data.starts(with: Data("PWS3".utf8)) { return "Password Safe V3" }
        let text = String(decoding: data, as: UTF8.self)
        // The markers are assembled so secret scanners do not mistake these constants for keys.
        let begin = "-----BEGIN ", privateKey = "PRIVATE " + "KEY-----"
        if text.contains(begin + "OPENSSH " + privateKey) { return "OpenSSH private key" }
        if text.contains(begin + "ENCRYPTED " + privateKey) { return "PEM private key (encrypted)" }
        if text.range(of: begin + "([A-Z]+ )?" + privateKey, options: .regularExpression) != nil { return "PEM private key" }
        if text.contains(begin + "CERTIFICATE-----") { return "PEM certificate" }
        if text.contains(begin + "PGP PRIVATE " + "KEY BLOCK-----") { return "OpenPGP private key" }
        if text.contains("-----BEGIN PGP PUBLIC KEY BLOCK-----") { return "OpenPGP public key" }
        if text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-sha2-") { return "OpenSSH public key" }
        if text.contains("<KeyFile") { return "KeePass key file" }
        let ext = url.pathExtension.lowercased()
        if ["p12", "pfx"].contains(ext), data.first == 0x30 { return "PKCS #12" }
        if ["cer", "crt", "der"].contains(ext), data.first == 0x30 { return "DER certificate" }
        if ext == "1pux", data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "1Password export (1PUX)" }
        return nil
    }

    /// After a restore: the file still has the format it had in the backup (a structural check, not opening it).
    public static func matches(_ url: URL, recorded: String?) -> Bool {
        guard let recorded else { return true }
        return describe(url, kind: nil) == recorded
    }
}

/// The result of adding credential files: what was added and, for everything else, why not.
public struct CredentialAddReport: Sendable {
    public var added: [String] = []
    /// Already in the selection (the same file, possibly reached through another path or link).
    public var alreadySelected: [String] = []
    public var refused: [(path: String, problem: CredentialProblem)] = []
    /// Files in a chosen folder that do not look like credentials (left alone, counted only).
    public var unrecognisedInFolders = 0
    /// Display paths of selected items with the same contents as another selected item (both are kept).
    public var sameContents: [String] = []
}

extension InventoryResult {
    /// Adds files and folders the user chose for the encrypted credential backup. Every chosen file is its own item;
    /// adding more never replaces or drops earlier ones. Folders are searched for files that look like credentials
    /// (links are not followed, so nothing is visited twice); a file chosen directly is taken even if MacReplica does
    /// not recognise it – the user said it is a secret.
    @discardableResult
    public mutating func addCredentialFiles(_ urls: [URL], layout: SystemLayout) -> CredentialAddReport {
        var report = CredentialAddReport()
        var identities = Set(credentialSelection.compactMap { Self.fileIdentity(layout.resolve(displayPath: $0.originalPath)) })
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                var foundAny = false
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                while let file = enumerator?.nextObject() as? URL {
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isSymbolicLink != true, values?.isRegularFile == true, file.lastPathComponent != ".DS_Store" else { continue }
                    var classification = SensitiveFileClassifier.classify(file)
                    // The public half of a key found here comes along (`deploy_ed25519.pub` next to `deploy_ed25519`).
                    if classification == nil, file.pathExtension == "pub",
                       SensitiveFileClassifier.classify(file.deletingPathExtension())?.kind == .privateKey {
                        classification = SensitiveClassification(kind: .privateKey, confidence: .low)
                    }
                    guard let classification else {
                        report.unrecognisedInFolders += 1
                        continue
                    }
                    foundAny = true
                    add(file, classification: classification, layout: layout, identities: &identities, report: &report)
                }
                if !foundAny { report.refused.append((layout.displayPath(url), .nothingRecognised)) }
            } else {
                add(url, classification: SensitiveFileClassifier.classify(url), layout: layout,
                    identities: &identities, report: &report)
            }
        }
        // Files with the same contents stay separate items (they may be used from both places); the user is told.
        var seen: [String: String] = [:]
        for item in credentialSelection {
            guard let sha = try? Hashing.sha256Hex(ofFile: layout.resolve(displayPath: item.originalPath)) else { continue }
            if let first = seen[sha] { report.sameContents.append(contentsOf: [first, item.originalPath]) } else { seen[sha] = item.originalPath }
        }
        report.sameContents = Array(Set(report.sameContents)).sorted()
        return report
    }

    private mutating func add(_ url: URL, classification: SensitiveClassification?, layout: SystemLayout,
                              identities: inout Set<String>, report: inout CredentialAddReport) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let display = layout.displayPath(resolved)
        if let kind = classification?.kind, !CredentialPolicy.isCopyable(kind) {
            report.refused.append((display, kind == .keychain ? .keychainNotCopyable : .browserStoreNotCopyable))
            return
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else { report.refused.append((display, .missing)); return }
        if AppDataScanner.isDataless(resolved) { report.refused.append((display, .notDownloaded)); return }
        guard FileManager.default.isReadableFile(atPath: resolved.path),
              let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              let identity = Self.fileIdentity(resolved) else {
            report.refused.append((display, .unreadable))
            return
        }
        guard identities.insert(identity).inserted else { report.alreadySelected.append(display); return }
        let kind = classification?.kind
        let format = CredentialFormat.describe(resolved, kind: kind)
        credentialSelection.append(CredentialSelectionItem(
            id: CredentialSelectionItem.identity(of: resolved), category: CredentialCategory.of(kind: kind, format: format), kind: kind,
            fileName: resolved.lastPathComponent, originalPath: display, format: format,
            size: Int64(values.fileSize ?? 0)))
        report.added.append(display)
        // It is no longer "left out": it is in the encrypted part of the backup.
        manifest.backupIssues.removeAll { $0.reason == .refusedSensitive && $0.path == display }
    }

    /// Device and inode: the same file reached through a link or another path is recognised.
    static func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// Takes an item out of the encrypted backup. A file that looks like a credential is listed again as left out, with
    /// the user's decision recorded, so it never silently disappears from the report.
    public mutating func removeCredentialFile(id: String, layout: SystemLayout) {
        guard let item = credentialSelection.first(where: { $0.id == id }) else { return }
        credentialSelection.removeAll { $0.id == id }
        let classification = SensitiveFileClassifier.classify(layout.resolve(displayPath: item.originalPath))
        if !manifest.backupIssues.contains(where: { $0.path == item.originalPath && $0.reason == .refusedSensitive }) {
            manifest.backupIssues.append(BackupIssue(path: item.originalPath, reason: .refusedSensitive, detail: .leftOutByUser,
                                                     sensitive: classification ?? SensitiveClassification(kind: .nameSuggestsSecret, confidence: .low)))
        }
    }

    /// The user decided not to preserve a detected credential file: recorded with that reason (and shown as such).
    public mutating func leaveOutCredential(path: String) {
        for index in manifest.backupIssues.indices where manifest.backupIssues[index].path == path && manifest.backupIssues[index].reason == .refusedSensitive {
            manifest.backupIssues[index].detail = .leftOutByUser
        }
    }

    /// Undoes `leaveOutCredential`: the file is listed as undecided again.
    public mutating func reconsiderCredential(path: String) {
        for index in manifest.backupIssues.indices where manifest.backupIssues[index].path == path && manifest.backupIssues[index].detail == .leftOutByUser {
            manifest.backupIssues[index].detail = nil
        }
    }
}

extension Manifest {
    /// Credential-looking files found but neither preserved nor deliberately left out: the user still has to decide.
    public var undecidedCredentials: [BackupIssue] {
        excludedSensitiveFiles.filter { $0.detail != .leftOutByUser && ($0.sensitive.map { CredentialPolicy.isCopyable($0.kind) } ?? true) }
    }

    /// Detected files that cannot be preserved as files at all (keychains, browser stores).
    public var uncopyableCredentials: [BackupIssue] {
        excludedSensitiveFiles.filter { !($0.sensitive.map { CredentialPolicy.isCopyable($0.kind) } ?? true) }
    }

    /// Files the user chose to leave out (recorded with that reason).
    public var credentialsLeftOutByUser: [BackupIssue] { excludedSensitiveFiles.filter { $0.detail == .leftOutByUser } }

    public var preservedCredentials: [CredentialItemRecord] { credentialItems.filter(\.isPreserved) }
    public var failedCredentials: [CredentialItemRecord] { credentialItems.filter { !$0.isPreserved } }
}

/// Files left out because they look like secrets, included again at the user's explicit request (and left out again).
extension InventoryResult {
    public enum IncludeOnRequestError: Error, Equatable, Sendable {
        /// Keychains and browser data are never copied.
        case notAllowed
        /// The file is no longer there or cannot be read.
        case unreadable
        /// The file is not in a folder MacReplica may back up (outside the home folder, or in `~/Library` outside a provider folder).
        case outsideSelectedFolders
    }

    /// Adds a file that was left out as sensitive to the encrypted credential backup (1.0.7: never as a plain copy).
    /// Works for every location the file can be read from – inside a chosen folder or not (home folder, iCloud Drive,
    /// another volume) – and any number of files, one after the other.
    public mutating func includeOnRequest(_ path: String, layout: SystemLayout) throws {
        let url = layout.resolve(displayPath: path)
        guard let classification = SensitiveFileClassifier.classify(url) else { throw IncludeOnRequestError.unreadable }
        guard CredentialPolicy.isCopyable(classification.kind) else { throw IncludeOnRequestError.notAllowed }
        let report = addCredentialFiles([url], layout: layout)
        if !report.refused.isEmpty { throw IncludeOnRequestError.unreadable }
    }

    /// Takes a file out of the encrypted credential backup again; it is listed as left out (by the user).
    public mutating func excludeAgain(_ path: String, layout: SystemLayout) {
        for item in credentialSelection where item.originalPath == path { removeCredentialFile(id: item.id, layout: layout) }
    }

    /// KeePass databases KeePassXC remembers that are neither in the backup nor already listed as left out: offered
    /// to the user, never included by themselves.
    public func rememberedPasswordDatabases(layout: SystemLayout) -> [URL] {
        let listed = Set(manifest.backupIssues.map(\.path))
        let included = Set(manifest.applicationData.flatMap(\.files).map(\.originalPath) + credentialSelection.map(\.originalPath))
        return KeePassXCLocations.rememberedDatabases(layout: layout).filter {
            let path = layout.displayPath($0)
            return !listed.contains(path) && !included.contains(path)
        }
    }
}
