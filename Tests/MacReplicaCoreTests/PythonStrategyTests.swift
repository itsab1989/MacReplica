import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The saved-copy strategy for Python environments, on top of the existing rebuild.
@Suite("Python environment strategies", .serialized)
struct PythonStrategyTests {
    struct Context {
        let sandbox: Sandbox
        let source: SimulationRoot
        let sourceEnvironment: SimulationEnvironment
        let backup: URL
        let manifest: Manifest
        let analysis: PythonEnvironment
    }

    func backup(_ name: String, preserve: Bool = true, prepare: (SimulationRoot) throws -> Void = { _ in }) async throws -> Context {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        try prepare(source)
        let environment = try source.environment
        var inventory = try await TestEnvironment.inventory(environment).run()
        let analysis = try #require(inventory.manifest.python.environments.first { $0.name == "analysis" })
        if preserve {
            await inventory.preservePythonEnvironments([analysis.id], layout: environment.layout, runner: environment.makeRunner(),
                                                       workFolder: try sandbox.folder("work"))
        }
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        let manifest = try ManifestIO.read(from: outcome.url)
        return Context(sandbox: sandbox, source: source, sourceEnvironment: environment, backup: outcome.url, manifest: manifest,
                       analysis: try #require(manifest.python.environments.first { $0.name == "analysis" }))
    }

    func restore(_ c: Context, on target: SimulationEnvironment, preserve: Bool = true, architecture: CPUArchitecture = .arm64) async -> ItemResult? {
        var selection = RestoreSelection(components: [.python])
        if preserve { selection.sourceChoices["python:\(c.analysis.id)"] = "preserve" }
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, architecture: architecture), backupRoot: c.backup,
                                            sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        return session.results["python:\(c.analysis.id)"]
    }

    var envPath: String { "home/Projects/analysis/.venv" }

    @Test func theSavedCopyIsRecordedWithoutSecrets() async throws {
        let c = try await backup("py-copy-record")
        let preservation = try #require(c.analysis.preservation)
        #expect(preservation.archivePath == "development/python/\(c.analysis.id)/environment.zip")
        #expect(preservation.nativeArchitectures.isEmpty, "pure Python")
        let archive = c.backup.appendingPathComponent(preservation.archivePath)
        #expect(try Hashing.sha256Hex(ofFile: archive) == preservation.sha256)
        let sums = try String(contentsOf: c.backup.appendingPathComponent("checksums/SHA256SUMS"), encoding: .utf8)
        #expect(sums.contains(preservation.archivePath), "the copy is part of the verified backup")
        let json = try String(contentsOf: c.backup.appendingPathComponent(ManifestIO.fileName), encoding: .utf8)
        #expect(!json.contains(c.source.url.path), "the home folder is stored as a salted hash only")
        #expect(BackupVerifier(layout: c.sourceEnvironment.layout).verify(backupAt: c.backup).isUsable)
    }

