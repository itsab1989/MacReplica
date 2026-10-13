import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.4: “are System Settings backed up and restored?” Explicit keys per category, read and written only
/// through `defaults`, merged into the new Mac's values, read back, and offered across macOS versions only where safe.
@Suite("macOS settings")
struct SystemSettingsTests {
    static func writePrefs(_ values: [String: Any], domain: String, home: URL) throws {
        let folder = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: folder.appendingPathComponent("\(domain).plist"))
    }

    static func readPrefs(_ domain: String, home: URL) -> [String: Any] {
        let url = home.appendingPathComponent("Library/Preferences/\(domain).plist")
        return (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]) ?? [:]
    }

    @Test func settingsAreRecordedAppliedAndReadBack() async throws {
        let sandbox = try Sandbox("settings")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let oldHome = source.layout.homeDirectory
        try Self.writePrefs(["tilesize": 48, "autohide": true, "persistent-apps": ["x"]], domain: "com.apple.dock", home: oldHome)
        try Self.writePrefs(["KeyRepeat": 2, "AppleLanguages": ["de-DE", "en"], "SomethingElse": 1], domain: ".GlobalPreferences", home: oldHome)
        try Self.writePrefs(["location": oldHome.path + "/Pictures/Shots"], domain: "com.apple.screencapture", home: oldHome)
        let result = try await TestEnvironment.inventory(source).run()
        let dock = try #require(result.manifest.settings.first { $0.category == "dock" })
        #expect(dock.keyCount == 2, "only the listed keys – never the apps in the Dock")
        #expect(result.manifest.settings.first { $0.category == "keyboard" }?.keyCount == 1)
        #expect(result.manifest.settings.first { $0.category == "languageRegion" }?.keyCount == 1)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let shots = try String(contentsOf: outcome.url.appendingPathComponent("settings/screenshots/com.apple.screencapture.plist"), encoding: .utf8)
        #expect(shots.contains(AppDataScanner.homePlaceholder) && !shots.contains(oldHome.path), "the home folder is stored as a placeholder")
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)

        // A new Mac with its own Dock settings and another home folder.
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let newHome = target.layout.homeDirectory
        try Self.writePrefs(["tilesize": 64, "orientation": "left"], domain: "com.apple.dock", home: newHome)
        let manifest = try ManifestIO.read(from: outcome.url)
        let selection = RestoreSelection(components: [.systemSettings])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
        let dry = await executor.dryRun(plan: plan, selection: selection)
        #expect(dry.first { $0.item.id == "settings:dock" }?.prediction == Prediction.willInstall)
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["settings:dock"]?.outcome == .succeeded)
        #expect(session.results["settings:dock"]?.notes.contains(.settingsApplied(count: 2)) == true)
        #expect(session.results["settings:keyboard"]?.notes.contains(.logoutRequired) == true)
        let newDock = Self.readPrefs("com.apple.dock", home: newHome)
        #expect(newDock["tilesize"] as? Int == 48 && newDock["autohide"] as? Bool == true)
        #expect(newDock["orientation"] as? String == "left", "settings that were not recorded stay as they are")
        #expect(newDock["persistent-apps"] == nil)
        #expect(Self.readPrefs("com.apple.screencapture", home: newHome)["location"] as? String == newHome.standardizedFileURL.path + "/Pictures/Shots")
        #expect(Self.readPrefs(".GlobalPreferences", home: newHome)["SomethingElse"] == nil)
        let restarted = (try? String(contentsOf: fresh.state.appendingPathComponent("restarted"), encoding: .utf8)) ?? ""
        #expect(restarted.contains("Dock") && restarted.contains("SystemUIServer"))
        // Running it again changes nothing.
        let again = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(again.results["settings:dock"]?.outcome == .alreadyPresent)
    }

    @Test func aValueOfAnotherKindIsLeftAlone() async throws {
        let sandbox = try Sandbox("settings-type")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        try Self.writePrefs(["tilesize": 48], domain: "com.apple.dock", home: source.layout.homeDirectory)
        let result = try await TestEnvironment.inventory(source).run()
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        try Self.writePrefs(["tilesize": "large"], domain: "com.apple.dock", home: target.layout.homeDirectory)
        let selection = RestoreSelection(components: [.systemSettings])
        let plan = RestorePlanner().plan(manifest: try ManifestIO.read(from: outcome.url), selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["settings:dock"]?.notes.contains(.settingsDifferentType(keys: ["com.apple.dock › tilesize"])) == true)
        #expect(session.results["settings:dock"]?.outcome == .alreadyPresent, "nothing was changed, nothing is claimed as restored")
        #expect(Self.readPrefs("com.apple.dock", home: target.layout.homeDirectory)["tilesize"] as? String == "large")
    }

    @Test func crossVersionRules() {
        let dock = SettingsCatalog.category("dock")!
        let shortcuts = SettingsCatalog.category("keyboardShortcuts")!
        #expect(dock.recommended(from: "14.8.4", to: "14.7") && dock.recommended(from: "14.8.4", to: "26.1"))
        #expect(!dock.recommended(from: "26.1", to: "14.8"), "never onto an older macOS by default")
        #expect(shortcuts.recommended(from: "14.8.4", to: "14.1") && !shortcuts.recommended(from: "14.8.4", to: "26.1"))
        var manifest = Manifest(macreplicaVersion: "1.0.5", createdAt: Date(), macosVersion: "14.8.4", architecture: .x86_64)
        manifest.settings = [SettingsRecord(category: "dock", files: [], keyCount: 1), SettingsRecord(category: "inputSources", files: [], keyCount: 1)]
        #expect(SettingsCatalog.notRecommendedItemIDs(manifest, targetMacOS: "26.1") == ["settings:inputSources"])
        #expect(SettingsCatalog.notRecommendedItemIDs(manifest, targetMacOS: "13.6") == ["settings:dock", "settings:inputSources"])
        #expect(SettingsCatalog.categories.allSatisfy { !$0.domains.contains { $0.name.contains("ByHost") } })
        #expect(SettingsValues.replacingHome("/Users/annabelle/x", from: "/Users/anna", to: "/Users/bob") as? String == "/Users/annabelle/x")
        #expect(SettingsValues.replacingHome("file:///Users/anna/Desktop/", from: "/Users/anna", to: "/Users/bob") as? String == "file:///Users/bob/Desktop/")
    }

    /// The real `defaults` on a throw-away domain (removed afterwards): export and import work as SettingsStore expects.
    @Test func realDefaultsRoundTrip() async throws {
        let domain = "io.github.itsab1989.MacReplica.settings-test-\(UUID().uuidString.prefix(8))"
        let layout = SystemLayout.live()
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        let store = SettingsStore(layout: layout, runner: runner)
        defer {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["delete", domain]
            try? process.run()
            process.waitUntilExit()
        }
        #expect(try await store.export(domain).isEmpty, "a domain that does not exist is empty")
        let sandbox = try Sandbox("settings-real")
        try await store.importDomain(domain, values: ["tilesize": 48, "autohide": true, "names": ["a", "b"]], work: sandbox.url)
        let read = try await store.export(domain)
        #expect(read["tilesize"] as? Int == 48 && read["autohide"] as? Bool == true && read["names"] as? [String] == ["a", "b"])
    }
}
