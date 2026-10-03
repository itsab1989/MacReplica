import Foundation

// MARK: - Node.js runtimes

/// Where a Node.js installation keeps its global packages and executables.
struct NodeInstallation {
    var runtime: RuntimeReference
    /// The `bin` folder with `node` and `npm`.
    var bin: URL
    /// `lib/node_modules` of the installation.
    var modules: URL
}

enum NodeLayout {
    /// nvm keeps versions in `~/.nvm/versions/node/v20.11.1`.
    static func nvmRoot(_ context: ToolchainContext) -> URL { context.homePath(".nvm") }

    /// fnm uses the first existing of these folders (see fnm's `directories.rs`).
    static func fnmCandidates(_ context: ToolchainContext) -> [URL] {
        [context.homePath(".local/share/fnm"), context.homePath(".fnm"), context.homePath("Library/Application Support/fnm")]
    }

    static func fnmRoot(_ context: ToolchainContext) -> URL? {
        fnmCandidates(context).first { ToolchainFiles.exists($0.appendingPathComponent("node-versions")) }
    }

    /// Homebrew's `node` and versioned `node@NN` formulae.
    static func homebrewInstallations(_ context: ToolchainContext) -> [NodeInstallation] {
        var result: [NodeInstallation] = []
        for prefix in context.layout.homebrewPrefixes {
            let opt = prefix.appendingPathComponent("opt")
            let formulae = ((try? FileManager.default.contentsOfDirectory(atPath: opt.path)) ?? [])
                .filter { $0 == "node" || $0.range(of: #"^node@\d+$"#, options: .regularExpression) != nil }.sorted()
            for formula in formulae where ToolchainFiles.exists(opt.appendingPathComponent("\(formula)/bin/node")) {
                // `node` installs its global packages into the prefix; keg-only `node@NN` into its own keg.
                let modules = formula == "node" ? prefix.appendingPathComponent("lib/node_modules")
                    : opt.appendingPathComponent("\(formula)/lib/node_modules")
                result.append(NodeInstallation(runtime: RuntimeReference(source: .homebrew, version: formula),
                                               bin: opt.appendingPathComponent("\(formula)/bin"), modules: modules))
            }
        }
        return result
    }

    /// The installation a runtime reference points to on this Mac.
    static func installation(for runtime: RuntimeReference, context: ToolchainContext, fnmRootHint: String? = nil) -> NodeInstallation? {
        guard ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
        switch (runtime.source, runtime.provider) {
        case (.homebrew, _):
            for prefix in context.layout.homebrewPrefixes {
                let keg = prefix.appendingPathComponent("opt/\(runtime.version)")
                let modules = runtime.version == "node" ? prefix.appendingPathComponent("lib/node_modules") : keg.appendingPathComponent("lib/node_modules")
                let candidate = NodeInstallation(runtime: runtime, bin: keg.appendingPathComponent("bin"), modules: modules)
                if ToolchainFiles.exists(keg) { return candidate }
            }
            return context.layout.homebrewPrefixes.first.map { prefix in
                let keg = prefix.appendingPathComponent("opt/\(runtime.version)")
                return NodeInstallation(runtime: runtime, bin: keg.appendingPathComponent("bin"),
                                        modules: runtime.version == "node" ? prefix.appendingPathComponent("lib/node_modules")
                                            : keg.appendingPathComponent("lib/node_modules"))
            }
        case (.manager, .nvm?):
            let folder = nvmRoot(context).appendingPathComponent("versions/node/\(runtime.version)")
            return NodeInstallation(runtime: runtime, bin: folder.appendingPathComponent("bin"), modules: folder.appendingPathComponent("lib/node_modules"))
        case (.manager, .fnm?):
            let root = fnmRoot(context) ?? fnmCandidates(context)[0]
            let folder = root.appendingPathComponent("node-versions/\(runtime.version)/installation")
            return NodeInstallation(runtime: runtime, bin: folder.appendingPathComponent("bin"), modules: folder.appendingPathComponent("lib/node_modules"))
        default:
            return nil
        }
    }

    /// Every Node.js installation whose global packages MacReplica records.
    static func allInstallations(_ context: ToolchainContext) -> [NodeInstallation] {
        var result = homebrewInstallations(context)
        for version in ToolchainFiles.directories(in: nvmRoot(context).appendingPathComponent("versions/node")) {
            let runtime = RuntimeReference(source: .manager, provider: .nvm, version: version)
            if let installation = installation(for: runtime, context: context) { result.append(installation) }
        }
        if let root = fnmRoot(context) {
            for version in ToolchainFiles.directories(in: root.appendingPathComponent("node-versions")) {
                let runtime = RuntimeReference(source: .manager, provider: .fnm, version: version)
                if let installation = installation(for: runtime, context: context) { result.append(installation) }
            }
        }
        return result
    }

    /// Reads `name` and `version` from the `package.json` files in a `node_modules` folder.
    /// Packages that come with Node.js itself (`npm`, `corepack`) are left out; linked packages
    /// (`npm link`) and git or local installs are kept but marked as not reinstallable.
    static func globalPackages(in modules: URL, runtime: RuntimeReference?) -> [ToolchainPackage] {
        let lock = ToolchainFiles.json(modules.appendingPathComponent(".package-lock.json"))?["packages"] as? [String: Any] ?? [:]
        var names: [String] = []
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? [] where !entry.hasPrefix(".") {
            if entry.hasPrefix("@") {
                for scoped in (try? FileManager.default.contentsOfDirectory(atPath: modules.appendingPathComponent(entry).path)) ?? []
                where !scoped.hasPrefix(".") { names.append("\(entry)/\(scoped)") }
            } else {
                names.append(entry)
            }
        }
        var result: [ToolchainPackage] = []
        for name in names.sorted() where !["npm", "corepack"].contains(name) {
            let folder = modules.appendingPathComponent(name)
            guard let manifest = ToolchainFiles.json(folder.appendingPathComponent("package.json")),
                  let recordedName = manifest["name"] as? String, recordedName == name,
                  ToolchainValidation.isSafePackageName(name) else { continue }
            let version = manifest["version"] as? String
            var origin: PackageOrigin = .index
            if ToolchainFiles.isSymbolicLink(folder) { origin = .editable }
            if let resolved = (lock["node_modules/\(name)"] as? [String: Any])?["resolved"] as? String {
                if resolved.hasPrefix("git") || resolved.hasPrefix("github:") { origin = .vcs }
                if resolved.hasPrefix("file:") { origin = .local }
            }
            if let version, !ToolchainValidation.isSafeVersion(version) { continue }
            result.append(ToolchainPackage(name: name, version: version, runtime: runtime, origin: origin))
        }
        return result
    }

    static func isPackageInstalled(_ name: String, in modules: URL) -> Bool {
        guard ToolchainValidation.isSafePackageName(name) else { return false }
        return ToolchainFiles.exists(modules.appendingPathComponent(name).appendingPathComponent("package.json"))
    }
}

/// nvm: Node.js versions in `~/.nvm`. nvm is a shell function, so MacReplica cannot run it;
/// versions are restored as guided steps (the user runs `nvm install`, MacReplica checks the result).
public struct NVMProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .nvm, ecosystem: .node, name: "nvm", website: "https://github.com/nvm-sh/nvm#installing-and-updating",
                            runtimes: .guided)
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let root = NodeLayout.nvmRoot(context)
        guard ToolchainFiles.exists(root.appendingPathComponent("nvm.sh")) else { return nil }
        let alias = ToolchainFiles.firstLine(root.appendingPathComponent("alias/default"))
        let versions = ToolchainFiles.directories(in: root.appendingPathComponent("versions/node")).filter(ToolchainValidation.isSafeVersion)
        let runtimes = versions.map { ToolchainRuntime(version: $0, isDefault: Self.matches(alias: alias, version: $0, all: versions),
                                                       path: context.layout.displayPath(root.appendingPathComponent("versions/node/\($0)"))) }
        return ToolchainRecord(provider: .nvm, location: context.layout.displayPath(root), runtimes: runtimes)
    }

    /// The default alias may name an exact version (`v20.11.1`) or a prefix (`20`); the newest match is the default.
    static func matches(alias: String?, version: String, all: [String]) -> Bool {
        guard let alias, !alias.isEmpty else { return false }
        let wanted = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
        let candidates = all.filter { $0.dropFirst() == wanted || $0.dropFirst().hasPrefix(wanted + ".") }
        return candidates.last == version
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        switch action.kind {
        case .manager: return ToolchainFiles.exists(NodeLayout.nvmRoot(context).appendingPathComponent("nvm.sh"))
        case .runtime:
            guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
            return ToolchainFiles.exists(NodeLayout.nvmRoot(context).appendingPathComponent("versions/node/\(version)/bin/node"))
        default: return false
        }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
        var lines = ["nvm install \(runtime.version)"]
        if runtime.isDefault { lines.append("nvm alias default \(runtime.version)") }
        return lines.joined(separator: "\n")
    }
}

