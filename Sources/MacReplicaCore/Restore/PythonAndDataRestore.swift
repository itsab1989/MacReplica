import Foundation

// MARK: - Read-only checks

extension Inspector {
    /// Where the environment is rebuilt: its original location in the home folder.
    func pythonTarget(_ environment: PythonEnvironment) -> URL? {
        guard environment.path.hasPrefix("~/") else { return nil }
        let relative = String(environment.path.dropFirst(2))
        return PathSafety.resolve(relative, inside: layout.homeDirectory)
    }

    /// Environments inside tool-managed folders (virtualenvwrapper, pyenv, pipenv) may
    /// create their parent folder; project environments need the project to exist.
    func mayCreateParent(_ environment: PythonEnvironment) -> Bool { environment.manager.isToolManaged }

    /// Interpreters that can rebuild the environment, best first: exactly the recorded version from
    /// pyenv or uv, then Homebrew's Python of the same minor version.
    /// The base interpreter a saved copy links to (`pyvenv.cfg` `home`), as executables to check.
    func baseInterpreters(for environment: PythonEnvironment) -> [String] {
        guard let home = environment.baseInterpreter else { return [] }
        let folder = layout.resolve(displayPath: home)
        return ["python\(environment.minorVersion)", "python3", "python"].map { folder.appendingPathComponent($0).path }
    }

    func pythonInterpreters(for environment: PythonEnvironment, brewPrefix: URL?) -> [String] {
        let minor = environment.minorVersion
        var candidates: [String] = []
        if ToolchainValidation.isSafeVersion(environment.pythonVersion) {
            candidates.append(layout.homeDirectory.appendingPathComponent(".pyenv/versions/\(environment.pythonVersion)/bin/python\(minor)").path)
            let architecture = environment.architectures.contains(.arm64) || environment.architectures.isEmpty ? "aarch64" : "x86_64"
            let uvFolder = layout.homeDirectory.appendingPathComponent(".local/share/uv/python/cpython-\(environment.pythonVersion)-macos-\(architecture)-none")
            candidates.append(uvFolder.appendingPathComponent("bin/python\(minor)").path)
        }
        for prefix in (brewPrefix.map { [$0] } ?? layout.homebrewPrefixes) { candidates.append(layout.homebrewPython(minor: minor, prefix: prefix)) }
        return candidates
    }

