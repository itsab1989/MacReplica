import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Files that look like secrets (beta feedback 1.0.4: "1 key or password file was not backed up" without saying which):
/// classified from name and file format only, listed with path, reason and advice, and included only on request.
@Suite("Sensitive files")
struct SensitiveFilesTests {
    static func write(_ data: Data, _ relative: String, in root: SimulationRoot) throws -> URL {
        let url = root.url.appendingPathComponent("home").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// A synthetic KDBX 4.1 header (signature, minor 1, major 4) followed by random bytes – no real database.
    static let kdbx = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 0x01, 0x00, 0x04, 0x00]) + Data((0..<64).map { _ in UInt8.random(in: 0...255) })

    @Test func classificationUsesNameAndFormatOnly() throws {
        let sandbox = try Sandbox("sensitive-classify")
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = sandbox.url.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let database = try file("Passwords.kdbx", Self.kdbx)
        #expect(SensitiveFileClassifier.classify(database) == SensitiveClassification(kind: .passwordDatabase, confidence: .high))
        #expect(KeePassHeader.read(database)?.format == "KDBX 4.1")
        #expect(SensitiveFileClassifier.classify(try file("Renamed.kdbx", Data("not a database".utf8)))?.confidence == .medium)
        #expect(KeePassHeader.read(try file("plain.txt", Data("hello".utf8))) == nil)
        // `.key`: a Keynote presentation (zip) is a document, not a secret; a PEM key or a KeePass XML key file is.
        #expect(SensitiveFileClassifier.classify(try file("Talk.key", Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 40))) == nil)
        #expect(SensitiveFileClassifier.classify(try file("server.key", Data("-----BEGIN PRIVATE KEY-----\n".utf8)))?.kind == .privateKey)
        #expect(SensitiveFileClassifier.classify(try file("vault.key", Data("<?xml version=\"1.0\"?><KeyFile><Meta/>".utf8)))?.kind == .keePassKeyFile)
        #expect(SensitiveFileClassifier.classify(try file("vault.keyx", Data("<KeyFile/>".utf8)))?.kind == .keePassKeyFile)
        #expect(SensitiveFileClassifier.classify(try file("ca.pem", Data("-----BEGIN CERTIFICATE-----".utf8)))?.kind == .certificate)
        #expect(SensitiveFileClassifier.classify(try file("login.keychain-db", Data()))?.kind == .keychain)
        #expect(SensitiveFileClassifier.classify(try file("id_ed25519", Data()))?.confidence == .high)
        #expect(SensitiveFileClassifier.classify(try file("api-token.json", Data()))?.kind == .nameSuggestsSecret)
        #expect(SensitiveFileClassifier.classify(try file("settings.json", Data())) == nil)
        #expect(!SensitiveKind.keychain.canBeIncludedOnRequest && !SensitiveKind.browserData.canBeIncludedOnRequest)
        #expect(SensitiveKind.passwordDatabase.canBeIncludedOnRequest)
    }

    @Test func leftOutFilesAreListedAndCanBeIncludedOnRequest() async throws {
        let sandbox = try Sandbox("sensitive-include")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        _ = try Self.write(Data("notes".utf8), "Documents/Vault/notes.txt", in: root)
        _ = try Self.write(Self.kdbx, "Documents/Vault/Family.kdbx", in: root)
        _ = try Self.write(Data("<KeyFile/>".utf8), "Documents/Vault/Family.keyx", in: root)
        _ = try Self.write(Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 20), "Documents/Vault/Talk.key", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let scan = try AppDataScanner(layout: source.layout).scanPersonal(source.layout.homeDirectory.appendingPathComponent("Documents/Vault"))
        inventory.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        #expect(Set(scan.files.map(\.record.relativePath)) == ["notes.txt", "Talk.key"], "a Keynote file is backed up")
        let left = inventory.manifest.excludedSensitiveFiles
        #expect(Set(left.map(\.fileName)) == ["Family.kdbx", "Family.keyx"])
        #expect(left.first { $0.fileName == "Family.kdbx" }?.sensitive?.kind == .passwordDatabase)
        #expect(inventory.manifest.completeness == .completeWithIntentionalExclusions)

        try inventory.includeOnRequest("~/Documents/Vault/Family.kdbx", layout: source.layout)
        #expect(inventory.manifest.excludedSensitiveFiles.map(\.fileName) == ["Family.keyx"], "the key file stays left out")
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let manifest = try ManifestIO.read(from: outcome.url)
        let included = try #require(manifest.sensitiveFilesIncludedOnRequest.first)
        #expect(included.fileName == "Family.kdbx" && included.metadata[AppDataScanner.includedOnRequestKey] == "passwordDatabase")
        let copy = try #require(PathSafety.resolve(included.backupPath, inside: outcome.url))
        #expect(try Data(contentsOf: copy) == Self.kdbx, "copied unchanged")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)
        #expect(manifest.completeness == .completeWithIntentionalExclusions && outcome.isComplete)
        // The report and the restore instructions name the file, the reason and the advice – never contents.
        let report = try String(contentsOf: outcome.url.appendingPathComponent("reports/inventory.html"), encoding: .utf8)
        let guide = try String(contentsOf: outcome.url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        for text in [report, guide] {
            #expect(text.contains("~/Documents/Vault/Family.keyx") && text.contains("KeePass key file") && text.contains("second factor"))
            #expect(text.contains("Included at your request (encrypted KeePass password database)"))
        }

        // Leaving it out again restores the earlier state.
        inventory.excludeAgain("~/Documents/Vault/Family.kdbx", layout: source.layout)
        #expect(Set(inventory.manifest.excludedSensitiveFiles.map(\.fileName)) == ["Family.kdbx", "Family.keyx"])
        #expect(inventory.manifest.sensitiveFilesIncludedOnRequest.isEmpty)
        #expect(!inventory.extraFiles.contains { $0.record.fileName == "Family.kdbx" })
        // Keychains are never included.
        let keychain = try Self.write(Data(), "Documents/Vault/old.keychain-db", in: root)
        #expect(throws: InventoryResult.IncludeOnRequestError.notAllowed) { try inventory.includeOnRequest(source.layout.displayPath(keychain), layout: source.layout) }
    }

    @Test func databasesKeePassXCRemembersAreListedNotIncluded() async throws {
        let sandbox = try Sandbox("sensitive-keepassxc")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        let database = try Self.write(Self.kdbx, "Sync/Passwords.kdbx", in: root)
        let home = source.layout.homeDirectory.path
        _ = try Self.write(Data("[General]\nLastDatabases=\(home)/Sync/Passwords.kdbx, \"\(home)/Gone/Old.kdbx\"\nLastActiveDatabase=\(home)/Sync/Passwords.kdbx\n".utf8),
                           "Library/Caches/KeePassXC/keepassxc.ini", in: root)
        _ = try Self.write(Data("[GUI]\nCompactMode=true\n".utf8), "Library/Application Support/KeePassXC/keepassxc.ini", in: root)
        var inventory = try await TestEnvironment.inventory(source).run()
        let listed = inventory.manifest.excludedSensitiveFiles.filter { $0.detail == .rememberedByApp }
        #expect(listed.map(\.path) == ["~/Sync/Passwords.kdbx"], "existing databases only, once")
        #expect(listed.first?.sensitive?.kind == .passwordDatabase)
        #expect(!inventory.extraFiles.contains { $0.url.lastPathComponent == "Passwords.kdbx" }, "never included by itself")
        #expect(inventory.manifest.applicationData.contains { $0.profile?.provider == "keepassxc" }, "its settings are offered")
        #expect(KeePassXCLocations.splitList("a, \"b, c\", d") == ["a", " b, c", " d"])

        // Included on request: a folder with only this file, restored to where it was.
        try inventory.includeOnRequest("~/Sync/Passwords.kdbx", layout: source.layout)
        let folder = try #require(inventory.manifest.applicationData.first { $0.isPersonal && $0.files.map(\.fileName) == ["Passwords.kdbx"] })
        #expect(folder.displayPath == "~/Sync")
        #expect(inventory.manifest.excludedSensitiveFiles.filter { $0.detail == .rememberedByApp }.isEmpty)
        _ = database
    }

    @Test func savedSelectionKeepsFilesIncludedOnRequest() throws {
        var preset = BackupSelectionPreset()
        preset.includedOnRequest = ["~/Sync/Passwords.kdbx"]
        preset.ownInstallers = ["com.example.app": [.init(path: "~/Installers/App.dmg", include: true, licence: true, approvedUnverified: true, sha256: "abc")]]
        let data = try JSONEncoder().encode(preset)
        let read = try JSONDecoder().decode(BackupSelectionPreset.self, from: data)
        #expect(read.includedOnRequest == ["~/Sync/Passwords.kdbx"])
        #expect(read.ownInstallers["com.example.app"]?.first?.approvedUnverified == true && read.ownInstallers["com.example.app"]?.first?.sha256 == "abc")
        // A selection saved by 1.0.4 (without the new keys) still loads.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "includedOnRequest")
        let legacy = try JSONDecoder().decode(BackupSelectionPreset.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.includedOnRequest == nil)
    }
}
