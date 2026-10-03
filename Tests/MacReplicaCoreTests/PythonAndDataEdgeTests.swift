import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A runner that answers some commands itself and passes the rest to the simulation.
final class InterceptingRunner: CommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (Command) -> CommandResult?
    private let lock = NSLock()
    private var _intercepted: [Command] = []
    private let base: CommandRunning
    private let handler: Handler

    init(base: CommandRunning, handler: @escaping Handler) {
        self.base = base
        self.handler = handler
    }

    var intercepted: [Command] { lock.withLock { _intercepted } }

    func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        if let answer = handler(command) {
            lock.withLock { _intercepted.append(command) }
            return answer
        }
        return try await base.run(command, onOutputLine: onOutputLine)
    }
}

func pythonEnvironment(_ path: String, manager: EnvironmentManager = .venv, version: String = "3.12.7", architectures: [CPUArchitecture] = [],
                       packages: [PythonPackage] = [PythonPackage(name: "rich", version: "13.9.2")]) -> PythonEnvironment {
    let id = "env-" + path.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    return PythonEnvironment(id: id, name: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent, path: path, manager: manager,
                             pythonVersion: version, baseInterpreter: nil, baseSource: .homebrew, architectures: architectures, packages: packages,
                             requirementsPath: "development/python/\(id)/requirements.txt")
}

/// The Python steps of a plan for these environments (their Homebrew prerequisites are left out).
func pythonPlan(_ environments: [PythonEnvironment]) -> RestorePlan {
    var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
    manifest.python.environments = environments
    return pythonPlan(manifest)
}

func pythonPlan(_ manifest: Manifest) -> RestorePlan {
    RestorePlan(items: RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.python])).items
        .filter { $0.kind == .pythonEnvironment }, manualApps: [])
}

/// Python environments: interpreter choice, predictions and the rebuild's edge cases.
@Suite("Python rebuild edge cases", .serialized)
struct PythonRestoreEdgeTests {
    func inspector(_ simulation: SimulationEnvironment, backup: URL) -> Inspector {
        Inspector(environment: TestEnvironment.restoreEnvironment(simulation), backupRoot: backup, selection: RestoreSelection(components: [.python]),
                  damagedFiles: [])
    }

    func run(_ plan: RestorePlan, on target: SimulationEnvironment, backup: URL, runner: CommandRunning? = nil) async -> RestoreSession {
        let selection = RestoreSelection(components: [.python])
        return await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, runner: runner), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    /// Homebrew's Python 3.12 on the simulated Mac, without installing Homebrew packages.
    func installHomebrewPython(_ root: SimulationRoot) throws {
        let bin = root.url.appendingPathComponent("opt/homebrew/opt/python@3.12/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.url.appendingPathComponent("tools/python"), to: bin.appendingPathComponent("python3.12"))
    }

    func baseHome(of environment: URL) throws -> String? {
        PythonScanner.parseConfig(try String(contentsOf: environment.appendingPathComponent("pyvenv.cfg"), encoding: .utf8))["home"]
    }

    @Test func uvsPythonDownloadMatchesTheEnvironmentsArchitecture() throws {
        let sandbox = try Sandbox("py-uv-arch")
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let inspector = inspector(target, backup: sandbox.url)
        func uvCandidate(_ architectures: [CPUArchitecture]) -> String? {
            inspector.pythonInterpreters(for: pythonEnvironment("~/p/.venv", architectures: architectures), brewPrefix: nil)
                .first { $0.contains(".local/share/uv/python/") }
        }
        #expect(uvCandidate([.arm64])?.contains("cpython-3.12.7-macos-aarch64-none/bin/python3.12") == true)
        #expect(uvCandidate([.arm64, .x86_64])?.contains("-macos-aarch64-none/") == true, "universal environments use the native download")
        #expect(uvCandidate([])?.contains("-macos-aarch64-none/") == true, "pure Python: the native download")
        #expect(uvCandidate([.x86_64])?.contains("cpython-3.12.7-macos-x86_64-none/bin/python3.12") == true, "Intel-only native code needs the Intel build")
        // Best first: the exact pyenv version, then uv's, then Homebrew's Python of the same minor version.
        let candidates = inspector.pythonInterpreters(for: pythonEnvironment("~/p/.venv"), brewPrefix: target.layout.homebrewPrefixes[0])
        #expect(candidates.count == 3)
        #expect(candidates.first?.hasSuffix(".pyenv/versions/3.12.7/bin/python3.12") == true)
        #expect(candidates.last == target.layout.homebrewPython(minor: "3.12", prefix: target.layout.homebrewPrefixes[0]))
        #expect(inspector.pythonInterpreters(for: pythonEnvironment("~/p/.venv", version: "3.12.7; rm -rf"), brewPrefix: nil).count == 1,
                "an unsafe version is never used in a path")
    }

