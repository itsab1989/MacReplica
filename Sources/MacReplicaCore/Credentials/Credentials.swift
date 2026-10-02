import CommonCrypto
import CryptoKit
import Foundation

/// How a credential type is handled. Every supported type has its own narrowly
/// defined provider; there is no general "search the Mac for secrets".
public protocol CredentialProvider: Sendable {
    var id: String { get }
    var titleKey: String { get }
    /// What exactly is handled, where it comes from, and the risks (localization keys).
    var descriptionKey: String { get }
    var riskKey: String { get }
    /// True if the credential still works after moving it to another Mac.
    var isPortable: Bool { get }
    /// Lists what would be exported. Reads names only, never contents.
    func detect(layout: SystemLayout) -> [String]
    /// Reads the selected credential files for encryption.
    func export(layout: SystemLayout) throws -> [CredentialFile]
    /// Where a restored file belongs.
    func destination(for file: CredentialFile, layout: SystemLayout) -> URL?
}

/// One file inside an encrypted credential vault.
public struct CredentialFile: Codable, Equatable, Sendable {
    public var name: String
    public var permissions: Int
    public var contents: Data
}

/// Manifest entry for an encrypted credential vault. It never contains secrets.
public struct CredentialRecord: Codable, Equatable, Sendable {
    public var provider: String
    /// File names only, e.g. `id_ed25519`, `config`.
    public var items: [String]
    /// Backup-relative location of the encrypted vault.
    public var vaultPath: String
    public var encryption: String

    public init(provider: String, items: [String], vaultPath: String, encryption: String = CredentialVault.algorithmDescription) {
        self.provider = provider
        self.items = items
        self.vaultPath = vaultPath
        self.encryption = encryption
    }
}

public enum CredentialError: Error, Equatable, Sendable {
    case passphraseTooShort
    case wrongPassphraseOrDamaged
    case unsupportedFormat
    case keyDerivationFailed
}

/// Encrypts credential exports with established, Apple-provided cryptography:
/// PBKDF2-HMAC-SHA256 (CommonCrypto) derives a 256-bit key from the user's
/// passphrase, and AES-256-GCM (CryptoKit) encrypts and authenticates the data.
/// The passphrase is never stored; without it the vault cannot be opened.
public enum CredentialVault {
    public static let algorithmDescription = "AES-256-GCM, key from PBKDF2-HMAC-SHA256"
    public static let minimumPassphraseLength = 12
    public static let defaultIterations = 600_000
    static let format = "macreplica-credential-vault"

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var cipher: String
        var sealed: Data
    }

    public static func seal(_ files: [CredentialFile], passphrase: String, iterations: Int = defaultIterations) throws -> Data {
        guard passphrase.count >= minimumPassphraseLength else { throw CredentialError.passphraseTooShort }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CredentialError.keyDerivationFailed }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let payload = try JSONEncoder().encode(files)
        let header = Data("\(format)/1/\(iterations)".utf8)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw CredentialError.unsupportedFormat }
        let envelope = Envelope(format: format, version: 1, kdf: "PBKDF2-HMAC-SHA256", iterations: iterations, salt: salt,
                                cipher: "AES-256-GCM", sealed: combined)
        return try JSONEncoder().encode(envelope)
    }

    public static func open(_ data: Data, passphrase: String) throws -> [CredentialFile] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format, envelope.version == 1,
              envelope.cipher == "AES-256-GCM", envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.iterations >= 100_000 else {
            throw CredentialError.unsupportedFormat
        }
        let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: envelope.iterations)
        let header = Data("\(format)/1/\(envelope.iterations)".utf8)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let payload = try AES.GCM.open(box, using: key, authenticating: header)
            return try JSONDecoder().decode([CredentialFile].self, from: payload)
        } catch {
            throw CredentialError.wrongPassphraseOrDamaged
        }
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { CChar(bitPattern: $0) }, password.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
        }
        guard status == kCCSuccess else { throw CredentialError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

/// SSH keys and configuration from `~/.ssh`.
///
/// SSH keys are portable files, so this is one of the few credentials that can
/// be migrated at all. It is never part of a normal backup: the user has to
/// switch it on explicitly and set a passphrase for the encrypted vault.
public struct SSHKeyProvider: CredentialProvider {
    public let id = "ssh"
    public let titleKey = "credentials.ssh.toggle"
    public let descriptionKey = "credentials.ssh.description"
    public let riskKey = "credentials.ssh.risk"
    public let isPortable = true

    public init() {}

    static let includedNames: Set<String> = ["config", "known_hosts"]

    func folder(_ layout: SystemLayout) -> URL { layout.homeDirectory.appendingPathComponent(".ssh") }

    static func isIncluded(_ name: String) -> Bool {
        if includedNames.contains(name) { return true }
        return name.hasPrefix("id_") && !name.contains("/")
    }

    public func detect(layout: SystemLayout) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(layout).path)) ?? []).filter(Self.isIncluded).sorted()
    }

    public func export(layout: SystemLayout) throws -> [CredentialFile] {
        try detect(layout: layout).compactMap { name in
            let url = folder(layout).appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let permissions = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
            return CredentialFile(name: name, permissions: permissions & 0o777, contents: try Data(contentsOf: url))
        }
    }

    public func destination(for file: CredentialFile, layout: SystemLayout) -> URL? {
        guard Self.isIncluded(file.name), PathSafety.isSafeRelativePath(file.name), !file.name.contains("/") else { return nil }
        return folder(layout).appendingPathComponent(file.name)
    }
}

