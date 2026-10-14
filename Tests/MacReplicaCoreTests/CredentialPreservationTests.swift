import CryptoKit
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Passwords, keys and credential files (1.0.7): chosen item by item, encrypted per item, accounted for in the manifest
/// and reports, restored only with an explicit conflict decision. All fixtures are synthetic.
@Suite("Credential preservation")
struct CredentialPreservationTests {
    static let passphrase = "synthetic test passphrase"
    /// Assembled so secret scanners do not mistake the fixtures for real keys.
    static let privateMarker = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
    static let privateKey = Data((privateMarker + "\nsynthetic-cred-key-material\n-----END " + "OPENSSH PRIVATE KEY-----\n").utf8)
    static let kdbx = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 0x01, 0x00, 0x04, 0x00]) + Data("synthetic-kdbx-body".utf8)

    static func keyring() throws -> CredentialKeyring { try CredentialKeyring.generate() }

    static func write(_ data: Data, _ relative: String, in root: SimulationRoot) throws -> URL {
        let url = root.url.appendingPathComponent("home").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func seal(_ data: Data, in sandbox: Sandbox, id: String = "cred-test", keyring: CredentialKeyring) throws -> (URL, SealedItem) {
        let source = sandbox.url.appendingPathComponent("source-\(UUID().uuidString)")
        try data.write(to: source)
        let target = sandbox.url.appendingPathComponent("\(UUID().uuidString).mrcred")
        return (target, try CredentialItemCipher.seal(source: source, to: target, itemID: id, keyring: keyring, permissions: 0o600))
    }

    func decrypt(_ url: URL, id: String = "cred-test", keyring: CredentialKeyring, in sandbox: Sandbox) throws -> Data {
        let out = sandbox.url.appendingPathComponent("plain-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        try CredentialItemCipher.open(url, itemID: id, keyring: keyring, writingTo: handle)
        try handle.close()
        return try Data(contentsOf: out)
    }

    // MARK: Encryption format

    @Test func itemsRoundTripForEmptySmallAndMultiRecordFiles() throws {
        let sandbox = try Sandbox("cred-roundtrip-sizes")
        let keyring = try Self.keyring()
        for size in [0, 1, CredentialStore.recordSize - 1, CredentialStore.recordSize, CredentialStore.recordSize * 3 + 17] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let (url, sealed) = try seal(data, in: sandbox, keyring: keyring)
            #expect(try decrypt(url, keyring: keyring, in: sandbox) == data, "size \(size)")
            #expect(sealed.plaintextSize == Int64(size))
            #expect(sealed.plaintextSHA256 == Hashing.sha256Hex(of: data))
            #expect(sealed.encryptedSHA256 == (try Hashing.sha256Hex(ofFile: url)))
            #expect(sealed.encryptedSize == Int64(try Data(contentsOf: url).count))
            let copy = sandbox.url.appendingPathComponent("copy-\(size)")
            try data.write(to: copy)
            #expect(try keyring.contentHMAC(ofFile: copy) == sealed.contentHMAC, "the keyed HMAC is over the plain bytes")
        }
    }

    @Test func ciphertextNeverContainsThePlaintextAndEveryItemIsDifferent() throws {
        let sandbox = try Sandbox("cred-ciphertext")
        let keyring = try Self.keyring()
        let (a, sealedA) = try seal(Self.privateKey, in: sandbox, keyring: keyring)
        let (b, sealedB) = try seal(Self.privateKey, in: sandbox, keyring: keyring)
        let bytesA = try Data(contentsOf: a)
        #expect(bytesA.range(of: Data("synthetic-cred-key-material".utf8)) == nil)
        #expect(bytesA != (try Data(contentsOf: b)), "a fresh salt per item: same contents, different ciphertext")
        #expect(sealedA.contentHMAC == sealedB.contentHMAC, "the keyed HMAC recognises the same contents")
        #expect(sealedA.contentHMAC != Hashing.sha256Hex(of: Self.privateKey), "never the plain SHA-256")
    }

    @Test func anyChangeTruncationOrExtensionIsDetected() throws {
        let sandbox = try Sandbox("cred-tamper")
        let keyring = try Self.keyring()
        let data = Data((0..<(CredentialStore.recordSize + 100)).map { UInt8(truncatingIfNeeded: $0) })
        let (url, _) = try seal(data, in: sandbox, keyring: keyring)
        let original = try Data(contentsOf: url)
        // Flip one byte in the magic, the header, the first record, its tag, and the final record.
        for offset in [0, 20, original.count / 3, CredentialStore.recordSize / 2, original.count - 30, original.count - 1] {
            var damaged = original
            damaged[offset] ^= 0x01
            try damaged.write(to: url)
            #expect(throws: (any Error).self, "offset \(offset)") { try decrypt(url, keyring: keyring, in: sandbox) }
        }
        try original.dropLast(40).write(to: url)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        try (original + Data([0])).write(to: url)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        // Without the final record (cut exactly at a record boundary) the item is incomplete.
        let lengthOfFirst = 8 + 4 + Int(original[8...11].reduce(0) { $0 << 8 | UInt32($1) })
        let firstRecord = 4 + Int(original[lengthOfFirst..<(lengthOfFirst + 4)].reduce(0) { $0 << 8 | UInt32($1) })
        try original.prefix(lengthOfFirst + firstRecord).write(to: url)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        // A header length of zero, or one that claims more than any header has, is refused before anything is read.
        for length in [UInt8](arrayLiteral: 0x00, 0x10) {
            try (CredentialStore.magic + Data([length, 0x00, 0x00, 0x00]) + Data(count: 64)).write(to: url)
            #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        }
        // 4096 bytes are already too many for a header, even when the file really has them.
        try (CredentialStore.magic + Data([0x00, 0x00, 0x10, 0x00]) + Data(repeating: 0x20, count: 4096 + 64)).write(to: url)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        // A record that claims to be longer than a record can be is refused.
        var oversized = original
        let headerEnd = 8 + 4 + Int(original[8...11].reduce(0) { $0 << 8 | UInt32($1) })
        let tooLong = UInt32(CredentialStore.recordSize + 17)
        oversized.replaceSubrange(headerEnd..<(headerEnd + 4), with: [UInt8(tooLong >> 24), UInt8(tooLong >> 16 & 0xFF), UInt8(tooLong >> 8 & 0xFF), UInt8(tooLong & 0xFF)])
        try oversized.write(to: url)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, keyring: keyring, in: sandbox) }
        try original.write(to: url)
        #expect(try decrypt(url, keyring: keyring, in: sandbox) == data)
    }

    @Test func itemsOfAnotherBackupOrAnotherItemDoNotOpen() throws {
        let sandbox = try Sandbox("cred-binding")
        let keyring = try Self.keyring()
        let (url, _) = try seal(Self.kdbx, in: sandbox, id: "cred-a", keyring: keyring)
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, id: "cred-b", keyring: keyring, in: sandbox) }
        #expect(throws: CredentialStoreError.itemDamaged) { try decrypt(url, id: "cred-a", keyring: try Self.keyring(), in: sandbox) }
        #expect(try decrypt(url, id: "cred-a", keyring: keyring, in: sandbox) == Self.kdbx)
    }

    @Test func keyFileOpensWithPassphraseOrRecoveryKeyOnly() throws {
        let keyring = try Self.keyring()
        let recovery = try RecoveryKey.generate()
        let file = try keyring.keyFile(passphrase: Self.passphrase, recoveryKey: recovery, iterations: 100_000)
        let text = String(decoding: file, as: UTF8.self)
        #expect(!text.contains(Self.passphrase) && !text.contains(recovery.text.replacingOccurrences(of: "-", with: "")))
        #expect(try CredentialKeyring.unlock(keyFile: file, with: .passphrase(Self.passphrase)).keyID == keyring.keyID)
        #expect(try CredentialKeyring.unlock(keyFile: file, with: .recoveryKey(recovery.text.lowercased())).keyID == keyring.keyID)
        #expect(throws: CredentialStoreError.wrongSecret) { try CredentialKeyring.unlock(keyFile: file, with: .passphrase("wrong passphrase value")) }
        #expect(throws: CredentialStoreError.wrongSecret) {
            try CredentialKeyring.unlock(keyFile: file, with: .recoveryKey(try RecoveryKey.generate().text))
        }
        #expect(throws: CredentialStoreError.passphraseTooShort) { try keyring.keyFile(passphrase: "short", recoveryKey: recovery) }
        // Exactly the minimum length is enough; one character less is not.
        #expect(throws: CredentialStoreError.passphraseTooShort) { try keyring.keyFile(passphrase: "elevenchars", recoveryKey: recovery, iterations: 100_000) }
        let minimum = try keyring.keyFile(passphrase: "twelve-chars", recoveryKey: recovery, iterations: 100_000)
        #expect(try CredentialKeyring.unlock(keyFile: minimum, with: .passphrase("twelve-chars")).keyID == keyring.keyID)
        // A weakened or changed key file is refused, not silently accepted.
        let weakened = text.replacingOccurrences(of: "\"iterations\" : 100000", with: "\"iterations\" : 1000")
        #expect(throws: CredentialStoreError.unsupportedFormat) { try CredentialKeyring.unlock(keyFile: Data(weakened.utf8), with: .passphrase(Self.passphrase)) }
        var object = try JSONSerialization.jsonObject(with: file) as! [String: Any]
        object["key_id"] = "0000000000000000"
        #expect(throws: CredentialStoreError.wrongSecret) {
            try CredentialKeyring.unlock(keyFile: JSONSerialization.data(withJSONObject: object), with: .passphrase(Self.passphrase))
        }
        #expect(throws: CredentialStoreError.unsupportedFormat) { try CredentialKeyring.unlock(keyFile: Data("{}".utf8), with: .passphrase(Self.passphrase)) }
    }

    @Test func recoveryKeysAreRandomTypedFriendlyAndChecked() throws {
        let key = try RecoveryKey.generate()
        #expect(key.text.count == 39 && key.text.split(separator: "-").count == 8)
        #expect(try RecoveryKey.generate() != key)
        #expect(try RecoveryKey(parsing: " " + key.text.lowercased().replacingOccurrences(of: "-", with: " ") + "\n") == key)
        // Look-alikes are accepted: O for 0, I and L for 1.
        let lookAlike = key.text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")
        #expect(try RecoveryKey(parsing: lookAlike) == key)
        var typo = Array(key.text)
        typo[0] = typo[0] == "2" ? "3" : "2"
        #expect(throws: CredentialStoreError.recoveryKeyMalformed) { try RecoveryKey(parsing: String(typo)) }
        #expect(throws: CredentialStoreError.recoveryKeyMalformed) { try RecoveryKey(parsing: String(key.text.dropLast(5))) }
        #expect(throws: CredentialStoreError.recoveryKeyMalformed) { try RecoveryKey(parsing: key.text + "-AAAA") }
    }

    // MARK: Selecting

    /// The 1.0.5/1.0.6 bug: after one key or database was included, further ones could not be added (the include created
    /// a hidden one-file folder; a second include into a folder chosen later silently did nothing, and files in the home
    /// folder or iCloud Drive could not be included at all).
    @Test func severalItemsFromOneFolderAndFromAnywhereCanBeAdded() async throws {
        let sandbox = try Sandbox("cred-multi")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        let home = source.layout.homeDirectory.path
        for name in ["A.kdbx", "B.kdbx"] { _ = try Self.write(Self.kdbx, "Sync/\(name)", in: root) }
        _ = try Self.write(Data("<KeyFile/>".utf8), "Sync/A.keyx", in: root)
        _ = try Self.write(Self.kdbx, "Passwords.kdbx", in: root)
        _ = try Self.write(Self.kdbx, "Library/Mobile Documents/com~apple~CloudDocs/Vault.kdbx", in: root)
        _ = try Self.write(Data("[General]\nLastDatabases=\(home)/Sync/A.kdbx, \(home)/Passwords.kdbx, \(home)/Library/Mobile Documents/com~apple~CloudDocs/Vault.kdbx\n".utf8),
                           "Library/Caches/KeePassXC/keepassxc.ini", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        #expect(Set(inventory.manifest.undecidedCredentials.map(\.fileName)) == ["A.kdbx", "Passwords.kdbx", "Vault.kdbx"])
        for path in ["~/Sync/A.kdbx", "~/Passwords.kdbx", "~/Library/Mobile Documents/com~apple~CloudDocs/Vault.kdbx"] {
            try inventory.includeOnRequest(path, layout: source.layout)
        }
        #expect(inventory.credentialSelection.count == 3)
        #expect(inventory.manifest.undecidedCredentials.isEmpty)
        #expect(inventory.rememberedPasswordDatabases(layout: source.layout).isEmpty, "included databases are not offered again")
        #expect(!inventory.manifest.applicationData.contains { $0.isPersonal }, "no hidden one-file folders any more")
        // Later the user also chooses ~/Sync as one of their folders: its other secrets are listed, the chosen one is not.
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Sync"))
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        #expect(Set(inventory.manifest.undecidedCredentials.map(\.fileName)) == ["B.kdbx", "A.keyx"])
        #expect(!inventory.manifest.backupIssues.contains { $0.detail == .rememberedByApp }, "inside a chosen folder now")
        try inventory.includeOnRequest("~/Sync/B.kdbx", layout: source.layout)
        try inventory.includeOnRequest("~/Sync/A.keyx", layout: source.layout)
        #expect(inventory.credentialSelection.map(\.fileName).sorted() == ["A.kdbx", "A.keyx", "B.kdbx", "Passwords.kdbx", "Vault.kdbx"])
        #expect(inventory.manifest.undecidedCredentials.isEmpty)
        #expect(Set(inventory.credentialSelection.map(\.id)).count == 5)
        #expect(inventory.credentialSelection.first { $0.fileName == "A.kdbx" }?.format == "KDBX 4.1")
    }

    @Test func pickerAddsFilesAndFoldersWithoutDuplicatesLoopsOrUnrelatedFiles() async throws {
        let sandbox = try Sandbox("cred-picker")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        var inventory = try await TestEnvironment.inventory(source).run()
        let keys = source.layout.homeDirectory.appendingPathComponent("Keys")
        let a = try Self.write(Self.privateKey, "Keys/work/id_ed25519", in: root)
        let b = try Self.write(Self.privateKey, "Keys/home/id_ed25519", in: root)
        _ = try Self.write(Data("ssh-ed25519 AAAA synthetic\n".utf8), "Keys/home/id_ed25519.pub", in: root)
        _ = try Self.write(Self.privateKey + Data("deploy".utf8), "Keys/deploy/deploy_ed25519", in: root)
        _ = try Self.write(Data("ssh-ed25519 AAAA synthetic deploy\n".utf8), "Keys/deploy/deploy_ed25519.pub", in: root)
        _ = try Self.write(Data("ssh-ed25519 AAAA stray\n".utf8), "Keys/stray.pub", in: root)
        _ = try Self.write(Data("holiday notes".utf8), "Keys/notes.txt", in: root)
        _ = try Self.write(Data(), "Keys/old.keychain-db", in: root)
        // A link back to the folder itself must not make the walk loop or add anything twice.
        try FileManager.default.createSymbolicLink(at: keys.appendingPathComponent("loop"), withDestinationURL: keys)
        try FileManager.default.createSymbolicLink(at: keys.appendingPathComponent("link-to-a"), withDestinationURL: a)
        let report = inventory.addCredentialFiles([keys], layout: source.layout)
        #expect(Set(report.added) == ["~/Keys/work/id_ed25519", "~/Keys/home/id_ed25519", "~/Keys/home/id_ed25519.pub",
                                      "~/Keys/deploy/deploy_ed25519", "~/Keys/deploy/deploy_ed25519.pub"])
        #expect(report.refused.map(\.problem) == [.keychainNotCopyable])
        #expect(report.unrecognisedInFolders == 2, "notes.txt and a public key without its private key are left alone")
        #expect(inventory.credentialSelection.first { $0.fileName == "deploy_ed25519.pub" }?.category == .publicKey)
        #expect(inventory.credentialSelection.first { $0.fileName == "deploy_ed25519" }?.category == .privateKey)
        #expect(Set(report.sameContents) == ["~/Keys/work/id_ed25519", "~/Keys/home/id_ed25519"], "same contents: both kept")
        // The same files again, directly and through the link: nothing new.
        let again = inventory.addCredentialFiles([a, b, keys.appendingPathComponent("link-to-a")], layout: source.layout)
        #expect(again.added.isEmpty && again.alreadySelected.count == 3)
        #expect(inventory.credentialSelection.count == 5)
        // A file chosen directly is taken even if MacReplica does not recognise it.
        let notes = inventory.addCredentialFiles([keys.appendingPathComponent("notes.txt")], layout: source.layout)
        #expect(notes.added == ["~/Keys/notes.txt"])
        #expect(inventory.credentialSelection.first { $0.fileName == "notes.txt" }?.category == .otherSecret)
        // Problems are reported with the reason; nothing silently disappears.
        let missing = inventory.addCredentialFiles([keys.appendingPathComponent("gone.kdbx")], layout: source.layout)
        #expect(missing.refused.map(\.problem) == [.missing])
        let locked = try Self.write(Self.kdbx, "Keys/locked.kdbx", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        #expect(inventory.addCredentialFiles([locked], layout: source.layout).refused.map(\.problem) == [.unreadable])
        let browser = try Self.write(Data(), "Keys/Login Data", in: root)
        #expect(inventory.addCredentialFiles([browser], layout: source.layout).refused.map(\.problem) == [.browserStoreNotCopyable])
        let empty = try sandbox.folder("source/home/Empty")
        #expect(inventory.addCredentialFiles([empty], layout: source.layout).refused.map(\.problem) == [.nothingRecognised])
    }

    @Test func removingLeavingOutAndUndoingAreRecorded() async throws {
        let sandbox = try Sandbox("cred-decisions")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        _ = try Self.write(Self.kdbx, "Vault/One.kdbx", in: root)
        _ = try Self.write(Self.kdbx, "Vault/Two.kdbx", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Vault"))
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        let two = try #require(inventory.manifest.undecidedCredentials.first { $0.fileName == "Two.kdbx" })
        inventory.leaveOutCredential(path: two.path)
        #expect(inventory.manifest.credentialsLeftOutByUser.map(\.fileName) == ["Two.kdbx"])
        #expect(inventory.manifest.undecidedCredentials.map(\.fileName) == ["One.kdbx"])
        // A rescan of the folder keeps the decision.
        let rescan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Vault"))
        inventory.addApplicationData(rescan.folder, files: rescan.files, issues: rescan.issues)
        #expect(inventory.manifest.credentialsLeftOutByUser.map(\.fileName) == ["Two.kdbx"])
        #expect(inventory.manifest.excludedSensitiveFiles.count == 2, "listed once each")
        let one = try #require(inventory.manifest.undecidedCredentials.first { $0.fileName == "One.kdbx" })
        inventory.leaveOutCredential(path: one.path)
        inventory.reconsiderCredential(path: two.path)
        #expect(inventory.manifest.credentialsLeftOutByUser.map(\.fileName) == ["One.kdbx"], "only the file the user undid")
        inventory.reconsiderCredential(path: one.path)
        #expect(inventory.manifest.credentialsLeftOutByUser.isEmpty)
        try inventory.includeOnRequest("~/Vault/One.kdbx", layout: source.layout)
        let item = try #require(inventory.credentialSelection.first)
        inventory.removeCredentialFile(id: item.id, layout: source.layout)
        #expect(inventory.credentialSelection.isEmpty)
        #expect(inventory.manifest.credentialsLeftOutByUser.map(\.fileName) == ["One.kdbx"], "taken out = left out by the user, still listed")
    }

    @Test func removingOneFolderKeepsTheIssuesOfOthers() async throws {
        let sandbox = try Sandbox("cred-nested")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        _ = try Self.write(Self.kdbx, "Documents/Keys/Inner.kdbx", in: root)
        _ = try Self.write(Data("x".utf8), "Documents/readme.txt", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let scanner = AppDataScanner(layout: source.layout)
        let outer = try scanner.scanPersonal(source.layout.homeDirectory.appendingPathComponent("Documents"))
        let inner = try scanner.scanPersonal(source.layout.homeDirectory.appendingPathComponent("Documents/Keys"))
        inventory.addApplicationData(outer.folder, files: outer.files, issues: outer.issues)
        inventory.addApplicationData(inner.folder, files: inner.files, issues: inner.issues)
        #expect(inventory.manifest.excludedSensitiveFiles.map(\.fileName) == ["Inner.kdbx"])
        inventory.removeApplicationData(id: outer.folder.id)
        #expect(inventory.manifest.excludedSensitiveFiles.map(\.fileName) == ["Inner.kdbx"], "still listed: the inner folder is still chosen")
    }

    // MARK: Backup

    func backup(_ sandbox: Sandbox, _ inventory: InventoryResult, layout: SystemLayout, providers: [String] = [],
                recovery: RecoveryKey? = nil, log: LogStore? = nil, request: Bool = true) throws -> BackupOutcome {
        let key = try recovery ?? RecoveryKey.generate()
        return try BackupWriter(layout: layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("out-\(UUID().uuidString)"), log: log ?? LogStore(fileURL: nil, homeDirectory: layout.homeDirectory),
                   credentials: request ? CredentialExportRequest(providerIDs: providers, passphrase: Self.passphrase, recoveryKey: key) : nil)
    }

    @Test func backupStoresEveryItemEncryptedVerifiedAndAccountedFor() async throws {
        let sandbox = try Sandbox("cred-backup")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        _ = try Self.write(Self.kdbx, "Vault/Family.kdbx", in: root)
        _ = try Self.write(Self.privateKey, "Keys/deploy_key", in: root)
        _ = try Self.write(Data("github-recovery-code-synthetic-1111\n".utf8), "Documents/github-recovery-codes.txt", in: root)
        let home = source.layout.homeDirectory
        var inventory = try await TestEnvironment.inventory(source).run()
        inventory.addCredentialFiles([home.appendingPathComponent("Vault/Family.kdbx"), home.appendingPathComponent("Keys/deploy_key"),
                                      home.appendingPathComponent("Documents/github-recovery-codes.txt")], layout: source.layout)
        let log = LogStore(fileURL: nil, homeDirectory: home)
        let outcome = try backup(sandbox, inventory, layout: source.layout, providers: ["ssh", "aws"], log: log)
        let manifest = try ManifestIO.read(from: outcome.url)
        #expect(manifest.manifestVersion == 4 && manifest.credentialItems.count == 9)
        #expect(manifest.credentialStore?.unlockMethods == ["passphrase", "recoveryKey"])
        #expect(Set(manifest.credentialItems.map(\.fileName)) == ["Family.kdbx", "deploy_key", "github-recovery-codes.txt", "config", "id_ed25519",
                                                                  "id_ed25519.pub", "known_hosts", "credentials"])
        #expect(manifest.credentialItems.allSatisfy { $0.status == .encryptedBackupVerified && $0.isPreserved })
        #expect(manifest.credentialItems.first { $0.fileName == "Family.kdbx" }?.prerequisites == [.masterPassword])
        #expect(manifest.credentialItems.first { $0.fileName == "github-recovery-codes.txt" }?.category == .recoveryMaterial)
        #expect(manifest.credentialItems.first { $0.fileName == "id_ed25519" }?.provider == "ssh")
        #expect(manifest.credentialItems.first { $0.fileName == "Family.kdbx" }?.homeRelativePath == "Vault/Family.kdbx")
        #expect(outcome.isComplete && BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
        // No secret in any plain file of the backup, the manifest or the log – and no plain hash of a secret either.
        let secrets = ["synthetic-cred-key-material", "synthetic-kdbx-body", "github-recovery-code-synthetic", "synthetic-test-key-not-real",
                       "synthetic-secret", Self.passphrase, Hashing.sha256Hex(of: Self.privateKey), Hashing.sha256Hex(of: Self.kdbx)]
        for path in BackupWriter.allFiles(in: outcome.url) {
            let bytes = try Data(contentsOf: outcome.url.appendingPathComponent(path))
            for secret in secrets { #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) in \(path)") }
        }
        for secret in secrets { #expect(!log.allLines.joined().contains(secret)) }
        #expect(!FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent("credentials/ssh.macreplica-vault").path))
        // Reports list every item and how to open them.
        let report = try String(contentsOf: outcome.url.appendingPathComponent("reports/inventory.html"), encoding: .utf8)
        #expect(report.contains("9 credentials encrypted and verified") && report.contains("~/Vault/Family.kdbx") && report.contains("recovery key"))
        // A changed encrypted item is caught by the backup check.
        let item = try #require(manifest.credentialItems.first?.encryptedPath)
        var bytes = try Data(contentsOf: outcome.url.appendingPathComponent(item))
        bytes[bytes.count - 3] ^= 0xFF
        try bytes.write(to: outcome.url.appendingPathComponent(item))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).damagedFiles.contains(item))
    }

    @Test func itemsThatCannotBePreservedMakeTheBackupPartialNeverSilentlyMissing() async throws {
        let sandbox = try Sandbox("cred-failed")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        let gone = try Self.write(Self.kdbx, "Vault/Gone.kdbx", in: root)
        _ = try Self.write(Self.kdbx, "Vault/Kept.kdbx", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        inventory.addCredentialFiles([gone, gone.deletingLastPathComponent().appendingPathComponent("Kept.kdbx")], layout: source.layout)
        try FileManager.default.removeItem(at: gone)
        let outcome = try backup(sandbox, inventory, layout: source.layout)
        #expect(outcome.manifest.preservedCredentials.map(\.fileName) == ["Kept.kdbx"], "the other item is still preserved")
        #expect(outcome.manifest.failedCredentials.map(\.problem) == [.missing])
        #expect(!outcome.isComplete && outcome.manifest.completeness == .partial)
        #expect(outcome.manifest.backupGaps.map(\.path) == ["~/Vault/Gone.kdbx"])
        // Without encryption nothing is written in plain text; every item is recorded as not preserved.
        let unencrypted = try backup(sandbox, inventory, layout: source.layout, request: false)
        #expect(unencrypted.manifest.credentialItems.map(\.problem) == [.noEncryptionKey, .noEncryptionKey])
        #expect(!FileManager.default.fileExists(atPath: unencrypted.url.appendingPathComponent("credentials").path))
        #expect(unencrypted.manifest.completeness == .partial)
    }

    @Test func backupsWithoutCredentialItemsStayReadableByOlderVersions() async throws {
        let sandbox = try Sandbox("cred-version")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        #expect(manifest.manifestVersion == Manifest.versionWithoutCredentialItems)
        #expect(try ManifestIO.read(from: backup).credentialItems.isEmpty)
        #expect(BackupWriter.estimatedSize(of: InventoryResult(manifest: manifest, fonts: [], colorProfiles: [])) > 0)
    }

    @Test func spaceEstimateIncludesCredentials() {
        var inventory = InventoryResult(manifest: Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64),
                                        fonts: [], colorProfiles: [])
        let empty = BackupWriter.estimatedSize(of: inventory)
        inventory.credentialSelection = [CredentialSelectionItem(id: "cred-x", category: .passwordDatabase, kind: .passwordDatabase, fileName: "x",
                                                                 originalPath: "~/x", format: nil, size: 7_000_000)]
        #expect(BackupWriter.estimatedSize(of: inventory) == empty + 7_000_000 + 70_000)
    }

    // MARK: Restore

    func restore(_ manifest: Manifest, backup: URL, on target: SimulationEnvironment, keyring: CredentialKeyring?,
                 selection: RestoreSelection = RestoreSelection(components: [.credentials]), session: RestoreSession? = nil) async -> RestoreSession {
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.credentialKeyring = keyring
        let session = session ?? RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id))
        return await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil).run(plan: plan, session: session, onEvent: { _ in })
    }

    func permissions(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }

    @Test func restoreIsExplicitVerifiedConflictSafeAndRepeatable() async throws {
        let sandbox = try Sandbox("cred-restore")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        let home = source.layout.homeDirectory
        _ = try Self.write(Self.kdbx, "Vault/Family.kdbx", in: root)
        _ = try Self.write(Data("-----BEGIN CERTIFICATE-----\nsynthetic\n".utf8), "Certs/ca.pem", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        inventory.addCredentialFiles([home.appendingPathComponent("Vault/Family.kdbx"), home.appendingPathComponent("Certs/ca.pem")], layout: source.layout)
        let recovery = try RecoveryKey.generate()
        let outcome = try backup(sandbox, inventory, layout: source.layout, providers: ["ssh"], recovery: recovery)
        let keys = try Data(contentsOf: outcome.url.appendingPathComponent(CredentialStore.keysPath))
        let keyring = try CredentialKeyring.unlock(keyFile: keys, with: .recoveryKey(recovery.text))
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let newHome = fresh.url.appendingPathComponent("home")

        // Not offered by default; without the key nothing is written.
        #expect(!RestorePlanner().plan(manifest: outcome.manifest, selection: RestoreSelection()).items.contains { $0.kind == .credentialFile })
        let locked = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: nil)
        #expect(locked.results.values.allSatisfy { $0.outcome == .skipped(.passphraseNotProvided) })
        #expect(!FileManager.default.fileExists(atPath: newHome.appendingPathComponent("Vault").path))

        // A restore interrupted while decrypting (the app was quit) left a partial file: the next run replaces it.
        let familyRecord = try #require(outcome.manifest.credentialItems.first { $0.fileName == "Family.kdbx" })
        try FileManager.default.createDirectory(at: newHome.appendingPathComponent("Vault"), withIntermediateDirectories: true)
        try Data("half-written".utf8).write(to: newHome.appendingPathComponent("Vault/.\(familyRecord.id).macreplica-partial"))
        // Into an empty Mac: same bytes, private permissions, the recorded format, and what the user still needs.
        let first = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring)
        #expect(first.results.count == 6 && first.results.values.allSatisfy { $0.outcome == .succeeded })
        let database = newHome.appendingPathComponent("Vault/Family.kdbx")
        #expect(try Data(contentsOf: database) == Self.kdbx)
        #expect(try permissions(database) == 0o600)
        #expect(try permissions(newHome.appendingPathComponent("Certs")) == 0o700, "folders MacReplica creates are private")
        #expect(try permissions(newHome.appendingPathComponent(".ssh/id_ed25519.pub")) == 0o644, "public keys stay readable")
        let familyID = "credentialFile:" + (outcome.manifest.credentialItems.first { $0.fileName == "Family.kdbx" }?.id ?? "")
        #expect(first.results[familyID]?.notes == [.credentialVerified(format: "KDBX 4.1"), .credentialNeeds([.masterPassword])])
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: database.deletingLastPathComponent().path)).contains { $0.contains("partial") })

        // Again: identical, nothing written.
        let second = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring)
        #expect(second.results.values.allSatisfy { $0.outcome == .alreadyPresent })

        // A different database at the same place: kept unless the user decides otherwise.
        try Data("someone else's database".utf8).write(to: database)
        let kept = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring)
        #expect(kept.results[familyID]?.outcome == .skipped(.keptExisting))
        #expect(try Data(contentsOf: database) == Data("someone else's database".utf8))
        var both = RestoreSelection(components: [.credentials])
        both.conflictOverrides[familyID] = .keepBoth
        let copy = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring, selection: both)
        #expect(copy.results[familyID]?.notes.first == .installedUnderNewName(name: "Family (MacReplica).kdbx"))
        #expect(try Data(contentsOf: newHome.appendingPathComponent("Vault/Family (MacReplica).kdbx")) == Self.kdbx)
        #expect(try Data(contentsOf: database) == Data("someone else's database".utf8))
        var replace = RestoreSelection(components: [.credentials])
        replace.conflictOverrides[familyID] = .replace
        let replaced = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring, selection: replace)
        #expect(replaced.results[familyID]?.outcome == .succeeded)
        #expect(try Data(contentsOf: database) == Self.kdbx)
        guard case .existingFileMovedAside(let aside)? = replaced.results[familyID]?.notes.first else { Issue.record("not moved aside"); return }
        let asideFile = target.layout.resolve(displayPath: aside).appendingPathComponent("Family.kdbx")
        #expect(try Data(contentsOf: asideFile) == Data("someone else's database".utf8), "the replaced file is kept")

        // A damaged encrypted item fails on its own and leaves nothing half-written; the backup is not changed.
        let item = try #require(outcome.manifest.credentialItems.first { $0.fileName == "ca.pem" })
        let itemURL = outcome.url.appendingPathComponent(try #require(item.encryptedPath))
        var bytes = try Data(contentsOf: itemURL)
        bytes[bytes.count - 5] ^= 0x10
        try bytes.write(to: itemURL)
        try FileManager.default.removeItem(at: newHome.appendingPathComponent("Certs/ca.pem"))
        let damaged = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring)
        #expect(damaged.results["credentialFile:\(item.id)"]?.outcome.label == "failed(backupFileDamaged)")
        #expect(!FileManager.default.fileExists(atPath: newHome.appendingPathComponent("Certs/ca.pem").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: newHome.appendingPathComponent("Certs").path)).isEmpty)
        #expect(damaged.results[familyID]?.outcome == .alreadyPresent, "other items are not affected")
    }

    @Test func restoreUsesAnotherPlaceWhenTheOriginalVolumeIsMissing() async throws {
        let sandbox = try Sandbox("cred-volume")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let volume = try sandbox.folder("Volumes/Stick")
        let database = volume.appendingPathComponent("Travel.kdbx")
        try Self.kdbx.write(to: database)
        var inventory = try await TestEnvironment.inventory(source).run()
        inventory.addCredentialFiles([database], layout: source.layout)
        let recovery = try RecoveryKey.generate()
        let outcome = try backup(sandbox, inventory, layout: source.layout, recovery: recovery)
        let record = try #require(outcome.manifest.credentialItems.first)
        #expect(record.homeRelativePath == nil && record.absolutePath == database.resolvingSymlinksInPath().path)
        let keyring = try CredentialKeyring.unlock(keyFile: Data(contentsOf: outcome.url.appendingPathComponent(CredentialStore.keysPath)),
                                                   with: .passphrase(Self.passphrase))
        try FileManager.default.removeItem(at: volume)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let session = await restore(outcome.manifest, backup: outcome.url, on: target, keyring: keyring)
        let result = try #require(session.results["credentialFile:\(record.id)"])
        #expect(result.outcome == .succeeded)
        #expect(result.notes.contains(.restoredToAlternateLocation(path: "~/MacReplica Restored Credentials/\(record.id)/Travel.kdbx")))
        #expect(try Data(contentsOf: fresh.url.appendingPathComponent("home/MacReplica Restored Credentials/\(record.id)/Travel.kdbx")) == Self.kdbx)
    }

    @Test func manifestEntriesAndUnsafePathsAreChecked() throws {
        var record = CredentialItemRecord(id: "cred-x", category: .privateKey, kind: .privateKey, provider: nil, fileName: "id_x", originalPath: "~/id_x",
                                          homeRelativePath: "../outside/id_x", absolutePath: nil, format: nil, size: 1, status: .encryptedBackupVerified)
        record.encryptedPath = "credentials/items/cred-x.mrcred"
        var item = RestoreItem(id: "credentialFile:cred-x", kind: .credentialFile, title: "id_x", identifier: "~/id_x", component: .credentials)
        item.credentialItem = record
        let sandbox = try Sandbox("cred-unsafe")
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.credentialKeyring = try Self.keyring()
        let inspector = Inspector(environment: environment, backupRoot: sandbox.url, selection: RestoreSelection(components: [.credentials]), damagedFiles: [])
        #expect(inspector.credentialTarget(item) == nil)
        #expect(inspector.predictCredentialFile(item) == .backupFileDamaged)
        record.homeRelativePath = "Keys/id_x"
        record.status = .failed
        item.credentialItem = record
        #expect(inspector.predictCredentialFile(item) == .willSkip(.fileNotSupported), "a failed item is never restored")
        #expect(record.prerequisites == [.keyPassphrase] && record.manualActionRequired)
        #expect(CredentialItemRecord(id: "c", category: .secretsFile, kind: nil, provider: nil, fileName: "a", originalPath: "~/a", homeRelativePath: "a",
                                     absolutePath: nil, format: nil, size: 0, status: .failed).manualActionRequired == false)
    }

    @Test func providersSourceOnlyRegularFiles() throws {
        let sandbox = try Sandbox("cred-provider-source")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        let ssh = try #require(CredentialProviders.provider(id: "ssh"))
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("home/.ssh/id_folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.url.appendingPathComponent("home/.ssh/id_link"),
                                                   withDestinationURL: root.url.appendingPathComponent("home/.ssh/id_ed25519"))
        #expect(ssh.sourceURL(for: "id_ed25519", layout: source.layout) != nil)
        #expect(ssh.sourceURL(for: "id_folder", layout: source.layout) == nil, "a folder is not a key file")
        #expect(ssh.sourceURL(for: "id_link", layout: source.layout) == nil, "links are not followed")
        #expect(ssh.sourceURL(for: "authorized_keys", layout: source.layout) == nil && ssh.sourceURL(for: "../id_x", layout: source.layout) == nil)
        let aws = try #require(CredentialProviders.provider(id: "aws"))
        #expect(aws.sourceURL(for: ".aws/credentials", layout: source.layout) != nil)
        #expect(aws.sourceURL(for: ".aws/sso/cache/x.json", layout: source.layout) == nil)
    }

    @Test func problemsMapToReasonsAndFailures() {
        #expect(BackupWriter.problem(for: CredentialStoreError.sourceChanged) == .changedDuringBackup)
        #expect(BackupWriter.problem(for: CredentialStoreError.sourceUnreadable) == .unreadable)
        #expect(BackupWriter.problem(for: CredentialStoreError.itemDamaged) == .encryptionFailed)
        #expect(BackupWriter.problem(for: CocoaError(.fileWriteOutOfSpace)) == .encryptionFailed)
        #expect(BackupWriter.gapIssue(path: "~/a", problem: .changedDuringBackup) == BackupIssue(path: "~/a", reason: .changedDuringBackup))
        #expect(BackupWriter.gapIssue(path: "~/a", problem: .notDownloaded) == BackupIssue(path: "~/a", reason: .notDownloaded))
        #expect(BackupWriter.gapIssue(path: "~/a", problem: .missing) == BackupIssue(path: "~/a", reason: .unreadable, detail: .missing))
        #expect(BackupWriter.gapIssue(path: "~/a", problem: .noEncryptionKey) == BackupIssue(path: "~/a", reason: .unreadable))
        #expect(RestoreExecutor.failureCategory(for: CredentialStoreError.itemDamaged) == .backupFileDamaged)
        #expect(RestoreExecutor.failureCategory(for: CredentialStoreError.unsupportedFormat) == .credentialCannotBeOpened)
    }

    @Test func aFileChosenByHandAndThroughItsProviderIsStoredOnce() async throws {
        let sandbox = try Sandbox("cred-provider-dedupe")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        var inventory = try await TestEnvironment.inventory(source).run()
        inventory.addCredentialFiles([source.layout.homeDirectory.appendingPathComponent(".ssh/id_ed25519")], layout: source.layout)
        let outcome = try backup(sandbox, inventory, layout: source.layout, providers: ["ssh"])
        #expect(outcome.manifest.credentialItems.filter { $0.fileName == "id_ed25519" }.count == 1)
        #expect(outcome.manifest.credentialItems.count == 4)
    }

    @Test func absoluteLocationsAreUsedWhenTheirFolderExists() throws {
        let sandbox = try Sandbox("cred-absolute")
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let volume = try sandbox.folder("Volumes/Present")
        var record = CredentialItemRecord(id: "cred-abs", category: .passwordDatabase, kind: .passwordDatabase, provider: nil, fileName: "T.kdbx",
                                          originalPath: volume.path + "/T.kdbx", homeRelativePath: nil, absolutePath: volume.path + "/T.kdbx",
                                          format: nil, size: 1, status: .encryptedBackupVerified)
        record.encryptedPath = "credentials/items/cred-abs.mrcred"
        var item = RestoreItem(id: "credentialFile:cred-abs", kind: .credentialFile, title: "T.kdbx", identifier: record.originalPath, component: .credentials)
        item.credentialItem = record
        let inspector = Inspector(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url,
                                  selection: RestoreSelection(components: [.credentials]), damagedFiles: [])
        let present = try #require(inspector.credentialTarget(item))
        #expect(present.url.path == volume.path + "/T.kdbx" && !present.alternate)
        // A path with a parent step is never written to as it is.
        record.absolutePath = volume.path + "/../Present/T.kdbx"
        item.credentialItem = record
        #expect(inspector.credentialTarget(item)?.alternate == true)
        // A file in place of the folder is not a folder.
        let file = sandbox.url.appendingPathComponent("NotAFolder")
        try Data().write(to: file)
        record.absolutePath = file.path + "/T.kdbx"
        item.credentialItem = record
        #expect(inspector.credentialTarget(item)?.alternate == true)
    }

    @Test func plannerOffersOnlyPreservedItems() {
        var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64)
        var ok = CredentialItemRecord(id: "cred-ok", category: .passwordDatabase, kind: .passwordDatabase, provider: nil, fileName: "a.kdbx",
                                      originalPath: "~/a.kdbx", homeRelativePath: "a.kdbx", absolutePath: nil, format: nil, size: 1, status: .encryptedBackupVerified)
        ok.encryptedPath = "credentials/items/cred-ok.mrcred"
        let failed = CredentialItemRecord(id: "cred-no", category: .passwordDatabase, kind: .passwordDatabase, provider: nil, fileName: "b.kdbx",
                                          originalPath: "~/b.kdbx", homeRelativePath: "b.kdbx", absolutePath: nil, format: nil, size: 1, status: .failed,
                                          problem: .missing)
        manifest.credentialItems = [ok, failed]
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.credentials]))
        #expect(plan.items.map(\.id) == ["credentialFile:cred-ok"])
    }

    // MARK: Policy and reports

    @Test func classificationCoversNewKindsAndPolicies() throws {
        let sandbox = try Sandbox("cred-classify")
        func file(_ name: String, _ data: Data = Data()) throws -> URL {
            let url = sandbox.url.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        #expect(SensitiveFileClassifier.classify(try file("export.1pux", Data([0x50, 0x4B, 0x03, 0x04])))?.kind == .passwordManagerExport)
        #expect(SensitiveFileClassifier.classify(try file("vault.psafe3", Data("PWS3rest".utf8))) == SensitiveClassification(kind: .passwordDatabase, confidence: .high))
        #expect(SensitiveFileClassifier.classify(try file("other.psafe3", Data("nope".utf8)))?.confidence == .medium)
        let unreadable = try file("locked.psafe3", Data("PWS3rest".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        #expect(SensitiveFileClassifier.classify(unreadable)?.confidence == .medium, "a header that cannot be read is not proof")
        #expect(SensitiveFileClassifier.classify(try file("github-recovery-codes.txt"))?.kind == .recoveryMaterial)
        #expect(SensitiveFileClassifier.classify(try file("1Password Emergency Kit.pdf"))?.kind == .recoveryMaterial)
        #expect(SensitiveFileClassifier.classify(try file("backup_codes.txt"))?.kind == .recoveryMaterial)
        #expect(CredentialFormat.describe(try file("k", Self.privateKey), kind: nil) == "OpenSSH private key")
        #expect(CredentialFormat.describe(try file("e.pem", Data(("-----BEGIN ENCRYPTED " + "PRIVATE KEY-----").utf8)), kind: nil) == "PEM private key (encrypted)")
        #expect(CredentialFormat.describe(try file("r.pem", Data(("-----BEGIN RSA " + "PRIVATE KEY-----").utf8)), kind: nil) == "PEM private key")
        #expect(CredentialFormat.describe(try file("c.p12", Data([0x30, 0x82])), kind: nil) == "PKCS #12")
        #expect(CredentialFormat.describe(try file("c.der", Data([0x30, 0x82])), kind: nil) == "DER certificate")
        #expect(CredentialFormat.describe(try file("n.txt", Data("hello".utf8)), kind: nil) == nil)
        #expect(CredentialFormat.describe(try file("all.1pux", Data([0x50, 0x4B, 0x03, 0x04, 0x00])), kind: nil) == "1Password export (1PUX)")
        #expect(CredentialFormat.describe(try file("broken.1pux", Data("not a zip".utf8)), kind: nil) == nil)
        #expect(CredentialFormat.describe(try file("x.zip", Data([0x50, 0x4B, 0x03, 0x04, 0x00])), kind: nil) == nil)
        #expect(CredentialFormat.describe(try file("p.asc", Data("-----BEGIN PGP PUBLIC KEY BLOCK-----".utf8)), kind: nil) == "OpenPGP public key")
        #expect(!CredentialPolicy.isCopyable(.keychain) && !CredentialPolicy.isCopyable(.browserData) && CredentialPolicy.isCopyable(.recoveryMaterial))
        #expect(CredentialPolicy.prerequisites(.certificate) == [.matchingPrivateKey])
        #expect(CredentialPolicy.prerequisites(.passwordManagerExport) == [.importIntoApp])
        #expect(CredentialPolicy.prerequisites(.passwordDatabaseKeyFile) == [.withMasterPassword])
        let item = CredentialSelectionItem(id: "x", category: .privateKey, kind: .privateKey, fileName: "id", originalPath: "~/id", format: nil,
                                           size: 0)
        #expect(CredentialPolicy.restoredPermissions(0o644, item: item) == 0o600)
        #expect(CredentialPolicy.restoredPermissions(0o400, item: item) == 0o400)
        #expect(CredentialPolicy.restoredPermissions(0, item: item) == 0o600)
        var pub = item
        pub.category = .publicKey
        #expect(CredentialPolicy.restoredPermissions(0o666, item: pub) == 0o644)
        #expect(CredentialCategory(.keePassKeyFile) == .passwordDatabaseKeyFile && CredentialCategory(.nameSuggestsSecret) == .otherSecret)
        // Keys saved under any name without an extension are recognised by their first line; other such files are not.
        #expect(SensitiveFileClassifier.classify(try file("deploy_ed25519", Self.privateKey)) == SensitiveClassification(kind: .privateKey, confidence: .high))
        #expect(SensitiveFileClassifier.classify(try file("signing", Data(("-----BEGIN PGP PRIVATE " + "KEY BLOCK-----\n").utf8)))?.kind == .pgpKey)
        #expect(SensitiveFileClassifier.classify(try file("README", Data("-----BEGIN here".utf8))) == nil)
        #expect(SensitiveFileClassifier.classify(try file("Makefile", Data("all:\n".utf8))) == nil)
        #expect(CredentialCategory.of(kind: .privateKey, format: "OpenSSH public key") == .publicKey)
        #expect(CredentialCategory.of(kind: .nameSuggestsSecret, format: nil, provider: "aws") == .applicationCredential)
        #expect(CredentialCategory.of(kind: .privateKey, format: "OpenSSH private key", provider: "ssh") == .privateKey)
        #expect(CredentialCategory.of(kind: nil, format: nil) == .otherSecret)
        #expect(CredentialPolicy.prerequisites(.publicKey).isEmpty)
    }

    @Test func readinessReportNamesEveryOutcome() {
        var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64)
        var ok = CredentialItemRecord(id: "cred-ok", category: .passwordDatabase, kind: .passwordDatabase, provider: nil, fileName: "a.kdbx",
                                      originalPath: "~/a.kdbx", homeRelativePath: "a.kdbx", absolutePath: nil, format: "KDBX 4.1", size: 1,
                                      status: .encryptedBackupVerified)
        ok.encryptedPath = "credentials/items/cred-ok.mrcred"
        manifest.credentialItems = [ok, CredentialItemRecord(id: "cred-no", category: .privateKey, kind: .privateKey, provider: nil, fileName: "k",
                                                             originalPath: "~/k", homeRelativePath: "k", absolutePath: nil, format: nil, size: 1,
                                                             status: .failed, problem: .changedDuringBackup)]
        manifest.backupIssues = [
            BackupIssue(path: "~/u.kdbx", reason: .refusedSensitive, sensitive: SensitiveClassification(kind: .passwordDatabase, confidence: .high)),
            BackupIssue(path: "~/l.kdbx", reason: .refusedSensitive, detail: .leftOutByUser, sensitive: SensitiveClassification(kind: .passwordDatabase, confidence: .high)),
            BackupIssue(path: "~/x/login.keychain-db", reason: .refusedSensitive, sensitive: SensitiveClassification(kind: .keychain, confidence: .high)),
        ]
        manifest.guidance = [GuidanceRecord(id: "passkeys", name: "Passkeys", kind: .manualMigration),
                             GuidanceRecord(id: "slack", name: "Slack", kind: .reauthenticationRequired)]
        #expect(manifest.undecidedCredentials.map(\.path) == ["~/u.kdbx"])
        var unclassified = manifest
        unclassified.backupIssues.append(BackupIssue(path: "~/legacy-entry", reason: .refusedSensitive))
        #expect(unclassified.undecidedCredentials.map(\.path) == ["~/u.kdbx", "~/legacy-entry"], "an older entry without a classification still needs a decision")
        #expect(unclassified.uncopyableCredentials.map(\.path) == ["~/x/login.keychain-db"])
        #expect(manifest.credentialsLeftOutByUser.map(\.path) == ["~/l.kdbx"])
        #expect(manifest.uncopyableCredentials.map(\.path) == ["~/x/login.keychain-db"])
        let html = ReportBuilder(localizer: TestEnvironment.english).inventoryReport(manifest)
        for text in ["1 credential encrypted and verified", "KDBX 4.1", "Encrypted and verified", "1 credential could not be preserved",
                     "changed while it was being encrypted", "1 credential file found but not in the backup", "1 credential file left out by you",
                     "Left out by your choice", "1 file cannot be backed up as a file", "Passkeys cannot be copied as files", "master password"] {
            #expect(html.contains(text), "\(text)")
        }
        #expect(!html.contains("Slack:"), "other sign-ins are not listed as credentials")
        let empty = ReportBuilder(localizer: TestEnvironment.english).inventoryReport(
            Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64))
        #expect(empty.contains("No passwords, keys or credential files were found or chosen."))
    }

    @Test(arguments: AppLanguage.allCases)
    func everyCredentialTextIsTranslated(_ language: AppLanguage) {
        let l = Localizer(language: language)
        var texts = CredentialCategory.allCases.map(l.credentialCategoryText)
        texts += CredentialPrerequisite.allCases.map { l.credentialNeedsText([$0]) }
        texts += [CredentialProblem.keychainNotCopyable, .browserStoreNotCopyable, .notDownloaded, .unreadable, .missing, .changedDuringBackup,
                  .noEncryptionKey, .encryptionFailed, .nothingRecognised].map(l.credentialProblemText)
        texts += SensitiveKind.allCases.flatMap { [l.sensitiveKindText($0), l.sensitiveAdvice($0)] }
        texts += GuidanceCatalog.credentialIDs.map { l.t("guidance.credential.\($0)") }
        texts += [l.noteText(.credentialVerified(format: nil)), l.noteText(.credentialVerified(format: "KDBX 4.1")),
                  l.noteText(.restoredToAlternateLocation(path: "~/x"))]
        #expect(texts.allSatisfy { !$0.isEmpty && $0 != "…" })
    }
}