/// fnm: a single binary, so versions are installed automatically.
public struct FNMProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .fnm, ecosystem: .node, name: "fnm", managerFormula: "fnm", website: "https://github.com/Schniz/fnm",
                            runtimes: .automatic)
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let root = NodeLayout.fnmRoot(context) else { return nil }
        // `aliases/default` is a symbolic link to `node-versions/<version>/installation`.
        let defaultTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("aliases/default").path))
        let defaultVersion = defaultTarget.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
        let runtimes = ToolchainFiles.directories(in: root.appendingPathComponent("node-versions")).filter(ToolchainValidation.isSafeVersion).map {
            ToolchainRuntime(version: $0, isDefault: $0 == defaultVersion, path: context.layout.displayPath(root.appendingPathComponent("node-versions/\($0)")))
        }
        return ToolchainRecord(provider: .fnm, location: context.layout.displayPath(root), runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("fnm") + NodeLayout.fnmCandidates(context).map { $0.appendingPathComponent("fnm").path }
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version),
              let fnm = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let root = NodeLayout.fnmRoot(context) ?? NodeLayout.fnmCandidates(context)[0]
        let environment = context.environment(extra: ["FNM_DIR": root.path])
        var commands = [ToolchainCommand(executable: fnm, arguments: ["install", runtime.version], environment: environment)]
        if runtime.isDefault { commands.append(ToolchainCommand(executable: fnm, arguments: ["default", runtime.version], environment: environment, timeout: 60)) }
        return commands
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .runtime, let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return NodeLayout.fnmCandidates(context).contains {
            ToolchainFiles.exists($0.appendingPathComponent("node-versions/\(version)/installation/bin/node"))
        }
    }
}

