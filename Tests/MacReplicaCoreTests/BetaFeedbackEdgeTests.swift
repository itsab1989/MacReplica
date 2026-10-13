import Foundation
import Testing
@testable import MacReplicaCore

/// Details of the 1.0.5 beta-feedback modules that the mutation run showed untested.
@Suite("Sensitive files: edge cases")
struct SensitiveFilesEdgeTests {
    static func file(_ name: String, _ content: Data) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try content.write(to: url)
        return (folder, url)
    }

    @Test func secretsFilesByName() throws {
        for name in [".netrc", ".env", ".env.local"] {
            let (folder, url) = try Self.file(name, Data("x=1".utf8))
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(SensitiveFileClassifier.classify(url) == SensitiveClassification(kind: .secretsFile, confidence: .high), "\(name)")
        }
        let (folder, url) = try Self.file("environment.txt", Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SensitiveFileClassifier.classify(url) == nil)
    }

    @Test func keyAndPemContentDecidesTheConfidence() throws {
        let cases: [(String, String, SensitiveClassification)] = [
            ("vault.key", "<?xml version=\"1.0\"?><KeyFile><Meta/></KeyFile>", SensitiveClassification(kind: .keePassKeyFile, confidence: .high)),
            ("random.key", "some random bytes", SensitiveClassification(kind: .keePassKeyFile, confidence: .low)),
            ("site.pem", "-----BEGIN CERTIFICATE-----", SensitiveClassification(kind: .certificate, confidence: .high)),
            ("other.pem", "nothing recognisable", SensitiveClassification(kind: .certificate, confidence: .low)),
        ]
        for (name, content, expected) in cases {
            let (folder, url) = try Self.file(name, Data(content.utf8))
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(SensitiveFileClassifier.classify(url) == expected, "\(name)")
        }
    }

    @Test func keePassHeaderNeedsEightBytes() throws {
        let kdbx: [UInt8] = [0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5]
        let (folder, eight) = try Self.file("eight.kdbx", Data(kdbx))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(KeePassHeader.read(eight)?.format == "KDBX", "the signature alone is enough to name the format")
        let seven = folder.appendingPathComponent("seven.kdbx")
        try Data(kdbx.prefix(7)).write(to: seven)
        #expect(KeePassHeader.read(seven) == nil)
    }
}

@Suite("Installer descriptions: approval states")
struct InstallerApprovalTests {
    @Test func approvedUnverifiedCanBeWithdrawnAndOtherDevelopersCannotBeApproved() {
        let approved = InstallerDescriptionTests.l.installerDescription(InstallerDescriptionTests.archive(approved: true), for: InstallerDescriptionTests.app)
        #expect(approved.canApproveUnverified, "the approval can be withdrawn again")
        #expect(approved.style == .attention && approved.nextAction != nil)
        var signedApp = InstallerDescriptionTests.app
        signedApp.teamIdentifier = "OWNTEAM123"
        let other = InstallerDescriptionTests.l.installerDescription(InstallerDescriptionTests.archive(trusted: true, team: "OTHERTEAM1"), for: signedApp)
        #expect(other.style == .blocked)
        #expect(!other.canApproveUnverified, "an installer signed by another developer is never offered for approval")
    }

    @Test func rememberedDatabasesSayWhy() {
        let l = InstallerDescriptionTests.l
        let remembered = BackupIssue(path: "~/x.kdbx", reason: .refusedSensitive, detail: .rememberedByApp,
                                     sensitive: SensitiveClassification(kind: .passwordDatabase, confidence: .high))
        #expect(l.sensitiveExplanation(remembered).hasPrefix(l.t("sensitive.rememberedByApp")))
        let plain = BackupIssue(path: "~/x.kdbx", reason: .refusedSensitive, sensitive: SensitiveClassification(kind: .passwordDatabase, confidence: .high))
        #expect(!l.sensitiveExplanation(plain).contains(l.t("sensitive.rememberedByApp")))
        #expect(l.architecturesText([.arm64, .x86_64]) == l.t("architecture.universal"))
        #expect(l.architecturesText([.unknown]) == nil)
    }
}

