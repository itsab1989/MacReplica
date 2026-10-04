import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Krita, GIMP, Inkscape, Scribus, DisplayCAL, BenQ, XP-Pen, Office, Mail, Cryptomator and configuration folders:
/// what is backed up, what never leaves the old Mac, and what the new Mac gets.
@Suite("Workflow app providers")
struct WorkflowAppProviderTests {
    static func backup(_ sandbox: Sandbox) async throws -> (SimulationRoot, URL, Manifest) {
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addWorkflowAppData()
        let result = try await TestEnvironment.inventory(source).run()
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        return (root, outcome.url, outcome.manifest)
    }

    static func folder(_ manifest: Manifest, _ provider: String, _ category: String) -> AppDataFolder? {
        manifest.applicationData.first { $0.profile?.provider == provider && $0.profile?.category == category }
    }

    static func restore(_ manifest: Manifest, _ backup: URL, _ target: SimulationEnvironment, continuing: RestoreSession? = nil) async -> RestoreSession {
        let selection = RestoreSelection(components: [.applicationData])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        return await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: continuing ?? RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    @Test func onlyUserCreatedDataIsBackedUp() async throws {
        let sandbox = try Sandbox("workflow-backup")
        let (_, backup, manifest) = try await Self.backup(sandbox)
        func files(_ provider: String, _ category: String) -> Set<String> { Set(Self.folder(manifest, provider, category)?.files.map(\.relativePath) ?? []) }
        #expect(files("krita", "kritaResources").isSuperset(of: ["resourcecache.sqlite", "Brush Pack.bundle", "paintoppresets/Ink Pen.kpp", "workspaces/Painting.kws"]),
                "Krita's resource database belongs to the resources (tags, active bundles)")
        #expect(files("gimp", "gimpProfile").isSuperset(of: ["brushes/Grain.gbr", "palettes/Brand.gpl", "gimprc", "menurc"]))
        #expect(files("gimp", "gimpPlugins") == ["sharpen/sharpen.py"])
        #expect(files("inkscape", "inkscapeExtensions") == ["hatch.inx"])
        #expect(files("scribus-settings", "preferences") == ["prefs150.xml"])
        #expect(files("displaycal", "calibrations").count == 3)
        #expect(files("benq-palette-master", "calibrationTargets") == ["benq_params"])
        #expect(Self.folder(manifest, "benq-palette-master", "calibrationTargets")?.displayPath == "/Users/Shared/RD/strings")
        #expect(files("xppen", "tabletSettings") == ["config.xml"])
        #expect(files("microsoft-office", "officeTemplates") == ["Normal.dotm", "Letter.dotx"], "Finder's .localized translations are not templates")
        #expect(files("microsoft-office", "autoCorrect") == ["Microsoft Office ACL [English]"])
        #expect(files("microsoft-office", "excelStartup") == ["Personal.xlsb"])
        #expect(files("apple-mail", "mailSignatures") == ["AllSignatures.plist", "1234.mailsignature"])
        #expect(files("apple-mail", "mailRules") == ["SyncedRules.plist"])
        #expect(files("cryptomator", "vaultList") == ["settings.json"])
        #expect(files("karabiner", "keyboardRules") == ["karabiner.json"])
        // Plug-ins, scripts and macros are offered but never selected by themselves.
        for (provider, category) in [("gimp", "gimpPlugins"), ("gimp", "gimpScripts"), ("krita", "kritaPlugins"), ("inkscape", "inkscapeExtensions"),
                                     ("microsoft-office", "excelStartup"), ("hammerspoon", "automationScripts")] {
            #expect(Self.folder(manifest, provider, category)?.profile?.classification == .containsCode, "\(provider)/\(category)")
        }
        #expect(!DataClassification.containsCode.selectedByDefault && DataClassification.containsCode.isOffered)
        #expect(Self.folder(manifest, "microsoft-office", "officeTemplates")?.profile?.requiresFullDiskAccess == true)
        #expect(Self.folder(manifest, "xppen", "tabletSettings")?.profile?.effectiveConfidence == .experimental)
        #expect(Self.folder(manifest, "krita", "kritaResources")?.profile?.effectiveConfidence == .checkInApp)
        let everything = BackupWriter.allFiles(in: backup)
        for never in ["krita.log", "kritadisplayrc", "pluginrc", "documents", "tmp/swap", "cache/thumbnails", "CrashLog/", "extension-errors.log", "cache/img", "/dl/", ".lock",
                      "mymac.ini", "MicrosoftRegistrationDB", "licensingV2", ".localized/de.strings", "Envelope Index", "INBOX.mbox", "key.p12",
                      "ipc.socket", "cipher.c9r", "automatic_backups"] {
            #expect(!everything.contains { $0.contains(never) }, "\(never) must not be in the backup")
        }
    }

