import Foundation

/// pyenv: Python versions in `~/.pyenv/versions`, rebuilt with `pyenv install`.
/// Environments made with pyenv-virtualenv are described by `PythonScanner` (symbolic links here).
public struct PyenvProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .pyenv, ecosystem: .python, name: "pyenv", managerFormula: "pyenv", website: "https://github.com/pyenv/pyenv",
                            runtimes: .automatic)
    }

    static func root(_ context: ToolchainContext) -> URL { context.homePath(".pyenv") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let versions = Self.root(context).appendingPathComponent("versions")
        guard ToolchainFiles.exists(versions) else { return nil }
        let globals = (try? String(contentsOf: Self.root(context).appendingPathComponent("version"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let runtimes = ToolchainFiles.directories(in: versions).filter { name in
            let folder = versions.appendingPathComponent(name)
            // Symbolic links and folders with pyvenv.cfg are environments, not interpreters.
            return !ToolchainFiles.isSymbolicLink(folder) && !ToolchainFiles.exists(folder.appendingPathComponent("pyvenv.cfg"))
                && ToolchainValidation.isSafeVersion(name)
        }.map { ToolchainRuntime(version: $0, isDefault: globals.first == $0, path: context.layout.displayPath(versions.appendingPathComponent($0))) }
        return ToolchainRecord(provider: .pyenv, location: context.layout.displayPath(Self.root(context)), runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("pyenv") + [Self.root(context).appendingPathComponent("bin/pyenv").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version),
              let pyenv = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let environment = context.environment(extra: ["PYENV_ROOT": Self.root(context).path])
        // Building Python from source takes several minutes.
        var commands = [ToolchainCommand(executable: pyenv, arguments: ["install", "--skip-existing", runtime.version],
                                         environment: environment, timeout: 3600)]
        if runtime.isDefault, !ToolchainFiles.exists(Self.root(context).appendingPathComponent("version")) {
            commands.append(ToolchainCommand(executable: pyenv, arguments: ["global", runtime.version], environment: environment, timeout: 60))
        }
        return commands
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .runtime, let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return ToolchainFiles.exists(Self.root(context).appendingPathComponent("versions/\(version)/bin/python"))
    }
}

/// uv: managed Python versions and tools, both restored with uv itself.
public struct UVProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .uv, ecosystem: .python, name: "uv", managerFormula: "uv", website: "https://docs.astral.sh/uv/",
                            runtimes: .automatic, packages: .automatic)
    }

    static func pythonFolder(_ context: ToolchainContext) -> URL { context.homePath(".local/share/uv/python") }
    static func toolFolder(_ context: ToolchainContext) -> URL { context.homePath(".local/share/uv/tools") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let pythons = Self.pythonFolder(context)
        let tools = Self.toolFolder(context)
        guard ToolchainFiles.exists(pythons) || ToolchainFiles.exists(tools) else { return nil }
        var runtimes: [ToolchainRuntime] = []
        for name in ToolchainFiles.directories(in: pythons) where !ToolchainFiles.isSymbolicLink(pythons.appendingPathComponent(name)) {
            if let version = Self.pythonVersion(fromFolder: name) { runtimes.append(ToolchainRuntime(version: version)) }
        }
        var packages: [ToolchainPackage] = []
        // The credentials folder next to these is never read.
        for name in ToolchainFiles.directories(in: tools) {
            let folder = tools.appendingPathComponent(name)
            guard let receipt = try? String(contentsOf: folder.appendingPathComponent("uv-receipt.toml"), encoding: .utf8),
                  let package = Self.package(fromReceipt: receipt, toolFolder: folder) else { continue }
            packages.append(package)
        }
        return ToolchainRecord(provider: .uv, location: "~/.local/share/uv", runtimes: runtimes, packages: packages)
    }

    /// `cpython-3.12.4-macos-aarch64-none` → `3.12.4`; other implementations keep their prefix (`pypy-3.10.14`).
    static func pythonVersion(fromFolder name: String) -> String? {
        let parts = name.split(separator: "-")
        guard parts.count >= 2, parts[1].range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil else { return nil }
        let version = parts[0] == "cpython" ? String(parts[1]) : "\(parts[0])-\(parts[1])"
        return ToolchainValidation.isSafeVersion(version) ? version : nil
    }

    /// Reads a `uv-receipt.toml`: the first requirement is the tool, further requirements were installed with `--with`.
    static func package(fromReceipt text: String, toolFolder: URL) -> ToolchainPackage? {
        let document = MiniTOML.parse(text)
        guard let requirements = MiniTOML.value(document, ["tool", "requirements"]) as? [[String: Any]],
              let main = requirements.first, let name = main["name"] as? String, ToolchainValidation.isSafePackageName(name) else { return nil }
        var origin: PackageOrigin = .index
        if main["git"] != nil { origin = .vcs }
        if main["path"] != nil || main["directory"] != nil || main["editable"] != nil { origin = .local }
        var extras = requirements.dropFirst().compactMap { $0["name"] as? String }.filter(ToolchainValidation.isSafePackageName).map { "with=\($0)" }
        if let features = main["extras"] as? [String] { extras += features.filter(ToolchainValidation.isSafePackageName).map { "extra=\($0)" } }
        if let python = MiniTOML.value(document, ["tool", "python"]) as? String, ToolchainValidation.isSafeVersion(python) { extras.append("python=\(python)") }
        let version = installedVersion(of: name, in: toolFolder)
        return ToolchainPackage(name: name, version: version, origin: origin, extras: extras)
    }

    /// The version from `<name>-<version>.dist-info` in the tool's own environment.
    static func installedVersion(of name: String, in folder: URL) -> String? {
        guard let site = PythonScanner.sitePackages(in: folder) else { return nil }
        let wanted = PythonPackage.normalize(name)
        return PythonScanner.readPackages(sitePackages: site).first { $0.normalizedName == wanted }.map(\.version)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("uv") + [context.homePath(".local/bin/uv").path, context.homePath(".cargo/bin/uv").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard let uv = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let environment = context.environment(extra: ["NO_COLOR": "1", "UV_NO_PROGRESS": "1"])
        switch action.kind {
        case .runtime:
            guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return nil }
            return [ToolchainCommand(executable: uv, arguments: ["python", "install", version], environment: environment)]
        case .package:
            guard let package = action.package, ToolchainValidation.isSafePackageName(package.name) else { return nil }
            let features = package.extras.filter { $0.hasPrefix("extra=") }.map { String($0.dropFirst(6)) }
            var requirement = package.name + (features.isEmpty ? "" : "[\(features.joined(separator: ","))]")
            if let version = package.version, ToolchainValidation.isSafeVersion(version) { requirement += "==\(version)" }
            var arguments = ["tool", "install", requirement]
            for extra in package.extras where extra.hasPrefix("with=") { arguments += ["--with", String(extra.dropFirst(5))] }
            if let python = package.extras.first(where: { $0.hasPrefix("python=") }) { arguments += ["--python", String(python.dropFirst(7))] }
            return [ToolchainCommand(executable: uv, arguments: arguments, environment: environment)]
        default:
            return nil
        }
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        switch action.kind {
        case .runtime:
            guard let version = action.runtime?.version else { return false }
            return ToolchainFiles.directories(in: Self.pythonFolder(context)).contains { Self.pythonVersion(fromFolder: $0) == version }
        case .package:
            guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name), !name.contains("/") else { return false }
            return ToolchainFiles.exists(Self.toolFolder(context).appendingPathComponent("\(name)/uv-receipt.toml"))
        default:
            return false
        }
    }
}

