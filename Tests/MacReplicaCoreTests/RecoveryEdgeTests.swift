import CryptoKit
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Developer tool edge cases")
struct ToolchainEdgeTests {
    func context(_ sandbox: Sandbox) -> ToolchainContext {
        ToolchainContext(layout: toolchainLayout(sandbox), workFolder: nil, architecture: .arm64)
    }

    @Test func gemsKeepTheNewestVersionAndRustupAnswersOnlyForToolchains() throws {
        let sandbox = try Sandbox("gems-newest")
        for gem in ["rails-7.1.3", "rails-7.0.0", "rails-6.1.7"] {
            try sandbox.file("home/.rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/\(gem).gemspec")
        }
        try sandbox.file("home/.rbenv/versions/3.3.5/bin/ruby")
        #expect(try #require(GemProvider().scan(context(sandbox))).packages.map(\.version) == ["7.1.3"])
        try sandbox.file("home/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")
        let stable = ToolchainRuntime(version: "stable")
        #expect(RustupProvider().isSatisfied(ToolchainAction(provider: .rustup, kind: .runtime, runtime: stable), context: context(sandbox)))
        #expect(!RustupProvider().isSatisfied(ToolchainAction(provider: .rustup, kind: .package, runtime: stable), context: context(sandbox)))
        #expect(!RustupProvider().isSatisfied(ToolchainAction(provider: .rustup, kind: .runtime, runtime: ToolchainRuntime(version: "../x")),
                                              context: context(sandbox)))
    }

    @Test func goReadsOnlyGOBINAndGOPATHFromItsSettings() throws {
        let sandbox = try Sandbox("go-env")
        let context = context(sandbox)
        #expect(GoProvider.binFolder(context).path == sandbox.url.appendingPathComponent("home/go/bin").path)
        try sandbox.file("home/Library/Application Support/go/env", "GOPROXY=https://user:secret@proxy.example.invalid\nGOPATH=~/work:~/other\n")
        #expect(GoProvider.binFolder(context).path == sandbox.url.appendingPathComponent("home/work/bin").path, "the first GOPATH entry")
        try sandbox.file("home/Library/Application Support/go/env", "GOPATH=~/work\nGOBIN=/opt/gobin\n")
        #expect(GoProvider.binFolder(context).path == "/opt/gobin", "GOBIN wins")
        #expect(!GoProvider().isSatisfied(ToolchainAction(provider: .go, kind: .package, package: ToolchainPackage(name: "../x")), context: context))
    }

    @Test func sdkmanCandidatesAndDefaults() throws {
        let sandbox = try Sandbox("sdkman")
        try sandbox.file("home/.sdkman/candidates/java/21.0.4-tem/bin/java")
        try sandbox.file("home/.sdkman/candidates/java/17.0.12-zulu/bin/java")
        try sandbox.symlink("home/.sdkman/candidates/java/current", to: "21.0.4-tem")
        try sandbox.file("home/.sdkman/candidates/gradle/8.10/bin/gradle")
        let record = try #require(SDKMANProvider().scan(context(sandbox)))
        #expect(record.runtimes.map(\.version) == ["gradle/8.10", "java/17.0.12-zulu", "java/21.0.4-tem"], "the current link is not a version")
        #expect(record.runtimes.filter(\.isDefault).map(\.version) == ["java/21.0.4-tem"])
        let java = ToolchainAction(provider: .sdkman, kind: .runtime, runtime: record.runtimes[2])
        #expect(SDKMANProvider().manualInstruction(for: java) == "sdk install java 21.0.4-tem\nsdk default java 21.0.4-tem")
        #expect(SDKMANProvider().isSatisfied(java, context: context(sandbox)))
        #expect(SDKMANProvider().manualInstruction(for: ToolchainAction(provider: .sdkman, kind: .runtime, runtime: ToolchainRuntime(version: "x"))) == nil)
        #expect(DotnetProvider().scan(context(try Sandbox("dotnet-empty"))) == nil)
    }

    @Test func nixMiseAsdfPkgxAndPipxDetails() throws {
        let sandbox = try Sandbox("pm-details")
        let context = context(sandbox)
        let manifest = """
            {"version":3,"elements":{"hello":{"active":true,"attrPath":"legacyPackages.aarch64-darwin.hello","originalUrl":"flake:nixpkgs"},
            "old":{"active":false,"attrPath":"legacyPackages.aarch64-darwin.old","originalUrl":"flake:nixpkgs"}}}
            """
        try sandbox.file("home/.nix-profile/manifest.json", manifest)
        let nix = try #require(NixProvider().scan(context))
        #expect(nix.packages.map(\.name) == ["hello"], "inactive elements are left out")
        let hello = ToolchainAction(provider: .nix, kind: .package, package: nix.packages[0])
        #expect(NixProvider().isSatisfied(hello, context: context))
        #expect(!NixProvider().isSatisfied(ToolchainAction(provider: .nix, kind: .package, package: ToolchainPackage(name: "other")), context: context))
        #expect(NixProvider().supportLevel(for: hello) == .automatic)
        #expect(NixProvider().supportLevel(for: ToolchainAction(provider: .nix, kind: .manager)) == .guided)
        #expect(NixProvider().supportLevel(for: ToolchainAction(provider: .nix, kind: .package, package: ToolchainPackage(name: "x", origin: .vcs))) == .guided)
        #expect(NixProvider.parse(["elements": [["attrPath": "packages.x86_64-darwin.tool", "originalUrl": "github:NixOS/nixpkgs/abc"]]])
                == [ToolchainPackage(name: "tool")], "manifest version 1 and 2 use an array")

        try sandbox.file("home/.local/share/mise/installs/node/22.3.1/bin/node")
        #expect(MiseProvider().isSatisfied(ToolchainAction(provider: .mise, kind: .runtime, runtime: ToolchainRuntime(version: "node@22")), context: context))
        #expect(!MiseProvider().isSatisfied(ToolchainAction(provider: .mise, kind: .runtime, runtime: ToolchainRuntime(version: "node@20")), context: context))
        #expect(!MiseProvider().isSatisfied(ToolchainAction(provider: .mise, kind: .runtime, runtime: ToolchainRuntime(version: "../x@1")), context: context))
        try sandbox.file("home/.asdf/installs/nodejs/20.11.0/bin/node")
        let asdfNode = ToolchainAction(provider: .asdf, kind: .runtime, runtime: ToolchainRuntime(version: "nodejs/20.11.0"))
        #expect(AsdfProvider().isSatisfied(asdfNode, context: context))
        #expect(AsdfProvider().manualInstruction(for: asdfNode) == "asdf plugin add nodejs\nasdf install nodejs 20.11.0")
        #expect(AsdfProvider().manualInstruction(for: ToolchainAction(provider: .asdf, kind: .runtime, runtime: ToolchainRuntime(version: "nodejs"))) == nil)

        #expect(PkgxProvider().scan(context) == nil, "neither pkgx nor packages")
        try sandbox.file("home/.local/pkgs/nodejs.org/v22.1.0/bin/node")
        #expect(PkgxProvider().scan(context)?.packages == [ToolchainPackage(name: "nodejs.org", version: "22.1.0")])

        try sandbox.file("opt/homebrew/bin/pipx", executable: true)
        let injected = ToolchainAction(provider: .pipx, kind: .package, package: ToolchainPackage(name: "black", version: "24.4.2", extras: ["inject=plugin"]))
        #expect(PipxProvider().commands(for: injected, context: context)?.map(\.arguments) == [["install", "black==24.4.2"], ["inject", "black", "plugin"]])
        let plain = ToolchainAction(provider: .pipx, kind: .package, package: ToolchainPackage(name: "ruff"))
        #expect(PipxProvider().commands(for: plain, context: context)?.count == 1)
        try sandbox.file("opt/homebrew/bin/yarn", executable: true)
        #expect(YarnProvider().commands(for: ToolchainAction(provider: .yarn, kind: .runtime), context: context) == nil)
    }

    @Test func tomlNestedTablesAndEdges() {
        let document = MiniTOML.parse("""
            [a.b]
            k = 1
            inline = {   x = "1"  ,  nested = { y = "2" }  }
            [c]
            last = "[" 
            [[
            """)
        #expect(MiniTOML.value(document, ["a", "b", "k"]) as? Int == 1)
        #expect(MiniTOML.value(document, ["a", "b", "inline", "x"]) as? String == "1")
        #expect(MiniTOML.value(document, ["a", "b", "inline", "nested", "y"]) as? String == "2")
        #expect(MiniTOML.value(document, ["c", "last"]) as? String == "[")
        #expect(MiniTOML.value(document, ["a", "k"]) == nil)
    }

    @Test func updateFeedLimits() {
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https://example.com/" + String(repeating: "a", count: 490)]) == nil, "over 500 characters")
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https://example.com/" + String(repeating: "a", count: 470)]) != nil)
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https:///appcast.xml"]) == nil, "no host")
        #expect(DownloadSourceFinder.isWebsite("https://example.com"))
        #expect(!DownloadSourceFinder.isWebsite("http://example.com"))
        #expect(!DownloadSourceFinder.isWebsite("https://user@example.com"))
    }
}