    @Test func sameMacSameUserRestoresTheVerifiedCopy() async throws {
        let c = try await backup("py-copy-same")
        let original = c.source.url.appendingPathComponent(envPath)
        let before = try FileManager.default.contentsOfDirectory(atPath: original.appendingPathComponent("lib/python3.12/site-packages").path).sorted()
        // macOS was reinstalled on the same Mac: the environment is gone, the Python installation is back.
        try FileManager.default.removeItem(at: original)
        c.source.clearCalls()
        let result = try #require(await restore(c, on: c.sourceEnvironment))
        #expect(result.outcome == .succeeded)
        #expect(result.notes.contains(.pythonEnvironmentPreserved))
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.appendingPathComponent("lib/python3.12/site-packages").path).sorted() == before)
        #expect(!c.source.calls().contains { $0.contains("-m venv") && $0.contains("analysis") }, "not rebuilt")
        #expect(c.source.calls().contains { $0.contains("MACREPLICA_PROBE") || $0.hasPrefix("python -I -c") }, "verified by running the environment")
    }

    @Test func anotherHomeFolderFallsBackToTheRebuild() async throws {
        let c = try await backup("py-copy-other")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try FileManager.default.createDirectory(at: fresh.url.appendingPathComponent("home/Projects/analysis"), withIntermediateDirectories: true)
        let result = try #require(await restore(c, on: target))
        #expect(result.notes.first == .pythonPreservationNotUsed(reason: .differentHomeFolder))
        #expect(result.outcome == .succeeded, "rebuilt from the package list")
        #expect(fresh.calls().contains { $0.contains("-m venv") && $0.contains("analysis") })
    }

    @Test func aCopyThatFailsVerificationIsRemovedAndRebuilt() async throws {
        let c = try await backup("py-copy-broken")
        let original = c.source.url.appendingPathComponent(envPath)
        try FileManager.default.removeItem(at: original)
        try c.source.setFlag("python/import-fails/yaml", true)
        let result = try #require(await restore(c, on: c.sourceEnvironment))
        #expect(result.notes.first == .pythonPreservationNotUsed(reason: .verificationFailed))
        #expect(result.outcome == .succeeded)
        #expect(c.source.calls().contains { $0.contains("-m venv") && $0.contains("analysis") }, "the proven rebuild ran")
    }

    @Test func nativeCodeForAnotherProcessorIsNotRestored() async throws {
        let c = try await backup("py-copy-arch") { source in
            let so = source.url.appendingPathComponent("home/Projects/analysis/.venv/lib/python3.12/site-packages/fastmath.cpython-312-darwin.so")
            try SimulationBuilder.machOHeader([.x86_64]).write(to: so)
        }
        #expect(c.analysis.preservation?.nativeArchitectures == [.x86_64])
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent(envPath))
        let result = try #require(await restore(c, on: c.sourceEnvironment, architecture: .arm64))
        #expect(result.notes.first == .pythonPreservationNotUsed(reason: .incompatibleArchitecture))
    }

    @Test func environmentsWithCredentialFilesAreNotCopied() async throws {
        let c = try await backup("py-copy-secret") { source in
            try Data("-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic\n".utf8)
                .write(to: source.url.appendingPathComponent("home/Projects/analysis/.venv/id_rsa"))
        }
        #expect(c.analysis.preservation == nil)
        #expect(c.manifest.backupIssues.contains { $0.reason == .refusedSensitive && $0.path.hasSuffix("id_rsa") })
    }

    @Test func withoutAChoiceTheExistingRebuildIsUsed() async throws {
        let c = try await backup("py-copy-default")
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent(envPath))
        let result = try #require(await restore(c, on: c.sourceEnvironment, preserve: false))
        #expect(result.outcome == .succeeded)
        #expect(!result.notes.contains(.pythonEnvironmentPreserved))
        #expect(!result.notes.contains { if case .pythonPreservationNotUsed = $0 { return true }; return false })
    }

    @Test func aRebuiltEnvironmentThatDoesNotRunIsAFailure() async throws {
        let c = try await backup("py-rebuild-broken", preserve: false)
        try FileManager.default.removeItem(at: c.source.url.appendingPathComponent(envPath))
        try c.source.setFlag("python/probe-broken", true)
        let result = try #require(await restore(c, on: c.sourceEnvironment, preserve: false))
        guard case .failed(let failure) = result.outcome else { Issue.record("reported as \(result.outcome)"); return }
        #expect(failure.category == .verificationFailed, "never reported as restored when its Python does not run")
    }

    @Test func probeParsingAndVerificationRules() {
        let environment = PythonEnvironment(id: "e", name: "e", path: "~/p/.venv", manager: .venv, pythonVersion: "3.12.7", baseInterpreter: nil,
                                            baseSource: .homebrew, packages: [PythonPackage(name: "PyYAML", version: "6.0.2")], requirementsPath: "r")
        let target = URL(fileURLWithPath: "/tmp/p/.venv")
        let good = PythonPreserver.ProbeResult(version: "3.12.4", prefix: "/tmp/p/.venv", machine: "arm64", dists: ["pyyaml": "6.0.2"], failed: [])
        #expect(PythonPreserver.verify(good, environment: environment, target: target), "patch versions are compatible")
        var wrongPrefix = good; wrongPrefix.prefix = "/tmp/other/.venv"
        var wrongMinor = good; wrongMinor.version = "3.11.9"
        var missing = good; missing.dists = [:]
        var older = good; older.dists = ["pyyaml": "5.4"]
        var importFails = good; importFails.failed = ["yaml"]
        for probe in [wrongPrefix, wrongMinor, missing, older, importFails] {
            #expect(!PythonPreserver.verify(probe, environment: environment, target: target))
        }
        #expect(PythonPreserver.parseProbe("warning\n{\"version\":\"3.12.7\",\"prefix\":\"/x\",\"machine\":\"arm64\",\"dists\":{},\"failed\":[]}") != nil)
        #expect(PythonPreserver.parseProbe("Traceback (most recent call last):") == nil)
    }

    @Test func machOMinimumMacOS() throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        if FileManager.default.fileExists(atPath: binary.path), let version = MachO.minimumMacOS(ofFile: binary) {
            #expect(VersionComparison.compare(version, "11.0") != .orderedAscending)
        }
        #expect(MachO.decode(0x000D_0000) == "13.0")
        #expect(MachO.decode(0x000E_0201) == "14.2.1")
        let sandbox = try Sandbox("macho-min")
        let file = try sandbox.file("x.so", "not a Mach-O file")
        #expect(MachO.minimumMacOS(ofFile: file) == nil)
    }
}

