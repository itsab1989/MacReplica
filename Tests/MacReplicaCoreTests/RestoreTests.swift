import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Records privileged operations. It can grant them (performing them after
/// making the sandboxed "system" folder writable, as root would) or deny them.
final class RecordingPrivileged: PrivilegedExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(operations: [PrivilegedOperation], reason: String)] = []
    let grant: Bool
    let unlock: [URL]

    init(grant: Bool, unlock: [URL] = []) {
        self.grant = grant
        self.unlock = unlock
    }

    var calls: [(operations: [PrivilegedOperation], reason: String)] { lock.withLock { _calls } }

    func run(_ operations: [PrivilegedOperation], reason: String) async throws {
        lock.withLock { _calls.append((operations, reason)) }
        guard grant else { throw PrivilegedError.denied }
        for folder in unlock { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try await DirectPrivilegedExecutor().run(operations, reason: reason)
        for folder in unlock { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
    }
}

@Suite("Restore planning")
struct RestorePlannerTests {
    let manifest = ManifestTests.sample()

    @Test func prerequisitesComeFirstAndEverythingDependsOnThem() {
        var selection = RestoreSelection()
        selection.enabledTaps = ["example/tools"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let ids = plan.items.map(\.id)
        #expect(Array(ids.prefix(2)) == [RestoreItem.commandLineToolsID, RestoreItem.homebrewID])
        #expect(ids.contains(RestoreItem.masToolID))
        #expect(ids.firstIndex(of: RestoreItem.masToolID)! < ids.firstIndex(of: "mas:42")!)
        #expect(plan.item(id: "mas:42")?.dependsOn == [RestoreItem.masToolID])
        #expect(plan.item(id: "formula:git")?.dependsOn == [RestoreItem.homebrewID])
        #expect(plan.item(id: RestoreItem.homebrewID)?.dependsOn == [RestoreItem.commandLineToolsID])
        #expect(ids.last == "icc:system/P.icc")
        // Unused taps are not added.
        #expect(!ids.contains("tap:example/tools"))
    }

    @Test func caskAppsAreDeduplicatedAndManualAppsListed() {
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        #expect(plan.items.filter { $0.id == "cask:example-editor" }.count == 1)
        let cask = plan.item(id: "cask:example-editor")
        #expect(cask?.title == "Example Editor")
        #expect(cask?.bundleIdentifier == "com.example.editor")
        #expect(cask?.appBundleNames == ["Example Editor.app"])
        #expect(plan.manualApps.map(\.name) == ["Tool"])
    }

    @Test func componentsAndExclusionsAreRespected() {
        let fontsOnly = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.fonts]))
        #expect(fontsOnly.items.map(\.id) == ["font:user/A.otf"], "no Homebrew prerequisites when nothing needs Homebrew")
        #expect(fontsOnly.manualApps.isEmpty)
        var selection = RestoreSelection()
        selection.excludedItemIDs = ["formula:git", "cask:example-editor", "mas:42", "font:user/A.otf", "manual:~/Applications/Tool.app"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(plan.items.map(\.id) == ["icc:system/P.icc"])
        #expect(plan.manualApps.isEmpty)
        // Candidate items ignore exclusions so they can be ticked again.
        #expect(RestorePlanner().candidateItems(manifest: manifest, selection: selection).contains { $0.id == "formula:git" })
        #expect(!RestorePlanner().candidateItems(manifest: manifest, selection: selection).contains { $0.kind == .homebrew })
    }

    @Test func matchDecisionsChangeTheMethod() {
        var selection = RestoreSelection(components: [.applications])
        selection.matchDecisions = ["~/Applications/Tool.app": "tool"]
        let chosen = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(chosen.item(id: "cask:tool")?.component == .applications)
        #expect(chosen.manualApps.isEmpty)
        selection.matchDecisions = ["~/Applications/Tool.app": ""]
        let none = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(none.item(id: "cask:tool") == nil)
        #expect(none.manualApps.map(\.name) == ["Tool"])
    }

    @Test func thirdPartyTapsAreAddedForPackagesThatNeedThem() {
        var manifest = self.manifest
        manifest.brewFormulae.append(BrewFormulaRecord(name: "example/tools/tool", version: "1", tap: "example/tools"))
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        let tap = plan.item(id: "tap:example/tools")
        #expect(tap?.tapRemote == "https://github.com/example/homebrew-tools")
        #expect(plan.item(id: "formula:example/tools/tool")?.dependsOn == [RestoreItem.homebrewID, "tap:example/tools"])
    }

    @Test func masFormulaReplacesTheHelperStep() {
        var manifest = self.manifest
        manifest.brewFormulae.append(BrewFormulaRecord(name: "mas", version: "1.8"))
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        #expect(plan.item(id: RestoreItem.masToolID) == nil)
        #expect(plan.item(id: "mas:42")?.dependsOn == ["formula:mas"])
        let ids = plan.items.map(\.id)
        #expect(ids.firstIndex(of: "formula:mas")! < ids.firstIndex(of: "mas:42")!)
    }

    @Test func retrySubsetIncludesPrerequisites() {
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        let subset = plan.subset(retrying: ["mas:42"])
        #expect(subset.items.map(\.id) == [RestoreItem.commandLineToolsID, RestoreItem.homebrewID, RestoreItem.masToolID, "mas:42"])
        #expect(subset.manualApps == plan.manualApps)
        #expect(plan.subset(retrying: ["font:user/A.otf"]).items.map(\.id) == ["font:user/A.otf"])
    }

    @Test func conflictResolutionOverrides() {
        var selection = RestoreSelection(conflictResolution: .skip)
        selection.conflictOverrides = ["font:user/A.otf": .replace]
        #expect(selection.resolution(for: "font:user/A.otf") == .replace)
        #expect(selection.resolution(for: "other") == .skip)
    }
}