@Suite("Download and guided installation edge cases")
struct DownloadEdgeTests {
    @Test func maximumSystemVersionAndDisabledCasksAreRespected() async {
        let item = AppcastItem(version: "2", shortVersion: "2.0", maximumSystemVersion: "14.9", enclosureURL: "https://dl.example.com/a.zip",
                               length: 1, edSignature: "s")
        let feed = UpdateFeed(url: "https://x", publicEDKey: Data(repeating: 1, count: 32).base64EncodedString())
        let app = AppRecord(name: "A", path: "/Applications/A.app")
        #expect(DownloadSourceFinder.feedOffers([item], feed: feed, app: app, itemID: "i", macOSVersion: "15.0", architecture: .arm64).isEmpty)
        #expect(DownloadSourceFinder.feedOffers([item], feed: feed, app: app, itemID: "i", macOSVersion: "14.5", architecture: .arm64).count == 1)
        let disabled = CaskInfo(token: "a", bundleIdentifiers: ["com.example.a"], disabled: true,
                                download: CaskDownload(url: "https://dl.example.com/a.dmg", sha256: String(repeating: "a", count: 64)))
        let enabled = CaskInfo(token: "a-new", bundleIdentifiers: ["com.example.a"],
                               download: CaskDownload(url: "https://dl.example.com/new.dmg", sha256: String(repeating: "b", count: 64)))
        let finder = DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/nonexistent")), catalog: CaskCatalog(casks: [disabled, enabled]),
                                          macOSVersion: "15.0", architecture: .arm64)
        let offers = await finder.offers(for: AppRecord(name: "A", bundleIdentifier: "com.example.a", path: "/Applications/A.app"), itemID: "i")
        #expect(offers.first?.url == "https://dl.example.com/new.dmg", "a disabled cask is skipped when matching by bundle identifier")
    }

    /// Counts downloads that are running at the same time, at the transport itself.
    actor Concurrency { var running = 0; var peak = 0
        func start() { running += 1; peak = max(peak, running) }
        func end() { running -= 1 } }
    struct CountingTransport: DownloadTransport {
        let inner: LocalDownloadTransport
        let counter: Concurrency
        func download(from url: URL, resumeData: Data?, to destination: URL,
                      progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
            await counter.start()
            do {
                let file = try await inner.download(from: url, resumeData: resumeData, to: destination, progress: progress)
                await counter.end()
                return file
            } catch {
                await counter.end()
                throw error
            }
        }
    }

    @Test func theQueueRespectsItsConcurrencyLimit() async throws {
        let sandbox = try Sandbox("queue-limit")
        for name in ["a", "b", "c"] { try Data(repeating: 1, count: 60_000).write(to: try sandbox.file("downloads/dl.example.com/\(name).zip")) }
        let counter = Concurrency()
        let transport = CountingTransport(inner: LocalDownloadTransport(root: sandbox.url, chunkSize: 5_000, delayPerChunk: 0.005), counter: counter)
        let queue = DownloadQueue(transport: transport, folder: sandbox.url.appendingPathComponent("dl"), maxConcurrent: 1)
        for name in ["a", "b", "c"] {
            await queue.enqueue(DownloadOffer(id: name, itemID: name, kind: .vendorFeed, url: "https://dl.example.com/\(name).zip", trust: .checksum))
        }
        await queue.waitUntilIdle()
        #expect(await counter.peak == 1)
        for name in ["a", "b", "c"] { if case .finished? = await queue.state(name) {} else { Issue.record("\(name) not finished") } }
    }

    @Test func archivesSkipMetadataFoldersAndAppsGoIntoTheFirstApplicationsFolder() throws {
        let sandbox = try Sandbox("find-app")
        let folder = try sandbox.folder("extracted")
        try SimulationBuilder.makeSyntheticApp(name: "Wrong", bundleID: "x", version: "1", in: try sandbox.folder("extracted/__MACOSX"))
        try SimulationBuilder.makeSyntheticApp(name: "Hidden", bundleID: "x", version: "1", in: try sandbox.folder("extracted/.hidden"))
        let right = try SimulationBuilder.makeSyntheticApp(name: "Right", bundleID: "y", version: "1", in: try sandbox.folder("extracted/Release"))
        #expect(DownloadInstaller.findApplication(in: folder)?.resolvingSymlinksInPath().path == right.resolvingSymlinksInPath().path)
        #expect(DownloadInstaller.findApplication(in: folder, depth: 1) == nil, "only one level when asked")
        var layout = toolchainLayout(sandbox)
        layout.applicationFolders = [try sandbox.folder("Applications"), try sandbox.folder("home/Applications")]
        let installer = DownloadInstaller(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:]),
                                          macOSVersion: "15.0", architecture: .arm64)
        let installed = try installer.installApplication(right, source: "https://example.com")
        #expect(installed.deletingLastPathComponent().path == layout.applicationFolders[0].path)
    }

    @Test func theSequenceDownloadsTheNextAppsWhileTheUserIsBusy() async throws {
        let fixture = try VendorFixture("prefetch")
        let layout = toolchainLayout(fixture.sandbox)
        try FileManager.default.createDirectory(at: layout.applicationFolders[0], withIntermediateDirectories: true)
        let published = try fixture.publishZip(appName: "Second", bundleID: "com.example.second", version: "1.0", path: "dl.example.com/second.zip")
        let installer = fixture.installer(layout: layout)
        let queue = DownloadQueue(transport: LocalDownloadTransport(root: fixture.root), folder: installer.downloadsFolder)
        let guided = GuidedInstallation(installer: installer, queue: queue)
        actor Observer: GuidedInstallInteraction {
            let queue: DownloadQueue
            var secondStateWhileWaiting: DownloadState?
            init(queue: DownloadQueue) { self.queue = queue }
            func openPackage(_ url: URL) async {}
            func openInFinder(_ url: URL) async {}
            func open(_ url: URL) async {}
            func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision {
                await queue.waitUntilIdle()
                secondStateWhileWaiting = await queue.state("second")
                return .later
            }
        }
        let interaction = Observer(queue: queue)
        let first = RestoreItem(id: "first", kind: .manualApp, title: "First", identifier: "/Applications/First.app", bundleIdentifier: "com.example.first",
                                appBundleNames: ["First.app"])
        let second = RestoreItem(id: "second", kind: .manualApp, title: "Second", identifier: "/Applications/Second.app",
                                 bundleIdentifier: "com.example.second", appBundleNames: ["Second.app"])
        let offer = DownloadOffer(id: "f", itemID: "second", kind: .vendorFeed, url: "https://dl.example.com/second.zip", expectedLength: published.length,
                                  edSignature: published.signature, publicEDKey: fixture.publicKey, expectedBundleIdentifier: "com.example.second",
                                  trust: .vendorSignature)
        await guided.runSequence([(first, nil), (second, offer)], interaction: interaction, isInstalled: { item in
            AppModelInstalled.version(item, layout: layout)
        }, record: { _, _ in })
        guard case .finished? = await interaction.secondStateWhileWaiting else { Issue.record("not downloaded in the background"); return }
    }
}