/// The saved-copy strategy with a real Python (the Command Line Tools' interpreter), in a sandbox.
@Suite("Python saved copy with a real interpreter", .serialized,
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")))
struct RealPythonPreservationTests {
    static let python = "/Library/Developer/CommandLineTools/usr/bin/python3"

    func makeEnvironment(_ sandbox: Sandbox) throws -> (SystemLayout, URL) {
        let layout = toolchainLayout(sandbox)
        let env = layout.homeDirectory.appendingPathComponent("Projects/demo/.venv")
        try FileManager.default.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        let create = Process()
        create.executableURL = URL(fileURLWithPath: Self.python)
        create.arguments = ["-m", "venv", "--without-pip", env.path]
        try create.run()
        create.waitUntilExit()
        try #require(create.terminationStatus == 0)
        // A small pure-Python package with metadata, as pip would install it.
        let site = try #require(PythonScanner.sitePackages(in: env))
        try FileManager.default.createDirectory(at: site.appendingPathComponent("demopkg"), withIntermediateDirectories: true)
        try Data("VALUE = 42\n".utf8).write(to: site.appendingPathComponent("demopkg/__init__.py"))
        let info = site.appendingPathComponent("demopkg-1.2.3.dist-info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try Data("Metadata-Version: 2.1\nName: demopkg\nVersion: 1.2.3\n".utf8).write(to: info.appendingPathComponent("METADATA"))
        try Data("demopkg\n".utf8).write(to: info.appendingPathComponent("top_level.txt"))
        return (layout, env)
    }

    func restore(_ manifest: Manifest, environmentID: String, layout: SystemLayout, backup: URL) async -> ItemResult? {
        var selection = RestoreSelection(components: [.python])
        selection.sourceChoices["python:\(environmentID)"] = "preserve"
        let plan = RestorePlan(items: RestorePlanner().plan(manifest: manifest, selection: selection).items.filter { $0.kind == .pythonEnvironment }, manualApps: [])
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                          baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
        let environment = RestoreEnvironment(layout: layout, runner: runner, privileged: DirectPrivilegedExecutor(),
                                             homebrewSource: LocalHomebrewPackageSource(package: backup), localizer: TestEnvironment.english,
                                             log: LogStore(fileURL: nil, homeDirectory: layout.homeDirectory))
        let session = await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        return session.results["python:\(environmentID)"]
    }

    @Test func aRealEnvironmentComesBackFromItsCopyAndRuns() async throws {
        let sandbox = try Sandbox("real-python")
        let (layout, env) = try makeEnvironment(sandbox)
        var manifest = Manifest(macreplicaVersion: "test", createdAt: Date(), macosVersion: SystemInfo.macOSVersion, architecture: SystemInfo.currentArchitecture)
        let scanned = try #require(PythonScanner(layout: layout).readEnvironment(at: env))
        manifest.python.environments = [scanned.0]
        let keys = HardwareKeys.make(platformIdentifier: nil)
        manifest.hardwareKeys = keys
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        guard case .preserved(let file, let preservation) = try await PythonPreserver.preserve(scanned.0, layout: layout, runner: runner,
                                                                                            workFolder: try sandbox.folder("work"), keys: keys) else {
            Issue.record("not preserved"); return
        }
        manifest.python.environments[0].preservation = preservation
        let backup = try sandbox.folder("backup")
        let archive = backup.appendingPathComponent(preservation.archivePath)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file.url, to: archive)

        // Reinstall: the environment is gone, the same Python installation is there.
        try FileManager.default.removeItem(at: env)
        let result = try #require(await restore(manifest, environmentID: scanned.0.id, layout: layout, backup: backup))
        #expect(result.outcome == .succeeded, "\(result.outcome) \(result.notes)")
        #expect(result.notes.contains(.pythonEnvironmentPreserved))
        // The real interpreter of the restored environment imports the package.
        let check = Process()
        check.executableURL = env.appendingPathComponent("bin/python")
        check.arguments = ["-I", "-c", "import demopkg, sys; assert demopkg.VALUE == 42; print(sys.prefix)"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        let prefix = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path == env.resolvingSymlinksInPath().path)

        // In another home folder the copy is not used (its paths would point to the old one).
        let other = try Sandbox("real-python-other")
        let otherLayout = toolchainLayout(other)
        try FileManager.default.createDirectory(at: otherLayout.homeDirectory.appendingPathComponent("Projects/demo"), withIntermediateDirectories: true)
        let elsewhere = try #require(await restore(manifest, environmentID: scanned.0.id, layout: otherLayout, backup: backup))
        #expect(elsewhere.notes.first == .pythonPreservationNotUsed(reason: .differentHomeFolder))
        #expect(!FileManager.default.fileExists(atPath: otherLayout.homeDirectory.appendingPathComponent("Projects/demo/.venv/lib").path) || elsewhere.outcome.isSuccessLike)
    }
}