@Suite("Restore execution", .serialized)
struct RestoreExecutionTests {
    func run(_ executor: RestoreExecutor, _ plan: RestorePlan, _ selection: RestoreSelection = RestoreSelection(),
             store: SessionStore? = nil) async -> RestoreSession {
        await executor.run(plan: plan, session: RestoreSession(backupPath: "~/b", selection: selection, itemIDs: plan.items.map(\.id)),
                           onEvent: { _ in })
    }

    @Test(arguments: [ConflictResolution.keepExisting, .replace, .skip])
    func conflictsFollowTheUsersChoice(_ resolution: ConflictResolution) async throws {
        let sandbox = try Sandbox("conflicts-\(resolution.rawValue)")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.fonts], conflictResolution: resolution)
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        let session = await run(executor, plan, selection)
        let serif = fresh.url.appendingPathComponent("home/Library/Fonts/ExampleSerif.ttf")
        let result = try #require(session.results["font:user/ExampleSerif.ttf"])
        let installedVersion = { FileScanner.fontIdentity(serif)?.shortVersion }
        switch resolution {
        case .keepExisting:
            #expect(result.outcome == .skipped(.keptExisting))
            #expect(installedVersion() == "1.000")
        case .skip:
            #expect(result.outcome == .skipped(.userSkipped))
            #expect(installedVersion() == "1.000")
        case .replace:
            #expect(result.outcome == .succeeded)
            #expect(installedVersion() == "2.000")
            let aside = target.layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/fonts/user/ExampleSerif.ttf")
            #expect(FileScanner.fontIdentity(aside)?.shortVersion == "1.000", "the old file is kept, never deleted")
            #expect(result.notes == [.existingFileMovedAside(path: target.layout.displayPath(aside))])
        case .keepBoth:
            Issue.record("not offered for a different font version")
        }
        #expect(session.results["font:user/Example Sans/ExampleSans-Regular.otf"]?.outcome == .alreadyPresent)
        #expect(session.results["font:user/Example Sans/ExampleSans-Regular.otf"]?.notes == [.identicalFileExists])
    }

    @Test func damagedBackupFilesAreNotRestored() async throws {
        let sandbox = try Sandbox("damaged")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        try Data("tampered".utf8).write(to: backup.appendingPathComponent("fonts/user/Example Sans/ExampleSans-Bold.otf"))
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.fonts]))
        // Without prior verification the executor checks the hash itself.
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        let session = await run(executor, plan)
        #expect(session.results["font:user/Example Sans/ExampleSans-Bold.otf"]?.outcome.label == "failed(backupFileDamaged)")
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/Library/Fonts/Example Sans/ExampleSans-Bold.otf").path))
        #expect(session.results["font:system/ExampleMono.ttc"]?.outcome == .succeeded, "other files still restore")
        // With verification results, damaged files are skipped up front.
        let report = BackupVerifier(layout: target.layout).verify(backupAt: backup)
        let verified = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil,
                                       damagedFiles: report.damagedFiles)
        let entries = await verified.dryRun(plan: plan, selection: RestoreSelection())
        #expect(entries.first { $0.item.id == "font:user/Example Sans/ExampleSans-Bold.otf" }?.prediction == .backupFileDamaged)
    }

    @Test func sharedFoldersUseOneAdministratorRequest() async throws {
        let sandbox = try Sandbox("privileged")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let systemFonts = fresh.url.appendingPathComponent("Library/Fonts")
        let systemProfiles = fresh.url.appendingPathComponent("Library/ColorSync/Profiles")
        for folder in [systemFonts, systemProfiles] { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in [systemFonts, systemProfiles] { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }

        let privileged = RecordingPrivileged(grant: true, unlock: [systemFonts, systemProfiles])
        let selection = RestoreSelection(components: [.fonts, .colorProfiles])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, privileged: privileged), backupRoot: backup, sessionStore: nil)
        let dry = await executor.dryRun(plan: plan, selection: selection)
        #expect(dry.first { $0.item.id == "font:system/ExampleMono.ttc" }?.requiresAdmin == true)
        #expect(dry.first { $0.item.id == "font:user/Example Sans/ExampleSans-Bold.otf" }?.requiresAdmin == false)

        let session = await run(executor, plan, selection)
        #expect(privileged.calls.count == 1, "one password prompt for all shared files")
        let operations = try #require(privileged.calls.first).operations
        #expect(operations.count == 2)
        #expect(privileged.calls.first?.reason.contains("1") == true)
        #expect(session.results["font:system/ExampleMono.ttc"]?.outcome == .succeeded)
        #expect(session.results["icc:system/Example Legacy Filter.icc"]?.outcome == .succeeded)
        // Already present elsewhere on this Mac: no administrator operation for it.
        #expect(session.results["icc:system/Example Press Proof.icc"]?.outcome == .alreadyPresent)
        #expect(session.results["font:user/Example Sans/ExampleSans-Bold.otf"]?.outcome == .succeeded)
    }

    @Test func deniedAdministratorRightsFailOnlyTheAffectedItems() async throws {
        let sandbox = try Sandbox("privileged-denied")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let systemFonts = fresh.url.appendingPathComponent("Library/Fonts")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: systemFonts.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemFonts.path) }
        let privileged = RecordingPrivileged(grant: false)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.fonts, .colorProfiles]))
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, privileged: privileged), backupRoot: backup, sessionStore: nil)
        let session = await run(executor, plan)
        #expect(session.results["font:system/ExampleMono.ttc"]?.outcome.label == "failed(adminRightsDenied)")
        #expect(session.results["icc:system/Example Legacy Filter.icc"]?.outcome == .succeeded)
        #expect(session.status == .completed)
    }

    @Test func failedDependencySkipsDependents() async throws {
        let sandbox = try Sandbox("dependency")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.setFlag("clt-never", true)
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.commandLineToolsTimeout = 0.5
        let selection = RestoreSelection(components: [.brewFormulae, .fonts])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await run(RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil), plan, selection)
        #expect(session.results[RestoreItem.commandLineToolsID]?.outcome.label == "failed(commandLineToolsUnavailable)")
        #expect(session.results[RestoreItem.homebrewID]?.outcome == .skipped(.dependencyFailed(itemTitle: "Xcode Command Line Tools")))
        #expect(session.results["formula:git"]?.outcome == .skipped(.dependencyFailed(itemTitle: "Homebrew")))
        #expect(session.results["font:system/ExampleMono.ttc"]?.outcome == .succeeded, "independent items continue")
    }

    @Test func intelMacsSkipAppleSiliconOnlyAppsAndAppleSiliconNotesRosetta() async throws {
        let sandbox = try Sandbox("architecture")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        var selection = RestoreSelection(components: [.applications])
        let orbit = try #require(manifest.applications.first { $0.name == "Orbit Browser" })
        selection.matchDecisions = [orbit.path: "orbit-browser"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let intel = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, architecture: .x86_64), backupRoot: backup, sessionStore: nil)
        let session = await run(intel, plan, selection)
        #expect(session.results["cask:terminal-plus"]?.outcome == .skipped(.incompatibleArchitecture(required: [.arm64])))
        #expect(session.results["cask:pixel-forge"]?.outcome == .succeeded)

        var appleManifest = manifest
        appleManifest.applications = manifest.applications.map { app in
            var app = app
            if app.name == "Pixel Forge" { app.architectures = [.x86_64] }
            return app
        }
        let sandbox2 = try Sandbox("architecture-arm")
        let (_, target2) = try TestEnvironment.freshMac(sandbox2)
        let armPlan = RestorePlanner().plan(manifest: appleManifest, selection: RestoreSelection(components: [.applications]))
        let arm = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target2, architecture: .arm64), backupRoot: backup, sessionStore: nil)
        let dry = await arm.dryRun(plan: armPlan, selection: RestoreSelection())
        #expect(dry.first { $0.item.id == "cask:pixel-forge" }?.notes == [.requiresRosetta])
        let armSession = await run(arm, armPlan)
        #expect(armSession.results["cask:pixel-forge"]?.notes.contains(.requiresRosetta) == true)
    }

    @Test func installReportedAsSuccessButMissingIsAFailure() async throws {
        let sandbox = try Sandbox("verify-install")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        // The cask "installs" without creating the app bundle.
        try fresh.setFlag("brew/available/casks/pixel-forge.json", true, content: #"{"version": "2.4.1", "app": "", "bundle_id": ""}"#)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applications]))
        let session = await run(RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil), plan)
        #expect(session.results["cask:pixel-forge"]?.outcome.label == "failed(verificationFailed)")
    }

    @Test func appInstalledOutsideHomebrewCountsAsPresent() async throws {
        let sandbox = try Sandbox("present-app")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let app = fresh.url.appendingPathComponent("Applications/Pixel Forge.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.pixelforge", "CFBundleShortVersionString": "9.0"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applications]))
        let session = await run(RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil), plan)
        #expect(session.results["cask:pixel-forge"]?.outcome == .alreadyPresent)
        #expect(session.results["cask:pixel-forge"]?.installedVersion == "9.0")
        #expect(!fresh.calls().contains("brew install --cask pixel-forge"))
    }

    @Test func eventsDescribeEveryStep() async throws {
        let sandbox = try Sandbox("events")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.brewFormulae]))
        let recorder = EventRecorder()
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        _ = await executor.run(plan: plan, session: RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: plan.items.map(\.id)),
                               onEvent: recorder.record)
        #expect(recorder.startedIDs == plan.items.map(\.id))
        let activities = recorder.activities
        #expect(activities.contains { $0.0 == RestoreItem.commandLineToolsID && $0.1 == .waitingForCommandLineTools })
        #expect(activities.contains { $0.0 == RestoreItem.homebrewID && $0.1 == .downloading })
        #expect(activities.contains { $0.0 == "formula:git" && $0.1 == .installing })
        #expect(activities.contains { $0.0 == "formula:git" && $0.1 == .verifying })
        // The third-party tap was not allowed, so it and its formula are skipped; nothing fails.
        #expect(recorder.summary?.failed == 0)
        #expect(recorder.summary?.skipped == 2)
        #expect(recorder.summary?.succeeded == plan.items.count - 2)
    }
}