/// The same check the app uses: installed when the bundle with that identifier is in the Applications folder.
enum AppModelInstalled {
    static func version(_ item: RestoreItem, layout: SystemLayout) -> String?? {
        let url = layout.applicationFolders[0].appendingPathComponent(item.appBundleNames[0])
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              (info["CFBundleIdentifier"] as? String) == item.bundleIdentifier else { return nil }
        return .some(info["CFBundleShortVersionString"] as? String)
    }
}

@Suite("Recovery restore edge cases", .serialized)
struct RecoveryRestoreEdgeTests {
    @Test func aUvProjectIsRebuiltFromItsLockFileWhenOnlyPythonIsRestored() async throws {
        let sandbox = try Sandbox("uv-python-only")
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        let environment = try source.environment
        let inventory = try await TestEnvironment.inventory(environment).run()
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        // uv and pyenv's Python are already there; Homebrew is not.
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/toolchain"), to: fresh.url.appendingPathComponent("opt/homebrew/bin/uv"))
        let pyenv = fresh.url.appendingPathComponent("home/.pyenv/versions/3.12.4/bin")
        try FileManager.default.createDirectory(at: pyenv, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/python"), to: pyenv.appendingPathComponent("python3.12"))
        var manifest = outcome.manifest
        manifest.python.environments = manifest.python.environments.filter { $0.name == "api-service" }
        let selection = RestoreSelection(components: [.python])
        let plan = RestorePlan(items: RestorePlanner().plan(manifest: manifest, selection: selection).items.filter { $0.kind == .pythonEnvironment },
                               manualApps: [])
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        let result = try #require(session.results.values.first)
        #expect(result.outcome == .succeeded, "\(result.outcome)")
        #expect(result.notes.contains(.pythonLockFileUsed(file: "uv.lock")))
        #expect(fresh.calls().contains { $0.hasPrefix("uv sync --frozen") })
    }

    @Test func aMissingToolWithoutAPrerequisiteIsAGuidedStepNotAFailure() async throws {
        let sandbox = try Sandbox("missing-tool")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        _ = fresh
        var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
        manifest.toolchains = [ToolchainRecord(provider: .npm, packages: [ToolchainPackage(name: "typescript", version: "5.4.5",
                                                                                          runtime: RuntimeReference(source: .other, version: "custom"))])]
        let selection = RestoreSelection(components: [.developerTools])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(plan.items.map(\.id) == ["toolchain:npm:package:other-custom/typescript"])
        #expect(plan.items[0].dependsOn.isEmpty)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
        #expect(await executor.dryRun(plan: plan, selection: selection).first?.prediction == .manualStep)
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)),
                                         onEvent: { _ in })
        #expect(session.results.values.first?.outcome == .skipped(.manualStepRequired))
    }

    @Test func automaticStepsWithTheirToolPresentArePredictedAsInstalls() async throws {
        let sandbox = try Sandbox("predict-install")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/toolchain"), to: fresh.url.appendingPathComponent("opt/homebrew/bin/uv"))
        var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
        manifest.toolchains = [ToolchainRecord(provider: .uv, runtimes: [ToolchainRuntime(version: "3.13.1")])]
        let selection = RestoreSelection(components: [.developerTools])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
            .dryRun(plan: plan, selection: selection)
        #expect(entries.first { $0.item.id == "toolchain:uv:runtime:3.13.1" }?.prediction == .willInstall, "uv is already there")
        try FileManager.default.removeItem(at: fresh.url.appendingPathComponent("opt/homebrew/bin/uv"))
        let later = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
            .dryRun(plan: plan, selection: selection)
        #expect(later.first { $0.item.id == "toolchain:uv:runtime:3.13.1" }?.prediction == .dependsOnEarlierStep, "after Homebrew installs uv")
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/toolchain"), to: fresh.url.appendingPathComponent("opt/homebrew/bin/uv"))
        let alone = RestorePlan(items: plan.items.filter { $0.kind == .toolchainStep }.map { var item = $0; item.dependsOn = []; return item }, manualApps: [])
        let direct = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
            .dryRun(plan: alone, selection: selection)
        #expect(direct.first?.prediction == .willInstall)
    }

    @Test func appStoreAppsAreFoundByBundleIdentifierAlone() async throws {
        let sandbox = try Sandbox("mas-bundle-only")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.simulateUserInstall(appNamed: "Ledger Lite")
        let item = RestoreItem(id: "mas:1234567890", kind: .appStoreApp, title: "Ledger Lite", identifier: "1234567890",
                               bundleIdentifier: "com.example.ledgerlite", component: .appStore)
        let plan = RestorePlan(items: [item], manualApps: [])
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: sandbox.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: RestoreSelection(), itemIDs: [item.id]), onEvent: { _ in })
        #expect(session.results[item.id]?.outcome == .alreadyPresent, "found by bundle identifier without mas")
    }
}

