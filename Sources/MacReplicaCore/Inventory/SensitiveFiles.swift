import Foundation

/// What a file that MacReplica leaves out of a backup by policy appears to be. Recorded with the backup issue so the
/// user can see which file it was, why it was left out and what to do – never anything from its contents.
public enum SensitiveKind: String, Codable, Sendable, CaseIterable {
    /// An encrypted password database (KeePass/KeePassXC `.kdbx`). Its contents stay encrypted when copied.
    case passwordDatabase
    /// A KeePass key file (`.keyx`, or `.key` in KeePass's XML format): a second factor that opens a database.
    case keePassKeyFile
    /// A private key (`id_ed25519`, PEM with a private key, `.p12`/`.pfx`).
    case privateKey
    /// A certificate (`.cer`, `.crt`, `.der`, PEM without a private key): usually public, but may belong to a private key.
    case certificate
    /// A PGP key or signature file (`.asc`, `.gpg`).
    case pgpKey
    /// A macOS keychain file: never copied, it only works on the Mac and with the password it was made with.
    case keychain
    /// Browser cookies or saved logins.
    case browserData
    /// Settings files that usually hold secrets (`.env`, `.netrc`).
    case secretsFile
    /// The name suggests a secret ("token", "secret", "credential", "password"); the contents were not checked.
    case nameSuggestsSecret
    /// An unencrypted export of a password manager (1Password `.1pux`/`.1pif`): every password in plain text.
    case passwordManagerExport
    /// Recovery codes, a recovery key or an emergency kit (e.g. `github-recovery-codes.txt`, "Emergency Kit").
    case recoveryMaterial

    /// MacReplica may include the file when the user explicitly asks for it. Keychains and browser data are never
    /// copied: they do not work on another Mac (or contain live sessions), and there are supported ways to move them.
    public var canBeIncludedOnRequest: Bool { self != .keychain && self != .browserData }
}

/// How sure the classification is.
public enum ClassificationConfidence: String, Codable, Sendable {
    /// Recognised by the file format (header bytes) or a definite name such as `id_ed25519`.
    case high
    /// Recognised by the file extension only.
    case medium
    /// Only the name suggests it.
    case low
}

public struct SensitiveClassification: Codable, Equatable, Sendable {
    public var kind: SensitiveKind
    public var confidence: ClassificationConfidence
    public init(kind: SensitiveKind, confidence: ClassificationConfidence) {
        self.kind = kind
        self.confidence = confidence
    }
}

/// Decides whether a file is left out because it looks like a secret, and what it appears to be.
///
/// Only the name and – for ambiguous extensions – the first bytes are read (a Keynote presentation is also `.key`;
/// a PEM file may hold only a public certificate). Nothing read is stored or logged.
public enum SensitiveFileClassifier {
    public static func classify(_ url: URL) -> SensitiveClassification? {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let ext = url.pathExtension.lowercased()
        func header(_ count: Int = 4096) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: count)
        }
        switch ext {
        case "kdbx", "kdb":
            return SensitiveClassification(kind: .passwordDatabase, confidence: KeePassHeader.read(url) != nil ? .high : .medium)
        case "psafe3":
            // Password Safe V3 databases start with the tag `PWS3`.
            let isPasswordSafe = header(4).map { $0 == Data("PWS3".utf8) } ?? false
            return SensitiveClassification(kind: .passwordDatabase, confidence: isPasswordSafe ? .high : .medium)
        case "1pux", "1pif":
            return SensitiveClassification(kind: .passwordManagerExport, confidence: .high)
        case "keyx":
            return SensitiveClassification(kind: .keePassKeyFile, confidence: .high)
        case "key":
            guard let data = header() else { return SensitiveClassification(kind: .privateKey, confidence: .low) }
            // Keynote saves presentations as zip archives with the `.key` extension: a document, not a secret.
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return nil }
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("-----BEGIN") { return SensitiveClassification(kind: .privateKey, confidence: .high) }
            if text.contains("<KeyFile") { return SensitiveClassification(kind: .keePassKeyFile, confidence: .high) }
            return SensitiveClassification(kind: .keePassKeyFile, confidence: .low)
        case "pem":
            let text = header().map { String(decoding: $0, as: UTF8.self) } ?? ""
            return text.contains("PRIVATE KEY") ? SensitiveClassification(kind: .privateKey, confidence: .high)
                                                : SensitiveClassification(kind: .certificate, confidence: text.contains("CERTIFICATE") ? .high : .low)
        case "p12", "pfx":
            return SensitiveClassification(kind: .privateKey, confidence: .medium)
        case "cer", "crt", "der":
            return SensitiveClassification(kind: .certificate, confidence: .medium)
        case "asc", "gpg":
            return SensitiveClassification(kind: .pgpKey, confidence: .medium)
        case "keychain", "keychain-db":
            return SensitiveClassification(kind: .keychain, confidence: .high)
        default:
            break
        }
        if name.range(of: #"^id_(rsa|dsa|ecdsa|ed25519)"#, options: .regularExpression) != nil {
            return SensitiveClassification(kind: .privateKey, confidence: name.hasSuffix(".pub") ? .low : .high)
        }
        // Keys are often saved without an extension under any name (`deploy_ed25519`, `github`): the first line tells.
        if ext.isEmpty, let start = header(64).map({ String(decoding: $0, as: UTF8.self) }), start.hasPrefix("-----BEGIN ") {
            if start.contains("PRIVATE KEY-----") { return SensitiveClassification(kind: .privateKey, confidence: .high) }
            if start.contains("PGP PRIVATE KEY BLOCK") { return SensitiveClassification(kind: .pgpKey, confidence: .high) }
        }
        if lower.range(of: #"^(cookies|login data|web data)(-journal)?$"#, options: .regularExpression) != nil {
            return SensitiveClassification(kind: .browserData, confidence: .high)
        }
        if name == ".netrc" || name.range(of: #"^\.env(\..*)?$"#, options: .regularExpression) != nil {
            return SensitiveClassification(kind: .secretsFile, confidence: .high)
        }
        if lower.range(of: #"(recovery[ _-]?(key|codes?)|backup[ _-]?codes|emergency[ _-]?kit)"#, options: .regularExpression) != nil {
            return SensitiveClassification(kind: .recoveryMaterial, confidence: .medium)
        }
        if lower.range(of: #"(token|secret|credential|password)s?(\.|$)"#, options: .regularExpression) != nil {
            return SensitiveClassification(kind: .nameSuggestsSecret, confidence: .low)
        }
        return nil
    }
}