/// A credential stored as a few well-known files with long-lived, portable secrets
/// (for example `~/.aws/credentials`). Exactly these files are handled; nothing is searched.
/// Device-bound, Keychain-held or short-lived logins are never handled this way; they are
/// listed in `GuidanceCatalog` as "re-authentication required".
public struct FileCredentialProvider: CredentialProvider {
    public let id: String
    public var titleKey: String { "credentials.\(id).title" }
    public var descriptionKey: String { "credentials.\(id).description" }
    public var riskKey: String { "credentials.\(id).risk" }
    public let isPortable = true
    /// Paths below the home folder.
    public let files: [String]
    public let evidence: [Evidence]

    public init(id: String, files: [String], evidence: [Evidence]) {
        self.id = id
        self.files = files
        self.evidence = evidence
    }

    public func detect(layout: SystemLayout) -> [String] {
        files.filter { path in
            guard PathSafety.isSafeRelativePath(path) else { return false }
            let url = layout.homeDirectory.appendingPathComponent(path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
    }

    public func export(layout: SystemLayout) throws -> [CredentialFile] {
        try detect(layout: layout).map { path in
            let url = layout.homeDirectory.appendingPathComponent(path)
            let permissions = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
            // Never restore anything readable by others, whatever the source permissions were.
            return CredentialFile(name: path, permissions: (permissions & 0o700) == 0 ? 0o600 : (permissions & 0o700), contents: try Data(contentsOf: url))
        }
    }

    public func destination(for file: CredentialFile, layout: SystemLayout) -> URL? {
        guard files.contains(file.name), PathSafety.isSafeRelativePath(file.name) else { return nil }
        return layout.homeDirectory.appendingPathComponent(file.name)
    }
}

public enum CredentialProviders {
    public static let all: [CredentialProvider] = [
        SSHKeyProvider(),
        FileCredentialProvider(id: "aws", files: [".aws/credentials", ".aws/config"], evidence: [
            Evidence(title: "AWS CLI: configuration and credential file settings",
                     url: "https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html")]),
        FileCredentialProvider(id: "gitCredentials", files: [".git-credentials"], evidence: [
            Evidence(title: "git-credential-store", url: "https://git-scm.com/docs/git-credential-store")]),
        FileCredentialProvider(id: "npm", files: [".npmrc"], evidence: [
            Evidence(title: "npm: npmrc", url: "https://docs.npmjs.com/cli/v10/configuring-npm/npmrc")]),
        FileCredentialProvider(id: "kubernetes", files: [".kube/config"], evidence: [
            Evidence(title: "Kubernetes: organizing cluster access using kubeconfig files",
                     url: "https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/")]),
        FileCredentialProvider(id: "terraform", files: [".terraform.d/credentials.tfrc.json"], evidence: [
            Evidence(title: "Terraform CLI: terraform login", url: "https://developer.hashicorp.com/terraform/cli/commands/login")]),
    ]

    public static func provider(id: String) -> CredentialProvider? { all.first { $0.id == id } }
}
