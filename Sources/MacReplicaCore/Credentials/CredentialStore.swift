import CommonCrypto
import CryptoKit
import Foundation

/// The encrypted credential store of a backup (format version 2, MacReplica 1.0.7 and later).
///
///     credentials/keys.json          the data key, wrapped once per unlock method (passphrase, recovery key)
///     credentials/items/<id>.mrcred  one encrypted file per credential item
///
/// Design (all primitives from CryptoKit and CommonCrypto; nothing self-made):
/// - A random 256-bit **data key** encrypts every item. It never leaves memory unwrapped.
/// - The data key is wrapped with AES-256-GCM under a key derived from the user's **passphrase**
///   (PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte random salt), and again under the **recovery key**
///   (160 random bits shown to the user once; HKDF-SHA256 because it is already uniformly random).
///   Either one unlocks the store; neither is stored anywhere.
/// - Each item gets its own key: HKDF-SHA256(data key, 32-byte random salt, item ID). Its contents are split into
///   64 KiB records sealed with AES-256-GCM; the nonce is the record counter (unique per key), and the associated
///   data binds the record to the item header, its position and whether it is the last one (the "STREAM"
///   construction), so records cannot be reordered, dropped or appended.
/// - The last record holds the file's size, SHA-256 and permissions – only inside the encryption.
/// - The manifest gets only non-secret facts: the encrypted file's SHA-256 (integrity without the key) and a keyed
///   HMAC of the contents (recognises an identical file at restore time without revealing anything).
public enum CredentialStore {
    public static let keysPath = "credentials/keys.json"
    public static let itemsFolder = "credentials/items"
    public static let formatVersion = 2
    public static let keysFormat = "macreplica-credential-keys"
    public static let itemFormat = "macreplica-credential-item/2"
    public static let algorithmDescription = "AES-256-GCM (64 KiB records), data key wrapped with PBKDF2-HMAC-SHA256 (passphrase) and HKDF-SHA256 (recovery key)"
    public static let minimumPassphraseLength = 12
    public static let defaultIterations = 600_000
    static let minimumIterations = 100_000
    static let recordSize = 64 * 1024
    static let magic = Data("MRCRED\u{0}\u{2}".utf8)

    public static func itemPath(_ id: String) -> String { "\(itemsFolder)/\(id).mrcred" }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case passphraseTooShort
    /// Neither the passphrase nor the recovery key opens the store (or the key file was changed).
    case wrongSecret
    case recoveryKeyMalformed
    case unsupportedFormat
    /// An encrypted item is damaged, truncated or belongs to another backup.
    case itemDamaged
    case randomFailed
    case keyDerivationFailed
    /// The source file changed while it was being encrypted.
    case sourceChanged
    case sourceUnreadable
}

/// What unlocks the store.
public enum CredentialSecret: Sendable {
    case passphrase(String)
    case recoveryKey(String)
}

/// A recovery key: 28 random Crockford-Base32 characters (140 bits) plus a 4-character checksum, written in groups
/// of four (`7KQ2-…`). The checksum catches typing mistakes before any decryption is attempted.
public struct RecoveryKey: Equatable, Sendable {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let dataCharacters = 28
    public let text: String