@Suite("Dry run", .serialized)
struct DryRunTests {
    @Test func dryRunChangesNothingAndRunsOnlyReadCommands() async throws {
        let sandbox = try Sandbox("dryrun")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let before = try snapshot(fresh.url)
        var selection = RestoreSelection()
        selection.enabledTaps = ["example/tools"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let privileged = RecordingPrivileged(grant: true)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, privileged: privileged), backupRoot: backup, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: selection)

        #expect(entries.count == plan.items.count)
        #expect(privileged.calls.isEmpty)
        let calls = fresh.calls()
        #expect(!calls.contains { $0.contains("install") || $0.hasPrefix("brew tap ") })
        var after = try snapshot(fresh.url)
        after["state/calls.log"] = nil
        #expect(after == before, "no file in the simulated Mac changed")

        func prediction(_ id: String) -> Prediction? { entries.first { $0.item.id == id }?.prediction }
        #expect(prediction(RestoreItem.commandLineToolsID) == .willInstall)
        #expect(prediction(RestoreItem.homebrewID) == .willInstall)
        #expect(entries.first { $0.item.id == RestoreItem.homebrewID }?.requiresAdmin == true)
        #expect(prediction("formula:git") == .dependsOnEarlierStep)
        #expect(prediction("font:user/ExampleSerif.ttf") == .conflict(resolution: .keepExisting))
        #expect(prediction("font:user/Example Sans/ExampleSans-Regular.otf") == .identicalFileExists)
        #expect(prediction("font:user/Example Sans/ExampleSans-Bold.otf") == .willCopy)
        #expect(prediction("mas:1234567890") == .willInstall)
    }

    @Test func dryRunOnAPreparedMacReportsWhatIsPresent() async throws {
        let sandbox = try Sandbox("dryrun-present")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        // Restoring onto the source Mac itself: everything is already there.
        let sourceSandbox = try Sandbox("dryrun-source")
        let (_, source) = try TestEnvironment.sourceMac(sourceSandbox)
        let selection = RestoreSelection()
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(source), backupRoot: backup, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: selection)
        // The sanitized Git configuration differs from the original, so it shows up as a conflict there.
        #expect(entries.first { $0.item.id == "git:config" }?.prediction == .conflict(resolution: .keepExisting))
        for entry in entries where entry.item.kind != .tap && entry.item.kind != .gitConfiguration {
            switch entry.prediction {
            case .alreadyPresent, .identicalFileExists: break
            default: Issue.record("\(entry.item.id): \(entry.prediction)")
            }
        }
        #expect(entries.first { $0.item.id == "tap:example/tools" }?.prediction == .willSkip(.tapNotEnabled(tap: "example/tools")))
        #expect(entries.first { $0.item.id == "formula:example-tool" }?.prediction == .alreadyPresent(version: "0.9.0"))
    }

    @Test func blockedPrerequisitesPropagateInTheDryRun() async throws {
        let sandbox = try Sandbox("dryrun-blocked")
        var manifest = ManifestTests.sample()
        manifest.brewFormulae = [BrewFormulaRecord(name: "example/tools/tool", version: "1", tap: "example/tools")]
        let (_, target) = try TestEnvironment.sourceMac(sandbox)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.brewFormulae]))
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: RestoreSelection())
        #expect(entries.first { $0.item.id == "formula:example/tools/tool" }?.prediction == .willSkip(.dependencyFailed(itemTitle: "example/tools")))
    }

    func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            result[relative] = try Hashing.sha256Hex(ofFile: url)
        }
        return result
    }
}