    @Test func onlyUvEnvironmentsWithLockAndProjectFileAreUvProjects() throws {
        let sandbox = try Sandbox("py-uv-project")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let inspector = inspector(target, backup: sandbox.url)
        let venv = fresh.url.appendingPathComponent("home/Projects/api-service/.venv")
        #expect(inspector.uvProject(for: pythonEnvironment("~/Projects/api-service/.venv", manager: .uv), target: venv)?.standardizedFileURL
                == venv.deletingLastPathComponent().standardizedFileURL)
        #expect(inspector.uvProject(for: pythonEnvironment("~/Projects/api-service/.venv", manager: .venv), target: venv) == nil,
                "a plain venv next to a uv.lock is rebuilt from its own package list")
        try FileManager.default.removeItem(at: fresh.url.appendingPathComponent("home/Projects/api-service/pyproject.toml"))
        #expect(inspector.uvProject(for: pythonEnvironment("~/Projects/api-service/.venv", manager: .uv), target: venv) == nil)
        let demo = fresh.url.appendingPathComponent("home/Projects/demo-app/.venv")
        #expect(inspector.uvProject(for: pythonEnvironment("~/Projects/demo-app/.venv", manager: .uv), target: demo) == nil, "no lock file")
    }

    @Test func predictionsForExistingAndMissingEnvironments() throws {
        let sandbox = try Sandbox("py-predict")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let inspector = inspector(target, backup: sandbox.url)
        let brew = HomebrewInstallation(executable: "brew", prefix: target.layout.homebrewPrefixes[0], version: "4.4.0")
        let project = pythonEnvironment("~/Projects/demo-app/.venv")
        let tools = pythonEnvironment("~/.virtualenvs/tools", manager: .virtualenvwrapper)
        let orphan = pythonEnvironment("~/Projects/gone/.venv")
        let plan = pythonPlan([project, tools, orphan])
        func predict(_ environment: PythonEnvironment, brew: HomebrewInstallation? = nil) throws -> Prediction {
            inspector.predictPython(try #require(plan.items.first { $0.pythonEnvironment?.id == environment.id }), brew: brew)
        }
        // Nothing there yet.
        #expect(try predict(project) == .dependsOnEarlierStep, "Python comes from Homebrew first")
        #expect(try predict(project, brew: brew) == .willRecreateEnvironment)
        #expect(try predict(orphan, brew: brew) == .willSkip(.projectFolderMissing(path: "~/Projects/gone")), "project folders are never created")
        #expect(try predict(tools, brew: brew) == .willRecreateEnvironment, "tool-managed folders may be created")

        // An environment is already at the location.
        let env = fresh.url.appendingPathComponent("home/Projects/demo-app/.venv")
        let site = env.appendingPathComponent("lib/python3.12/site-packages")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("version = 3.11.9\n".utf8).write(to: env.appendingPathComponent("pyvenv.cfg"))
        #expect(try predict(project, brew: brew) == .environmentConflict, "another Python version is left alone")
        try Data("version = 3.12.2\n".utf8).write(to: env.appendingPathComponent("pyvenv.cfg"))
        #expect(try predict(project, brew: brew) == .willCompleteEnvironment, "a package is missing")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("rich-13.9.2.dist-info"), withIntermediateDirectories: true)
        try Data("Name: rich\nVersion: 13.9.2\n".utf8).write(to: site.appendingPathComponent("rich-13.9.2.dist-info/METADATA"))
        #expect(try predict(project, brew: brew) == .alreadyPresent(version: "3.12.7"))
    }

    @Test func theExactPyenvVersionIsPreferredOverHomebrewsPython() async throws {
        let sandbox = try Sandbox("py-pyenv-first")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try installHomebrewPython(fresh)
        let pyenv = fresh.url.appendingPathComponent("home/.pyenv/versions/3.12.7/bin")
        try FileManager.default.createDirectory(at: pyenv, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/python"), to: pyenv.appendingPathComponent("python3.12"))
        let session = await run(pythonPlan([pythonEnvironment("~/Projects/demo-app/.venv")]), on: target, backup: sandbox.url)
        #expect(session.results.values.first?.outcome == .succeeded)
        let home = try baseHome(of: fresh.url.appendingPathComponent("home/Projects/demo-app/.venv"))
        #expect(home.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == pyenv.resolvingSymlinksInPath().path,
                "built on the recorded pyenv version, not on Homebrew's Python")
    }

    @Test func withoutAnInterpreterTheReasonDependsOnHomebrew() async throws {
        let sandbox = try Sandbox("py-no-interpreter")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let plan = pythonPlan([pythonEnvironment("~/Projects/demo-app/.venv")])
        let withoutHomebrew = await run(plan, on: target, backup: sandbox.url)
        #expect(withoutHomebrew.results.values.first?.outcome.label == "failed(homebrewUnavailable)")
        try FileManager.default.createDirectory(at: fresh.url.appendingPathComponent("opt/homebrew/bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/brew"), to: fresh.url.appendingPathComponent("opt/homebrew/bin/brew"))
        let withHomebrew = await run(plan, on: target, backup: sandbox.url)
        guard case .failed(let failure)? = withHomebrew.results.values.first?.outcome else { Issue.record("not a failure"); return }
        #expect(failure.category == .pythonVersionUnavailable, "Homebrew is there, but not its Python 3.12")
        #expect(failure.technicalDetail.contains("Python 3.12"))
    }

    @Test func toolManagedEnvironmentsCreateTheirWholeFolderPath() async throws {
        let sandbox = try Sandbox("py-pipenv")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try installHomebrewPython(fresh)
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/.local").path))
        let session = await run(pythonPlan([pythonEnvironment("~/.local/share/virtualenvs/tools-Ab3dE9", manager: .pipenv)]), on: target,
                                backup: sandbox.url)
        #expect(session.results.values.first?.outcome == .succeeded, "\(String(describing: session.results.values.first?.outcome))")
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/.local/share/virtualenvs/tools-Ab3dE9/pyvenv.cfg").path))
    }

    @Test func diskFullAndTimeoutsAreReportedWithoutRetryingEachPackage() async throws {
        for (name, answer, expected) in [
            ("disk", CommandResult(exitCode: 1, stdout: "", stderr: "ERROR: Could not install packages due to an OSError: [Errno 28] No space left on device"),
             FailureCategory.diskFull),
            ("timeout", CommandResult(exitCode: 1, stdout: "", stderr: "", timedOut: true), .timeout),
        ] {
            let sandbox = try Sandbox("py-\(name)")
            let (fresh, target) = try TestEnvironment.freshMac(sandbox)
            try installHomebrewPython(fresh)
            let runner = InterceptingRunner(base: target.makeRunner()) { command in
                command.arguments.contains("install") && command.arguments.contains { $0.contains("==") } ? answer : nil
            }
            let environment = pythonEnvironment("~/Projects/demo-app/.venv", packages: [PythonPackage(name: "rich", version: "13.9.2"),
                                                                                       PythonPackage(name: "requests", version: "2.32.3")])
            let session = await run(pythonPlan([environment]), on: target, backup: sandbox.url, runner: runner)
            guard case .failed(let failure)? = session.results.values.first?.outcome else { Issue.record("\(name): not a failure"); continue }
            #expect(failure.category == expected, "\(name)")
            #expect(runner.intercepted.count == 1, "\(name): one package at a time would not help")
        }
    }

    @Test func theFailureShowsPipsAnswerToTheLastAttempt() async throws {
        let sandbox = try Sandbox("py-last-output")
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try installHomebrewPython(fresh)
        try fresh.setFlag("pip/missing/rich", true)
        let session = await run(pythonPlan([pythonEnvironment("~/Projects/demo-app/.venv")]), on: target, backup: sandbox.url)
        guard case .failed(let failure)? = session.results.values.first?.outcome else { Issue.record("not a failure"); return }
        #expect(failure.category == .pythonPackagesIncomplete)
        // First the recorded version was tried, then the current one; the detail is pip's answer to the latter.
        let lines = failure.technicalDetail.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasSuffix("No matching distribution found for rich") }, "\(lines)")
        #expect(!lines.contains { $0.contains("rich==13.9.2") }, "\(lines)")
    }

    // MARK: uv projects

    struct UVContext {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
        let fresh: SimulationRoot
        let target: SimulationEnvironment
    }

    /// A backup of the developer Mac with only the uv project, and a new Mac with uv and pyenv's Python 3.12.4.
    func uvContext(_ name: String) async throws -> UVContext {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        let environment = try source.environment
        let inventory = try await TestEnvironment.inventory(environment).run()
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/toolchain"), to: fresh.url.appendingPathComponent("opt/homebrew/bin/uv"))
        let pyenv = fresh.url.appendingPathComponent("home/.pyenv/versions/3.12.4/bin")
        try FileManager.default.createDirectory(at: pyenv, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/python"), to: pyenv.appendingPathComponent("python3.12"))
        var manifest = outcome.manifest
        manifest.python.environments = manifest.python.environments.filter { $0.name == "api-service" }
        return UVContext(sandbox: sandbox, backup: outcome.url, manifest: manifest, fresh: fresh, target: target)
    }

    @Test func aUvProjectUsesItsLockFileAndHomebrewsUvFirst() async throws {
        let c = try await uvContext("uv-lock-notes")
        // Another uv that does not work; Homebrew's comes first, like for the uv steps.
        let broken = c.fresh.url.appendingPathComponent("home/.local/bin/uv")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        let session = await run(pythonPlan(c.manifest), on: c.target, backup: c.backup)
        let result = try #require(session.results.values.first)
        #expect(result.outcome == .succeeded)
        #expect(result.notes == [.pythonLockFileUsed(file: "uv.lock")], "nothing needs manual setup")
        #expect(c.fresh.calls().contains { $0.hasPrefix("uv sync --frozen") })
        #expect(!c.fresh.calls().contains { $0.contains("-m pip --python") }, "not rebuilt from the package list")
    }

    @Test func packagesFromLocalFoldersAreNamedAfterALockFileRebuild() async throws {
        let c = try await uvContext("uv-lock-manual")
        var manifest = c.manifest
        manifest.python.environments[0].packages.append(PythonPackage(name: "api-service", version: "0.1.0", origin: .editable))
        let session = await run(pythonPlan(manifest), on: c.target, backup: c.backup)
        let result = try #require(session.results.values.first)
        #expect(result.outcome == .succeeded)
        #expect(result.notes == [.pythonLockFileUsed(file: "uv.lock"), .pythonPackagesNeedManualSetup(names: ["api-service"])])
    }

    @Test func anExistingUvEnvironmentIsCompletedNotSyncedOver() async throws {
        let c = try await uvContext("uv-existing")
        let env = c.fresh.url.appendingPathComponent("home/Projects/api-service/.venv")
        let site = env.appendingPathComponent("lib/python3.12/site-packages/fastapi-0.115.0.dist-info")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("version_info = 3.12.4\n".utf8).write(to: env.appendingPathComponent("pyvenv.cfg"))
        try Data("Name: fastapi\nVersion: 0.115.0\n".utf8).write(to: site.appendingPathComponent("METADATA"))
        let session = await run(pythonPlan(c.manifest), on: c.target, backup: c.backup)
        #expect(session.results.values.first?.outcome == .alreadyPresent)
        #expect(!c.fresh.calls().contains { $0.hasPrefix("uv sync") }, "an existing environment is never replaced by uv sync")
    }
}

