import Foundation

/// Finds Python interpreters, virtual environments and safe settings by reading
/// files only. No interpreter is started during the scan.
public struct PythonScanner: Sendable {
    public var layout: SystemLayout
    /// Additional folders the user asked MacReplica to search.
    public var extraRoots: [URL]
    public var maxDepth: Int
    public var maxVisitedFolders: Int

    public init(layout: SystemLayout, extraRoots: [URL] = [], maxDepth: Int = 5, maxVisitedFolders: Int = 40_000) {
        self.layout = layout
        self.extraRoots = extraRoots
        self.maxDepth = maxDepth
        self.maxVisitedFolders = maxVisitedFolders
    }

    /// Folders in the home folder that macOS protects with a permission prompt, plus
    /// places that never contain projects. They are only searched if the user adds them.
    static let skippedHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
                                                  "Public", "Applications", ".Trash"]
    static let skippedFolderNames: Set<String> = ["node_modules", ".git", ".hg", ".svn", "__pycache__", ".cache", ".npm", ".cargo",
                                                  ".rustup", ".gradle", ".m2", "build", "dist", "DerivedData", "Pods"]
    /// Hidden folders that commonly hold environments and are searched anyway.
    static let searchedHiddenNames: Set<String> = [".venv", ".virtualenvs", ".pyenv", ".local", ".env"]

    /// Settings that are known to be harmless to record. Anything else is ignored,
    /// so tokens or index URLs with credentials can never end up in a backup.
    static let safeSettingKeys: Set<String> = ["PYENV_ROOT", "PYENV_VERSION", "PIP_REQUIRE_VIRTUALENV", "PIPENV_VENV_IN_PROJECT",
                                               "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED", "VIRTUAL_ENV_DISABLE_PROMPT", "WORKON_HOME",
                                               "POETRY_VIRTUALENVS_IN_PROJECT", "PYTHONUTF8"]

    var containerFolders: [URL] {
        let home = layout.homeDirectory
        return [home.appendingPathComponent(".virtualenvs"), home.appendingPathComponent(".pyenv/versions"),
                home.appendingPathComponent(".local/share/virtualenvs")]
    }

    public func scan(homebrewPrefixes: [URL]? = nil) -> (snapshot: PythonSnapshot, projectFiles: [ScannedFile]) {
        let installations = findInstallations(homebrewPrefixes: homebrewPrefixes ?? layout.homebrewPrefixes)
        var environments: [PythonEnvironment] = []
        var files: [ScannedFile] = []
        for folder in findEnvironmentFolders() {
            guard let (environment, projectFiles) = readEnvironment(at: folder) else { continue }
            environments.append(environment)
            files += projectFiles
        }
        environments.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (PythonSnapshot(installations: installations, environments: environments, settings: findSettings()), files)
    }

    // MARK: Interpreters

    func findInstallations(homebrewPrefixes: [URL]) -> [PythonInstallation] {
        let fm = FileManager.default
        var result: [PythonInstallation] = []
        for prefix in homebrewPrefixes {
            for minor in PythonVersion.supportedMinors {
                let executable = prefix.appendingPathComponent("opt/python@\(minor)/bin/python\(minor)")
                guard fm.isExecutableFile(atPath: executable.path) else { continue }
                let cellar = prefix.appendingPathComponent("Cellar/python@\(minor)")
                let version = (try? fm.contentsOfDirectory(atPath: cellar.path))?.sorted { VersionComparison.compare($0, $1) == .orderedAscending }.last
                result.append(PythonInstallation(version: version.map(Self.stripRevision) ?? minor, executable: layout.displayPath(executable),
                                                 source: .homebrew, architectures: MachO.architectures(ofFile: executable.resolvingSymlinksInPath())))
            }
        }
        let pyenvVersions = layout.homeDirectory.appendingPathComponent(".pyenv/versions")
        for name in ((try? fm.contentsOfDirectory(atPath: pyenvVersions.path)) ?? []).sorted() {
            let folder = pyenvVersions.appendingPathComponent(name)
            guard !fm.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path),
                  name.range(of: #"^\d+\.\d+(\.\d+)?"#, options: .regularExpression) != nil else { continue }
            let executable = folder.appendingPathComponent("bin/python3")
            guard fm.fileExists(atPath: executable.path) else { continue }
            result.append(PythonInstallation(version: name, executable: layout.displayPath(executable), source: .pyenv,
                                             architectures: MachO.architectures(ofFile: executable.resolvingSymlinksInPath())))
        }
        let framework = layout.pythonFrameworks.appendingPathComponent("Python.framework/Versions")
        for name in ((try? fm.contentsOfDirectory(atPath: framework.path)) ?? []).sorted() where name != "Current" {
            let executable = framework.appendingPathComponent("\(name)/bin/python\(name)")
            guard fm.fileExists(atPath: executable.path) else { continue }
            result.append(PythonInstallation(version: name, executable: layout.displayPath(executable), source: .pythonOrg,
                                             architectures: MachO.architectures(ofFile: executable.resolvingSymlinksInPath())))
        }
        return result
    }

    /// Homebrew keg folders may carry a revision suffix: "3.12.4_1" → "3.12.4".
    static func stripRevision(_ version: String) -> String {
        String(version.split(separator: "_").first ?? Substring(version))
    }

    // MARK: Environments

    func findEnvironmentFolders() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = containerFolders
        let home = layout.homeDirectory
        for name in ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []) {
            if Self.skippedHomeFolders.contains(name) { continue }
            if name.hasPrefix("."), !Self.searchedHiddenNames.contains(name) { continue }
            if [".pyenv", ".virtualenvs", ".local"].contains(name) { continue } // handled as containers
            roots.append(home.appendingPathComponent(name))
        }
        roots += extraRoots

        var found: [URL] = []
        var seen = Set<String>()
        var visited = 0
        func visit(_ folder: URL, depth: Int) {
            guard visited < maxVisitedFolders else { return }
            visited += 1
            let key = folder.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            if fm.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path) {
                found.append(folder)
                return // never descend into an environment
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            else { return }
            for child in children {
                let name = child.lastPathComponent
                if Self.skippedFolderNames.contains(name) { continue }
                if name.hasPrefix("."), !Self.searchedHiddenNames.contains(name) { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
                visit(child, depth: depth + 1)
            }
        }
        for root in roots where fm.fileExists(atPath: root.path) {
            visit(root, depth: 0)
        }
        return found
    }

    /// Parses `pyvenv.cfg` (`key = value` lines).
    public static func parseConfig(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func environmentID(for path: String) -> String {
        "env-" + Hashing.sha256Hex(of: Data(path.utf8)).prefix(12)
    }

    func manager(for folder: URL) -> EnvironmentManager {
        let path = folder.standardizedFileURL.path
        let home = layout.homeDirectory.standardizedFileURL.path
        if path.hasPrefix(home + "/.virtualenvs/") { return .virtualenvwrapper }
        if path.hasPrefix(home + "/.pyenv/versions/") { return .pyenvVirtualenv }
        if path.hasPrefix(home + "/.local/share/virtualenvs/") { return .pipenv }
        return .venv
    }

    func readEnvironment(at folder: URL) -> (PythonEnvironment, [ScannedFile])? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("pyvenv.cfg"), encoding: .utf8) else { return nil }
        let config = Self.parseConfig(text)
        let sitePackages = Self.sitePackages(in: folder)
        var version = config["version"] ?? config["version_info"] ?? ""
        if version.isEmpty, let site = sitePackages {
            version = site.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "python", with: "")
        }
        guard !version.isEmpty else { return nil }
        version = version.split(separator: ".").prefix(3).joined(separator: ".")

        let display = layout.displayPath(folder)
        let id = Self.environmentID(for: display)
        let manager = manager(for: folder)
        let isProjectLocal = manager == .venv
        let name = isProjectLocal && [".venv", "venv", "env", ".env"].contains(folder.lastPathComponent)
            ? folder.deletingLastPathComponent().lastPathComponent : folder.lastPathComponent
        let home = config["home"].map { layout.redact($0) }
        let packages = sitePackages.map(Self.readPackages) ?? []
        let interpreter = folder.appendingPathComponent("bin/python").resolvingSymlinksInPath()

        var projectFiles: [ScannedFile] = []
        if isProjectLocal {
            let project = folder.deletingLastPathComponent()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []).filter {
                ($0.hasPrefix("requirements") && $0.hasSuffix(".txt")) || ["pyproject.toml", "Pipfile", "Pipfile.lock", "poetry.lock",
                                                                            "setup.cfg", ".python-version"].contains($0)
            }.sorted()
            for fileName in names {
                let url = project.appendingPathComponent(fileName)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1_000_000,
                      let hash = try? Hashing.sha256Hex(ofFile: url) else { continue }
                let record = FileRecord(fileName: fileName, domain: .user, relativePath: fileName, originalPath: layout.displayPath(url),
                                        backupPath: "development/python/\(id)/project/\(fileName)", sha256: hash, size: Int64(values.fileSize ?? 0))
                projectFiles.append(ScannedFile(url: url, record: record))
            }
        }

        let environment = PythonEnvironment(
            id: id, name: name, path: display, manager: manager, pythonVersion: version, baseInterpreter: home,
            baseSource: home.map(PythonSource.from(path:)) ?? .unknown,
            architectures: MachO.architectures(ofFile: interpreter),
            packages: packages, pipVersion: packages.first { $0.normalizedName == "pip" }?.version,
            requirementsPath: "development/python/\(id)/requirements.txt",
            projectFiles: projectFiles.map(\.record))
        return (environment, projectFiles)
    }

    static func sitePackages(in folder: URL) -> URL? {
        let lib = folder.appendingPathComponent("lib")
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).filter { $0.hasPrefix("python") }.sorted()
        for candidate in candidates.reversed() {
            let site = lib.appendingPathComponent("\(candidate)/site-packages")
            if FileManager.default.fileExists(atPath: site.path) { return site }
        }
        return nil
    }

    /// Reads installed packages from `*.dist-info` / `*.egg-info` metadata.
    public static func readPackages(sitePackages: URL) -> [PythonPackage] {
        let fm = FileManager.default
        var packages: [String: PythonPackage] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: sitePackages.path)) ?? [] {
            let folder = sitePackages.appendingPathComponent(name)
            var metadataURL: URL?
            if name.hasSuffix(".dist-info") { metadataURL = folder.appendingPathComponent("METADATA") }
            else if name.hasSuffix(".egg-info") {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                metadataURL = isDirectory.boolValue ? folder.appendingPathComponent("PKG-INFO") : folder
            }
            guard let metadataURL, let metadata = try? String(contentsOf: metadataURL, encoding: .utf8),
                  let (packageName, version) = parseMetadata(metadata) else { continue }
            var origin: PackageOrigin = .index
            if let data = try? Data(contentsOf: folder.appendingPathComponent("direct_url.json")) {
                origin = parseDirectURL(data)
            }
            let package = PythonPackage(name: packageName, version: version, origin: origin)
            packages[package.normalizedName] = package
        }
        return packages.values.sorted { $0.normalizedName < $1.normalizedName }
    }

    /// Reads `Name:` and `Version:` from core metadata (RFC 822 style headers).
    public static func parseMetadata(_ text: String) -> (String, String)? {
        var name: String?
        var version: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break } // headers end at the first empty line
            if line.hasPrefix("Name:") { name = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Version:") { version = line.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        guard let name, let version, !name.isEmpty, !version.isEmpty else { return nil }
        return (name, version)
    }

    /// PEP 610 `direct_url.json`. Only the kind of origin is kept, never the URL or
    /// path itself, which may point to private repositories or folders.
    public static func parseDirectURL(_ data: Data) -> PackageOrigin {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .local }
        if let dirInfo = object["dir_info"] as? [String: Any], dirInfo["editable"] as? Bool == true { return .editable }
        if object["vcs_info"] != nil { return .vcs }
        if let url = object["url"] as? String, url.hasPrefix("file:") { return .local }
        return .local
    }

    // MARK: Settings

    func findSettings() -> [PythonSetting] {
        var result: [PythonSetting] = []
        let home = layout.homeDirectory
        for file in [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile"] {
            let url = home.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result += Self.parseSettings(text, source: "~/\(file)", layout: layout)
        }
        if let global = try? String(contentsOf: home.appendingPathComponent(".pyenv/version"), encoding: .utf8) {
            let value = global.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if Self.isSafeValue(value), !value.isEmpty { result.append(PythonSetting(key: "pyenv global", value: value, source: "~/.pyenv/version")) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.key).inserted }
    }

    static func parseSettings(_ text: String, source: String, layout: SystemLayout) -> [PythonSetting] {
        var result: [PythonSetting] = []
        let regex = try! NSRegularExpression(pattern: #"^\s*export\s+([A-Z_][A-Z0-9_]*)=(.*)$"#)
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[keyRange])
            guard safeSettingKeys.contains(key) else { continue }
            var value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            value = layout.redact(value).replacingOccurrences(of: "$HOME", with: "~")
            guard isSafeValue(value) else { continue }
            result.append(PythonSetting(key: key, value: value, source: source))
        }
        return result
    }

    /// Rejects anything that could carry credentials or expand to commands.
    static func isSafeValue(_ value: String) -> Bool {
        !value.contains("://") && !value.contains("@") && !value.contains("$(") && !value.contains("`") && value.count <= 200
    }
}