    public static func generate() throws -> RecoveryKey {
        var bytes = [UInt8](repeating: 0, count: dataCharacters)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CredentialStoreError.randomFailed }
        let data = String(bytes.map { alphabet[Int($0 & 31)] })
        bytes.resetAll()
        return RecoveryKey(normalized: data + checksum(data))
    }

    private init(normalized: String) {
        text = stride(from: 0, to: normalized.count, by: 4).map { start in
            let s = normalized.index(normalized.startIndex, offsetBy: start)
            return String(normalized[s..<normalized.index(s, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Accepts what the user typed: any case, spaces or dashes, and the usual look-alikes (O → 0, I/L → 1).
    public init(parsing input: String) throws {
        let mapped = input.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ", "\n", "\t": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        }
        let normalized = String(mapped)
        guard normalized.count == Self.dataCharacters + 4, normalized.allSatisfy(Self.alphabet.contains) else {
            throw CredentialStoreError.recoveryKeyMalformed
        }
        let data = String(normalized.prefix(Self.dataCharacters))
        guard Self.checksum(data) == String(normalized.suffix(4)) else { throw CredentialStoreError.recoveryKeyMalformed }
        self.init(normalized: normalized)
    }

    static func checksum(_ data: String) -> String {
        let digest = Array(SHA256.hash(data: Data(data.utf8)))
        return String((0..<4).map { alphabet[Int(digest[$0] & 31)] })
    }

    /// The characters without dashes, used as key material.
    var material: Data { Data(text.replacingOccurrences(of: "-", with: "").utf8) }
}

/// The unwrapped data key of one backup's store. Held in memory only while a backup is written or restored.
public struct CredentialKeyring: Sendable {
    let dataKey: SymmetricKey
    /// A short public fingerprint of the data key, written into every item header (to detect items of another backup).
    public let keyID: String

    init(dataKey: SymmetricKey) {
        self.dataKey = dataKey
        keyID = Self.derive(dataKey, info: "macreplica-key-id").withUnsafeBytes { Data($0).prefix(8).map { String(format: "%02x", $0) }.joined() }
    }

    public static func generate() throws -> CredentialKeyring {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { throw CredentialStoreError.randomFailed }
        defer { bytes.resetAll() }
        return CredentialKeyring(dataKey: SymmetricKey(data: bytes))
    }

    static func derive(_ key: SymmetricKey, salt: Data = Data(), info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Keyed HMAC of a file's contents: the same file gives the same value with this keyring, nothing else can be learned.
    var contentKey: SymmetricKey { Self.derive(dataKey, info: "macreplica-content-id") }

    public func contentHMAC(ofFile url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CredentialStoreError.sourceUnreadable }
        defer { try? handle.close() }
        var mac = HMAC<SHA256>(key: contentKey)
        while let chunk = try handle.read(upToCount: CredentialStore.recordSize), !chunk.isEmpty { mac.update(data: chunk) }
        return Data(mac.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Key file

    struct KeyFile: Codable {
        struct Slot: Codable {
            var kind: String
            var kdf: String
            var iterations: Int?
            var salt: Data
            var wrappedKey: Data
        }
        var format: String
        var version: Int
        var cipher: String
        var keyId: String
        var slots: [Slot]
    }

    static func slotAAD(_ kind: String) -> Data { Data("\(CredentialStore.keysFormat)/\(CredentialStore.formatVersion)/\(kind)".utf8) }

    /// `keys.json`: the data key wrapped under the passphrase and under the recovery key.
    public func keyFile(passphrase: String, recoveryKey: RecoveryKey, iterations: Int = CredentialStore.defaultIterations) throws -> Data {
        guard passphrase.count >= CredentialStore.minimumPassphraseLength else { throw CredentialStoreError.passphraseTooShort }
        let passSalt = try Self.random(16)
        let passKey = try Self.passphraseKey(passphrase, salt: passSalt, iterations: iterations)
        let recoverySalt = try Self.random(16)
        let recoveryKeyKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey.material), salt: recoverySalt,
                                                    info: Data("macreplica-recovery-key".utf8), outputByteCount: 32)
        let raw = dataKey.withUnsafeBytes { Data($0) }
        func wrap(_ key: SymmetricKey, _ kind: String) throws -> Data {
            guard let combined = try AES.GCM.seal(raw, using: key, authenticating: Self.slotAAD(kind)).combined else {
                throw CredentialStoreError.unsupportedFormat
            }
            return combined
        }
        let file = KeyFile(format: CredentialStore.keysFormat, version: CredentialStore.formatVersion, cipher: "AES-256-GCM", keyId: keyID, slots: [
            .init(kind: "passphrase", kdf: "PBKDF2-HMAC-SHA256", iterations: iterations, salt: passSalt, wrappedKey: try wrap(passKey, "passphrase")),
            .init(kind: "recoveryKey", kdf: "HKDF-SHA256", iterations: nil, salt: recoverySalt, wrappedKey: try wrap(recoveryKeyKey, "recoveryKey")),
        ])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Opens `keys.json` with the passphrase or the recovery key.
    public static func unlock(keyFile data: Data, with secret: CredentialSecret) throws -> CredentialKeyring {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let file = try? decoder.decode(KeyFile.self, from: data), file.format == CredentialStore.keysFormat,
              file.version == CredentialStore.formatVersion, file.cipher == "AES-256-GCM" else {
            throw CredentialStoreError.unsupportedFormat
        }
        let kind: String
        let key: SymmetricKey
        switch secret {
        case .passphrase(let passphrase):
            kind = "passphrase"
            guard let slot = file.slots.first(where: { $0.kind == kind }), slot.kdf == "PBKDF2-HMAC-SHA256",
                  let iterations = slot.iterations, iterations >= CredentialStore.minimumIterations, slot.salt.count >= 16 else {
                throw CredentialStoreError.unsupportedFormat
            }
            key = try passphraseKey(passphrase, salt: slot.salt, iterations: iterations)
        case .recoveryKey(let text):
            kind = "recoveryKey"
            let recovery = try RecoveryKey(parsing: text)
            guard let slot = file.slots.first(where: { $0.kind == kind }), slot.kdf == "HKDF-SHA256", slot.salt.count >= 16 else {
                throw CredentialStoreError.unsupportedFormat
            }
            key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recovery.material), salt: slot.salt,
                                         info: Data("macreplica-recovery-key".utf8), outputByteCount: 32)
        }
        guard let slot = file.slots.first(where: { $0.kind == kind }),
              let box = try? AES.GCM.SealedBox(combined: slot.wrappedKey),
              var raw = try? AES.GCM.open(box, using: key, authenticating: slotAAD(kind)), raw.count == 32 else {
            throw CredentialStoreError.wrongSecret
        }
        defer { raw.resetBytes(in: 0..<raw.count) }
        let keyring = CredentialKeyring(dataKey: SymmetricKey(data: raw))
        // The fingerprint in the file must belong to the key it wraps.
        guard keyring.keyID == file.keyId else { throw CredentialStoreError.wrongSecret }
        return keyring
    }

    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw CredentialStoreError.randomFailed }
        return Data(bytes)
    }

    static func passphraseKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer { password.resetAll(); derived.resetAll() }
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { pointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, pw.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw CredentialStoreError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

extension Array where Element == UInt8 {
    /// Overwrites secret bytes before the buffer is released.
    mutating func resetAll() { for index in indices { self[index] = 0 } }
}

/// What sealing one file produced (no secrets).
public struct SealedItem: Equatable, Sendable {
    public var plaintextSize: Int64
    public var plaintextSHA256: String
    public var contentHMAC: String
    public var encryptedSize: Int64
    public var encryptedSHA256: String
}

/// The facts stored inside the last encrypted record of an item.
public struct CredentialTrailer: Codable, Equatable, Sendable {
    public var size: Int64
    public var sha256: String
    public var permissions: Int
    public var name: String
}

/// Encrypts and decrypts single credential files (see `CredentialStore` for the format).
public enum CredentialItemCipher {
    struct Header: Codable {
        var format: String
        var itemId: String
        var keyId: String
        var salt: Data
        var recordSize: Int
    }

    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { bytes[11 - index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))) }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func aad(_ headerDigest: Data, _ counter: UInt64, final: Bool) -> Data {
        var data = headerDigest
        for index in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index)))) }
        data.append(final ? 1 : 0)
        return data
    }

    static func uint32(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// Encrypts `source` into `destination` (created new, never overwritten) and checks the result by decrypting it
    /// again. The source is hashed a second time afterwards: if it changed while it was read, nothing is kept.
    public static func seal(source: URL, to destination: URL, itemID: String, keyring: CredentialKeyring, permissions: Int) throws -> SealedItem {
        guard let input = try? FileHandle(forReadingFrom: source) else { throw CredentialStoreError.sourceUnreadable }
        defer { try? input.close() }
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let salt = try CredentialKeyring.random(32)
            let header = Header(format: CredentialStore.itemFormat, itemId: itemID, keyId: keyring.keyID, salt: salt, recordSize: CredentialStore.recordSize)
            let headerData = try JSONEncoder.sorted.encode(header)
            let digest = Data(SHA256.hash(data: headerData))
            let key = CredentialKeyring.derive(keyring.dataKey, salt: salt, info: "\(CredentialStore.itemFormat)/\(itemID)")
            var encryptedHash = SHA256()
            func emit(_ data: Data) throws {
                encryptedHash.update(data: data)
                try output.write(contentsOf: data)
            }
            try emit(CredentialStore.magic + uint32(headerData.count) + headerData)
            var plainHash = SHA256()
            var mac = HMAC<SHA256>(key: keyring.contentKey)
            var counter: UInt64 = 0
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: CredentialStore.recordSize), !chunk.isEmpty {
                plainHash.update(data: chunk)
                mac.update(data: chunk)
                size += Int64(chunk.count)
                let sealed = try AES.GCM.seal(chunk, using: key, nonce: try nonce(counter), authenticating: aad(digest, counter, final: false))
                let record = sealed.ciphertext + sealed.tag
                try emit(uint32(record.count) + record)
                counter += 1
            }
            let sha = Data(plainHash.finalize()).hex
            let trailer = CredentialTrailer(size: size, sha256: sha, permissions: permissions, name: source.lastPathComponent)
            let sealed = try AES.GCM.seal(try JSONEncoder.sorted.encode(trailer), using: key, nonce: try nonce(counter),
                                          authenticating: aad(digest, counter, final: true))
            try emit(uint32(sealed.ciphertext.count + 16) + sealed.ciphertext + sealed.tag)
            try output.synchronize()
            try output.close()
            // Read back: every record must open and the contents must be the ones that were read.
            guard try open(destination, itemID: itemID, keyring: keyring, writingTo: nil) == trailer else { throw CredentialStoreError.itemDamaged }
            guard (try? Hashing.sha256Hex(ofFile: source)) == sha else { throw CredentialStoreError.sourceChanged }
            let encryptedSize = (try fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            return SealedItem(plaintextSize: size, plaintextSHA256: sha, contentHMAC: Data(mac.finalize()).hex,
                              encryptedSize: encryptedSize, encryptedSHA256: Data(encryptedHash.finalize()).hex)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Decrypts an item, writing the contents to `output` (or only checking every record when nil).
    /// Throws `itemDamaged` for any change, truncation, extension or an item of another backup.
    @discardableResult
    public static func open(_ url: URL, itemID: String, keyring: CredentialKeyring, writingTo output: FileHandle?) throws -> CredentialTrailer {
        guard let input = try? FileHandle(forReadingFrom: url) else { throw CredentialStoreError.itemDamaged }
        defer { try? input.close() }
        func read(_ count: Int) throws -> Data {
            guard let data = try input.read(upToCount: count), data.count == count else { throw CredentialStoreError.itemDamaged }
            return data
        }
        func length() throws -> Int { try read(4).reduce(0) { $0 << 8 | Int($1) } }
        guard try read(CredentialStore.magic.count) == CredentialStore.magic else { throw CredentialStoreError.unsupportedFormat }
        let headerLength = try length()
        guard headerLength > 0, headerLength < 4096 else { throw CredentialStoreError.itemDamaged }
        let headerData = try read(headerLength)
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData), header.format == CredentialStore.itemFormat else {
            throw CredentialStoreError.unsupportedFormat
        }
        guard header.itemId == itemID, header.keyId == keyring.keyID, header.salt.count == 32,
              header.recordSize == CredentialStore.recordSize else { throw CredentialStoreError.itemDamaged }
        let digest = Data(SHA256.hash(data: headerData))
        let key = CredentialKeyring.derive(keyring.dataKey, salt: header.salt, info: "\(CredentialStore.itemFormat)/\(itemID)")
        var counter: UInt64 = 0
        var hash = SHA256()
        var size: Int64 = 0
        while true {
            let recordLength = try length()
            // A data record holds at most one record of contents plus its tag; the final record is far smaller.
            guard recordLength >= 16, recordLength <= header.recordSize + 16 else { throw CredentialStoreError.itemDamaged }
            let record = try read(recordLength)
            let box = try AES.GCM.SealedBox(nonce: try nonce(counter), ciphertext: record.prefix(recordLength - 16), tag: record.suffix(16))
            // A data record, or the final record holding the trailer: exactly one of the two opens.
            if let plain = try? AES.GCM.open(box, using: key, authenticating: aad(digest, counter, final: false)) {
                guard plain.count <= header.recordSize else { throw CredentialStoreError.itemDamaged }
                hash.update(data: plain)
                size += Int64(plain.count)
                try output?.write(contentsOf: plain)
                counter += 1
                continue
            }
            guard let plain = try? AES.GCM.open(box, using: key, authenticating: aad(digest, counter, final: true)),
                  let trailer = try? JSONDecoder().decode(CredentialTrailer.self, from: plain) else { throw CredentialStoreError.itemDamaged }
            // Nothing may follow the final record, and the trailer must describe what was decrypted.
            guard try input.read(upToCount: 1)?.isEmpty ?? true, trailer.size == size, trailer.sha256 == Data(hash.finalize()).hex else {
                throw CredentialStoreError.itemDamaged
            }
            return trailer
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