    @Test func homePathsAreStoredAsPlaceholdersAndFilledInOnTheNewMac() async throws {
        let sandbox = try Sandbox("workflow-home")
        let (root, backup, manifest) = try await Self.backup(sandbox)
        let ini = try #require(Self.folder(manifest, "displaycal-settings", "calibrationSettings")?.files.first)
        #expect(ini.metadata["homePlaceholder"] == "1")
        let stored = try String(contentsOf: backup.appendingPathComponent(ini.backupPath), encoding: .utf8)
        #expect(stored.contains("{{MACREPLICA_HOME}}/Library/Application Support/DisplayCAL/storage") && !stored.contains(root.homePath),
                "the backup does not contain the old home path")
        #expect(stored.contains("argyll.dir = /opt/homebrew/bin"), "other paths stay as they are")

        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let session = await Self.restore(manifest, backup, target)
        let id = "appdata:\(try #require(Self.folder(manifest, "displaycal-settings", "calibrationSettings")).id)"
        #expect(session.results[id]?.outcome == .succeeded)
        let restored = try String(contentsOf: fresh.url.appendingPathComponent("home/Library/Preferences/DisplayCAL/DisplayCAL.ini"), encoding: .utf8)
        #expect(restored.contains("\(fresh.homePath)/Library/Application Support/DisplayCAL/storage"), "this Mac's home folder")
        #expect(!restored.contains("{{MACREPLICA_HOME}}") && !restored.contains(root.homePath))
        let kritarc = try String(contentsOf: fresh.url.appendingPathComponent("home/Library/Preferences/kritarc"), encoding: .utf8)
        #expect(kritarc.contains("ResourceDirectory=\(fresh.homePath)/Library/Application Support/krita"))
        let tags = try String(contentsOf: fresh.url.appendingPathComponent("home/Library/Application Support/GIMP/2.10/tags.xml"), encoding: .utf8)
        #expect(tags.contains("external:\(fresh.homePath)/Library/Fonts/Brand.otf"), "GIMP's tags name resources by absolute path")
        // Second run: the restored files are recognised as identical, nothing is written again.
        let again = await Self.restore(manifest, backup, target)
        #expect(again.results[id]?.outcome == .alreadyPresent)
    }

    @Test func gimpDataStaysInItsVersionFolderAndPluginsStayExecutable() async throws {
        let sandbox = try Sandbox("workflow-gimp")
        let (_, backup, manifest) = try await Self.backup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try FileManager.default.createDirectory(at: fresh.url.appendingPathComponent("home/Library/Application Support/GIMP/3.2"), withIntermediateDirectories: true)
        _ = await Self.restore(manifest, backup, target)
        let gimp = fresh.url.appendingPathComponent("home/Library/Application Support/GIMP")
        #expect(FileManager.default.fileExists(atPath: gimp.appendingPathComponent("2.10/brushes/Grain.gbr").path),
                "restored for 2.10: GIMP 3 imports it on its first start")
        #expect(!FileManager.default.fileExists(atPath: gimp.appendingPathComponent("3.2/brushes").path), "never moved into another GIMP version")
        let plugin = gimp.appendingPathComponent("2.10/plug-ins/sharpen/sharpen.py")
        #expect(FileManager.default.isExecutableFile(atPath: plugin.path), "GIMP only runs executable plug-ins")
    }

    @Test func cryptomatorVaultsAreCheckedWithoutTouchingThem() async throws {
        let sandbox = try Sandbox("workflow-cryptomator")
        let (_, backup, manifest) = try await Self.backup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        // The vault folder is back (restored with the user's documents, or synced); the drive is not connected.
        try FileManager.default.createDirectory(at: fresh.url.appendingPathComponent("home/Vaults/Private"), withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: fresh.url.appendingPathComponent("home/Vaults/Private/vault.cryptomator"))
        let session = await Self.restore(manifest, backup, target)
        let id = "appdata:\(try #require(Self.folder(manifest, "cryptomator", "vaultList")).id)"
        #expect(session.results[id]?.outcome == .succeeded)
        #expect(session.results[id]?.notes.contains(.vaultsRegistered(found: 1, missing: ["Work"])) == true)
        let settings = try String(contentsOf: fresh.url.appendingPathComponent("home/Library/Application Support/Cryptomator/settings.json"), encoding: .utf8)
        #expect(settings.contains("\(fresh.homePath)/Vaults/Private"))
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/Library/Application Support/Cryptomator/key.p12").path))
        #expect(CryptomatorSettings.vaults(in: URL(fileURLWithPath: "/nonexistent/settings.json")).isEmpty)
    }

    @Test func protectedLocationsWaitForFullDiskAccess() async throws {
        let sandbox = try Sandbox("workflow-fda")
        let (_, backup, manifest) = try await Self.backup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let mail = fresh.url.appendingPathComponent("home/Library/Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        // Without Full Disk Access, macOS refuses to list ~/Library/Mail.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.path) }
        let signatures = try #require(Self.folder(manifest, "apple-mail", "mailSignatures"))
        let id = "appdata:\(signatures.id)"
        let first = await Self.restore(manifest, backup, target)
        #expect(first.results[id]?.outcome == .skipped(.needsFullDiskAccess(name: "Mail")))
        #expect(first.results[id]?.outcome.isOpen == true, "offered again after access was granted")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.path)
        let second = await Self.restore(manifest, backup, target, continuing: first)
        #expect(second.results[id]?.outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: mail.appendingPathComponent("V10/MailData/Signatures/1234.mailsignature").path))
    }

    @Test func mailSettingsOnlyThroughTheProvider() throws {
        let sandbox = try Sandbox("workflow-mail")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        try root.addWorkflowAppData()
        let scanner = AppDataScanner(layout: simulation.layout)
        let mailData = root.url.appendingPathComponent("home/Library/Mail/V10/MailData")
        #expect(throws: AppDataError.sensitiveLocation("Library/Mail")) { try scanner.scan(mailData) }
        #expect(throws: AppDataError.sensitiveLocation("Library/Mail")) {
            try scanner.scan(root.url.appendingPathComponent("home/Library/Mail/V10"), allowProviderExceptions: true)
        }
        let rules = try scanner.scan(mailData, onlyFiles: ["SyncedRules.plist"], allowProviderExceptions: true)
        #expect(rules.files.map(\.record.relativePath) == ["SyncedRules.plist"])
    }
}
