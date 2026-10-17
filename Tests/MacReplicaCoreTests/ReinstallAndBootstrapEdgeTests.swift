import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The reinstall guide's structure (numbered steps vs. bullet lists), its notices, and the bootstrap copy's
/// processor rules and size – details the mutation run showed untested.
@Suite("Reinstall guide: structure")
struct ReinstallGuideStructureTests {
    /// The list tag following each numbered heading (`1` → `ul`, …).
    static func listTags(_ html: String) -> [Int: String] {
        var tags: [Int: String] = [:]
        for part in html.components(separatedBy: "<h2>").dropFirst() {
            guard let number = Int(part.prefix { $0.isNumber }) else { continue }
            let ol = part.range(of: "<ol>")?.lowerBound
            let ul = part.range(of: "<ul>")?.lowerBound
            switch (ol, ul) {
            case let (o?, u?): tags[number] = o < u ? "ol" : "ul"
            case (_?, nil): tags[number] = "ol"
            case (nil, _?): tags[number] = "ul"
            default: break
            }
        }
        return tags
    }

    @Test func stepsAreNumberedAndChoicesAreBullets() {
        let builder = ReportBuilder(localizer: TestEnvironment.english)
        let appleSilicon = builder.reinstallGuide(profile: MacProfile(architecture: .arm64, modelIdentifier: "Mac15,9", macOSVersion: "27.0.1"),
                                                  manifest: nil, backupFolderName: nil)
        #expect(Self.listTags(appleSilicon) == [1: "ul", 2: "ul", 3: "ul", 4: "ul", 5: "ol", 6: "ol", 7: "ol", 8: "ol", 9: "ol", 10: "ol", 11: "ol", 12: "ul", 13: "ul"])
        let intel = builder.reinstallGuide(profile: MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro16,1", macOSVersion: "14.8.4"),
                                           manifest: nil, backupFolderName: nil)
        // On Intel the startup keys are alternatives, not a sequence.
        #expect(Self.listTags(intel)[6] == "ul")
        #expect(Self.listTags(intel)[7] == "ol")
    }

    @Test func backupStateAndBootstrapLine() {
        let builder = ReportBuilder(localizer: TestEnvironment.english)
        let profile = MacProfile(architecture: .arm64, modelIdentifier: "Mac15,9", macOSVersion: "27.0.1")
        var manifest = Manifest(macreplicaVersion: "1.0.5", createdAt: Date(), macosVersion: "27.0.1", architecture: .arm64)
        let complete = builder.reinstallGuide(profile: profile, manifest: manifest, backupFolderName: nil)
        #expect(complete.contains("<p class=\"ok\">" + HTML.escape(TestEnvironment.english.completenessTitle(manifest))))
        #expect(complete.contains(HTML.escape(TestEnvironment.english.t("guide.newMac.1"))), "no copy in the backup: download MacReplica")
        #expect(complete.contains(HTML.escape(TestEnvironment.english.t("bootstrap.missing"))))
        manifest.backupIssues = [BackupIssue(path: "~/Documents/x", reason: .unreadable)]
        manifest.bootstrapApp = BootstrapAppRecord(path: "MacReplica.app", version: "1.0.5", build: "90", architectures: [.arm64, .x86_64], teamIdentifier: nil)
        let partial = builder.reinstallGuide(profile: profile, manifest: manifest, backupFolderName: nil)
        #expect(partial.contains("<p class=\"warn\">" + HTML.escape(TestEnvironment.english.completenessTitle(manifest))))
        #expect(partial.contains(HTML.escape(TestEnvironment.english.t("guide.newMac.1.fromBackup"))))
        #expect(!partial.contains(HTML.escape(TestEnvironment.english.t("guide.newMac.1")) + "<"))
    }
}

@Suite("Bootstrap copy: processors and size")
struct BootstrapAppEdgeTests {
    static func record(_ architectures: [CPUArchitecture]) -> BootstrapAppRecord {
        BootstrapAppRecord(path: "MacReplica.app", version: "1.0.5", build: nil, architectures: architectures, teamIdentifier: nil)
    }

    @Test func whichMacsTheCopyRunsOn() {
        #expect(Self.record([.arm64, .x86_64]).runs(on: .arm64) && Self.record([.arm64, .x86_64]).runs(on: .x86_64))
        #expect(Self.record([.arm64]).runs(on: .arm64))
        #expect(!Self.record([.arm64]).runs(on: .x86_64), "an Apple silicon build does not run on Intel")
        #expect(Self.record([.x86_64]).runs(on: .x86_64))
        #expect(Self.record([.x86_64]).runs(on: .arm64), "an Intel build runs on Apple silicon with Rosetta")
        #expect(!Self.record([]).runs(on: .arm64) && !Self.record([]).runs(on: .x86_64))
        #expect(!Self.record([.x86_64]).runs(on: .unknown))
        #expect(Self.record([.arm64, .x86_64]).isUniversal && !Self.record([.arm64]).isUniversal)
    }

    @Test func sizeCountsEveryFileOfAnAppBundleOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: app.appendingPathComponent("Contents/MacOS/Test"))
        try Data(count: 234).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(BootstrapApp.size(of: app) == 1234)
        #expect(BootstrapApp.size(of: folder) == 0, "only an app bundle is measured")
        #expect(try BootstrapApp.copy(folder, into: folder) == nil, "not an app bundle: no copy")
    }
}