    /// For uv projects with a lock file: the project folder, if `uv.lock` and `pyproject.toml` are there.
    func uvProject(for environment: PythonEnvironment, target: URL) -> URL? {
        guard environment.manager == .uv else { return nil }
        let project = target.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: project.appendingPathComponent("uv.lock").path),
              fm.fileExists(atPath: project.appendingPathComponent("pyproject.toml").path) else { return nil }
        return project
    }

    func existingMinorVersion(of folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("pyvenv.cfg"), encoding: .utf8) else { return nil }
        let config = PythonScanner.parseConfig(text)
        guard let version = config["version"] ?? config["version_info"] else { return nil }
        return PythonVersion.minor(version)
    }

    func installedPackages(in folder: URL) -> [PythonPackage] {
        PythonScanner.sitePackages(in: folder).map(PythonScanner.readPackages) ?? []
    }

    /// Recorded packages that are not installed in exactly the recorded version.
    func missingPackages(_ environment: PythonEnvironment, installed: [PythonPackage]) -> [PythonPackage] {
        let versions = Dictionary(installed.map { ($0.normalizedName, $0.version) }, uniquingKeysWith: { first, _ in first })
        return environment.installablePackages.filter { versions[$0.normalizedName] != $0.version }
    }

    func predictPython(_ item: RestoreItem, brew: HomebrewInstallation?) -> Prediction {
        guard let environment = item.pythonEnvironment, let target = pythonTarget(environment) else { return .environmentConflict }
        if FileManager.default.fileExists(atPath: target.path) {
            guard existingMinorVersion(of: target) == environment.minorVersion else { return .environmentConflict }
            return missingPackages(environment, installed: installedPackages(in: target)).isEmpty
                ? .alreadyPresent(version: environment.pythonVersion) : .willCompleteEnvironment
        }
        let parent = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path), !mayCreateParent(environment) {
            return .willSkip(.projectFolderMissing(path: layout.displayPath(parent)))
        }
        return brew == nil ? .dependsOnEarlierStep : .willRecreateEnvironment
    }

    struct DataFilePlan {
        var record: FileRecord
        var source: URL
        var destination: URL
        var state: State
        enum State { case new, identical, different, damaged }
    }

    /// Where an application data folder goes on this Mac.
    ///
    /// Data of a versioned app (e.g. "Adobe Photoshop 2025") goes back into its version's folder. If the data
    /// also works in other versions and that version is not on this Mac, the newest other version that is
    /// (same app, same channel: the folder pattern keeps release and beta apart) is used instead; the user
    /// can choose another one (`sourceChoices[item.id]`). Shared-library data (`/Library`) needs the app's
    /// own folder, which its installer creates.
    func applicationDataTarget(_ folder: AppDataFolder, itemID: String?) -> AppDataTarget? {
        guard PathSafety.isSafeRelativePath(folder.relativePath) else { return nil }
        let root = layout.root(of: folder.effectiveScope)
        var target = AppDataTarget(root: root, relativePath: folder.relativePath)
        let components = folder.relativePath.split(separator: "/").map(String.init)
        if let version = folder.profile?.appVersion, let index = components.firstIndex(of: version) {
            let parent = components[..<index].joined(separator: "/")
            let parentURL = parent.isEmpty ? root : root.appendingPathComponent(parent)
            let fm = FileManager.default
            let originalExists = fm.fileExists(atPath: parentURL.appendingPathComponent(version).path)
            var alternatives: [String] = []
            if folder.profile?.movesBetweenVersions == true, let pattern = folder.profile?.versionFolderPattern {
                alternatives = ((try? fm.contentsOfDirectory(atPath: parentURL.path)) ?? [])
                    .filter { $0 != version && $0.range(of: pattern, options: .regularExpression) != nil && PathSafety.isSafeRelativePath($0) }
                    .sorted { VersionComparison.compare(Self.versionNumber($0), Self.versionNumber($1)) == .orderedDescending }
            }
            var chosen = version
            if let itemID, let choice = selection.sourceChoices[itemID], choice == version || alternatives.contains(choice) {
                chosen = choice
            } else if !originalExists, let newest = alternatives.first {
                chosen = newest
            }
            var replaced = components
            replaced[index] = chosen
            target.relativePath = replaced.joined(separator: "/")
            target.version = VersionTarget(original: version, chosen: chosen, originalExists: originalExists, alternatives: alternatives)
        }
        if folder.effectiveScope == .sharedLibrary {
            target.appFolderMissing = !FileManager.default.fileExists(atPath: root.appendingPathComponent(folder.relativePath).path)
        }
        return target
    }

    /// The number in a version folder name, e.g. "2026" in "Adobe Photoshop 2026" or "4.2" in "4.2".
    static func versionNumber(_ name: String) -> String {
        guard let range = name.range(of: #"\d+(\.\d+)*"#, options: [.regularExpression, .backwards]) else { return "0" }
        return String(name[range])
    }

    func applicationDataPlan(_ folder: AppDataFolder) -> [DataFilePlan]? { applicationDataPlan(folder, itemID: nil) }

    func applicationDataPlan(_ folder: AppDataFolder, itemID: String?) -> [DataFilePlan]? {
        guard let target = applicationDataTarget(folder, itemID: itemID),
              let base = PathSafety.resolve(target.relativePath, inside: target.root) else { return nil }
        var result: [DataFilePlan] = []
        for record in folder.files {
            guard let source = PathSafety.resolve(record.backupPath, inside: backupRoot),
                  let destination = PathSafety.resolve(record.relativePath, inside: base) else { return nil }
            var state: DataFilePlan.State = .new
            if damagedFiles.contains(record.backupPath) || !FileManager.default.fileExists(atPath: source.path) {
                state = .damaged
            } else if FileManager.default.fileExists(atPath: destination.path) {
                state = (try? Hashing.sha256Hex(ofFile: destination)) == record.sha256 ? .identical : .different
            }
            result.append(DataFilePlan(record: record, source: source, destination: destination, state: state))
        }
        return result
    }

    /// What the restore selection shows for an application data item: which files differ and, for
    /// versioned apps, which version the data goes into.
    func applicationDataComparison(_ item: RestoreItem) -> AppDataComparison? {
        guard let folder = item.applicationData, let target = applicationDataTarget(folder, itemID: item.id),
              let plan = applicationDataPlan(folder, itemID: item.id) else { return nil }
        let different = plan.filter { $0.state == .different }.map { file in
            let values = try? file.destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return AppDataComparison.DifferentFile(path: file.record.relativePath, backupSize: file.record.size, backupModified: file.record.modifiedAt,
                                                   existingSize: Int64(values?.fileSize ?? 0), existingModified: values?.contentModificationDate)
        }
        return AppDataComparison(newFiles: plan.filter { $0.state == .new }.count, identicalFiles: plan.filter { $0.state == .identical }.count,
                                 differentFiles: different, version: target.version)
    }

    /// The installed copy of an app, found by bundle identifier in the application folders and one folder
    /// below them (some apps install into a folder, e.g. /Applications/DaVinci Resolve/DaVinci Resolve.app).
    func installedAppVersion(bundleIdentifiers: [String]) -> (found: Bool, version: String?) {
        let wanted = Set(bundleIdentifiers.map { $0.lowercased() })
        let fm = FileManager.default
        func check(_ url: URL) -> (Bool, String?)? {
            guard url.pathExtension == "app",
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, wanted.contains(id.lowercased()) else { return nil }
            return (true, info["CFBundleShortVersionString"] as? String)
        }
        for folder in layout.applicationFolders {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if let found = check(url) { return found }
                guard url.pathExtension.isEmpty else { continue }
                for inner in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    if let found = check(inner) { return found }
                }
            }
        }
        return (false, nil)
    }

    /// Data that needs its app: waits until the app is installed, and never goes to an older version of it.
    func applicationDataRequirement(_ folder: AppDataFolder) -> SkipReason? {
        guard let profile = folder.profile, profile.appMustBeInstalled || profile.notForOlderApp else { return nil }
        let installed = installedAppVersion(bundleIdentifiers: profile.bundleIdentifiers)
        if !installed.found { return profile.appMustBeInstalled ? .applicationNotInstalled(name: profile.appName) : nil }
        if profile.notForOlderApp, let backup = profile.sourceAppVersion, let version = installed.version,
           VersionComparison.compare(version, backup) == .orderedAscending {
            return .applicationVersionOlder(name: profile.appName, installed: version, backup: backup)
        }
        return nil
    }

    func predictApplicationData(_ item: RestoreItem) -> Prediction {
        guard let folder = item.applicationData, let target = applicationDataTarget(folder, itemID: item.id),
              let plan = applicationDataPlan(folder, itemID: item.id) else { return .backupFileDamaged }
        if plan.contains(where: { $0.state == .damaged }) { return .backupFileDamaged }
        if target.appFolderMissing { return .willSkip(.applicationNotInstalled(name: folder.profile?.appName ?? folder.name)) }
        if let reason = applicationDataRequirement(folder) { return .willSkip(reason) }
        if plan.contains(where: { $0.state == .different }) { return .conflict(resolution: selection.resolution(for: item.id)) }
        if plan.allSatisfy({ $0.state == .identical }) { return .identicalFileExists }
        return .willCopy
    }

    /// Notes shown before the restore: the data goes into another version, or into one that is not installed.
    func applicationDataNotes(_ item: RestoreItem) -> [ResultNote] {
        guard let folder = item.applicationData, let version = applicationDataTarget(folder, itemID: item.id)?.version else { return [] }
        if version.chosen != version.original { return [.restoredIntoVersion(original: version.original, target: version.chosen)] }
        return version.originalExists ? [] : [.applicationVersionDiffers(original: version.original)]
    }
}