/// The saved copy of an environment: what is recorded, and when the copy is used.
@Suite("Python saved copy edge cases", .serialized)
struct PythonPreservationEdgeTests {
    /// A thin Mach-O header with `LC_BUILD_VERSION` for macOS.
    static func machO(_ architecture: CPUArchitecture, minimumMacOS: (UInt32, UInt32)) -> Data {
        func le(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)] }
        let cpu: UInt32 = architecture == .arm64 ? 0x0100_000C : 0x0100_0007
        let header = le(0xFEED_FACF) + le(cpu) + le(0) + le(6) + le(1) + le(24) + le(0) + le(0)
        let buildVersion = le(0x32) + le(24) + le(1) + le(minimumMacOS.0 << 16 | minimumMacOS.1 << 8) + le(0) + le(0)
        return Data(header + buildVersion)
    }

    struct Source {
        let sandbox: Sandbox
        let root: SimulationRoot
        let simulation: SimulationEnvironment
        var envURL: URL { root.url.appendingPathComponent("home/Projects/analysis/.venv") }
        var site: URL { envURL.appendingPathComponent("lib/python3.12/site-packages") }
    }

    func source(_ name: String) throws -> Source {
        let sandbox = try Sandbox(name)
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        return Source(sandbox: sandbox, root: root, simulation: try root.environment)
    }

    func preserve(_ s: Source, packages: [PythonPackage]? = nil) async throws -> PythonPreservation? {
        var environment = try #require(PythonScanner(layout: s.simulation.layout).readEnvironment(at: s.envURL)).0
        if let packages { environment.packages = packages }
        guard case .preserved(_, let preservation) = try await PythonPreserver.preserve(
            environment, layout: s.simulation.layout, runner: s.simulation.makeRunner(), workFolder: try s.sandbox.folder("work-\(UUID().uuidString)"),
            keys: HardwareKeys(salt: "s", macKey: nil)) else { return nil }
        return preservation
    }

    @Test func nativeCodeInExtensionsAndLibrariesIsRecordedWithTheHighestMacOS() async throws {
        let s = try source("py-native")
        try Self.machO(.arm64, minimumMacOS: (13, 0)).write(to: s.site.appendingPathComponent("fast.cpython-312-darwin.so"))
        try Self.machO(.x86_64, minimumMacOS: (14, 2)).write(to: s.site.appendingPathComponent("libcodec.dylib"))
        try Self.machO(.arm64, minimumMacOS: (12, 0)).write(to: s.site.appendingPathComponent("old.SO"))
        try Self.machO(.x86_64, minimumMacOS: (15, 0)).write(to: s.site.appendingPathComponent("notes.txt"))
        let preservation = try #require(await preserve(s))
        #expect(preservation.nativeArchitectures == [.arm64, .x86_64], "the library counts too; other files do not")
        #expect(preservation.minimumMacOS == "14.2", "the highest minimum of all native files")
    }

    @Test func pureEnvironmentsHaveNoMinimumMacOS() async throws {
        let s = try source("py-pure")
        let preservation = try #require(await preserve(s))
        #expect(preservation.nativeArchitectures.isEmpty)
        #expect(preservation.minimumMacOS == nil)
    }

    @Test func packagesFromLocalFoldersAreFlagged() async throws {
        let s = try source("py-local-paths")
        func flag(_ origin: PackageOrigin) async throws -> Bool? {
            try await preserve(s, packages: [PythonPackage(name: "rich", version: "13.9.2"), PythonPackage(name: "mine", version: "1", origin: origin)])?
                .referencesLocalPaths
        }
        #expect(try await preserve(s, packages: [PythonPackage(name: "rich", version: "13.9.2")])?.referencesLocalPaths == false)
        #expect(try await flag(.vcs) == false, "a VCS package is fetched again, not read from a local folder")
        #expect(try await flag(.editable) == true)
        #expect(try await flag(.local) == true)
    }

    @Test func importNamesAreValidUniqueAndOnlyFromRecordedPackages() throws {
        let sandbox = try Sandbox("py-import-names")
        let env = try sandbox.folder("env")
        let site = env.appendingPathComponent("lib/python3.12/site-packages")
        func dist(_ entry: String, _ topLevel: String) throws {
            try FileManager.default.createDirectory(at: site.appendingPathComponent(entry), withIntermediateDirectories: true)
            try Data(topLevel.utf8).write(to: site.appendingPathComponent("\(entry)/top_level.txt"))
        }
        try dist("PyYAML-6.0.2.dist-info", "yaml\n_yaml\n")
        try dist("ruamel.yaml-0.18.6.dist-info", "ruamel\nyaml\n")
        try dist("odd_names-1.0.dist-info", "not-a-module\n9lives\n  spaced  \nfine.sub\n")
        try dist("unrelated-2.0.dist-info", "unrelated\n")
        let packages = [PythonPackage(name: "PyYAML", version: "6.0.2"), PythonPackage(name: "ruamel.yaml", version: "0.18.6"),
                        PythonPackage(name: "odd-names", version: "1.0")]
        #expect(PythonPreserver.importNames(in: env, packages: packages) == ["yaml", "_yaml", "spaced", "ruamel"])
    }

    // MARK: Using the copy

    struct Context {
        let sandbox: Sandbox
        let source: SimulationRoot
        let simulation: SimulationEnvironment
        let backup: URL
        let manifest: Manifest
        let analysis: PythonEnvironment
    }

    func backup(_ name: String) async throws -> Context {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        let environment = try source.environment
        var inventory = try await TestEnvironment.inventory(environment).run()
        let analysis = try #require(inventory.manifest.python.environments.first { $0.name == "analysis" })
        await inventory.preservePythonEnvironments([analysis.id], layout: environment.layout, runner: environment.makeRunner(),
                                                   workFolder: try sandbox.folder("work"))
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        var manifest = try ManifestIO.read(from: outcome.url)
        manifest.python.environments = manifest.python.environments.filter { $0.name == "analysis" }
        // Reinstalled on the same Mac: the environment is gone, its base interpreter is back.
        try FileManager.default.removeItem(at: source.url.appendingPathComponent("home/Projects/analysis/.venv"))
        return Context(sandbox: sandbox, source: source, simulation: environment, backup: outcome.url, manifest: manifest,
                       analysis: try #require(manifest.python.environments.first))
    }

    func restore(_ c: Context, manifest: Manifest? = nil, macOS: String = "15.0") async -> ItemResult? {
        var selection = RestoreSelection(components: [.python])
        selection.sourceChoices["python:\(c.analysis.id)"] = "preserve"
        let plan = pythonPlan(manifest ?? c.manifest)
        var environment = TestEnvironment.restoreEnvironment(c.simulation)
        environment.macOSVersion = macOS
        return await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
            .results["python:\(c.analysis.id)"]
    }

    @Test func theCopyIsUsedFromItsMinimumMacOSOn() async throws {
        let c = try await backup("py-copy-macos")
        var manifest = c.manifest
        manifest.python.environments[0].preservation?.minimumMacOS = "14.2"
        let older = try #require(await restore(c, manifest: manifest, macOS: "14.1.2"))
        #expect(older.notes.first == .pythonPreservationNotUsed(reason: .requiresNewerMacOS))
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent("home/Projects/analysis/.venv"))
        let same = try #require(await restore(c, manifest: manifest, macOS: "14.2"))
        #expect(same.notes.first == .pythonEnvironmentPreserved, "exactly the minimum is enough")
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent("home/Projects/analysis/.venv"))
        let newer = try #require(await restore(c, manifest: manifest, macOS: "15.1"))
        #expect(newer.notes.first == .pythonEnvironmentPreserved)
    }

    @Test func aRestoredCopyNamesOnlyPackagesThatNeedManualSetup() async throws {
        let c = try await backup("py-copy-notes")
        let plain = try #require(await restore(c))
        #expect(plain.outcome == .succeeded)
        #expect(plain.notes == [.pythonEnvironmentPreserved])
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent("home/Projects/analysis/.venv"))
        var manifest = c.manifest
        manifest.python.environments[0].packages.append(PythonPackage(name: "analysis", version: "0.1.0", origin: .editable))
        let withLocal = try #require(await restore(c, manifest: manifest))
        #expect(withLocal.outcome == .succeeded)
        #expect(withLocal.notes == [.pythonEnvironmentPreserved, .pythonPackagesNeedManualSetup(names: ["analysis"])])
    }
}