/// The unencrypted header of a KeePass database: enough to confirm the file is one, without opening it.
public struct KeePassHeader: Equatable, Sendable {
    /// `KDBX 4.1`, `KDBX 3.1`, or `KDB 1` for the old KeePass 1 format.
    public var format: String

    /// Reads the first 12 bytes. KeePass 2 (KDBX): signature `03 D9 A2 9A 67 FB 4B B5`, then minor and major version.
    /// KeePass 1 (KDB): `03 D9 A2 9A 65 FB 4B B5`.
    public static func read(_ url: URL) -> KeePassHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12), data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0...3] == [0x03, 0xD9, 0xA2, 0x9A][0...3], bytes[5...7] == [0xFB, 0x4B, 0xB5][0...2] else { return nil }
        switch bytes[4] {
        case 0x67:
            guard bytes.count >= 12 else { return KeePassHeader(format: "KDBX") }
            let minor = Int(bytes[8]) | Int(bytes[9]) << 8
            let major = Int(bytes[10]) | Int(bytes[11]) << 8
            return KeePassHeader(format: "KDBX \(major).\(minor)")
        case 0x65:
            return KeePassHeader(format: "KDB 1")
        default:
            return nil
        }
    }
}

/// The databases KeePassXC remembers (its own list of recent databases), so they can be offered even when they are
/// outside the folders chosen for the backup. Only paths are read – never the databases or any password.
public enum KeePassXCLocations {
    /// `~/Library/Caches/KeePassXC/keepassxc.ini` keeps `LastDatabases`/`LastOpenedDatabases`/`LastActiveDatabase`
    /// (KeePassXC's `Config.cpp`); older versions kept them in the settings file in Application Support.
    public static func rememberedDatabases(layout: SystemLayout) -> [URL] {
        let home = layout.homeDirectory
        let files = ["Library/Caches/KeePassXC/keepassxc.ini", "Library/Application Support/KeePassXC/keepassxc.ini"]
        var seen = Set<String>()
        var result: [URL] = []
        for file in files {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for path in paths(in: text) where seen.insert(path).inserted {
                let url = layout.resolve(displayPath: path.hasPrefix(home.path + "/") ? "~/" + path.dropFirst(home.path.count + 1) : path)
                if FileManager.default.fileExists(atPath: url.path) { result.append(url) }
            }
        }
        return result
    }

    /// Paths from the `Last…Database(s)` keys of a Qt settings file: a comma-separated list, entries possibly quoted.
    static func paths(in ini: String) -> [String] {
        var result: [String] = []
        for line in ini.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, ["LastDatabases", "LastOpenedDatabases", "LastActiveDatabase"].contains(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("@") else { continue }
            for entry in splitList(value) {
                let path = entry.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                if path.hasPrefix("/"), path.lowercased().hasSuffix(".kdbx") { result.append(path) }
            }
        }
        return result
    }

    /// Splits `a, "b, c", d` at commas outside quotes.
    static func splitList(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" { quoted.toggle(); continue }
            if character == ",", !quoted { items.append(current); current = ""; continue }
            current.append(character)
        }
        items.append(current)
        return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
