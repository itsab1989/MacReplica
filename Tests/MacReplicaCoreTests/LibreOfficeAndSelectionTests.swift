import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// LibreOffice's user profile (round 4) and the saved backup selection.
@Suite("LibreOffice and saved selection", .serialized)
struct LibreOfficeAndSelectionTests {
    @Test func libreOfficeKeepsTheUsersCustomizationsOnly() async throws {
        let sandbox = try Sandbox("libreoffice")
        let (root, backup, manifest) = try await WorkflowAppProviderTests.backup(sandbox)
        func files(_ category: String) -> Set<String> {
            Set(WorkflowAppProviderTests.folder(manifest, "libreoffice", category)?.files.map(\.relativePath) ?? [])
        }
        #expect(files("libreofficeSettings") == ["registrymodifications.xcu"])
        #expect(files("templates") == ["Letter.ott"] && files("autoCorrect") == ["acor_de-DE.dat"] && files("autoText") == ["mytexts.bau"])
        #expect(files("dictionaries") == ["standard.dic"] && files("gallery") == ["sg100.thm"])
        #expect(files("menusToolbarsShortcuts") == ["modules/swriter/toolbar/standardbar.xml"])
        #expect(files("colorPalettes") == ["brand.soc"], "palettes, but not the machine's Java settings next to them")
        #expect(files("basicMacros") == ["Standard/Module1.xba"] && files("userScripts") == ["python/tools.py"])
        #expect(WorkflowAppProviderTests.folder(manifest, "libreoffice", "basicMacros")?.profile?.classification == .containsCode,
                "macros are code: offered, never selected automatically")
        let everything = BackupWriter.allFiles(in: backup)
        for never in ["LibreOffice/4/user/backup/", "/temp/lu123", "/crash/", "/extensions/", "/uno_packages/", "/store/", "/pack/", "javasettings"] {
            #expect(!everything.contains { $0.contains(never) }, "\(never) must not be in the backup")
        }
        // The settings name the home folder: stored as a placeholder, filled in on the new Mac.
        let settings = try #require(WorkflowAppProviderTests.folder(manifest, "libreoffice", "libreofficeSettings")?.files.first)
        let stored = try String(contentsOf: backup.appendingPathComponent(settings.backupPath), encoding: .utf8)
        #expect(stored.contains("file://{{MACREPLICA_HOME}}/Documents") && !stored.contains(root.homePath))
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        _ = await WorkflowAppProviderTests.restore(manifest, backup, target)
        let restored = try String(contentsOf: fresh.url.appendingPathComponent("home/Library/Application Support/LibreOffice/4/user/registrymodifications.xcu"),
                                  encoding: .utf8)
        #expect(restored.contains("file://\(fresh.homePath)/Documents"))
    }

    @Test func everyKindOfDataIsExplainedInEveryLanguage() {
        let keys = Set(AppDataCatalog.providers.flatMap { $0.categories.map(\.key) })
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for key in keys {
                #expect(localizer.has("appData.help.\(key)"), "\(language.rawValue): appData.help.\(key)")
            }
        }
        let folder = AppDataFolder(id: "x", name: "Krita · krita", relativePath: "Library/Application Support/krita",
                                   files: ["a.kpp", "b.kpp", "c.kpp", "d.kpp"].map { FileRecord(fileName: $0, domain: .user, relativePath: $0, originalPath: "~/\($0)", backupPath: "application-data/x/\($0)", sha256: "0", size: 1000) },
                                   profile: AppDataProfileReference(provider: "krita", appName: "Krita", category: "kritaResources", mustBeClosed: true))
        let help = Localizer(language: .english).appDataHelp(folder)
        #expect(help.contains("Your Krita resources") && help.contains("4 files") && help.contains("a.kpp, b.kpp, c.kpp, …"))
        #expect(help.contains("~/Library/Application Support/krita") && help.contains("Krita must be closed"))
    }

    @Test func aSavedSelectionIsReadBackAndKeepsDefaultsForNewItems() throws {
        let sandbox = try Sandbox("selection-preset")
        let preset = BackupSelectionPreset(applications: ["com.example.a": false, "com.example.b": true], applicationData: ["appdata-1": true],
                                           includeGitEmail: true, credentialProviders: ["ssh"], matchChoices: ["com.example.c": ""],
                                           personalFolders: ["~/Documents/Novel"],
                                           ownInstallers: ["com.microsoft.Word": [.init(path: "/Volumes/USB/Office.pkg", include: true)]],
                                           destination: "/Volumes/Backup")
        let url = sandbox.url.appendingPathComponent(BackupSelectionPreset.fileName)
        try preset.write(to: url)
        let read = try BackupSelectionPreset.read(from: url)
        #expect(read.applications == preset.applications && read.ownInstallers == preset.ownInstallers && read.destination == "/Volumes/Backup")
        #expect(read.includeGitEmail && read.credentialProviders == ["ssh"] && read.matchChoices == ["com.example.c": ""])
        #expect(BackupSelectionPreset.saved(in: sandbox.url) == read)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("passphrase"), "no passphrase is ever stored")
        // A saved choice wins; an item that is new keeps its default (on, or off if it is off by default).
        let excluded = BackupSelectionPreset.excluded(ids: ["com.example.a", "com.example.b", "com.example.new", "off-by-default"],
                                                      saved: read.applications, excludedByDefault: ["off-by-default", "com.example.b"])
        #expect(excluded == ["com.example.a", "off-by-default"])
        #expect(BackupSelectionPreset.choices(ids: ["x", "y"], excluded: ["y"]) == ["x": true, "y": false])
        // A selection of a newer MacReplica is not applied half; garbage is refused.
        try Data(#"{"format": 99}"#.utf8).write(to: url)
        #expect(throws: BackupSelectionPreset.PresetError.newerFormat(99)) { try BackupSelectionPreset.read(from: url) }
        try Data("not json".utf8).write(to: url)
        #expect(throws: BackupSelectionPreset.PresetError.unreadable) { try BackupSelectionPreset.read(from: url) }
        #expect(BackupSelectionPreset.saved(in: sandbox.url.appendingPathComponent("missing")) == nil)
    }
}
