import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Where versioned application data goes on the new Mac, what the restore selection shows for it, and
/// data that waits for its app.
@Suite("Application data version targets and requirements")
struct AppDataVersionTargetTests {
    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let folder: AppDataFolder
        let fresh: SimulationRoot
        let target: SimulationEnvironment
        /// The folder that holds the version folders on the new Mac.
        var parent: URL { fresh.url.appendingPathComponent("home/Library/Application Support/Vendor") }
        var item: RestoreItem {
            var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
            manifest.applicationData = [folder]
            return RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData])).items.first!
        }
    }

    /// Two files of "Editor 8"'s presets in a backup, and a new Mac with the given version folders.
    static func context(_ name: String, profile: AppDataProfileReference? = nil, versionsOnNewMac: [String] = []) throws -> Context {
        let sandbox = try Sandbox(name)
        let backup = try sandbox.folder("backup")
        var records: [FileRecord] = []
        for (file, text) in [("a.preset", "first"), ("sub/b.preset", "second")] {
            let backupPath = "application-data/editor/\(file)"
            let url = backup.appendingPathComponent(backupPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            records.append(FileRecord(fileName: url.lastPathComponent, domain: .user, relativePath: file,
                                      originalPath: "~/Library/Application Support/Vendor/Editor 8/Presets/\(file)", backupPath: backupPath,
                                      sha256: try Hashing.sha256Hex(ofFile: url), size: Int64(text.utf8.count)))
        }
        let reference = profile ?? AppDataProfileReference(provider: "editor", appName: "Editor", category: "presets", appVersion: "Editor 8",
                                                           versionFolderPattern: #"^Editor \d+$"#, movesBetweenVersions: true)
        let folder = AppDataFolder(id: "editor", name: "Editor 8 · Presets", relativePath: "Library/Application Support/Vendor/Editor 8/Presets",
                                   files: records, profile: reference)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let context = Context(sandbox: sandbox, backup: backup, folder: folder, fresh: fresh, target: target)
        for version in versionsOnNewMac {
            try FileManager.default.createDirectory(at: context.parent.appendingPathComponent(version), withIntermediateDirectories: true)
        }
        return context
    }

    static func inspector(_ c: Context, choice: String? = nil) -> Inspector {
        var selection = RestoreSelection(components: [.applicationData])
        if let choice { selection.sourceChoices[c.item.id] = choice }
        return Inspector(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, selection: selection, damagedFiles: [])
    }

    static func installEditor(_ c: Context, bundleID: String, version: String) throws {
        // In a folder of its own, as some vendor installers do.
        let folder = c.fresh.url.appendingPathComponent("Applications/Editor Suite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Editor.app").path) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent("Editor.app"))
        }
        try SimulationBuilder.makeSyntheticApp(name: "Editor", bundleID: bundleID, version: version, in: folder)
    }

    @Test func theNewestOtherVersionIsChosenByVersionNumberNotByName() throws {
        // "Editor 9" sorts after "Editor 11" as text; by version number 11 is the newest.
        let c = try Self.context("version-newest", versionsOnNewMac: ["Editor 9", "Editor 11", "Editor 10", "Editor Beta"])
        let target = try #require(Self.inspector(c).applicationDataTarget(c.folder, itemID: c.item.id))
        let version = try #require(target.version)
        #expect(version.alternatives == ["Editor 11", "Editor 10", "Editor 9"], "newest first; folders of another channel are not offered")
        #expect(version.chosen == "Editor 11" && version.original == "Editor 8" && !version.originalExists)
        #expect(target.relativePath == "Library/Application Support/Vendor/Editor 11/Presets")
        #expect(Self.inspector(c).applicationDataNotes(c.item) == [.restoredIntoVersion(original: "Editor 8", target: "Editor 11")])
    }

    @Test func theUserCanChooseAnyOfferedVersionButNothingElse() throws {
        let c = try Self.context("version-choice", versionsOnNewMac: ["Editor 8", "Editor 9", "Editor 10", "Other"])
        // The original exists: it is used unless the user picks another offered version.
        #expect(Self.inspector(c).applicationDataTarget(c.folder, itemID: c.item.id)?.version?.chosen == "Editor 8")
        #expect(Self.inspector(c).applicationDataNotes(c.item).isEmpty)
        let older = try #require(Self.inspector(c, choice: "Editor 9").applicationDataTarget(c.folder, itemID: c.item.id))
        #expect(older.version?.chosen == "Editor 9")
        #expect(older.relativePath == "Library/Application Support/Vendor/Editor 9/Presets")
        #expect(Self.inspector(c, choice: "Editor 9").applicationDataNotes(c.item) == [.restoredIntoVersion(original: "Editor 8", target: "Editor 9")])
        // A folder that is not a version of the app, or that is not on this Mac, is never used.
        for invalid in ["Other", "Editor 12", "../Editor 9"] {
            #expect(Self.inspector(c, choice: invalid).applicationDataTarget(c.folder, itemID: c.item.id)?.version?.chosen == "Editor 8", "\(invalid)")
        }
        // Without an item (the plan of a restore without a selection) the choice does not apply.
        #expect(Self.inspector(c, choice: "Editor 9").applicationDataTarget(c.folder, itemID: nil)?.version?.chosen == "Editor 8")
    }

    @Test func dataThatOnlyWorksInItsOwnVersionIsNeverMoved() throws {
        let profile = AppDataProfileReference(provider: "editor", appName: "Editor", category: "preferences", appVersion: "Editor 8",
                                              versionFolderPattern: #"^Editor \d+$"#, movesBetweenVersions: false)
        let c = try Self.context("version-stays", profile: profile, versionsOnNewMac: ["Editor 10"])
        let version = try #require(Self.inspector(c).applicationDataTarget(c.folder, itemID: c.item.id)?.version)
        #expect(version.chosen == "Editor 8" && version.alternatives.isEmpty && !version.originalExists)
        #expect(Self.inspector(c, choice: "Editor 10").applicationDataTarget(c.folder, itemID: c.item.id)?.version?.chosen == "Editor 8")
        #expect(Self.inspector(c).applicationDataNotes(c.item) == [.applicationVersionDiffers(original: "Editor 8")])
    }

    @Test func versionNumbersAreTakenFromTheEndOfTheFolderName() {
        #expect(Inspector.versionNumber("Adobe Photoshop 2026") == "2026")
        #expect(Inspector.versionNumber("4.2") == "4.2")
        #expect(Inspector.versionNumber("Adobe Photoshop (Beta)") == "0")
    }

    @Test func theComparisonCountsNewIdenticalAndDifferentFiles() throws {
        let c = try Self.context("version-comparison", versionsOnNewMac: ["Editor 8"])
        let empty = try #require(Self.inspector(c).applicationDataComparison(c.item))
        #expect(empty.newFiles == 2 && empty.identicalFiles == 0 && empty.differentFiles.isEmpty)
        #expect(empty.version?.chosen == "Editor 8" && empty.version?.originalExists == true)
        let presets = c.parent.appendingPathComponent("Editor 8/Presets")
        try FileManager.default.createDirectory(at: presets.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: presets.appendingPathComponent("a.preset"))
        let partly = try #require(Self.inspector(c).applicationDataComparison(c.item))
        #expect(partly.newFiles == 1 && partly.identicalFiles == 1 && partly.differentFiles.isEmpty)
        #expect(Self.inspector(c).predictApplicationData(c.item) == .willCopy)
        try Data("changed on this Mac".utf8).write(to: presets.appendingPathComponent("sub/b.preset"))
        let different = try #require(Self.inspector(c).applicationDataComparison(c.item))
        #expect(different.newFiles == 0 && different.identicalFiles == 1)
        #expect(different.differentFiles.map(\.path) == ["sub/b.preset"])
        #expect(different.differentFiles.first?.backupSize == 6 && different.differentFiles.first?.existingSize == 19)
    }

    @Test func dataThatNeedsItsAppWaitsUntilItIsInstalled() throws {
        let profile = AppDataProfileReference(provider: "editor", appName: "Editor", category: "presets", bundleIdentifiers: ["com.example.Editor"],
                                              appMustBeInstalled: true)
        let c = try Self.context("requirement-installed", profile: profile)
        #expect(Self.inspector(c).predictApplicationData(c.item) == .willSkip(.applicationNotInstalled(name: "Editor")))
        // Found one folder below the application folder, whatever the case of its bundle identifier.
        try Self.installEditor(c, bundleID: "COM.EXAMPLE.EDITOR", version: "1.0")
        #expect(Self.inspector(c).installedAppVersion(bundleIdentifiers: ["com.example.Editor"]) == (true, "1.0"))
        #expect(Self.inspector(c).predictApplicationData(c.item) == .willCopy)
        #expect(Self.inspector(c).installedAppVersion(bundleIdentifiers: ["com.example.other"]) == (false, nil))
    }

    @Test func dataForANewerAppOnlyWaitsForAnOlderOne() throws {
        let profile = AppDataProfileReference(provider: "editor", appName: "Editor", category: "presets", bundleIdentifiers: ["com.example.editor"],
                                              sourceAppVersion: "2.5", notForOlderApp: true)
        let c = try Self.context("requirement-older", profile: profile)
        // Without the app the data can be restored (only appMustBeInstalled waits for it).
        #expect(Self.inspector(c).applicationDataRequirement(c.folder) == nil)
        try Self.installEditor(c, bundleID: "com.example.editor", version: "2.4.9")
        #expect(Self.inspector(c).predictApplicationData(c.item)
                == .willSkip(.applicationVersionOlder(name: "Editor", installed: "2.4.9", backup: "2.5")))
        try Self.installEditor(c, bundleID: "com.example.editor", version: "2.5")
        #expect(Self.inspector(c).applicationDataRequirement(c.folder) == nil, "the same version")
        // Data without requirements never looks for the app.
        var plain = c.folder
        plain.profile?.notForOlderApp = false
        try Self.installEditor(c, bundleID: "com.example.editor", version: "1.0")
        #expect(Self.inspector(c).applicationDataRequirement(plain) == nil)
    }

    @Test func providersThatListFilesAreOnlyDetectedWhenOneOfThemIsThere() throws {
        let sandbox = try Sandbox("detect-listed-files")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let folder = root.url.appendingPathComponent("home/Library/Preferences/Editor")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: folder.appendingPathComponent("unrelated.plist"))
        let provider = AppDataProvider(id: "editor", appName: "Editor", bundleIdentifiers: ["com.example.editor"], base: "Library/Preferences/Editor",
                                       categories: [AppDataCategory("keyboard", "", files: ["Keys.xml"])], mustBeClosed: false,
                                       status: .fixtureTested, evidence: [], researchedOn: "2026-10-03", limitations: [])
        #expect(AppDataProviders.detect(layout: simulation.layout, providers: [provider]).isEmpty, "only an unrelated file is there")
        try Data("keys".utf8).write(to: folder.appendingPathComponent("Keys.xml"))
        let detected = AppDataProviders.detect(layout: simulation.layout, providers: [provider])
        #expect(detected.map(\.files) == [["Keys.xml"]])
    }

    @Test func folderIdentityAndFileDomainDependOnTheScope() throws {
        let sandbox = try Sandbox("scan-scope")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let scanner = AppDataScanner(layout: simulation.layout)
        let relative = "Library/Application Support/Vendor/App"
        func make(_ path: String) throws -> URL {
            let url = root.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("data".utf8).write(to: url.appendingPathComponent("data.txt"))
            return url
        }
        func id(_ identity: String) -> String { "appdata-" + String(Hashing.sha256Hex(of: Data(identity.utf8)).prefix(12)) }
        // The identifier of a home folder is the same as in earlier backups; a shared one never collides with it.
        let home = try scanner.scan(try make("home/" + relative))
        #expect(home.folder.id == id(relative))
        #expect(home.folder.files.map(\.domain) == [.user])
        #expect(home.folder.shippedFilesLeftOut == nil, "nothing came with an app")
        #expect(home.folder.scope == nil && home.folder.displayPath == "~/" + relative)
        let shared = try scanner.scan(try make(relative), scope: .sharedLibrary)
        #expect(shared.folder.id == id("/Library/Application Support/Vendor/App"))
        #expect(shared.folder.files.map(\.domain) == [.system])
        #expect(shared.folder.scope == .sharedLibrary && shared.folder.displayPath == "/Library/Application Support/Vendor/App")
    }

    @Test func symbolicLinksInsideAnApplicationFolderAreNotFollowed() throws {
        let sandbox = try Sandbox("scan-symlink")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let folder = root.url.appendingPathComponent("home/Library/Application Support/Linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("own".utf8).write(to: folder.appendingPathComponent("own.txt"))
        let outside = root.url.appendingPathComponent("home/elsewhere.txt")
        try Data("elsewhere".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let scanned = try AppDataScanner(layout: simulation.layout).scan(folder)
        #expect(scanned.folder.files.map(\.relativePath) == ["own.txt"])
    }
}