@Suite("Resume", .serialized)
struct ResumeTests {
    @Test func interruptedRestoreResumesWhereItStopped() async throws {
        let sandbox = try Sandbox("resume")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.setDelay(0.4)
        let store = SessionStore(folder: target.layout.applicationSupport.appendingPathComponent("Sessions"), homeDirectory: target.layout.homeDirectory)
        let selection = RestoreSelection(components: [.brewFormulae, .fonts])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: store)
        let initial = RestoreSession(backupPath: backup.path, selection: selection, itemIDs: plan.items.map(\.id))

        let recorder = EventRecorder()
        let task = Task { await executor.run(plan: plan, session: initial, onEvent: recorder.record) }
        // Stop as soon as the first formula started installing.
        while !recorder.activities.contains(where: { $0.0.hasPrefix("formula:") && $0.1 == .installing }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        let stopped = await task.value
        #expect(stopped.status == .inProgress)
        #expect(stopped.results[RestoreItem.homebrewID]?.outcome == .succeeded)
        #expect(!stopped.remainingItemIDs.isEmpty)

        // What a relaunch sees:
        let unfinished = try #require(store.unfinishedSession())
        #expect(unfinished.id == initial.id)
        #expect(unfinished.results == stopped.results)

        fresh.clearCalls()
        let resumed = await executor.run(plan: plan, session: unfinished, onEvent: { _ in })
        #expect(resumed.status == .completed)
        #expect(resumed.remainingItemIDs.isEmpty)
        #expect(store.unfinishedSession() == nil)
        // Finished steps were not repeated.
        let finishedFormulae = stopped.results.keys.filter { $0.hasPrefix("formula:") }.map { String($0.dropFirst("formula:".count)) }
        for name in finishedFormulae {
            #expect(!fresh.calls().contains("brew install --formula \(name)"))
        }
        #expect(resumed.results[RestoreItem.homebrewID] == stopped.results[RestoreItem.homebrewID])
        #expect(!resumed.results.values.contains { $0.outcome.isFailure })
    }

