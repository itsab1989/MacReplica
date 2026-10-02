import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Full flows against sandboxed simulation roots, using the real process runner,
/// the real parsers and real file operations.
@Suite("End-to-end", .serialized)
struct EndToEndTests {
    @Test("Inventory of the synthetic Mac finds apps, Homebrew, App Store, fonts and profiles")
    func inventoryFindsEverything() async throws {
        let sandbox = try Sandbox("e2e-inventory")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let manifest = result.manifest

        #expect(result.warnings.isEmpty)
        #expect(manifest.applications.count == 7)
        func app(_ name: String) throws -> AppRecord { try #require(manifest.applications.first { $0.name == name }) }

        #expect(try app("Nimbus Notes").source == .homebrewCask(token: "nimbus-notes"))
        #expect(try app("Nimbus Notes").restoreMethod == .homebrewCask(token: "nimbus-notes"))
        #expect(try app("Pixel Forge").restoreMethod == .homebrewCask(token: "pixel-forge"))
        #expect(try app("Terminal Plus").restoreMethod == .homebrewCask(token: "terminal-plus"))
        #expect(try app("Orbit Browser").needsMatchDecision)
        #expect(try app("Orbit Browser").candidates.map(\.token).sorted() == ["orbit-browser", "orbit-browser@esr"])
        #expect(try app("Ledger Lite").restoreMethod == .appStore(id: 1_234_567_890))
        #expect(try app("Quill Writer").restoreMethod == .officialDownload(url: "https://quill.example.com/"))
        #expect(try app("Studio Mixer").restoreMethod == .manual)
        #expect(try app("Studio Mixer").architectures == [.x86_64])
        #expect(try app("Pixel Forge").vendor == "Forgeworks Inc.")
        #expect(try app("Pixel Forge").architectures == [.arm64, .x86_64])

        #expect(manifest.brewFormulae.count == 7)
        #expect(manifest.brewFormulae.first { $0.name == "python@3.12" }?.installedOnRequest == false)
        #expect(manifest.brewFormulae.first { $0.name == "openssl@3" }?.installedOnRequest == false)
        #expect(manifest.brewCasks.map(\.token) == ["font-example-mono", "nimbus-notes"])
        #expect(manifest.brewTaps == [BrewTapRecord(name: "example/tools", remote: "https://github.com/example/homebrew-tools")])
        #expect(manifest.homebrew?.version == "4.4.0")
        #expect(manifest.masApps.map(\.appStoreID) == [1_234_567_890])
        #expect(manifest.fonts.count == 4)
        #expect(manifest.iccProfiles.count == 3)
        #expect(manifest.iccProfiles.first { $0.fileName == "Example Studio Display.icc" }?.metadata["description"] == "Example Studio Display D65")

        // No absolute home paths in the manifest.
        let json = String(decoding: try ManifestIO.encode(manifest), as: UTF8.self)
        #expect(!json.contains(source.layout.homeDirectory.path))
        #expect(json.contains("~/Library/Fonts/ExampleSerif.ttf"))
    }

    @Test("Backup, verification, restore onto a fresh Mac and a second idempotent restore")
    func fullRestoreFlow() async throws {
        let sandbox = try Sandbox("e2e-restore")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let report = BackupVerifier(layout: try TestEnvironment.sourceMac(Sandbox("unused")).1.layout).verify(backupAt: backup)
        #expect(report.isIntact)
        // 7 fonts/profiles + 2 Python project files + 3 detected app-data files
        // + requirements, reports, instructions and README.
        #expect(report.checkedFiles == 18)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("reports/inventory.html").path))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("reports/manual_installations.html").path))

        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        var selection = RestoreSelection()
        selection.enabledTaps = ["example/tools"]
        let orbit = try #require(manifest.applications.first { $0.name == "Orbit Browser" })
        selection.matchDecisions = [orbit.path: "orbit-browser"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(plan.items.first?.kind == .commandLineTools)
        #expect(plan.manualApps.map(\.name) == ["Quill Writer", "Studio Mixer"])

        let store = SessionStore(folder: target.layout.applicationSupport.appendingPathComponent("Sessions"), homeDirectory: target.layout.homeDirectory)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: store)
        let recorder = EventRecorder()
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: backup.path, selection: selection,
                                                                             itemIDs: plan.items.map(\.id)),
                                         onEvent: recorder.record)
        let outcomes = Dictionary(uniqueKeysWithValues: session.results.map { ($0.key, $0.value.outcome.label) })

        #expect(outcomes[RestoreItem.commandLineToolsID] == "succeeded")
        #expect(outcomes[RestoreItem.homebrewID] == "succeeded")
        #expect(outcomes["tap:example/tools"] == "succeeded")
        // The backed-up "mas" formula doubles as the App Store helper.
        #expect(outcomes[RestoreItem.masToolID] == nil)
        #expect(outcomes["formula:mas"] == "succeeded")
        #expect(outcomes["formula:git"] == "succeeded")
        #expect(outcomes["formula:example-tool"] == "succeeded")
        #expect(outcomes["formula:openssl@3"] == nil)
        #expect(outcomes["cask:nimbus-notes"] == "succeeded")
        #expect(outcomes["cask:pixel-forge"] == "succeeded")
        #expect(outcomes["cask:orbit-browser"] == "succeeded")
        #expect(outcomes["mas:1234567890"] == "succeeded")
        #expect(outcomes["font:user/ExampleSerif.ttf"] == "skipped(keptExisting)")
        #expect(outcomes["font:user/Example Sans/ExampleSans-Regular.otf"] == "alreadyPresent")
        #expect(outcomes["font:user/Example Sans/ExampleSans-Bold.otf"] == "succeeded")
        #expect(outcomes["font:system/ExampleMono.ttc"] == "succeeded")
        #expect(outcomes["icc:user/Example Studio Display.icc"] == "succeeded")
        #expect(session.status == .completed)
        #expect(recorder.summary?.failed == 0)

        // A newer cask version is reported transparently.
        #expect(session.results["cask:pixel-forge"]?.notes == [.newerVersionInstalled(original: "2.4.0", installed: "2.4.1")])
        // Installed apps really exist.
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("Applications/Pixel Forge.app/Contents/Info.plist").path))
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("Applications/Ledger Lite.app").path))

        // Second run: everything is detected as already present, nothing is installed again.
        fresh.clearCalls()
        let second = await executor.run(plan: plan, session: RestoreSession(backupPath: backup.path, selection: selection,
                                                                            itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(second.results.values.allSatisfy { $0.outcome == .alreadyPresent || $0.outcome == .skipped(.keptExisting) })
        #expect(!fresh.calls().contains { $0.contains(" install ") || $0.hasPrefix("brew install") || $0.hasPrefix("mas install") })
    }
}