/// Application data and credentials: predictions, damaged backup files, replaced files and permissions.
@Suite("Application data and credential edge cases", .serialized)
struct DataRestoreEdgeTests {
    struct DataContext {
        let sandbox: Sandbox
        let backup: URL
        let folder: AppDataFolder
        let fresh: SimulationRoot
        let target: SimulationEnvironment
        var destination: URL { fresh.url.appendingPathComponent("home").appendingPathComponent(folder.relativePath) }
        var item: RestoreItem {
            var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
            manifest.applicationData = [folder]
            return RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData])).items.first!
        }
    }

    /// Two files of an application folder in a backup, and a new Mac.
    func dataContext(_ name: String) throws -> DataContext {
        let sandbox = try Sandbox(name)
        let backup = try sandbox.folder("backup")
        var records: [FileRecord] = []
        for (file, text) in [("a.txt", "first"), ("sub/b.txt", "second")] {
            let backupPath = "application-data/example/\(file)"
            let url = backup.appendingPathComponent(backupPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            records.append(FileRecord(fileName: URL(fileURLWithPath: file).lastPathComponent, domain: .user, relativePath: file,
                                      originalPath: "~/Library/Application Support/Example/\(file)", backupPath: backupPath,
                                      sha256: try Hashing.sha256Hex(ofFile: url), size: Int64(text.utf8.count)))
        }
        let folder = AppDataFolder(id: "example", name: "Example", relativePath: "Library/Application Support/Example", files: records)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        return DataContext(sandbox: sandbox, backup: backup, folder: folder, fresh: fresh, target: target)
    }

    func inspector(_ c: DataContext, damaged: Set<String> = []) -> Inspector {
        Inspector(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup,
                  selection: RestoreSelection(components: [.applicationData]), damagedFiles: damaged)
    }

    func write(_ text: String, _ file: String, in c: DataContext) throws {
        let url = c.destination.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func applicationDataPredictions() throws {
        let c = try dataContext("appdata-predict")
        #expect(inspector(c).predictApplicationData(c.item) == .willCopy)
        try write("first", "a.txt", in: c)
        #expect(inspector(c).predictApplicationData(c.item) == .willCopy, "one identical, one new")
        try write("second", "sub/b.txt", in: c)
        #expect(inspector(c).predictApplicationData(c.item) == .identicalFileExists)
        try write("changed", "sub/b.txt", in: c)
        #expect(inspector(c).predictApplicationData(c.item) == .conflict(resolution: .keepExisting))
        // A backup file the verification found damaged, or one that is missing, decides first.
        #expect(inspector(c, damaged: ["application-data/example/a.txt"]).predictApplicationData(c.item) == .backupFileDamaged)
        try FileManager.default.removeItem(at: c.backup.appendingPathComponent("application-data/example/sub/b.txt"))
        #expect(inspector(c).predictApplicationData(c.item) == .backupFileDamaged)
    }

    @Test func damagedBackupFilesAreNeverCopiedAndReportedOnce() async throws {
        let c = try dataContext("appdata-damaged")
        let selection = RestoreSelection(components: [.applicationData])
        let plan = RestorePlan(items: [c.item], manualApps: [])
        // The verification marked a.txt as damaged: it is not copied, even though its bytes still look right.
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil,
                                            damagedFiles: ["application-data/example/a.txt"])
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        let result = try #require(session.results.values.first)
        guard case .failed(let failure) = result.outcome else { Issue.record("not a failure: \(result.outcome)"); return }
        #expect(failure.technicalDetail == "1 of 2 files: a.txt")
        #expect(result.notes == [.applicationDataCopied(copied: 1, identical: 0, kept: 0)])
        #expect(!FileManager.default.fileExists(atPath: c.destination.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: c.destination.appendingPathComponent("sub/b.txt").path))
    }

    @Test func anAppIsRecognisedAsRunningByAnyOfItsBundleIdentifiers() async throws {
        var c = try dataContext("appdata-running")
        let selection = RestoreSelection(components: [.applicationData])
        var folder = c.folder
        folder.profile = AppDataProfileReference(provider: "example", appName: "Example Editor", category: "settings",
                                                 bundleIdentifiers: ["com.example.editor", "com.example.editor.beta"], mustBeClosed: true)
        c = DataContext(sandbox: c.sandbox, backup: c.backup, folder: folder, fresh: c.fresh, target: c.target)
        let plan = RestorePlan(items: [c.item], manualApps: [])
        var environment = TestEnvironment.restoreEnvironment(c.target)
        environment.isApplicationRunning = { $0 == "com.example.editor.beta" }
        let session = await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        guard case .failed(let failure)? = session.results.values.first?.outcome else { Issue.record("not a failure"); return }
        #expect(failure.category == .applicationRunning)
        #expect(failure.technicalDetail == "Example Editor (com.example.editor.beta) is running")
        #expect(!FileManager.default.fileExists(atPath: c.destination.path))
    }

    // MARK: Credentials

    static let passphrase = "synthetic edge passphrase"

    func credentialBackup(_ sandbox: Sandbox, files: [CredentialFile]) throws -> (URL, Manifest) {
        let backup = try sandbox.folder("backup")
        let vault = backup.appendingPathComponent("credentials/ssh.macreplica-vault")
        try FileManager.default.createDirectory(at: vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CredentialVault.seal(files, passphrase: Self.passphrase, iterations: 100_000).write(to: vault)
        var manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
        manifest.credentials = [CredentialRecord(provider: "ssh", items: files.map(\.name), vaultPath: "credentials/ssh.macreplica-vault")]
        return (backup, manifest)
    }

    func restoreCredentials(_ manifest: Manifest, backup: URL, on target: SimulationEnvironment,
                            resolution: ConflictResolution? = nil) async -> (ItemResult?, RestoreSession) {
        var selection = RestoreSelection(components: [.credentials])
        if let resolution { selection.conflictResolution = resolution }
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.credentialPassphrase = Self.passphrase
        let session = RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id))
        let result = await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: session, onEvent: { _ in })
        return (result.results["credential:ssh"], session)
    }

    func permissions(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    @Test func credentialFilesKeepTheirPermissionsAndAreNeverLeftUnreadable() async throws {
        let sandbox = try Sandbox("cred-permissions")
        let files = [CredentialFile(name: "id_ed25519", permissions: 0o600, contents: Data("synthetic-key".utf8)),
                     CredentialFile(name: "id_ed25519.pub", permissions: 0o644, contents: Data("ssh-ed25519 AAAAsynthetic".utf8)),
                     CredentialFile(name: "config", permissions: 0, contents: Data("Host example\n".utf8))]
        let (backup, manifest) = try credentialBackup(sandbox, files: files)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let (result, _) = await restoreCredentials(manifest, backup: backup, on: target)
        #expect(result?.outcome == .succeeded)
        #expect(result?.notes == [.applicationDataCopied(copied: 3, identical: 0, kept: 0)])
        let ssh = fresh.url.appendingPathComponent("home/.ssh")
        #expect(try permissions(ssh.appendingPathComponent("id_ed25519")) == 0o600)
        #expect(try permissions(ssh.appendingPathComponent("id_ed25519.pub")) == 0o644, "the public key stays readable")
        #expect(try permissions(ssh.appendingPathComponent("config")) == 0o600, "no recorded permissions: private")
    }

    @Test func replacedCredentialFilesAreMovedAsideIntoOneFolder() async throws {
        let sandbox = try Sandbox("cred-replace")
        let files = [CredentialFile(name: "config", permissions: 0o600, contents: Data("Host example\n".utf8)),
                     CredentialFile(name: "id_ed25519", permissions: 0o600, contents: Data("synthetic-key".utf8)),
                     CredentialFile(name: "known_hosts", permissions: 0o644, contents: Data("example.com ssh-ed25519 AAAA\n".utf8))]
        let (backup, manifest) = try credentialBackup(sandbox, files: files)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let ssh = fresh.url.appendingPathComponent("home/.ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("Host other\n".utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("other-key".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        try Data("example.com ssh-ed25519 AAAA\n".utf8).write(to: ssh.appendingPathComponent("known_hosts"))
        let (result, session) = await restoreCredentials(manifest, backup: backup, on: target, resolution: .replace)
        let aside = target.layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/ssh")
        #expect(result?.outcome == .succeeded)
        #expect(result?.notes == [.existingFileMovedAside(path: target.layout.displayPath(aside)),
                                  .applicationDataCopied(copied: 2, identical: 1, kept: 0)], "one note for the folder, not one per file")
        #expect(try String(contentsOf: aside.appendingPathComponent("config"), encoding: .utf8) == "Host other\n")
        #expect(try String(contentsOf: aside.appendingPathComponent("id_ed25519"), encoding: .utf8) == "other-key")
        #expect(try String(contentsOf: ssh.appendingPathComponent("id_ed25519"), encoding: .utf8) == "synthetic-key")
    }
}
