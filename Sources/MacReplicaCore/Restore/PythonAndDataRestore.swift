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

    func applicationDataPlan(_ folder: AppDataFolder) -> [DataFilePlan]? {
        guard PathSafety.isSafeRelativePath(folder.relativePath),
              let base = PathSafety.resolve(folder.relativePath, inside: layout.homeDirectory) else { return nil }
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

    func predictApplicationData(_ item: RestoreItem) -> Prediction {
        guard let folder = item.applicationData, let plan = applicationDataPlan(folder) else { return .backupFileDamaged }
        if plan.contains(where: { $0.state == .damaged }) { return .backupFileDamaged }
        if plan.contains(where: { $0.state == .different }) { return .conflict(resolution: selection.resolution(for: item.id)) }
        if plan.allSatisfy({ $0.state == .identical }) { return .identicalFileExists }
        return .willCopy
    }
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

    func restorePythonEnvironment(_ item: RestoreItem, inspector: Inspector, brew: HomebrewInstallation?, context: RunContext,
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
        return ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: inspector.existingMinorVersion(of: target), notes: notes)
    }

    private func runPython(_ python: String, _ arguments: [String], timeout: TimeInterval, brew: HomebrewInstallation?,
                           runner: CommandRunning? = nil) async throws -> CommandResult {
        try await (runner ?? environment.runner).run(pythonCommand(python, arguments, timeout: timeout, brew: brew))
    }

    func restoreApplicationData(_ item: RestoreItem, inspector: Inspector, session: RestoreSession,
                                onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        guard let folder = item.applicationData, let plan = inspector.applicationDataPlan(folder) else {
            return failed(item, .backupFileDamaged, "unsafe paths in backup")
        }
        // Some apps overwrite their files on quit; never write underneath a running app.
        if let profile = folder.profile, profile.mustBeClosed,
           let running = profile.bundleIdentifiers.first(where: environment.isApplicationRunning) {
            return failed(item, .applicationRunning, "\(profile.appName) (\(running)) is running")
        }
        let resolution = inspector.selection.resolution(for: item.id)
        let fm = FileManager.default
        var copied = 0, identical = 0, kept = 0
        var problems: [String] = []
        var versionNotes: [ResultNote] = []
        // Presets of a versioned app (e.g. "Adobe Photoshop 2025") go back into that version's folder.
        // If that version is not on this Mac, the data is still restored but the user is told.
        if let version = folder.profile?.appVersion, let range = folder.relativePath.range(of: "/" + version + "/") {
            let versionFolder = layout.homeDirectory.appendingPathComponent(String(folder.relativePath[..<range.upperBound]))
            if !fm.fileExists(atPath: versionFolder.path) { versionNotes.append(.applicationVersionDiffers(original: version)) }
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
