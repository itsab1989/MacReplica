import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Python environments", .serialized)
struct PythonTests {
    @Test func scannerFindsInterpretersEnvironmentsAndSafeSettingsOnly() throws {
        let sandbox = try Sandbox("py-scan")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        // An environment inside Documents must not be found unless the user adds the folder.
        let documents = root.url.appendingPathComponent("home/Documents/hidden-project/.venv")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("version = 3.12.1\n".utf8).write(to: documents.appendingPathComponent("pyvenv.cfg"))

        let scan = PythonScanner(layout: simulation.layout).scan()
        let snapshot = scan.snapshot
        #expect(snapshot.installations == [PythonInstallation(version: "3.12.7", executable: "/opt/homebrew/opt/python@3.12/bin/python3.12",
                                                              source: .homebrew, architectures: [])])
        #expect(snapshot.environments.map(\.name).sorted() == ["demo-app", "tools"])
        let demo = try #require(snapshot.environments.first { $0.name == "demo-app" })
        #expect(demo.path == "~/Projects/demo-app/.venv")
        #expect(demo.manager == .venv)
        #expect(demo.pythonVersion == "3.12.7")
        #expect(demo.baseSource == .homebrew)
        #expect(demo.architectures == [.arm64])
        #expect(demo.pipVersion == "24.2")
        #expect(demo.installablePackages.map(\.name) == ["requests", "rich", "urllib3"])
        #expect(demo.manualPackages.map(\.origin) == [.editable, .vcs])
        #expect(demo.projectFiles.map(\.fileName) == ["pyproject.toml", "requirements.txt"], "source code is never copied")
        let tools = try #require(snapshot.environments.first { $0.name == "tools" })
        #expect(tools.manager == .virtualenvwrapper)
        #expect(tools.projectFiles.isEmpty)
        // Only allow-listed, non-secret settings.
        #expect(snapshot.settings == [PythonSetting(key: "PIP_REQUIRE_VIRTUALENV", value: "true", source: "~/.zshrc"),
                                      PythonSetting(key: "WORKON_HOME", value: "~/.virtualenvs", source: "~/.zshrc")])
        let json = String(decoding: try ManifestIO.encode(Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15",
                                                                    architecture: .arm64, python: snapshot)), as: UTF8.self)
        #expect(!json.contains("sk-synthetic"))
        #expect(!json.contains("example.internal"), "VCS URLs of private packages are not recorded")
        #expect(!json.contains("user:pass"))
        #expect(!json.contains(simulation.layout.homeDirectory.path))

        let extra = PythonScanner(layout: simulation.layout, extraRoots: [root.url.appendingPathComponent("home/Documents")]).scan()
        #expect(extra.snapshot.environments.contains { $0.name == "hidden-project" })
    }

    @Test func metadataAndConfigParsing() {
        #expect(PythonScanner.parseMetadata("Metadata-Version: 2.1\nName: Foo_Bar\nVersion: 1.0\n\nName: ignored") ?? ("", "") == ("Foo_Bar", "1.0"))
        #expect(PythonScanner.parseMetadata("Version: 1.0\n") == nil)
        #expect(PythonScanner.parseConfig("home = /opt/x\nversion=3.11.2\nbroken line\n") == ["home": "/opt/x", "version": "3.11.2"])
        #expect(PythonScanner.parseDirectURL(Data(#"{"url": "file:///x", "dir_info": {"editable": true}}"#.utf8)) == .editable)
        #expect(PythonScanner.parseDirectURL(Data(#"{"url": "https://x", "vcs_info": {}}"#.utf8)) == .vcs)
        #expect(PythonScanner.parseDirectURL(Data(#"{"url": "file:///x.whl", "archive_info": {}}"#.utf8)) == .local)
        #expect(PythonScanner.parseDirectURL(Data("nope".utf8)) == .local)
        #expect(PythonPackage.normalize("Foo__Bar.baz") == "foo-bar-baz")
        #expect(PythonVersion.minor("3.12.7") == "3.12")
        #expect(PythonVersion.formula(forMinor: "3.11") == "python@3.11")
        #expect(PythonScanner.stripRevision("3.12.7_1") == "3.12.7")
        #expect(PythonSource.from(path: "/Users/x/.pyenv/versions/3.11.4/bin") == .pyenv)
        #expect(PythonSource.from(path: "/Library/Frameworks/Python.framework/Versions/3.12/bin") == .pythonOrg)
        #expect(PythonSource.from(path: "/usr/local/opt/python@3.12/bin") == .homebrew)
        #expect(PythonSource.from(path: "/usr/bin") == .system)
        #expect(PythonSource.from(path: "/somewhere") == .unknown)
    }

    @Test func settingsParserRejectsSecretsAndCommands() {
        var layout = SystemLayout.live()
        layout.homeDirectory = URL(fileURLWithPath: "/Users/jane")
        let text = """
        export PYENV_ROOT="/Users/jane/.pyenv"   # comment
        export PIPENV_VENV_IN_PROJECT=1
        export PYENV_VERSION=$(cat x)
        export WORKON_HOME=git@host:x
        export GITHUB_TOKEN=abc
          export PYTHONUNBUFFERED='1'
        """
        #expect(PythonScanner.parseSettings(text, source: "~/.zshrc", layout: layout) == [
            PythonSetting(key: "PYENV_ROOT", value: "~/.pyenv", source: "~/.zshrc"),
            PythonSetting(key: "PIPENV_VENV_IN_PROJECT", value: "1", source: "~/.zshrc"),
            PythonSetting(key: "PYTHONUNBUFFERED", value: "1", source: "~/.zshrc"),
        ])
    }

    @Test func requirementsFileListsOnlyReinstallablePackages() {
        let environment = PythonEnvironment(id: "env-1", name: "x", path: "~/x", manager: .venv, pythonVersion: "3.12.1", baseInterpreter: nil,
                                            baseSource: .homebrew, packages: [
                                                PythonPackage(name: "Zeta", version: "1"), PythonPackage(name: "alpha", version: "2"),
                                                PythonPackage(name: "pip", version: "24"), PythonPackage(name: "mine", version: "0.1", origin: .editable),
                                            ], requirementsPath: "development/python/env-1/requirements.txt")
        #expect(environment.requirementsText(header: "Header\nline 2") ==
                "# Header\n# line 2\nalpha==2\nZeta==1\n# mine==0.1 (editable, not reinstallable automatically)\n")
    }

    @Test func requirementSafety() {
        #expect(RestoreExecutor.isSafeRequirement(PythonPackage(name: "zope.interface", version: "6.0")))
        #expect(RestoreExecutor.isSafeRequirement(PythonPackage(name: "torch", version: "2.4.0+cpu")))
        #expect(!RestoreExecutor.isSafeRequirement(PythonPackage(name: "--index-url", version: "1")))
        #expect(!RestoreExecutor.isSafeRequirement(PythonPackage(name: "x", version: "1 ; rm")))
        #expect(!RestoreExecutor.isSafeRequirement(PythonPackage(name: "-e", version: "git+https://x")))
    }

    func restore(_ sandbox: Sandbox, prepare: (SimulationRoot) throws -> Void = { _ in }) async throws -> (RestoreSession, SimulationRoot, Manifest) {
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try prepare(fresh)
        let selection = RestoreSelection(components: [.python])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        return (session, fresh, manifest)
    }

    func id(_ manifest: Manifest, _ name: String) -> String {
        "python:" + (manifest.python.environments.first { $0.name == name }?.id ?? "?")
    }

    @Test func environmentsAreRebuiltAndVerified() async throws {
        let sandbox = try Sandbox("py-restore")
        let (session, fresh, manifest) = try await restore(sandbox)
        #expect(session.results["formula:python@3.12"]?.outcome == .succeeded)
        let demo = try #require(session.results[id(manifest, "demo-app")])
        #expect(demo.outcome == .succeeded)
        #expect(demo.notes == [.pythonPackagesNeedManualSetup(names: ["demo-app", "private-lib"])])
        let tools = try #require(session.results[id(manifest, "tools")])
        #expect(tools.outcome == .succeeded, "the virtualenvwrapper folder is created when missing")
        let site = fresh.url.appendingPathComponent("home/Projects/demo-app/.venv/lib/python3.12/site-packages")
        let installed = PythonScanner.readPackages(sitePackages: site).map { "\($0.name)==\($0.version)" }
        #expect(installed.contains("requests==2.32.3") && installed.contains("rich==13.9.2") && installed.contains("urllib3==2.2.3"))
        let calls = fresh.calls()
        #expect(calls.contains { $0.hasPrefix("python -m venv") })
        #expect(calls.contains { $0.contains("-m pip --python") && $0.contains("requests==2.32.3") })
    }

    @Test func missingProjectFolderIsSkippedWithAClearReason() async throws {
        let sandbox = try Sandbox("py-noproject")
        let (session, _, manifest) = try await restore(sandbox) { fresh in
            try FileManager.default.removeItem(at: fresh.url.appendingPathComponent("home/Projects/demo-app"))
        }
        #expect(session.results[id(manifest, "demo-app")]?.outcome == .skipped(.projectFolderMissing(path: "~/Projects/demo-app")))
        #expect(session.results[id(manifest, "tools")]?.outcome == .succeeded)
    }

    @Test func unavailablePackageVersionsFallBackToCurrentOnesTransparently() async throws {
        let sandbox = try Sandbox("py-newer")
        let (session, _, manifest) = try await restore(sandbox) { fresh in
            try fresh.setFlag("pip/latest/rich", true, content: "14.0.0")
        }
        let demo = try #require(session.results[id(manifest, "demo-app")])
        #expect(demo.outcome == .succeeded)
        #expect(demo.notes.contains(.pythonPackagesUpdated(count: 1)))
    }

    @Test func packagesThatCannotBeInstalledAreReportedNotHidden() async throws {
        let sandbox = try Sandbox("py-missing")
        let (session, _, manifest) = try await restore(sandbox) { fresh in
            try fresh.setFlag("pip/missing/rich", true)
        }
        guard case .failed(let failure) = session.results[id(manifest, "demo-app")]?.outcome else {
            Issue.record("expected failure"); return
        }
        #expect(failure.category == .pythonPackagesIncomplete)
        #expect(failure.technicalDetail.contains("missing: rich"))
        #expect(session.results[id(manifest, "tools")]?.outcome == .succeeded, "other environments continue")
    }

    @Test func offlinePackageInstallIsANetworkFailure() async throws {
        let sandbox = try Sandbox("py-offline")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.python])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        // Homebrew and Python install fine; only the package downloads fail.
        let prerequisites = plan.subset(retrying: ["formula:python@3.12"])
        _ = await executor.run(plan: prerequisites, session: RestoreSession(backupPath: "", selection: selection, itemIDs: prerequisites.items.map(\.id)),
                               onEvent: { _ in })
        try fresh.setOffline(true)
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)),
                                         onEvent: { _ in })
        #expect(session.results[id(manifest, "demo-app")]?.outcome.label == "failed(network)")
    }

    @Test func existingEnvironmentsAreReusedOrLeftAlone() async throws {
        let sandbox = try Sandbox("py-existing")
        let (session, fresh, manifest) = try await restore(sandbox) { fresh in
            // A compatible environment with one package already installed.
            let env = fresh.url.appendingPathComponent("home/Projects/demo-app/.venv")
            try FileManager.default.createDirectory(at: env.appendingPathComponent("lib/python3.12/site-packages/requests-2.32.3.dist-info"),
                                                    withIntermediateDirectories: true)
            try Data("version = 3.12.2\n".utf8).write(to: env.appendingPathComponent("pyvenv.cfg"))
            try Data("Name: requests\nVersion: 2.32.3\n".utf8)
                .write(to: env.appendingPathComponent("lib/python3.12/site-packages/requests-2.32.3.dist-info/METADATA"))
            // Like every real environment, it has its own working interpreter.
            try FileManager.default.createDirectory(at: env.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/python"), to: env.appendingPathComponent("bin/python"))
            // A different Python version where the second environment belongs.
            let other = fresh.url.appendingPathComponent("home/.virtualenvs/tools")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("version = 3.9.1\n".utf8).write(to: other.appendingPathComponent("pyvenv.cfg"))
        }
        let demo = try #require(session.results[id(manifest, "demo-app")])
        #expect(demo.outcome == .succeeded)
        #expect(demo.notes.contains(.pythonEnvironmentReused))
        #expect(!fresh.calls().contains { $0.contains("-m venv") && $0.contains("demo-app") })
        #expect(session.results[id(manifest, "tools")]?.outcome.label == "failed(pythonEnvironmentConflict)")
        #expect(try String(contentsOf: fresh.url.appendingPathComponent("home/.virtualenvs/tools/pyvenv.cfg"), encoding: .utf8) == "version = 3.9.1\n")
    }

    @Test func missingPythonVersionIsReported() async throws {
        let sandbox = try Sandbox("py-noversion")
        let (session, _, manifest) = try await restore(sandbox) { fresh in
            try FileManager.default.removeItem(at: fresh.state.appendingPathComponent("brew/available/formulae/python@3.12"))
        }
        #expect(session.results["formula:python@3.12"]?.outcome.label == "failed(packageNotFound)")
        #expect(session.results[id(manifest, "demo-app")]?.outcome == .skipped(.dependencyFailed(itemTitle: "Python 3.12")))
    }

    @Test func dryRunDescribesPythonWithoutTouchingAnything() async throws {
        let sandbox = try Sandbox("py-dry")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.python])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .dryRun(plan: plan, selection: selection)
        #expect(entries.first { $0.item.id == id(manifest, "demo-app") }?.prediction == .dependsOnEarlierStep)
        #expect(!fresh.calls().contains { $0.hasPrefix("python") })
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/Projects/demo-app/.venv").path))
    }

    @Test func plannerAddsRuntimesAndRespectsExclusions() {
        var manifest = ManifestTests.sample()
        let environment = PythonEnvironment(id: "env-a", name: "a", path: "~/a/.venv", manager: .venv, pythonVersion: "3.11.9",
                                            baseInterpreter: nil, baseSource: .pyenv, requirementsPath: "development/python/env-a/requirements.txt")
        manifest.python = PythonSnapshot(environments: [environment])
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.python]))
        #expect(plan.items.map(\.id) == [RestoreItem.commandLineToolsID, RestoreItem.homebrewID, "formula:python@3.11", "python:env-a"])
        #expect(plan.item(id: "python:env-a")?.dependsOn == ["formula:python@3.11"])
        let excluded = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.python], excludedItemIDs: ["python:env-a"]))
        #expect(excluded.items.isEmpty, "the runtime is dropped when no environment needs it")
    }

    @Test func selectingEnvironmentsForTheBackup() async throws {
        let sandbox = try Sandbox("py-select")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        var result = try await TestEnvironment.inventory(source).run()
        let demo = try #require(result.manifest.python.environments.first { $0.name == "demo-app" })
        result.keepPythonEnvironments([demo.id], includeSettings: false)
        #expect(result.manifest.python.environments.map(\.name) == ["demo-app"])
        #expect(result.manifest.python.settings.isEmpty)
        result.keepPythonEnvironments([], includeSettings: false)
        #expect(!result.extraFiles.contains { $0.record.backupPath.hasPrefix("development/python/") })
    }
}