/// Where an application data folder is restored to (see `Inspector.applicationDataTarget`).
struct AppDataTarget {
    var root: URL
    var relativePath: String
    var version: VersionTarget?
    /// Shared-library data whose app folder does not exist: the app is not installed.
    var appFolderMissing = false
}

/// The app version folder application data is restored into.
public struct VersionTarget: Equatable, Sendable {
    public var original: String
    public var chosen: String
    public var originalExists: Bool
    /// Other versions of the same app on this Mac that the data also works in, newest first.
    public var alternatives: [String]
}

/// How the backup copy of an application data folder relates to what this Mac has.
public struct AppDataComparison: Equatable, Sendable {
    public struct DifferentFile: Equatable, Sendable {
        public var path: String
        public var backupSize: Int64
        public var backupModified: Date?
        public var existingSize: Int64
        public var existingModified: Date?
    }
    public var newFiles: Int
    public var identicalFiles: Int
    public var differentFiles: [DifferentFile]
    public var version: VersionTarget?
}

// MARK: - Restore

extension RestoreExecutor {
    /// Package names and versions are passed to pip as separate arguments; they must look like what they are.
    static func isSafeRequirement(_ package: PythonPackage) -> Bool {
        package.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$"#, options: .regularExpression) != nil
            && package.version.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+!_-]{0,100}$"#, options: .regularExpression) != nil
    }

    private func pythonCommand(_ python: String, _ arguments: [String], timeout: TimeInterval, brew: HomebrewInstallation?) -> Command {
        Command(executable: python, arguments: arguments,
                environment: layout.processEnvironment(homebrewPrefix: brew?.prefix, askpass: nil).merging([
                    "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_NO_INPUT": "1", "PYTHONDONTWRITEBYTECODE": "1",
                ]) { $1 },
                timeout: timeout)
    }

    /// Restores an environment: from its saved copy when the user chose that and it fits this Mac (verified by
    /// running it), otherwise — and as fallback — by rebuilding it from the recorded packages.
    func restorePythonEnvironment(_ item: RestoreItem, inspector: Inspector, brew: HomebrewInstallation?, context: RunContext,
                                  onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        guard let environment = item.pythonEnvironment, let target = inspector.pythonTarget(environment) else {
            return try await rebuildPythonEnvironment(item, inspector: inspector, brew: brew, context: context, onEvent: onEvent)
        }
        var fallback: ResultNote?
        if inspector.selection.sourceChoices[item.id] == "preserve", let preservation = environment.preservation,
           !FileManager.default.fileExists(atPath: target.path) {
            switch try await restorePreservedCopy(item, environment: environment, preservation: preservation, target: target,
                                                  inspector: inspector, context: context, onEvent: onEvent) {
            case .restored(let result): return result
            case .notUsed(let problem):
                log.warning("\(item.id): saved copy not used (\(problem.rawValue)); rebuilding from the package list", component: .python)
                fallback = .pythonPreservationNotUsed(reason: problem)
            }
        }
        var result = try await rebuildPythonEnvironment(item, inspector: inspector, brew: brew, context: context, onEvent: onEvent)
        if let fallback { result.notes.insert(fallback, at: 0) }
        return result
    }

    enum PreservedOutcome { case restored(ItemResult), notUsed(PythonPreservationProblem) }

    /// The saved copy is only used for the same home folder, an existing base interpreter, a compatible
    /// architecture and macOS, and an intact archive. After unpacking, the environment's own Python must
    /// report the expected version, location and packages and import them; otherwise the copy is removed.
    func restorePreservedCopy(_ item: RestoreItem, environment: PythonEnvironment, preservation: PythonPreservation, target: URL,
                              inspector: Inspector, context: RunContext,
                              onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> PreservedOutcome {
        let fm = FileManager.default
        guard let keys = item.hardwareKeys, keys.key(for: layout.homeDirectory.standardizedFileURL.path) == preservation.homeKey else {
            return .notUsed(.differentHomeFolder)
        }
        if !preservation.nativeArchitectures.isEmpty, !preservation.nativeArchitectures.contains(self.environment.targetArchitecture) {
            return .notUsed(.incompatibleArchitecture)
        }
        if let minimum = preservation.minimumMacOS, VersionComparison.compare(self.environment.macOSVersion, minimum) == .orderedAscending {
            return .notUsed(.requiresNewerMacOS)
        }
        guard inspector.baseInterpreters(for: environment).contains(where: { fm.isExecutableFile(atPath: $0) }) else {
            return .notUsed(.baseInterpreterMissing)
        }
        guard let archive = PathSafety.resolve(preservation.archivePath, inside: backupRoot), !inspector.damagedFiles.contains(preservation.archivePath),
              (try? Hashing.sha256Hex(ofFile: archive)) == preservation.sha256 else { return .notUsed(.archiveDamaged) }
        let parent = target.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) || inspector.mayCreateParent(environment) else { return .notUsed(.extractionFailed) }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let runner = context.toolchainRunner ?? self.environment.runner
        onEvent(.activity(itemID: item.id, .copying))
        let unpack = try await runner.run(Command(executable: layout.ditto, arguments: ["-x", "-k", archive.path, parent.path],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 3600))
        guard unpack.succeeded, fm.fileExists(atPath: target.appendingPathComponent("pyvenv.cfg").path) else {
            removeUnpacked(target)
            return .notUsed(.extractionFailed)
        }
        onEvent(.activity(itemID: item.id, .verifying))
        let names = PythonPreserver.importNames(in: target, packages: environment.installablePackages)
        let probe = try await runProbe(target: target, names: names, runner: runner)
        guard let probe, PythonPreserver.verify(probe, environment: environment, target: target) else {
            removeUnpacked(target)
            return .notUsed(.verificationFailed)
        }
        log.info("\(item.id): saved copy restored and verified (Python \(probe.version), \(probe.dists.count) packages, \(names.count) imports)",
                 component: .python)
        var notes: [ResultNote] = [.pythonEnvironmentPreserved]
        if !environment.manualPackages.isEmpty { notes.append(.pythonPackagesNeedManualSetup(names: environment.manualPackages.map(\.name).sorted())) }
        return .restored(ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: probe.version, notes: notes))
    }

    /// Runs the probe with the environment's own Python.
    func runProbe(target: URL, names: [String], runner: CommandRunning) async throws -> PythonPreserver.ProbeResult? {
        let python = target.appendingPathComponent("bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
        let arguments = try String(decoding: JSONEncoder().encode(names), as: UTF8.self)
        let result = try await runner.run(Command(executable: python, arguments: ["-I", "-c", PythonPreserver.probeScript, arguments],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 600))
        guard result.succeeded else { return nil }
        return PythonPreserver.parseProbe(result.stdout)
    }

    /// Removes an environment MacReplica unpacked in this step (the location was empty before).
    private func removeUnpacked(_ target: URL) {
        try? FileManager.default.removeItem(at: target)
    }

    func rebuildPythonEnvironment(_ item: RestoreItem, inspector: Inspector, brew: HomebrewInstallation?, context: RunContext,
                                  onEvent: @escaping @Sendable (RestoreEvent) -> Void) async throws -> ItemResult {
        guard let environment = item.pythonEnvironment else { return failed(item, .unknown) }
        guard let target = inspector.pythonTarget(environment) else {
            return failed(item, .pythonEnvironmentConflict, "environment is outside the home folder")
        }
        guard let python = inspector.pythonInterpreters(for: environment, brewPrefix: brew?.prefix)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            if brew == nil { return failed(item, .homebrewUnavailable) }
            return failed(item, .pythonVersionUnavailable, "Python \(environment.minorVersion) is not available from Homebrew")
        }
        // A uv project with a lock file is rebuilt exactly from that lock file.
        if !FileManager.default.fileExists(atPath: target.path), let project = inspector.uvProject(for: environment, target: target),
           let uv = context.toolchainContext.flatMap({ UVProvider().executableCandidates(for: ToolchainAction(provider: .uv, kind: .package), context: $0)
               .first { FileManager.default.isExecutableFile(atPath: $0) } }) {
            onEvent(.activity(itemID: item.id, .creatingEnvironment))
            let sync = try await (context.toolchainRunner ?? self.environment.runner).run(Command(
                executable: uv, arguments: ["sync", "--frozen", "--project", project.path, "--python", python],
                environment: layout.processEnvironment(homebrewPrefix: brew?.prefix, askpass: nil)
                    .merging(["UV_PROJECT_ENVIRONMENT": target.path, "NO_COLOR": "1", "UV_NO_PROGRESS": "1"]) { $1 },
                timeout: 3600))
            if sync.succeeded, inspector.existingMinorVersion(of: target) == environment.minorVersion {
                log.info("\(item.id): rebuilt from uv.lock", component: .python)
                var lockNotes: [ResultNote] = [.pythonLockFileUsed(file: "uv.lock")]
                if !environment.manualPackages.isEmpty { lockNotes.append(.pythonPackagesNeedManualSetup(names: environment.manualPackages.map(\.name).sorted())) }
                return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: environment.minorVersion, notes: lockNotes)
            }
            log.warning("\(item.id): uv sync failed, rebuilding from the recorded packages", component: .python)
        }
        let fm = FileManager.default
        var notes: [ResultNote] = []

        if fm.fileExists(atPath: target.path) {
            guard inspector.existingMinorVersion(of: target) == environment.minorVersion else {
                return failed(item, .pythonEnvironmentConflict, layout.displayPath(target))
            }
            if inspector.missingPackages(environment, installed: inspector.installedPackages(in: target)).isEmpty {
                return ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: environment.pythonVersion)
            }
            notes.append(.pythonEnvironmentReused)
        } else {
            let parent = target.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                guard inspector.mayCreateParent(environment) else {
                    return ItemResult(itemID: item.id, outcome: .skipped(.projectFolderMissing(path: layout.displayPath(parent))))
                }
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            onEvent(.activity(itemID: item.id, .creatingEnvironment))
            let created = try await runPython(python, ["-m", "venv", target.path], timeout: 900, brew: brew, runner: context.toolchainRunner)
            guard created.succeeded else { return ItemResult(itemID: item.id, outcome: .failed(failure(from: created))) }
            guard inspector.existingMinorVersion(of: target) == environment.minorVersion else {
                return failed(item, .verificationFailed, "virtual environment was not created")
            }
            // Bring the packaging tools up to date; not fatal if it fails (e.g. offline).
            let tools = try await runPython(python, ["-m", "pip", "--python", target.path, "install", "--upgrade", "pip", "setuptools", "wheel"],
                                                  timeout: 900, brew: brew, runner: context.toolchainRunner)
            if !tools.succeeded { log.warning("Could not update packaging tools in \(environment.path)", component: .python) }
        }

        let pinned = inspector.missingPackages(environment, installed: inspector.installedPackages(in: target)).filter(Self.isSafeRequirement)
        var lastOutput = ""
        if !pinned.isEmpty {
            onEvent(.activity(itemID: item.id, .installingPackages))
            let install = try await runPython(python, ["-m", "pip", "--python", target.path, "install"] + pinned.map { "\($0.name)==\($0.version)" },
                                                    timeout: 3600, brew: brew, runner: context.toolchainRunner)
            lastOutput = install.combinedOutput
            if !install.succeeded {
                let category = ErrorClassifier.classify(install.combinedOutput, exitCode: install.exitCode, timedOut: install.timedOut)
                if category == .network || category == .timeout || category == .diskFull {
                    return ItemResult(itemID: item.id, outcome: .failed(failure(from: install)))
                }
                // pip installs all or nothing. Retry one package at a time: first the recorded
                // version, and only if that no longer exists, the current compatible version.
                for package in inspector.missingPackages(environment, installed: inspector.installedPackages(in: target)).filter(Self.isSafeRequirement) {
                    try Task.checkCancellation()
                    let exact = try await runPython(python, ["-m", "pip", "--python", target.path, "install", "\(package.name)==\(package.version)"],
                                                    timeout: 1800, brew: brew, runner: context.toolchainRunner)
                    if exact.succeeded { continue }
                    let current = try await runPython(python, ["-m", "pip", "--python", target.path, "install", package.name], timeout: 1800, brew: brew,
                                                      runner: context.toolchainRunner)
                    if !current.succeeded { lastOutput = current.combinedOutput }
                }
            }
        }

        onEvent(.activity(itemID: item.id, .verifying))
        let installed = inspector.installedPackages(in: target)
        let installedNames = Set(installed.map(\.normalizedName))
        let stillMissing = environment.installablePackages.filter { !installedNames.contains($0.normalizedName) }
        if !stillMissing.isEmpty {
            let names = stillMissing.map(\.name).sorted().joined(separator: ", ")
            let detail = "missing: \(names)\n" + ErrorClassifier.technicalDetail(lastOutput, layout: layout, maxLines: 8)
            return ItemResult(itemID: item.id, outcome: .failed(RestoreFailure(category: .pythonPackagesIncomplete, technicalDetail: detail)),
                              notes: notes)
        }
        let changed = inspector.missingPackages(environment, installed: installed).count
        if changed > 0 { notes.append(.pythonPackagesUpdated(count: changed)) }
        if !environment.manualPackages.isEmpty {
            notes.append(.pythonPackagesNeedManualSetup(names: environment.manualPackages.map(\.name).sorted()))
        }
        // The rebuilt environment must also run: its own Python reports the expected version and location.
        guard let probe = try await runProbe(target: target, names: [], runner: context.toolchainRunner ?? self.environment.runner),
              PythonVersion.minor(probe.version) == environment.minorVersion,
              URL(fileURLWithPath: probe.prefix).resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else {
            return ItemResult(itemID: item.id, outcome: .failed(RestoreFailure(category: .verificationFailed,
                                                                              technicalDetail: "the environment's Python does not run as expected")), notes: notes)
        }
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: probe.version, notes: notes)
    }

    private func runPython(_ python: String, _ arguments: [String], timeout: TimeInterval, brew: HomebrewInstallation?,
                           runner: CommandRunning? = nil) async throws -> CommandResult {
        try await (runner ?? environment.runner).run(pythonCommand(python, arguments, timeout: timeout, brew: brew))
    }

    func restoreApplicationData(_ item: RestoreItem, inspector: Inspector, session: RestoreSession,
                                onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        guard let folder = item.applicationData, let target = inspector.applicationDataTarget(folder, itemID: item.id),
              let plan = inspector.applicationDataPlan(folder, itemID: item.id) else {
            return failed(item, .backupFileDamaged, "unsafe paths in backup")
        }
        if target.appFolderMissing {
            return ItemResult(itemID: item.id, outcome: .skipped(.applicationNotInstalled(name: folder.profile?.appName ?? folder.name)))
        }
        if let reason = inspector.applicationDataRequirement(folder) { return ItemResult(itemID: item.id, outcome: .skipped(reason)) }
        // Some apps overwrite their files on quit; never write underneath a running app.
        if let profile = folder.profile, profile.mustBeClosed,
           let running = profile.bundleIdentifiers.first(where: environment.isApplicationRunning) {
            return failed(item, .applicationRunning, "\(profile.appName) (\(running)) is running")
        }
        let resolution = inspector.selection.resolution(for: item.id)
        if resolution == .skip, plan.contains(where: { $0.state == .different }) {
            return ItemResult(itemID: item.id, outcome: .skipped(.userSkipped))
        }
        let fm = FileManager.default
        var copied = 0, identical = 0, kept = 0
        var problems: [String] = []
        // Data of a versioned app goes into the version chosen in the plan (see `applicationDataTarget`);
        // the user is told when that is another version, or one that is not installed.
        let versionNotes = inspector.applicationDataNotes(item)
        if folder.effectiveScope == .sharedLibrary, let base = PathSafety.resolve(target.relativePath, inside: target.root),
           !fm.isWritableFile(atPath: base.path) {
            return failed(item, .permissionDenied, layout.displayPath(base))
        }
        onEvent(.activity(itemID: item.id, .copying))
        for file in plan {
            switch file.state {
            case .identical:
                identical += 1
                continue
            case .damaged:
                problems.append(file.record.relativePath)
                continue
            case .different where resolution != .replace:
                kept += 1
                continue
            default:
                break
            }
            guard (try? Hashing.sha256Hex(ofFile: file.source)) == file.record.sha256 else {
                problems.append(file.record.relativePath)
                continue
            }
            do {
                try fm.createDirectory(at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if file.state == .different {
                    let asideFolder = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/application-data/\(folder.id)")
                    guard let aside = PathSafety.resolve(file.record.relativePath, inside: asideFolder) else { throw CocoaError(.fileWriteInvalidFileName) }
                    try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                    try fm.moveItem(at: file.destination, to: aside)
                }
                try fm.copyItem(at: file.source, to: file.destination)
                guard (try? Hashing.sha256Hex(ofFile: file.destination)) == file.record.sha256 else { throw CocoaError(.fileWriteUnknown) }
                copied += 1
            } catch {
                problems.append(file.record.relativePath)
            }
        }
        if !problems.isEmpty {
            let detail = "\(problems.count) of \(plan.count) files: " + problems.prefix(10).joined(separator: ", ")
            return ItemResult(itemID: item.id, outcome: .failed(RestoreFailure(category: .verificationFailed, technicalDetail: detail)),
                              notes: [.applicationDataCopied(copied: copied, identical: identical, kept: kept)])
        }
        if copied == 0 && kept == 0 {
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, notes: [.identicalFileExists])
        }
        return ItemResult(itemID: item.id, outcome: .succeeded,
                          notes: [.applicationDataCopied(copied: copied, identical: identical, kept: kept)] + versionNotes)
    }
}

