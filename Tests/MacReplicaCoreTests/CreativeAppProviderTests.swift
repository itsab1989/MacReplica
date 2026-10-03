import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Photoshop (release and beta) and DaVinci Resolve: what is backed up, where it goes on the new Mac,
/// and what never leaves the old one.
@Suite("Creative app providers")
struct CreativeAppProviderTests {
    /// The source Mac with Photoshop and Resolve data, written as a backup.
    static func creativeBackup(_ sandbox: Sandbox) async throws -> (URL, Manifest) {
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addCreativeAppData()
        let result = try await TestEnvironment.inventory(source).run()
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        return (outcome.url, outcome.manifest)
    }

    static func folder(_ manifest: Manifest, _ provider: String, _ category: String, version: String? = nil) -> AppDataFolder? {
        manifest.applicationData.first {
            $0.profile?.provider == provider && $0.profile?.category == category && (version == nil || $0.profile?.appVersion == version)
        }
    }

    static func restore(_ manifest: Manifest, backup: URL, on target: SimulationEnvironment, selection: RestoreSelection = RestoreSelection(components: [.applicationData]),
                        continuing previous: RestoreSession? = nil) async -> RestoreSession {
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = previous ?? RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id))
        return await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: session, onEvent: { _ in })
    }

    @Test func photoshopBetaIsSeparateFromTheReleaseAndMachineStateStaysBehind() async throws {
        let sandbox = try Sandbox("creative-photoshop")
        let (backup, manifest) = try await Self.creativeBackup(sandbox)
        let beta = try #require(Self.folder(manifest, "adobe-photoshop-beta", "actions"))
        #expect(beta.name == "Adobe Photoshop (Beta) · Actions")
        #expect(beta.profile?.appVersion == "Adobe Photoshop (Beta)")
        #expect(Self.folder(manifest, "adobe-photoshop-beta", "toolPresets")?.files.map(\.relativePath) == ["Beta Tools.tpl"])
        let panels = try #require(Self.folder(manifest, "adobe-photoshop-beta-settings", "panelsAndWorkspaces"))
        #expect(Set(panels.files.map(\.relativePath)) == ["Brushes.psp", "Actions Palette.psp", "Swatches.psp"])
        #expect(panels.profile?.classification == .safe, "Adobe lists these files as copyable between installations")
        let preferences = try #require(Self.folder(manifest, "adobe-photoshop-beta-settings", "generalPreferences"))
        #expect(preferences.files.map(\.relativePath) == ["Adobe Photoshop (Beta) Prefs.psp"])
        #expect(preferences.profile?.classification == .compatibilitySensitive)
        #expect(Self.folder(manifest, "adobe-photoshop-settings", "generalPreferences")?.files.map(\.relativePath) == ["Adobe Photoshop 2025 Prefs.psp"])
        #expect(Self.folder(manifest, "adobe-photoshop-beta-settings", "modifiedWorkspaces")?.files.map(\.relativePath) == ["Retouch.psw"])
        #expect(Self.folder(manifest, "adobe-color-settings", "colorSettingsFiles")?.files.map(\.relativePath) == ["Print Studio.csf"])
        // The beta data never ends up in a release folder and vice versa.
        #expect(!manifest.applicationData.contains { $0.profile?.provider == "adobe-photoshop" && $0.relativePath.contains("(Beta)") })
        #expect(!manifest.applicationData.contains { $0.profile?.provider == "adobe-photoshop-beta" && !$0.relativePath.contains("(Beta)") })
        let everything = BackupWriter.allFiles(in: backup)
        for never in ["MachinePrefs.psp", "PluginCache.psp", "FMCache.psp", "LaunchEndFlag.psp", "sniffer-out.txt", "AutoRecover", "CT Font Cache"] {
            #expect(!everything.contains { $0.contains(never) }, "\(never) is machine state or a cache")
        }
    }

    @Test func presetsGoIntoThePhotoshopVersionOnTheNewMacUnlessTheUserChoosesOtherwise() async throws {
        let sandbox = try Sandbox("creative-photoshop-version")
        let (backup, manifest) = try await Self.creativeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.launchPhotoshop("Adobe Photoshop 2026")
        let session = await Self.restore(manifest, backup: backup, on: target)
        let home = fresh.url.appendingPathComponent("home/Library")
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }
        // Presets and the panel files work in later versions: they go to Photoshop 2026, with a note.
        let brushes = try #require(manifest.applicationData.first { $0.profile?.provider == "adobe-photoshop" && $0.profile?.category == "brushes" })
        #expect(session.results["appdata:\(brushes.id)"]?.notes.contains(.restoredIntoVersion(original: "Adobe Photoshop 2025", target: "Adobe Photoshop 2026")) == true)
        #expect(exists("Application Support/Adobe/Adobe Photoshop 2026/Presets/Brushes/Release Brushes.abr"))
        #expect(!exists("Application Support/Adobe/Adobe Photoshop 2025/Presets/Brushes/Release Brushes.abr"))
        #expect(exists("Preferences/Adobe Photoshop 2026 Settings/Brushes.psp"))
        // The Preferences dialog is only for the same version: it stays in the 2025 folder and the user is told.
        let preferences = try #require(Self.folder(manifest, "adobe-photoshop-settings", "generalPreferences"))
        #expect(session.results["appdata:\(preferences.id)"]?.notes.contains(.applicationVersionDiffers(original: "Adobe Photoshop 2025 Settings")) == true)
        #expect(exists("Preferences/Adobe Photoshop 2025 Settings/Adobe Photoshop 2025 Prefs.psp"))
        // Beta data only ever goes into the beta's folders, even though the release is installed.
        #expect(exists("Application Support/Adobe/Adobe Photoshop (Beta)/Presets/Actions/Beta Actions.atn"))
        #expect(exists("Preferences/Adobe Photoshop (Beta) Settings/Actions Palette.psp"))
        #expect(!exists("Application Support/Adobe/Adobe Photoshop 2026/Presets/Actions/Beta Actions.atn"))

        // The user can keep the original version instead.
        let (other, otherTarget) = try TestEnvironment.freshMac(sandbox, name: "other")
        try other.launchPhotoshop("Adobe Photoshop 2026")
        // The restore selection shows the choice.
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(otherTarget), backupRoot: backup, sessionStore: nil)
            .dryRun(plan: RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData])),
                    selection: RestoreSelection(components: [.applicationData]), checkPackages: false)
        let version = try #require(entries.first { $0.id == "appdata:\(brushes.id)" }?.appDataComparison?.version)
        #expect(version.chosen == "Adobe Photoshop 2026" && version.original == "Adobe Photoshop 2025" && !version.originalExists)
        #expect(version.alternatives == ["Adobe Photoshop 2026"])
        var selection = RestoreSelection(components: [.applicationData])
        selection.sourceChoices["appdata:\(brushes.id)"] = "Adobe Photoshop 2025"
        let kept = await Self.restore(manifest, backup: backup, on: otherTarget, selection: selection)
        #expect(kept.results["appdata:\(brushes.id)"]?.outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: other.url.appendingPathComponent(
            "home/Library/Application Support/Adobe/Adobe Photoshop 2025/Presets/Brushes/Release Brushes.abr").path))
    }

    @Test func resolveLUTsLeaveOutWhatResolveShipsAndWaitForResolve() async throws {
        let sandbox = try Sandbox("creative-resolve-luts")
        let (backup, manifest) = try await Self.creativeBackup(sandbox)
        let luts = try #require(Self.folder(manifest, "davinci-resolve-luts", "luts"))
        #expect(luts.effectiveScope == .sharedLibrary)
        #expect(luts.displayPath == "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT")
        #expect(Set(luts.files.map(\.relativePath)) == ["Custom Looks/Teal Orange.cube", "Custom Looks/Film/Print Emulation.cube"])
        #expect(luts.shippedFilesLeftOut == 3, "the LUTs in Resolve's installer receipt come back with Resolve")
        #expect(luts.profile?.appMustBeInstalled == true)

        // Resolve is not installed yet: the LUTs wait, and nothing is written.
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let first = await Self.restore(manifest, backup: backup, on: target)
        let id = "appdata:\(luts.id)"
        #expect(first.results[id]?.outcome == .skipped(.applicationNotInstalled(name: "DaVinci Resolve")))
        #expect(first.results[id]?.outcome.isOpen == true, "offered again when the restore continues")
        let lutFolder = fresh.url.appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT")
        #expect(!FileManager.default.fileExists(atPath: lutFolder.path))

        // After installing Resolve, continuing the restore puts the user's LUTs next to Resolve's own.
        try fresh.installResolve(version: "21.1.0")
        let second = await Self.restore(manifest, backup: backup, on: target, continuing: first)
        #expect(second.results[id]?.outcome == .succeeded)
        #expect(try String(contentsOf: lutFolder.appendingPathComponent("Custom Looks/Film/Print Emulation.cube"), encoding: .utf8).hasPrefix("LUT_3D_SIZE"))
        #expect(try String(contentsOf: lutFolder.appendingPathComponent("Invert Color.ilut"), encoding: .utf8) == "shipped Invert Color.ilut")
        let third = await Self.restore(manifest, backup: backup, on: target, continuing: nil)
        #expect(third.results[id]?.outcome == .alreadyPresent, "idempotent")

        // A LUT folder MacReplica may not write to is reported, not silently skipped.
        let (locked, lockedTarget) = try TestEnvironment.freshMac(sandbox, name: "locked")
        try locked.installResolve(version: "21.1.0")
        let lockedFolder = locked.url.appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.path) }
        let denied = await Self.restore(manifest, backup: backup, on: lockedTarget)
        #expect(denied.results[id]?.outcome.label == "failed(permissionDenied)")
    }

    @Test func resolvePreferencesKeepMachineStateBehindAndNeverGoToAnOlderResolve() async throws {
        let sandbox = try Sandbox("creative-resolve-prefs")
        let (backup, manifest) = try await Self.creativeBackup(sandbox)
        let keyboard = try #require(Self.folder(manifest, "davinci-resolve-preferences", "keyboardPresets"))
        #expect(keyboard.profile?.sourceAppVersion == "21.1.0")
        #expect(keyboard.profile?.classification == .safe)
        #expect(Self.folder(manifest, "davinci-resolve-preferences", "userPreferences")?.profile?.classification == .compatibilitySensitive)
        #expect(Self.folder(manifest, "davinci-resolve-fairlight", "fairlightPresets")?.files.map(\.relativePath) == ["EQ/Voice.preset"])
        #expect(Self.folder(manifest, "davinci-resolve", "fusionTemplates")?.files.map(\.relativePath).contains("Edit/Titles/Lower Third.setting") == true)
        let everything = BackupWriter.allFiles(in: backup)
        for never in ["config.dat", "dblist.conf", "recentprojects.conf", "DiskCache", "ResolveDebug.txt", ".license"] {
            #expect(!everything.contains { $0.contains(never) }, "\(never) is machine state, a database list, a cache or a log")
        }
        let id = "appdata:\(keyboard.id)"
        // An older Resolve on the new Mac: the step waits (the user can update Resolve and continue).
        let (older, olderTarget) = try TestEnvironment.freshMac(sandbox, name: "older")
        try older.installResolve(version: "20.3.2")
        let olderSession = await Self.restore(manifest, backup: backup, on: olderTarget)
        #expect(olderSession.results[id]?.outcome == .skipped(.applicationVersionOlder(name: "DaVinci Resolve", installed: "20.3.2", backup: "21.1.0")))
        #expect(!FileManager.default.fileExists(atPath: older.url.appendingPathComponent("home/Library/Preferences/Blackmagic Design/DaVinci Resolve/keyboard.preset.xml").path))
        // Not installed: waits as well.
        let (_, emptyTarget) = try TestEnvironment.freshMac(sandbox, name: "empty")
        #expect(await Self.restore(manifest, backup: backup, on: emptyTarget).results[id]?.outcome == .skipped(.applicationNotInstalled(name: "DaVinci Resolve")))
        // The same or a newer Resolve: restored.
        let (newer, newerTarget) = try TestEnvironment.freshMac(sandbox, name: "newer")
        try newer.installResolve(version: "21.2.0")
        #expect(await Self.restore(manifest, backup: backup, on: newerTarget).results[id]?.outcome == .succeeded)
    }

    @Test func filesThatDifferFollowTheUsersDecision() async throws {
        let sandbox = try Sandbox("creative-conflict")
        let (backup, manifest) = try await Self.creativeBackup(sandbox)
        let keyboard = try #require(Self.folder(manifest, "davinci-resolve-preferences", "keyboardPresets"))
        let id = "appdata:\(keyboard.id)"
        func prepare(_ name: String) throws -> (SimulationRoot, SimulationEnvironment, URL) {
            let (root, target) = try TestEnvironment.freshMac(sandbox, name: name)
            try root.installResolve(version: "21.1.0")
            let file = root.url.appendingPathComponent("home/Library/Preferences/Blackmagic Design/DaVinci Resolve/keyboard.preset.xml")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("this Mac's presets".utf8).write(to: file)
            return (root, target, file)
        }
        // Before the restore: the conflict and the file that differs are shown.
        let (_, keepTarget, keepFile) = try prepare("keep")
        let selection = RestoreSelection(components: [.applicationData])
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(keepTarget), backupRoot: backup, sessionStore: nil)
            .dryRun(plan: RestorePlanner().plan(manifest: manifest, selection: selection), selection: selection, checkPackages: false)
        let entry = try #require(entries.first { $0.id == id })
        #expect(entry.prediction == .conflict(resolution: .keepExisting))
        #expect(entry.appDataComparison?.differentFiles.map(\.path) == ["keyboard.preset.xml"])
        #expect(entry.appDataComparison?.differentFiles.first?.existingSize == Int64("this Mac's presets".utf8.count))
        // Default: this Mac's file stays.
        let kept = await Self.restore(manifest, backup: backup, on: keepTarget)
        #expect(kept.results[id]?.notes.contains(.applicationDataCopied(copied: 0, identical: 0, kept: 1)) == true)
        #expect(try String(contentsOf: keepFile, encoding: .utf8) == "this Mac's presets")
        // Replace: the backup copy is restored and this Mac's file is kept aside.
        let (replaceRoot, replaceTarget, replaceFile) = try prepare("replace")
        var replace = selection
        replace.conflictOverrides[id] = .replace
        let replaced = await Self.restore(manifest, backup: backup, on: replaceTarget, selection: replace)
        #expect(replaced.results[id]?.outcome == .succeeded)
        #expect(try String(contentsOf: replaceFile, encoding: .utf8).contains("SmKeyboardPresetList"))
        let aside = replaceRoot.url.appendingPathComponent("home/Library/Application Support/MacReplica/Replaced Files/\(replaced.id)/application-data/\(keyboard.id)/keyboard.preset.xml")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "this Mac's presets")
        // Skip: nothing happens.
        let (_, skipTarget, skipFile) = try prepare("skip")
        var skip = selection
        skip.conflictOverrides[id] = .skip
        #expect(await Self.restore(manifest, backup: backup, on: skipTarget, selection: skip).results[id]?.outcome == .skipped(.userSkipped))
        #expect(try String(contentsOf: skipFile, encoding: .utf8) == "this Mac's presets")
    }

    @Test func sharedLocationsAreLimitedToAppFoldersAndOlderBackupsStillRead() throws {
        let sandbox = try Sandbox("creative-shared")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let scanner = AppDataScanner(layout: simulation.layout)
        let library = root.url.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Application Support/Vendor/App"), withIntermediateDirectories: true)
        #expect(throws: AppDataError.notAProviderLocation) { try scanner.validateShared(library.appendingPathComponent("Application Support")) }
        #expect(throws: AppDataError.notAProviderLocation) { try scanner.validateShared(library.appendingPathComponent("Application Support/Vendor")) }
        #expect(throws: AppDataError.notAProviderLocation) { try scanner.validateShared(library.appendingPathComponent("Fonts")) }
        #expect(try scanner.validateShared(library.appendingPathComponent("Application Support/Vendor/App")) == "Application Support/Vendor/App")
        // Receipt paths are relative to "/" (or the simulation root standing in for it).
        let paths = InventoryService.receiptPaths("Library/X/LUT\nLibrary/X/LUT/a.cube\nLibrary/X/LUT/sub/b.cube\nLibrary/Y/c.cube\n",
                                                  below: root.url.appendingPathComponent("Library/X/LUT"), root: root.url)
        #expect(paths == ["a.cube", "sub/b.cube"])
        // A folder from a backup made before scopes existed is in the home folder.
        let old = #"{"id":"appdata-1","name":"Old","relativePath":"Library/Application Support/Old","files":[],"profile":{"provider":"p","appName":"A","category":"c"}}"#
        let decoded = try JSONDecoder().decode(AppDataFolder.self, from: Data(old.utf8))
        #expect(decoded.effectiveScope == .home && decoded.displayPath == "~/Library/Application Support/Old")
        #expect(decoded.profile?.movesBetweenVersions == false && decoded.profile?.notForOlderApp == false)
    }
}
