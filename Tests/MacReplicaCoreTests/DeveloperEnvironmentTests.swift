import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// End-to-end: a developer Mac is scanned and backed up, then restored onto a fresh simulated Mac.
@Suite("Developer environments end to end", .serialized)
struct DeveloperEnvironmentTests {
    struct Context {
        let sandbox: Sandbox
        let source: SimulationRoot
        let fresh: SimulationRoot
        let target: SimulationEnvironment
        let backup: URL
        let manifest: Manifest
    }

    func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        let environment = try source.environment
        let inventory = try await TestEnvironment.inventory(environment).run()
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        let backup = outcome.url
        let manifest = try ManifestIO.read(from: backup)
        let fresh = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("fresh"), scenario: .freshMac)
        return Context(sandbox: sandbox, source: source, fresh: fresh, target: try fresh.environment, backup: backup, manifest: manifest)
    }

    func run(_ c: Context, _ plan: RestorePlan, _ session: RestoreSession) async -> RestoreSession {
        await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: session, onEvent: { _ in })
    }

    @Test func inventoryRecordsEveryEnvironmentWithoutSecretsAndTheAppChannel() async throws {
        let c = try await context("dev-inventory")
        let providers = Set(c.manifest.toolchains.map(\.provider))
        #expect(providers == [.nvm, .npm, .pyenv, .uv, .pipx, .conda, .rbenv, .gem, .rustup, .cargo, .go, .jdk, .dotnet, .macports, .nix, .pixi, .mise])
        let json = try String(contentsOf: c.backup.appendingPathComponent(ManifestIO.fileName), encoding: .utf8)
        #expect(!json.contains("never read by MacReplica"), "uv's credentials store is not read")
        #expect(!json.contains("sk-synthetic"), "no secrets from shell profiles")
        #expect(!json.contains(c.source.url.path), "no sandbox paths in the manifest")
        let nightly = try #require(c.manifest.applications.first { $0.name == "Orbit Browser Nightly" })
        #expect(nightly.channel == .nightly && nightly.channelEvidence == .bundleIdentifier)
        #expect(nightly.updateFeed == UpdateFeed(url: SimulationBuilder.nightlyFeed, publicEDKey: SimulationBuilder.vendorPublicKey))
        #expect(nightly.restoreMethod == .manual)
        let api = try #require(c.manifest.python.environments.first { $0.name == "api-service" })
        #expect(api.manager == .uv && api.baseSource == .pyenv && api.pythonVersion == "3.12.4")
        #expect(api.projectFiles.map(\.fileName).contains("uv.lock"))
        let instructions = try String(contentsOf: c.backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(instructions.contains("nvm install v20.11.1") && instructions.contains("sudo port -N install ffmpeg +gpl2"),
                "guided commands are in the restore instructions")
    }

    @Test func backupSelectionKeepsOnlyChosenManagers() async throws {
        let sandbox = try Sandbox("dev-selection")
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        var inventory = try await TestEnvironment.inventory(try source.environment).run()
        inventory.keepToolchains([.rustup, .cargo])
        inventory.excludeApplications(["org.example.orbit.nightly"])
        #expect(inventory.manifest.toolchains.map(\.provider) == [.rustup, .cargo])
        #expect(!inventory.manifest.applications.contains { $0.bundleIdentifier == "org.example.orbit.nightly" })
    }

    @Test func restoreInstallsManagersRuntimesAndToolsGuidesTheRestAndResumes() async throws {
        let c = try await context("dev-restore")
        let selection = RestoreSelection(components: [.developerTools, .packageManagers, .python])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let ids = plan.items.map(\.id)
        func position(_ id: String) -> Int { ids.firstIndex(of: id) ?? -1 }
        // Managers come from Homebrew before their steps; packages wait for their runtime.
        #expect(position("formula:uv") >= 0 && position("formula:uv") < position("toolchain:uv:runtime:3.13.1"))
        #expect(position("toolchain:rustup:runtime:stable") < position("toolchain:cargo:package:ripgrep"))
        #expect(plan.item(id: "toolchain:cargo:package:ripgrep")?.dependsOn.contains("toolchain:rustup:runtime:stable") == true)
        #expect(plan.item(id: "toolchain:npm:package:manager-v20.11.1/typescript")?.dependsOn == ["toolchain:nvm:runtime:v20.11.1"])
        #expect(plan.item(id: "cask:temurin@21")?.component == .developerTools, "the JDK comes back as the matching cask")
        #expect(plan.item(id: "cask:miniforge") != nil, "Conda comes back as the distribution that was installed")
        let api = try #require(plan.items.first { $0.pythonEnvironment?.name == "api-service" })
        #expect(api.dependsOn == ["toolchain:pyenv:runtime:3.12.4"], "the exact pyenv version, not Homebrew's Python")

        let dry = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .dryRun(plan: plan, selection: selection)
        func predicted(_ id: String) -> Prediction? { dry.first { $0.item.id == id }?.prediction }
        #expect(predicted("toolchain:nvm:runtime:v20.11.1") == .manualStep)
        #expect(predicted("toolchain:npm:package:manager-v20.11.1/typescript") == .dependsOnEarlierStep)
        #expect(predicted("toolchain:macports:manager") == .manualStep)

        let session = await run(c, plan, RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: ids))
        func outcome(_ id: String) -> String? { session.results[id]?.outcome.label }
        for id in ["formula:uv", "toolchain:uv:runtime:3.13.1", "toolchain:uv:package:ruff", "toolchain:pyenv:runtime:3.11.9",
                   "toolchain:pyenv:runtime:3.12.4", "toolchain:pipx:package:black", "cask:miniforge", "toolchain:conda:env:datasci",
                   "toolchain:rbenv:runtime:3.3.5", "toolchain:gem:package:manager-3.3.5/rails", "toolchain:rustup:runtime:stable",
                   "toolchain:cargo:package:ripgrep", "formula:go", "toolchain:go:package:golang.org/x/tools/gopls", "cask:temurin@21",
                   "toolchain:dotnet:package:dotnet-ef", "toolchain:pixi:env:search", "toolchain:mise:runtime:node@22", "toolchain:nix:package:hello"] {
            #expect(outcome(id) == "succeeded" || (id == "toolchain:nix:package:hello" && outcome(id) == "skipped(waitingForManualStep(itemTitle: \"Nix\"))"),
                    "\(id): \(outcome(id) ?? "missing")")
        }
        #expect(outcome("python:\(api.pythonEnvironment!.id)") == "succeeded")
        #expect(session.results["python:\(api.pythonEnvironment!.id)"]?.notes.contains(.pythonLockFileUsed(file: "uv.lock")) == true)
        // Steps MacReplica cannot do itself wait for the user instead of failing.
        #expect(outcome("toolchain:nvm:runtime:v20.11.1") == "skipped(manualStepRequired)")
        #expect(outcome("toolchain:npm:package:manager-v20.11.1/typescript")?.hasPrefix("skipped(waitingForManualStep") == true)
        #expect(outcome("toolchain:macports:manager") == "skipped(manualStepRequired)")
        #expect(outcome("toolchain:dotnet:runtime:8.0.404") == "skipped(manualStepRequired)")
        #expect(session.results.values.filter(\.outcome.isFailure).isEmpty, "\(session.results.filter { $0.value.outcome.isFailure })")
        #expect(session.status == .inProgress && session.onlyWaitingForUser)
        // Every command ran without a shell, through the simulated tools only.
        let calls = c.fresh.calls()
        #expect(calls.contains("uv tool install ruff==0.6.9"))
        #expect(calls.contains { $0.hasPrefix("cargo install --locked ripgrep --version 14.1.0") })
        #expect(calls.contains("go install golang.org/x/tools/gopls@v0.16.2"))
        #expect(!calls.contains { $0.hasPrefix("nvm") || $0.contains("sudo") })

        // The user installs Node.js with nvm as shown; continuing the session finishes the npm packages.
        let node = c.fresh.url.appendingPathComponent("home/.nvm/versions/node/v20.11.1/bin")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        try Data("node".utf8).write(to: node.appendingPathComponent("node"))
        try FileManager.default.copyItem(at: c.fresh.url.appendingPathComponent("tools/toolchain"), to: node.appendingPathComponent("npm"))
        let resumed = await run(c, plan, session)
        #expect(resumed.results["toolchain:nvm:runtime:v20.11.1"]?.outcome == .alreadyPresent)
        #expect(resumed.results["toolchain:npm:package:manager-v20.11.1/typescript"]?.outcome == .succeeded)
        #expect(resumed.results["toolchain:npm:package:manager-v20.11.1/@angular/cli"]?.outcome == .succeeded)
        #expect(resumed.results["formula:uv"] == session.results["formula:uv"], "finished steps are not repeated")

        // A second restore finds everything that was installed.
        c.fresh.clearCalls()
        let again = await run(c, plan, RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: ids))
        #expect(again.results["toolchain:cargo:package:ripgrep"]?.outcome == .alreadyPresent)
        #expect(again.results["toolchain:conda:env:datasci"]?.outcome == .alreadyPresent)
        let reinstalls = c.fresh.calls().filter { $0.contains(" install ") && !$0.hasPrefix("brew") }
        #expect(reinstalls.isEmpty, "\(reinstalls)")
    }

    @Test func toolchainFailuresAreReportedPerStepAndRetried() async throws {
        let c = try await context("dev-failure")
        try c.fresh.failOnce("cargo-ripgrep", message: "error: failed to compile `ripgrep v14.1.0`")
        let selection = RestoreSelection(components: [.developerTools])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let session = await run(c, plan, RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)))
        #expect(session.results["toolchain:cargo:package:ripgrep"]?.outcome.isFailure == true)
        #expect(session.results["toolchain:rustup:runtime:stable"]?.outcome == .succeeded, "other steps continue")
        let retry = await run(c, plan.subset(retrying: ["toolchain:cargo:package:ripgrep"]),
                              RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)))
        #expect(retry.results["toolchain:cargo:package:ripgrep"]?.outcome == .succeeded)
    }

    @Test func tapsAreTrustedOnHomebrewSixAndLater() async throws {
        let sandbox = try Sandbox("tap-trust")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.setHomebrewVersion("7.0.7")
        var selection = RestoreSelection(components: [.brewFormulae])
        selection.enabledTaps = ["example/tools"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["tap:example/tools"]?.outcome == .succeeded)
        #expect(fresh.calls().contains("brew trust --tap example/tools"))
        #expect(session.results["formula:example/tools/example-tool"]?.outcome == .succeeded || session.results["formula:example-tool"]?.outcome == .succeeded)
    }

    @Test func developmentBuildsAreReproducedUnlessTheUserChoosesStable() async throws {
        let sandbox = try Sandbox("head-formula")
        var (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        manifest.brewFormulae = [BrewFormulaRecord(name: "jq", version: "HEAD-1a2b3c")]
        #expect(manifest.brewFormulae[0].isHead)
        for (choice, expected) in [(nil as String?, "brew install --formula jq --HEAD"), ("stable", "brew install --formula jq")] {
            let (fresh, target) = try TestEnvironment.freshMac(sandbox, name: "fresh-\(choice ?? "head")")
            var selection = RestoreSelection(components: [.brewFormulae])
            if let choice { selection.sourceChoices["formula:jq"] = choice }
            let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
            let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
                .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
            #expect(session.results["formula:jq"]?.outcome == .succeeded)
            #expect(fresh.calls().contains(expected), "\(fresh.calls())")
        }
    }

    @Test func sessionsFromEarlierVersionsStillLoad() throws {
        let json = #"{"components":["fonts","futureComponent"],"excludedItemIDs":[],"enabledTaps":[],"matchDecisions":{},"conflictResolution":"keepExisting","conflictOverrides":{}}"#
        let selection = try JSONDecoder().decode(RestoreSelection.self, from: Data(json.utf8))
        #expect(selection.components == [.fonts])
        #expect(selection.sourceChoices.isEmpty)
    }
}