@Suite("Application data", .serialized)
struct ApplicationDataTests {
    @Test func refusesBroadAndSensitiveLocations() throws {
        let sandbox = try Sandbox("appdata-refuse")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let scanner = AppDataScanner(layout: simulation.layout)
        let home = root.url.appendingPathComponent("home")
        for (path, expected) in [("Library", AppDataError.wholeHomeOrLibrary), ("Library/Application Support", .wholeHomeOrLibrary),
                                 ("Library/Keychains", .sensitiveLocation("Library/Keychains")), (".ssh", .sensitiveLocation(".ssh")),
                                 ("Library/Mail/V10", .sensitiveLocation("Library/Mail"))] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
            #expect(throws: expected) { _ = try scanner.validate(home.appendingPathComponent(path)) }
        }
        #expect(throws: AppDataError.outsideHome) { _ = try scanner.validate(root.url.appendingPathComponent("Applications")) }
        #expect(throws: AppDataError.notAFolder) { _ = try scanner.validate(home.appendingPathComponent(".zshrc")) }
        for name in ["login.keychain-db", "id_ed25519", "server.pem", "Cookies", "api-token.json", ".env", ".netrc", "secrets.yaml"] {
            #expect(AppDataScanner.isRefusedFile(name), "\(name)")
        }
        for name in ["settings.json", "Letter.tmpl", "tokenizer.json", "presets.plist"] {
            #expect(!AppDataScanner.isRefusedFile(name), "\(name)")
        }
    }

    @Test func backupAndRestoreOfApplicationData() async throws {
        let sandbox = try Sandbox("appdata-roundtrip")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        var result = try await TestEnvironment.inventory(source).run()
        let folder = root.url.appendingPathComponent("home/Library/Application Support/Example Editor")
        let scan = try AppDataScanner(layout: source.layout).scan(folder)
        #expect(scan.folder.files.map(\.relativePath) == ["Templates/Letter.tmpl", "settings.json"])
        #expect(Set(scan.issues.map(\.reason)) == [.refusedSensitive])
        #expect(scan.issues.count == 2)
        let detected = result.manifest.applicationData.count
        result.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        result.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
        #expect(result.manifest.applicationData.count == detected + 1, "adding twice replaces")

        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("out"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        #expect(outcome.isComplete, "files left out on purpose do not make the backup partial")
        #expect(outcome.manifest.excludedSensitiveFiles.count == 2)
        #expect(FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent("application-data/\(scan.folder.id)/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent("application-data/\(scan.folder.id)/token.json").path))

        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let destination = fresh.url.appendingPathComponent("home/Library/Application Support/Example Editor")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"theme": "light"}"#.utf8).write(to: destination.appendingPathComponent("settings.json"))
        let selection = RestoreSelection(components: [.applicationData])
        let full = RestorePlanner().plan(manifest: outcome.manifest, selection: selection)
        let plan = RestorePlan(items: full.items.filter { $0.id == "appdata:\(scan.folder.id)" }, manualApps: [])
        #expect(plan.items.count == 1)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
        let dry = await executor.dryRun(plan: plan, selection: selection)
        #expect(dry.first?.prediction == .conflict(resolution: .keepExisting))
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)),
                                         onEvent: { _ in })
        #expect(session.results.values.first?.notes == [.applicationDataCopied(copied: 1, identical: 0, kept: 1)])
        #expect(try String(contentsOf: destination.appendingPathComponent("settings.json"), encoding: .utf8) == #"{"theme": "light"}"#)
        #expect(try String(contentsOf: destination.appendingPathComponent("Templates/Letter.tmpl"), encoding: .utf8) == "synthetic template")

        // Replacing keeps the old file aside.
        var replace = selection
        replace.conflictResolution = .replace
        let second = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: replace, itemIDs: plan.items.map(\.id)),
                                        onEvent: { _ in })
        #expect(second.results.values.first?.notes == [.applicationDataCopied(copied: 1, identical: 1, kept: 0)])
        #expect(try String(contentsOf: destination.appendingPathComponent("settings.json"), encoding: .utf8) == #"{"theme": "dark"}"#)
        // Third time: everything identical.
        let third = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: replace, itemIDs: plan.items.map(\.id)),
                                       onEvent: { _ in })
        #expect(third.results.values.first?.outcome == .alreadyPresent)

        result.removeApplicationData(id: scan.folder.id)
        #expect(result.manifest.applicationData.count == detected)
        #expect(result.manifest.backupIssues.isEmpty)
        #expect(!result.extraFiles.contains { $0.record.backupPath.hasPrefix("application-data/\(scan.folder.id)/") })
    }
}