/// Volta: Node.js, package managers and global tools pinned in `~/.volta`.
/// Volta is no longer maintained upstream; its own documentation recommends mise.
public struct VoltaProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .volta, ecosystem: .node, name: "Volta", managerFormula: "volta", website: "https://volta.sh",
                            runtimes: .automatic, packages: .automatic)
    }

    static func root(_ context: ToolchainContext) -> URL { context.homePath(".volta") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let root = Self.root(context)
        guard ToolchainFiles.exists(root.appendingPathComponent("tools")) else { return nil }
        let platform = ToolchainFiles.json(root.appendingPathComponent("tools/user/platform.json"))
        let defaultNode = (platform?["node"] as? [String: Any])?["runtime"] as? String
        let runtimes = ToolchainFiles.directories(in: root.appendingPathComponent("tools/image/node")).filter(ToolchainValidation.isSafeVersion).map {
            ToolchainRuntime(version: $0, isDefault: $0 == defaultNode)
        }
        var packages: [ToolchainPackage] = []
        let packageFolder = root.appendingPathComponent("tools/user/packages")
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: packageFolder.path)) ?? []).sorted() where file.hasSuffix(".json") {
            let info = ToolchainFiles.json(packageFolder.appendingPathComponent(file))
            let name = (info?["name"] as? String) ?? String(file.dropLast(5))
            let version = info?["version"] as? String
            guard ToolchainValidation.isSafePackageName(name), version.map(ToolchainValidation.isSafeVersion) ?? true else { continue }
            packages.append(ToolchainPackage(name: name, version: version))
        }
        return ToolchainRecord(provider: .volta, location: context.layout.displayPath(root), runtimes: runtimes, packages: packages)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        [Self.root(context).appendingPathComponent("bin/volta").path] + context.homebrewExecutables("volta")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard let volta = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let environment = context.environment(prepending: [Self.root(context).appendingPathComponent("bin").path],
                                              extra: ["VOLTA_HOME": Self.root(context).path])
        switch action.kind {
        case .runtime:
            guard let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
            // `install` also makes the version the default; other versions are only fetched.
            return [ToolchainCommand(executable: volta, arguments: [runtime.isDefault ? "install" : "fetch", "node@\(runtime.version)"],
                                     environment: environment)]
        case .package:
            guard let package = action.package, ToolchainValidation.isSafePackageName(package.name) else { return nil }
            let spec = package.version.flatMap { ToolchainValidation.isSafeVersion($0) ? "\(package.name)@\($0)" : nil } ?? package.name
            return [ToolchainCommand(executable: volta, arguments: ["install", spec], environment: environment)]
        default:
            return nil
        }
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        let root = Self.root(context)
        switch action.kind {
        case .runtime:
            guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
            return ToolchainFiles.exists(root.appendingPathComponent("tools/image/node/\(version)"))
        case .package:
            guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name), !name.contains("/") || name.hasPrefix("@") else { return false }
            return ToolchainFiles.exists(root.appendingPathComponent("tools/user/packages/\(name).json"))
        default:
            return false
        }
    }
}

// MARK: - Global packages