/// pipx: Python applications in their own environments, reinstalled with `pipx install`.
public struct PipxProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .pipx, ecosystem: .python, name: "pipx", managerFormula: "pipx", website: "https://pipx.pypa.io",
                            packages: .automatic)
    }

    /// pipx 1.3 and later use `~/Library/Application Support/pipx` unless the older `~/.local/pipx` exists.
    static func homes(_ context: ToolchainContext) -> [URL] {
        [context.homePath(".local/pipx"), context.homePath("Library/Application Support/pipx")]
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        var packages: [ToolchainPackage] = []
        var location: URL?
        for home in Self.homes(context) {
            let venvs = home.appendingPathComponent("venvs")
            for name in ToolchainFiles.directories(in: venvs) {
                guard let metadata = ToolchainFiles.json(venvs.appendingPathComponent("\(name)/pipx_metadata.json")),
                      let package = Self.package(fromMetadata: metadata) else { continue }
                packages.append(package)
                location = location ?? home
            }
        }
        return packages.isEmpty ? nil : ToolchainRecord(provider: .pipx, location: location.map(context.layout.displayPath), packages: packages)
    }

    /// Reads `pipx_metadata.json`. Packages installed from a URL or folder are kept as not reinstallable.
    static func package(fromMetadata metadata: [String: Any]) -> ToolchainPackage? {
        guard let main = metadata["main_package"] as? [String: Any], let name = main["package"] as? String,
              ToolchainValidation.isSafePackageName(name) else { return nil }
        let source = main["package_or_url"] as? String ?? name
        var origin: PackageOrigin = .index
        if source != name, !source.hasPrefix(name + "=") && !source.hasPrefix(name + "<") && !source.hasPrefix(name + ">") {
            origin = source.contains("git+") ? .vcs : .local
        }
        var extras: [String] = []
        if let injected = metadata["injected_packages"] as? [String: Any] {
            extras = injected.keys.sorted().filter(ToolchainValidation.isSafePackageName).map { "inject=\($0)" }
        }
        let version = (main["package_version"] as? String).flatMap { ToolchainValidation.isSafeVersion($0) ? $0 : nil }
        return ToolchainPackage(name: name, version: version, origin: origin, extras: extras)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("pipx") + [context.homePath(".local/bin/pipx").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let pipx = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let environment = context.environment(extra: ["PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_NO_INPUT": "1"])
        var spec = package.name
        if let version = package.version, ToolchainValidation.isSafeVersion(version) { spec += "==\(version)" }
        var commands = [ToolchainCommand(executable: pipx, arguments: ["install", spec], environment: environment)]
        let injected = package.extras.filter { $0.hasPrefix("inject=") }.map { String($0.dropFirst(7)) }
        if !injected.isEmpty {
            commands.append(ToolchainCommand(executable: pipx, arguments: ["inject", package.name] + injected, environment: environment))
        }
        return commands
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name), !name.contains("/") else { return false }
        return Self.homes(context).contains { ToolchainFiles.exists($0.appendingPathComponent("venvs/\(name)/pipx_metadata.json")) }
    }
}