@Suite("Backup package and diagnostics", .serialized)
struct PackageAndDiagnosticsTests {
    @Test func backupFolderIsSelfContainedAndDocumented() async throws {
        let sandbox = try Sandbox("package")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        for path in ["README.txt", "manifest.json", "manifest.json.sha256", "restore/RESTORE_INSTRUCTIONS.html", "reports/inventory.html",
                     "reports/manual_installations.html", "checksums/SHA256SUMS", "logs/inventory.log"] {
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent(path).path), "\(path)")
        }
        let demo = try #require(manifest.python.environments.first { $0.name == "demo-app" })
        let requirements = try String(contentsOf: backup.appendingPathComponent(demo.requirementsPath), encoding: .utf8)
        #expect(requirements.contains("requests==2.32.3\nrich==13.9.2\nurllib3==2.2.3\n"))
        #expect(requirements.contains("# demo-app==0.1.0 (editable"))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("development/python/\(demo.id)/project/pyproject.toml").path))
        let sums = try String(contentsOf: backup.appendingPathComponent("checksums/SHA256SUMS"), encoding: .utf8)
        #expect(sums.contains("  restore/RESTORE_INSTRUCTIONS.html"))
        #expect(!sums.contains("logs/"))
        let guide = try String(contentsOf: backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        for text in ["On the old Mac", "On the new Mac", "Moving the backup", "Python environments", "python@3.12", "-m venv",
                     "export PIP_REQUIRE_VIRTUALENV", "Everything that was selected is in this backup"] {
            #expect(guide.contains(text), "\(text)")
        }
        #expect(!guide.contains("sk-synthetic"))
        let readme = try String(contentsOf: backup.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains(backup.lastPathComponent))
    }

    @Test func tamperingWithAnyPackageFileIsDetected() async throws {
        let sandbox = try Sandbox("package-tamper")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        try Data("<h1>tampered</h1>".utf8).write(to: backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"))
        let demo = try #require(manifest.python.environments.first { $0.name == "demo-app" })
        try Data("evil==1\n".utf8).write(to: backup.appendingPathComponent(demo.requirementsPath))
        let report = BackupVerifier(layout: .live()).verify(backupAt: backup)
        #expect(report.issues.contains(.hashMismatch("restore/RESTORE_INSTRUCTIONS.html")))
        #expect(report.issues.contains(.hashMismatch(demo.requirementsPath)))
        #expect(!report.isIntact)
    }

    @Test func instructionsFollowTheSelectedLanguage() async throws {
        let sandbox = try Sandbox("package-de")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let german = Localizer(language: .german)
        let outcome = try BackupWriter(layout: source.layout, localizer: german)
            .write(result, into: try sandbox.folder("out"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let guide = try String(contentsOf: outcome.url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("<html lang=\"de\">"))
        #expect(guide.contains(HTML.escape(german.t("guide.newMac.title"))))
        #expect(!guide.contains("On the new Mac"))
        // The manifest stays language independent.
        let json = try String(contentsOf: outcome.url.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(json.contains("\"restore_method\"") && json.contains("\"python\""))
    }

    @Test func startupRecorderTracksStagesAndDetectsFailedLaunches() throws {
        let sandbox = try Sandbox("startup")
        let file = sandbox.url.appendingPathComponent("logs/startup.json")
        let first = StartupRecorder(fileURL: file, version: "1.0.0")
        #expect(!first.previousLaunchFailed)
        first.reached(.configuration)
        first.reached(.localization)
        first.reached(.localization)
        #expect(first.current.stages == [.launch, .configuration, .localization])
        // The app "crashes" here; the next launch notices.
        let second = StartupRecorder(fileURL: file, version: "1.0.0", safeMode: true)
        #expect(second.previousLaunchFailed)
        #expect(second.previousLaunch?.lastStage == .localization)
        second.failed(.storage, error: "session file unreadable")
        second.completed()
        #expect(second.current.completed && second.current.stages.last == .userInterface)
        let third = StartupRecorder(fileURL: file)
        #expect(!third.previousLaunchFailed)
        #expect(third.previousLaunch?.failure == "storage: session file unreadable")
        for _ in 0..<15 { _ = StartupRecorder(fileURL: file).completed() }
        #expect(StartupRecorder(fileURL: file).history.count == 10)
    }

    @Test func diagnosticReportIsUsefulAndRedacted() throws {
        let sandbox = try Sandbox("diagnostics")
        var layout = SystemLayout.live()
        layout.homeDirectory = try sandbox.folder("home")
        layout.logs = try sandbox.folder("home/Library/Logs/MacReplica")
        let log = LogStore(fileURL: layout.logs.appendingPathComponent("restore-20260101-120000.log"), homeDirectory: layout.homeDirectory)
        log.error("could not copy \(layout.homeDirectory.path)/Library/Fonts/a.otf", component: .restore)
        let recorder = StartupRecorder(fileURL: layout.logs.appendingPathComponent("startup.json"))
        recorder.reached(.configuration)
        let report = DiagnosticReport.make(layout: layout, startupFile: recorder.fileURL)
        #expect(report.contains("MacReplica diagnostic report"))
        #expect(report.contains("stages: launch → configuration"))
        #expect(report.contains("[ERROR] [restore] could not copy ~/Library/Fonts/a.otf"))
        #expect(!report.contains(layout.homeDirectory.path))
        #expect(report.contains("== macOS crash reports for MacReplica\n(none)"))
    }

    @Test func logLinesCarrySeverityAndComponent() {
        let log = LogStore(fileURL: nil, homeDirectory: URL(fileURLWithPath: "/Users/jane"))
        log.warning("Homebrew answered slowly", component: .homebrew)
        log.info("plain")
        #expect(log.allLines[0].hasSuffix("[WARN] [homebrew] Homebrew answered slowly"))
        #expect(log.allLines[1].hasSuffix("[INFO] [general] plain"))
    }
}