@Suite("Homebrew: removed casks")
struct HomebrewRemovedCaskTests {
    @Test func emptyURLWithoutTapIsRemovedButNotWithATap() {
        #expect(HomebrewClient.availability(["token": "x", "url": ""]).state == .removed, "no tap key at all")
        #expect(HomebrewClient.availability(["token": "x", "url": "", "tap": NSNull()]).state == .removed)
        #expect(HomebrewClient.availability(["token": "x", "url": "", "tap": "homebrew/cask"]).state == .available)
        #expect(HomebrewClient.availability(["token": "x", "url": "https://x", "tap": NSNull()]).state == .available)
    }
}

@Suite("Application locator")
struct ApplicationLocatorTests {
    static func app(_ relative: String, id: String?, version: String = "1.0", in folder: URL) throws {
        let contents = folder.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func findsByNameAndIdentifierAndInSuiteFolders() throws {
        // Resolved, so /var and /private/var compare equal.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Applications")
        let second = root.appendingPathComponent("home/Applications")
        try Self.app("Viewer.app", id: "com.example.viewer", version: "2.1", in: first)
        try Self.app("Clone.app", id: "com.other.clone", in: first)
        try Self.app("DisplayCAL/DisplayCAL.app", id: "net.displaycal.DisplayCAL", in: second)
        try Self.app("NoInfo.app", id: nil, in: first)

        // By name; with an identifier the name has to belong to that app (case-insensitive).
        #expect(ApplicationLocator.find(names: ["Viewer.app"], bundleIdentifier: nil, in: [first])?.resolvingSymlinksInPath() == first.appendingPathComponent("Viewer.app"))
        #expect(ApplicationLocator.find(names: ["Viewer.app"], bundleIdentifier: "COM.EXAMPLE.VIEWER", in: [first])?.resolvingSymlinksInPath() == first.appendingPathComponent("Viewer.app"))
        // A name that is another app falls through to the search by identifier, which finds the right one.
        #expect(ApplicationLocator.find(names: ["Clone.app"], bundleIdentifier: "com.example.viewer", in: [first])?.resolvingSymlinksInPath() == first.appendingPathComponent("Viewer.app"))
        // A suite folder one level down, found by identifier, also in the second folder.
        #expect(ApplicationLocator.find(names: ["DisplayCAL.app"], bundleIdentifier: "net.displaycal.DisplayCAL", in: [first, second])?
                .resolvingSymlinksInPath() == second.appendingPathComponent("DisplayCAL/DisplayCAL.app"))
        #expect(ApplicationLocator.find(names: ["DisplayCAL/DisplayCAL.app"], bundleIdentifier: nil, in: [first, second])?
                .resolvingSymlinksInPath() == second.appendingPathComponent("DisplayCAL/DisplayCAL.app"))
        // Without an identifier nothing is searched beyond the given names.
        #expect(ApplicationLocator.find(names: ["DisplayCAL.app"], bundleIdentifier: nil, in: [first, second]) == nil)
        // An app without Info.plist identifier counts as found by name only when no identifier is expected.
        #expect(ApplicationLocator.find(names: ["NoInfo.app"], bundleIdentifier: nil, in: [first])?.resolvingSymlinksInPath() == first.appendingPathComponent("NoInfo.app"))
        #expect(ApplicationLocator.find(names: ["NoInfo.app"], bundleIdentifier: "com.x", in: [first]) == nil)
        // Unsafe names are never looked at.
        #expect(ApplicationLocator.find(names: ["../Applications/Viewer.app", "/Applications/Viewer.app", "a/b/c.app"], bundleIdentifier: nil, in: [first]) == nil)
        #expect(ApplicationLocator.find(names: ["Missing.app"], bundleIdentifier: "com.missing", in: [first, second]) == nil)
        #expect(ApplicationLocator.version(of: first.appendingPathComponent("Viewer.app")) == "2.1")
        #expect(ApplicationLocator.version(of: first.appendingPathComponent("Missing.app")) == nil)
    }
}