@Suite("More recovery edge cases")
struct MoreRecoveryEdgeTests {
    func context(_ sandbox: Sandbox) -> ToolchainContext {
        ToolchainContext(layout: toolchainLayout(sandbox), workFolder: nil, architecture: .arm64)
    }

    @Test func rvmRubiesDefaultAndGuidedInstructions() throws {
        let sandbox = try Sandbox("rvm")
        try sandbox.file("home/.rvm/rubies/ruby-3.3.5/bin/ruby")
        try sandbox.file("home/.rvm/rubies/ruby-3.2.4/bin/ruby")
        try sandbox.symlink("home/.rvm/rubies/default", to: "ruby-3.3.5")
        try sandbox.file("home/.rvm/config/alias", "default=ruby-3.3.5\n")
        let record = try #require(RVMProvider().scan(context(sandbox)))
        #expect(record.runtimes.map(\.version) == ["ruby-3.2.4", "ruby-3.3.5"], "the default link is not a version")
        #expect(record.runtimes.filter(\.isDefault).map(\.version) == ["ruby-3.3.5"])
        #expect(RVMProvider().manualInstruction(for: ToolchainAction(provider: .rvm, kind: .runtime, runtime: record.runtimes[1]))
                == "rvm install ruby-3.3.5\nrvm alias create default ruby-3.3.5")
        #expect(RVMProvider().manualInstruction(for: ToolchainAction(provider: .rvm, kind: .runtime, runtime: record.runtimes[0])) == "rvm install ruby-3.2.4")
        #expect(RVMProvider().isSatisfied(ToolchainAction(provider: .rvm, kind: .runtime, runtime: record.runtimes[0]), context: context(sandbox)))
        #expect(!NVMProvider().isSatisfied(ToolchainAction(provider: .nvm, kind: .environment), context: context(sandbox)))
        #expect(!DotnetProvider().isSatisfied(ToolchainAction(provider: .dotnet, kind: .environment), context: context(sandbox)))
        #expect(!YarnProvider().isSatisfied(ToolchainAction(provider: .yarn, kind: .package), context: context(sandbox)))
    }

    @Test func theFirstCondaInstallationIsUsed() throws {
        let sandbox = try Sandbox("conda-bases")
        for base in ["miniforge3", "miniconda3"] {
            try sandbox.file("home/\(base)/bin/conda", executable: true)
            try sandbox.file("home/\(base)/conda-meta/history", "==> a <==\n# update specs: ['python']\n==> b <==\n# update specs: ['\(base)-extra']\n")
        }
        let record = try #require(CondaProvider().scan(context(sandbox)))
        #expect(record.location == "~/miniforge3")
        #expect(record.environments.first?.requestedPackages == ["miniforge3-extra"])
    }

    @Test func tomlWhitespaceAndUnreadableArrayItems() {
        let document = MiniTOML.parse("a = [\t\"x\",\r\n  @, \"y\" ]\nb\t=\t2\n")
        #expect(document["a"] as? [String] == ["x", "@", "y"])
        #expect(document["b"] as? Int == 2)
    }

    @Test func casksMatchedByAppNameUseTheFirstMatch() async {
        let first = CaskInfo(token: "example", appArtifacts: ["Example.app"], download: CaskDownload(url: "https://dl.example.com/first.dmg", sha256: String(repeating: "a", count: 64)))
        let second = CaskInfo(token: "example-other", appArtifacts: ["Example.app"], download: CaskDownload(url: "https://dl.example.com/second.dmg", sha256: String(repeating: "b", count: 64)))
        let offers = await DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/x")), catalog: CaskCatalog(casks: [first, second]),
                                                macOSVersion: "15.0", architecture: .arm64)
            .offers(for: AppRecord(name: "Example", path: "/Applications/Example.app"), itemID: "i")
        #expect(offers.first?.url == "https://dl.example.com/first.dmg")
    }

    @Test func queueStatesForQueuedPausesHttpWithSignatureAndCancellation() async throws {
        let sandbox = try Sandbox("queue-states")
        for name in ["a", "b"] { try Data(repeating: 2, count: 80_000).write(to: try sandbox.file("downloads/dl.example.com/\(name).zip")) }
        let queue = DownloadQueue(transport: LocalDownloadTransport(root: sandbox.url, chunkSize: 4_000, delayPerChunk: 0.01),
                                  folder: sandbox.url.appendingPathComponent("dl"), maxConcurrent: 1)
        await queue.enqueue(DownloadOffer(id: "a", itemID: "a", kind: .vendorFeed, url: "https://dl.example.com/a.zip", trust: .checksum))
        await queue.enqueue(DownloadOffer(id: "b", itemID: "b", kind: .vendorFeed, url: "http://dl.example.com/b.zip", edSignature: "sig",
                                          trust: .vendorSignature))
        #expect(await queue.state("b") == .queued, "plain HTTP is accepted when the file carries the vendor's signature")
        await queue.pause("b")
        #expect(await queue.state("b") == .paused, "a queued download can be paused before it starts")
        await queue.cancel("a")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await queue.state("a") == .cancelled, "a cancelled download stays cancelled, it is not reported as a failure")
        #expect(await queue.state("b") == .paused, "a paused download does not start on its own")
        await queue.resume("b")
        await queue.waitUntilIdle()
        if case .finished? = await queue.state("b") {} else { Issue.record("b not finished") }
    }

    @Test func packagesFromAnotherDeveloperAreRefused() async throws {
        let sandbox = try Sandbox("pkg-team")
        let stub = try sandbox.file("bin/pkgutil", """
            #!/bin/sh
            cat <<OUT
            Package "x.pkg":
               Status: signed by a developer certificate issued by Apple for distribution
               Certificate Chain:
                1. Developer ID Installer: Example Corporation (AAAAA11111)
            OUT
            """, executable: true)
        var layout = toolchainLayout(sandbox)
        layout.pkgutil = stub.path
        let installer = DownloadInstaller(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: [stub.path]),
                                                                                       baseEnvironment: [:]), macOSVersion: "15.0", architecture: .arm64)
        let package = try sandbox.file("x.pkg", "synthetic")
        var offer = DownloadOffer(id: "o", itemID: "i", kind: .homebrewCask, url: "https://x/x.pkg", expectedTeamIdentifier: "BBBBB22222", trust: .checksum)
        await #expect(throws: DownloadError.wrongDeveloper(expected: "BBBBB22222", actual: "AAAAA11111")) {
            try await installer.prepare(package, offer: offer, staging: sandbox.url.appendingPathComponent("staging"))
        }
        offer.expectedTeamIdentifier = "AAAAA11111"
        #expect(try await installer.prepare(package, offer: offer, staging: sandbox.url.appendingPathComponent("staging"))
                == .package(package, teamIdentifier: "AAAAA11111"))
    }

    @Test func archivesAreSearchedTwoLevelsDeepInNameOrder() throws {
        let sandbox = try Sandbox("find-depth")
        let root = try sandbox.folder("x")
        try SimulationBuilder.makeSyntheticApp(name: "Deep", bundleID: "d", version: "1", in: try sandbox.folder("x/a/b"))
        #expect(DownloadInstaller.findApplication(in: root) == nil, "three levels down is too deep")
        try SimulationBuilder.makeSyntheticApp(name: "Zeta", bundleID: "z", version: "1", in: root)
        try SimulationBuilder.makeSyntheticApp(name: "Alpha", bundleID: "a", version: "1", in: root)
        #expect(DownloadInstaller.findApplication(in: root)?.lastPathComponent == "Alpha.app")
    }
}