/// Conda (Miniconda, Anaconda, Miniforge): environments rebuilt from the packages the user asked
/// for, as `conda env export --from-history` would list them, read from `conda-meta/history`.
public struct CondaProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .conda, ecosystem: .python, name: "Conda", managerCask: "miniforge",
                            website: "https://docs.conda.io/projects/conda/en/latest/user-guide/install/macos.html",
                            environments: .automatic)
    }

    /// Default installation folders of the distributions, in the home folder and in Homebrew's Caskroom.
    static func baseCandidates(_ context: ToolchainContext) -> [URL] {
        ["miniforge3", "miniconda3", "anaconda3", "mambaforge"].map { context.homePath($0) }
            + context.layout.homebrewPrefixes.flatMap { prefix in
                ["miniforge", "miniconda"].map { prefix.appendingPathComponent("Caskroom/\($0)/base") } + [prefix.appendingPathComponent("anaconda3")]
            }
    }

    static func bases(_ context: ToolchainContext) -> [URL] {
        baseCandidates(context).filter { ToolchainFiles.exists($0.appendingPathComponent("conda-meta")) && ToolchainFiles.exists($0.appendingPathComponent("bin/conda")) }
    }

    /// The Homebrew cask for the distribution that was installed.
    static func cask(forBase path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("anaconda") { return "anaconda" }
        if lower.contains("miniconda") { return "miniconda" }
        return "miniforge"
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let base = Self.bases(context).first else { return nil }
        var folders: [(name: String, folder: URL)] = [("base", base)]
        for name in ToolchainFiles.directories(in: base.appendingPathComponent("envs")) {
            folders.append((name, base.appendingPathComponent("envs/\(name)")))
        }
        // Environments created elsewhere are listed in ~/.conda/environments.txt; only those in the home folder are used.
        let registry = (try? String(contentsOf: context.homePath(".conda/environments.txt"), encoding: .utf8)) ?? ""
        let home = context.home.standardizedFileURL.path
        for line in registry.split(whereSeparator: \.isNewline) {
            let path = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).standardizedFileURL
            guard path.path.hasPrefix(home + "/"), !folders.contains(where: { $0.folder.standardizedFileURL == path }),
                  ToolchainFiles.exists(path.appendingPathComponent("conda-meta")) else { continue }
            folders.append((path.lastPathComponent, path))
        }
        var environments: [ToolchainEnvironment] = []
        for (name, folder) in folders {
            guard ToolchainValidation.isSafeVersion(name) else { continue }
            let history = (try? String(contentsOf: folder.appendingPathComponent("conda-meta/history"), encoding: .utf8)) ?? ""
            // The base environment's first entry is the installer's own; only later additions belong to the user.
            let specs = Self.requestedSpecs(fromHistory: history, skipFirstEntry: name == "base")
            if name == "base", specs.isEmpty { continue }
            let installed = Self.installedPackages(in: folder)
            environments.append(ToolchainEnvironment(
                name: name, path: context.layout.displayPath(folder), requestedPackages: specs,
                channels: Self.channels(installed.map(\.channel)), pythonVersion: installed.first { $0.name == "python" }?.version,
                installedCount: installed.count))
        }
        return ToolchainRecord(provider: .conda, location: context.layout.displayPath(base), homebrewFormula: nil, environments: environments)
    }

    /// Accumulates `# update specs: [...]` and removes `# remove specs: [...]` per package name.
    static func requestedSpecs(fromHistory history: String, skipFirstEntry: Bool) -> [String] {
        var specs: [String: String] = [:]
        var order: [String] = []
        var entry = 0
        for line in history.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("==>") { entry += 1; continue }
            if skipFirstEntry && entry <= 1 { continue }
            for (prefix, removing) in [("# update specs:", false), ("# install specs:", false), ("# remove specs:", true)] where line.hasPrefix(prefix) {
                for spec in parsePythonList(String(line.dropFirst(prefix.count))) where ToolchainValidation.isSafeCondaSpec(spec) {
                    let name = packageName(ofSpec: spec)
                    if removing {
                        specs[name] = nil
                    } else {
                        if specs[name] == nil, !order.contains(name) { order.append(name) }
                        specs[name] = spec
                    }
                }
            }
        }
        return order.compactMap { specs[$0] }
    }

    /// `numpy[version='<3']` → `numpy`; `conda-forge::xarray>=2024` → `xarray`.
    static func packageName(ofSpec spec: String) -> String {
        var name = spec
        if let range = name.range(of: "::") { name = String(name[range.upperBound...]) }
        let end = name.firstIndex { "=<>![ ".contains($0) } ?? name.endIndex
        return String(name[..<end]).lowercased()
    }

    /// Parses a Python list literal of strings such as `['python=3.12', "numpy[version='<3']"]`.
    static func parsePythonList(_ text: String) -> [String] {
        var items: [String] = []
        var quote: Character?
        var current = ""
        for character in text {
            if let open = quote {
                if character == open { items.append(current); current = ""; quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            }
        }
        return items
    }

    struct InstalledPackage { var name: String; var version: String; var channel: String }

    static func installedPackages(in environment: URL) -> [InstalledPackage] {
        let meta = environment.appendingPathComponent("conda-meta")
        return ((try? FileManager.default.contentsOfDirectory(atPath: meta.path)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let json = ToolchainFiles.json(meta.appendingPathComponent(file)), let name = json["name"] as? String,
                  let version = json["version"] as? String else { return nil }
            return InstalledPackage(name: name, version: version, channel: json["channel"] as? String ?? "")
        }
    }

    /// Channel names from channel URLs (`https://conda.anaconda.org/conda-forge/osx-arm64` → `conda-forge`);
    /// Anaconda's own `pkgs/main` channels become `defaults`. URLs with credentials or tokens are dropped.
    static func channels(_ urls: [String]) -> [String] {
        var result: [String] = []
        for value in urls {
            var name: String?
            if value.contains("repo.anaconda.com") || value.hasPrefix("pkgs/") { name = "defaults" }
            else if let url = URL(string: value), url.host == "conda.anaconda.org", url.user == nil, !url.path.contains("/t/") {
                name = url.pathComponents.dropFirst().first
            } else if !value.contains("/") { name = value }
            if let name, ToolchainValidation.isSafeChannel(name), !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// The `environment.yml` used to recreate an environment.
    static func environmentFile(_ environment: ToolchainEnvironment) -> String {
        var lines = ["name: \(environment.name)"]
        let channels = environment.channels.filter(ToolchainValidation.isSafeChannel)
        if !channels.isEmpty { lines.append("channels:"); lines += channels.map { "  - \($0)" } }
        lines.append("dependencies:")
        lines += environment.requestedPackages.filter(ToolchainValidation.isSafeCondaSpec).map { "  - \"\($0)\"" }
        return lines.joined(separator: "\n") + "\n"
    }

    public func managerPackage(for record: ToolchainRecord) -> HomebrewPackageReference? {
        .cask(Self.cask(forBase: record.location ?? ""))
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        Self.baseCandidates(context).map { $0.appendingPathComponent("bin/conda").path } + context.homebrewExecutables("conda")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .environment, let environment = action.environment, ToolchainValidation.isSafeVersion(environment.name),
              !environment.requestedPackages.isEmpty,
              let conda = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        // Anaconda's terms of service are never accepted on the user's behalf: no CI variable for conda.
        var variables = context.environment(prepending: [URL(fileURLWithPath: conda).deletingLastPathComponent().path])
        variables["CI"] = nil
        if environment.name == "base" {
            let specs = environment.requestedPackages.filter(ToolchainValidation.isSafeCondaSpec)
            return [ToolchainCommand(executable: conda, arguments: ["install", "--yes", "--name", "base"]
                                     + environment.channels.filter(ToolchainValidation.isSafeChannel).flatMap { ["--channel", $0] } + specs,
                                     environment: variables)]
        }
        guard let folder = context.workFolder else { return nil }
        let file = folder.appendingPathComponent("conda-\(environment.name).yml")
        return [ToolchainCommand(executable: conda, arguments: ["env", "create", "--yes", "--name", environment.name, "--file", file.path],
                                 environment: variables, timeout: 3600, inputFiles: [file: Self.environmentFile(environment)])]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .environment, let environment = action.environment, ToolchainValidation.isSafeVersion(environment.name) else { return false }
        let bases = Self.bases(context)
        if environment.name == "base" {
            guard let base = bases.first else { return false }
            let installed = Set(Self.installedPackages(in: base).map { $0.name.lowercased() })
            return environment.requestedPackages.allSatisfy { installed.contains(Self.packageName(ofSpec: $0)) }
        }
        return bases.contains { ToolchainFiles.exists($0.appendingPathComponent("envs/\(environment.name)/conda-meta")) }
    }
}