    @Test func sessionIsSavedAfterEveryStep() async throws {
        let sandbox = try Sandbox("resume-save")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let store = SessionStore(folder: target.layout.applicationSupport.appendingPathComponent("Sessions"), homeDirectory: target.layout.homeDirectory)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.fonts]))
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: store)
        let session = RestoreSession(backupPath: backup.path, selection: RestoreSelection(components: [.fonts]), itemIDs: plan.items.map(\.id))
        final class Counts: @unchecked Sendable { var saved: [Int] = []; let lock = NSLock() }
        let counts = Counts()
        _ = await executor.run(plan: plan, session: session) { event in
            if case .finished = event { counts.lock.withLock { counts.saved.append(store.load(id: session.id)?.results.count ?? -1) } }
        }
        #expect(counts.saved == Array(1...plan.items.count))
        #expect(store.load(id: session.id)?.status == .completed)
    }

    @Test func corruptOrForeignSessionFilesAreIgnored() throws {
        let sandbox = try Sandbox("resume-corrupt")
        let folder = try sandbox.folder("Sessions")
        let store = SessionStore(folder: folder, homeDirectory: sandbox.url)
        let broken = try sandbox.folder("Sessions/broken")
        try OwnershipMarker(kind: .session).write(into: broken)
        try Data("{".utf8).write(to: broken.appendingPathComponent("session.json"))
        _ = try sandbox.folder("Sessions/foreign")
        #expect(store.unfinishedSession() == nil)
        var done = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: [])
        done.status = .completed
        try store.save(done)
        #expect(store.unfinishedSession() == nil)
        let open = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: ["x"])
        try store.save(open)
        #expect(store.unfinishedSession()?.id == open.id)
    }

    @Test func oldCompletedSessionsArePruned() throws {
        let sandbox = try Sandbox("resume-prune")
        let store = SessionStore(folder: try sandbox.folder("Sessions"), homeDirectory: sandbox.url)
        for index in 0..<7 {
            var session = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: [], createdAt: Date(timeIntervalSince1970: Double(index)))
            session.status = .completed
            session.updatedAt = Date(timeIntervalSince1970: Double(index))
            try store.save(session)
        }
        let open = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: ["x"])
        try store.save(open)
        store.pruneCompleted(keep: 3)
        #expect(store.allSessions().filter { $0.status == .completed }.count == 3)
        #expect(store.load(id: open.id) != nil)
    }
}