// MARK: - Git configuration and credentials

extension Inspector {
    var gitConfigURL: URL { layout.homeDirectory.appendingPathComponent(".gitconfig") }

    func predictGitConfiguration(_ item: RestoreItem) -> Prediction {
        guard let text = item.gitConfig else { return .backupFileDamaged }
        guard let existing = try? String(contentsOf: gitConfigURL, encoding: .utf8) else { return .willCopy }
        return existing == text ? .identicalFileExists : .conflict(resolution: selection.resolution(for: item.id))
    }
}

extension RestoreExecutor {
    func restoreGitConfiguration(_ item: RestoreItem, inspector: Inspector, session: RestoreSession) -> ItemResult {
        guard let text = item.gitConfig else { return failed(item, .backupFileDamaged) }
        let target = inspector.gitConfigURL
        var notes: [ResultNote] = []
        switch inspector.predictGitConfiguration(item) {
        case .identicalFileExists:
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, notes: [.identicalFileExists])
        case .conflict(.keepExisting):
            return ItemResult(itemID: item.id, outcome: .skipped(.keptExisting))
        case .conflict(.skip):
            return ItemResult(itemID: item.id, outcome: .skipped(.userSkipped))
        case .conflict(.replace):
            let aside = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/gitconfig")
            do {
                try FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: target, to: aside)
                notes.append(.existingFileMovedAside(path: layout.displayPath(aside)))
            } catch {
                return failed(item, .unknown, layout.redact(error.localizedDescription))
            }
        default:
            break
        }
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
        } catch {
            return failed(item, .unknown, layout.redact(error.localizedDescription))
        }
        guard (try? String(contentsOf: target, encoding: .utf8)) == text else { return failed(item, .verificationFailed) }
        return ItemResult(itemID: item.id, outcome: .succeeded, notes: notes)
    }

    /// Decrypts a credential vault with the passphrase the user entered and restores
    /// its files with private permissions. Secrets never appear in logs or results.
    func restoreCredential(_ item: RestoreItem, inspector: Inspector, session: RestoreSession,
                           onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        let providerID = String(item.id.dropFirst("credential:".count))
        guard let provider = CredentialProviders.provider(id: providerID) else {
            return failed(item, .credentialCannotBeOpened, "unknown credential type")
        }
        guard let passphrase = environment.credentialPassphrase else {
            return ItemResult(itemID: item.id, outcome: .skipped(.passphraseNotProvided))
        }
        guard let vault = PathSafety.resolve(item.identifier, inside: backupRoot), let data = try? Data(contentsOf: vault) else {
            return failed(item, .backupFileDamaged, item.identifier)
        }
        let files: [CredentialFile]
        do {
            files = try CredentialVault.open(data, passphrase: passphrase)
        } catch {
            log.warning("Credential vault \(providerID) could not be opened", component: .permissions)
            return failed(item, .credentialCannotBeOpened)
        }
        onEvent(.activity(itemID: item.id, .copying))
        let fm = FileManager.default
        let resolution = inspector.selection.resolution(for: item.id)
        var copied = 0, identical = 0, kept = 0
        var notes: [ResultNote] = []
        for file in files {
            guard let destination = provider.destination(for: file, layout: layout) else {
                return failed(item, .credentialCannotBeOpened, "unexpected entry")
            }
            do {
                let folder = destination.deletingLastPathComponent()
                if !fm.fileExists(atPath: folder.path) {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                if fm.fileExists(atPath: destination.path) {
                    if (try? Data(contentsOf: destination)) == file.contents { identical += 1; continue }
                    if resolution != .replace { kept += 1; continue }
                    let aside = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/\(providerID)/\(file.name)")
                    try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
                    try fm.moveItem(at: destination, to: aside)
                    if !notes.contains(where: { if case .existingFileMovedAside = $0 { return true }; return false }) {
                        notes.append(.existingFileMovedAside(path: layout.displayPath(aside.deletingLastPathComponent())))
                    }
                }
                // Create with private permissions before writing any secret bytes.
                guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: destination)
                try handle.write(contentsOf: file.contents)
                try handle.close()
                try fm.setAttributes([.posixPermissions: file.permissions == 0 ? 0o600 : file.permissions], ofItemAtPath: destination.path)
                guard (try? Data(contentsOf: destination)) == file.contents else { throw CocoaError(.fileWriteUnknown) }
                copied += 1
            } catch {
                return failed(item, .verificationFailed, file.name)
            }
        }
        log.info("Restored \(copied) credential files (\(identical) identical, \(kept) kept) for \(providerID)", component: .permissions)
        if copied == 0 && kept == 0 { return ItemResult(itemID: item.id, outcome: .alreadyPresent) }
        return ItemResult(itemID: item.id, outcome: .succeeded,
                          notes: notes + [.applicationDataCopied(copied: copied, identical: identical, kept: kept)])
    }
}