/// Global npm packages of every recorded Node.js installation (Homebrew, nvm, fnm).
/// They are reinstalled with the `npm` of the same installation once that installation exists.
public struct NPMProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .npm, ecosystem: .node, name: "npm", website: "https://docs.npmjs.com/cli/commands/npm-install",
                            packages: .automatic)
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let packages = NodeLayout.allInstallations(context).flatMap { NodeLayout.globalPackages(in: $0.modules, runtime: $0.runtime) }
        return packages.isEmpty ? nil : ToolchainRecord(provider: .npm, packages: packages)
    }

    private func installation(_ action: ToolchainAction, context: ToolchainContext) -> NodeInstallation? {
        guard let runtime = action.package?.runtime else { return nil }
        return NodeLayout.installation(for: runtime, context: context)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        installation(action, context: context).map { [$0.bin.appendingPathComponent("npm").path] } ?? []
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let node = installation(action, context: context),
              let npm = context.firstExecutable([node.bin.appendingPathComponent("npm").path]) else { return nil }
        let spec = package.version.flatMap { ToolchainValidation.isSafeVersion($0) ? "\(package.name)@\($0)" : nil } ?? package.name
        // npm is a Node.js script; the installation's `bin` folder goes first in PATH so that it finds its own `node`.
        return [ToolchainCommand(executable: npm, arguments: ["install", "--global", "--no-fund", "--no-audit", spec],
                                 environment: context.environment(prepending: [node.bin.path], extra: ["npm_config_update_notifier": "false"]))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, let node = installation(action, context: context) else { return false }
        return NodeLayout.isPackageInstalled(name, in: node.modules)
    }
}

/// pnpm global packages (`$PNPM_HOME/global/<layout>/package.json`).
public struct PNPMProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .pnpm, ecosystem: .node, name: "pnpm", managerFormula: "pnpm", website: "https://pnpm.io/installation",
                            packages: .automatic)
    }

    static func home(_ context: ToolchainContext) -> URL { context.homePath("Library/pnpm") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let global = Self.home(context).appendingPathComponent("global")
        var packages: [ToolchainPackage] = []
        for layout in ToolchainFiles.directories(in: global) {
            let folder = global.appendingPathComponent(layout)
            guard let dependencies = ToolchainFiles.json(folder.appendingPathComponent("package.json"))?["dependencies"] as? [String: String] else { continue }
            for name in dependencies.keys.sorted() where ToolchainValidation.isSafePackageName(name) {
                let installed = ToolchainFiles.json(folder.appendingPathComponent("node_modules/\(name)/package.json"))?["version"] as? String
                let version = installed ?? dependencies[name].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "^~=")) }
                packages.append(ToolchainPackage(name: name, version: version.flatMap { ToolchainValidation.isSafeVersion($0) ? $0 : nil }))
            }
        }
        return packages.isEmpty ? nil : ToolchainRecord(provider: .pnpm, location: context.layout.displayPath(Self.home(context)), packages: packages)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("pnpm") + [Self.home(context).appendingPathComponent("pnpm").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let pnpm = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let home = Self.home(context).path
        let spec = package.version.flatMap { ToolchainValidation.isSafeVersion($0) ? "\(package.name)@\($0)" : nil } ?? package.name
        return [ToolchainCommand(executable: pnpm, arguments: ["add", "--global", spec],
                                 environment: context.environment(prepending: [home], extra: ["PNPM_HOME": home]))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name) else { return false }
        let global = Self.home(context).appendingPathComponent("global")
        return ToolchainFiles.directories(in: global).contains {
            ToolchainFiles.exists(global.appendingPathComponent("\($0)/node_modules/\(name)/package.json"))
        }
    }
}

/// Yarn 1 ("classic") global packages in `~/.config/yarn/global`. Yarn 2 and later has no global packages.
public struct YarnProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .yarn, ecosystem: .node, name: "Yarn", managerFormula: "yarn", website: "https://classic.yarnpkg.com",
                            packages: .automatic)
    }

    static func global(_ context: ToolchainContext) -> URL { context.homePath(".config/yarn/global") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let global = Self.global(context)
        guard let dependencies = ToolchainFiles.json(global.appendingPathComponent("package.json"))?["dependencies"] as? [String: String] else { return nil }
        let packages = dependencies.keys.sorted().filter(ToolchainValidation.isSafePackageName).map { name -> ToolchainPackage in
            let version = ToolchainFiles.json(global.appendingPathComponent("node_modules/\(name)/package.json"))?["version"] as? String
            return ToolchainPackage(name: name, version: version.flatMap { ToolchainValidation.isSafeVersion($0) ? $0 : nil })
        }
        return packages.isEmpty ? nil : ToolchainRecord(provider: .yarn, location: context.layout.displayPath(global), packages: packages)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("yarn")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let yarn = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let spec = package.version.flatMap { ToolchainValidation.isSafeVersion($0) ? "\(package.name)@\($0)" : nil } ?? package.name
        return [ToolchainCommand(executable: yarn, arguments: ["global", "add", "--non-interactive", spec], environment: context.environment())]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name else { return false }
        return NodeLayout.isPackageInstalled(name, in: Self.global(context).appendingPathComponent("node_modules"))
    }
}
