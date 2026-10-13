import Foundation
import Testing
@testable import MacReplicaCore

/// Parts of the own-installer model that need no signed installer: defaults of older backups, which app an installer
/// contains, which apps a folder holds, and what the offer on the new Mac says.
@Suite("Own installers: edge cases")
struct InstallerArchiveEdgeTests {
    static func archive(kind: InstallerArchive.Kind = .dmg, bundle: String? = nil, apps: [InstallerArchive.ContainedApp] = [], trusted: Bool = false,
                        team: String? = nil, approved: Bool = false, included: String? = nil, fileName: String = "Tool.dmg", id: String = "a") -> InstallerArchive {
        InstallerArchive(id: id, fileName: fileName, kind: kind, size: 3, sha256: "s", teamIdentifier: team, signer: nil, trustedSignature: trusted,
                         bundleIdentifier: bundle, includedPath: included, originalPath: "/Volumes/None/\(fileName)", containedApps: apps,
                         userApprovedUnverified: approved)
    }

    static func contained(_ id: String?, _ name: String = "App") -> InstallerArchive.ContainedApp {
        .init(name: name, bundleIdentifier: id, version: "1", path: "\(name).app")
    }

    @Test func olderBackupsDecodeWithSafeDefaults() throws {
        let minimal = #"{"id":"a","fileName":"x.dmg","kind":"dmg","size":1,"sha256":"s","originalPath":"/x.dmg"}"#
        let dmg = try JSONDecoder().decode(InstallerArchive.self, from: Data(minimal.utf8))
        #expect(!dmg.trustedSignature && !dmg.containsLicence && !dmg.hasLicenseAgreement && !dmg.userApprovedUnverified && !dmg.containsPackage)
        #expect(dmg.architectures.isEmpty && dmg.containedApps.isEmpty)
        let pkg = try JSONDecoder().decode(InstallerArchive.self, from: Data(minimal.replacingOccurrences(of: "\"dmg\"", with: "\"pkg\"").utf8))
        #expect(pkg.containsPackage, "a package is a package even in a backup that did not record it")
        let explicit = minimal.replacingOccurrences(of: "}", with: #","trustedSignature":true,"containsLicence":true,"hasLicenseAgreement":true,"userApprovedUnverified":true,"containsPackage":true}"#)
        let full = try JSONDecoder().decode(InstallerArchive.self, from: Data(explicit.utf8))
        #expect(full.trustedSignature && full.containsLicence && full.hasLicenseAgreement && full.userApprovedUnverified && full.containsPackage)
        // The memberwise initializer has the same defaults.
        let made = InstallerArchive(id: "a", fileName: "x.dmg", kind: .dmg, size: 1, sha256: "s", originalPath: "/x.dmg")
        #expect(!made.hasLicenseAgreement && !made.userApprovedUnverified && !made.containsPackage)
        #expect(InstallerArchive(id: "a", fileName: "x.pkg", kind: .pkg, size: 1, sha256: "s", originalPath: "/x.pkg").containsPackage)
    }

    @Test func differentAppNamesTheFirstContainedApp() {
        var app = AppRecord(name: "Wanted", bundleIdentifier: "com.wanted", path: "/Applications/Wanted.app")
        app.teamIdentifier = nil
        let archive = Self.archive(apps: [Self.contained("com.first"), Self.contained("com.second")])
        #expect(archive.usability(for: app) == .differentApp("com.first"))
        #expect(Self.archive(kind: .app).mustBeIncluded)
        #expect(!Self.archive(kind: .dmg).mustBeIncluded && !Self.archive(kind: .zip).mustBeIncluded)
    }

    @Test func mainAppIsTheOneOthersExtend() {
        func main(_ ids: [String?]) -> String? {
            InstallerArchiveInspector.mainApp(ids.enumerated().map { Self.contained($0.element, "App\($0.offset)") })?.name
        }
        // net.x is extended by net.x.helper.
        #expect(main(["net.x.helper", "net.x"]) == "App1")
        // The first extended identifier wins, even if a later one is extended too.
        #expect(main(["a.b", "a.b.c", "a.b.c.d"]) == "App0")
        // Nobody extends anybody: the first app, also when it has no identifier.
        #expect(main([nil, "b", "c"]) == "App0")
        #expect(main([nil, nil]) == "App0")
        #expect(main([]) == nil)
    }

    @Test func applicationsInAFolderAndOneLevelDown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for path in ["B.app", "A.app", ".Hidden.app", "__MACOSX/Junk.app", "Suite/Inner.app", "Fake.bundle/Nested.app"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("Suite/readme.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("README"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Link.app"), withDestinationURL: root.appendingPathComponent("A.app"))
        // Relative to the temporary folder (whose path may be reported with or without /private).
        let found = InstallerArchiveInspector.applications(in: root).map { $0.path.components(separatedBy: "/" + root.lastPathComponent + "/").last ?? "" }
        #expect(found == ["A.app", "B.app", "Suite/Inner.app"], "\(found)")
    }

    @Test func offerSaysWhenTheDeveloperIsUnverified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("installers"), withIntermediateDirectories: true)
        for name in ["Tool.dmg", "Extra.pkg", "Signed.pkg"] { try Data("abc".utf8).write(to: root.appendingPathComponent("installers/\(name)")) }
        var app = AppRecord(name: "Tool", bundleIdentifier: "com.tool", path: "/Applications/Tool.app")
        app.teamIdentifier = "TEAM123456"
        app.ownInstallers = [
            Self.archive(bundle: "com.tool", approved: true, included: "installers/Tool.dmg"),
            Self.archive(kind: .pkg, approved: true, included: "installers/Extra.pkg", fileName: "Extra.pkg", id: "b"),
            Self.archive(kind: .pkg, trusted: true, team: "TEAM123456", included: "installers/Signed.pkg", fileName: "Signed.pkg", id: "c"),
        ]
        let offer = try #require(OwnInstallerSource.offer(for: app, itemID: "app:tool", backupRoot: root, layout: .live()))
        #expect(offer.developerUnverified == true)
        #expect(offer.expectedTeamIdentifier == nil, "an unverified installer is not checked against a team")
        #expect((offer.followUps ?? []).map(\.name) == ["Extra.pkg", "Signed.pkg"])
        #expect((offer.followUps ?? []).map(\.developerUnverified) == [true, nil])
        // The signed one first: verified, with the team to check.
        app.ownInstallers = [Self.archive(bundle: "com.tool", trusted: true, team: "TEAM123456", included: "installers/Tool.dmg")]
        let verified = try #require(OwnInstallerSource.offer(for: app, itemID: "app:tool", backupRoot: root, layout: .live()))
        #expect(verified.developerUnverified == nil)
        #expect(verified.expectedTeamIdentifier == "TEAM123456")
    }
}
