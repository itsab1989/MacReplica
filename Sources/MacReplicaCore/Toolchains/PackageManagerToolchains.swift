import Foundation
import SQLite3

/// MacPorts: requested ports with their variants, read from the MacPorts registry database.
/// MacPorts has to be installed for each macOS version and needs administrator rights to install
/// ports, so the restore is guided: MacReplica shows the exact `port install` commands and checks the result.
public struct MacPortsProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .macports, ecosystem: .packageManagers, name: "MacPorts", website: "https://www.macports.org/install.php",
                            packages: .guided)
    }

    static func prefix(_ context: ToolchainContext) -> URL { context.systemPath("/opt/local") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let database = Self.prefix(context).appendingPathComponent("var/macports/registry/registry.db")
        guard ToolchainFiles.exists(database) else { return nil }
        let packages = Self.requestedPorts(database: database)
        return ToolchainRecord(provider: .macports, location: "/opt/local", packages: packages)
    }

    /// Reads `name, version, revision, variants` of requested, installed ports (read-only).
    static func requestedPorts(database: URL) -> [ToolchainPackage] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let query = "SELECT name, version, revision, variants FROM ports WHERE requested = 1 AND state = 'installed' ORDER BY name"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [ToolchainPackage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
            let name = column(0)
            let version = column(1) + (column(2).isEmpty ? "" : "_\(column(2))")
            let variants = column(3)
            guard ToolchainValidation.isSafePackageName(name), ToolchainValidation.isSafeVersion(version) else { continue }
            let extras = variants.split(separator: "+").map(String.init).filter(ToolchainValidation.isSafePackageName).map { "+\($0)" }
            result.append(ToolchainPackage(name: name, version: version, extras: extras))
        }
        return result
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        switch action.kind {
        case .manager:
            return ToolchainFiles.exists(Self.prefix(context).appendingPathComponent("bin/port"))
        case .package:
            guard let name = action.package?.name else { return false }
            let database = Self.prefix(context).appendingPathComponent("var/macports/registry/registry.db")
            return Self.requestedPorts(database: database).contains { $0.name == name }
        default:
            return false
        }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name) else { return nil }
        return (["sudo port -N install", package.name] + package.extras.filter { $0.hasPrefix("+") }).joined(separator: " ")
    }

    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] {
        [ToolchainAction(provider: .macports, kind: .manager)] + record.packages.map { ToolchainAction(provider: .macports, kind: .package, package: $0) }
    }
}

/// Nix: packages of the user's `nix profile`, read from the profile's `manifest.json`.
/// Nix itself is installed with the official installer (a guided step); packages from Nixpkgs are
/// then added automatically. Packages from other flakes are third-party sources and stay guided.
public struct NixProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .nix, ecosystem: .packageManagers, name: "Nix", website: "https://nixos.org/download/", packages: .automatic)
    }

    static func manifests(_ context: ToolchainContext) -> [URL] {
        [context.homePath(".nix-profile/manifest.json"), context.homePath(".local/state/nix/profiles/profile/manifest.json")]
    }

    static func nixExecutable(_ context: ToolchainContext) -> String {
        context.systemPath("/nix/var/nix/profiles/default/bin/nix").path
    }

    /// `legacyPackages.aarch64-darwin.hello` → `hello`, so the package is installed for the new Mac's platform.
    static func attribute(_ attrPath: String) -> String {
        let parts = attrPath.split(separator: ".").map(String.init)
        if parts.count >= 3, ["legacyPackages", "packages"].contains(parts[0]) { return parts.dropFirst(2).joined(separator: ".") }
        return attrPath
    }

    /// Manifest version 3 keeps elements in an object keyed by name, versions 1 and 2 in an array.
    static func parse(_ json: [String: Any]) -> [ToolchainPackage] {
        var elements: [(String?, [String: Any])] = []
        if let byName = json["elements"] as? [String: Any] {
            elements = byName.keys.sorted().compactMap { key in (byName[key] as? [String: Any]).map { (key, $0) } }
        } else if let list = json["elements"] as? [[String: Any]] {
            elements = list.map { (nil, $0) }
        }
        var result: [ToolchainPackage] = []
        for (_, element) in elements {
            guard element["active"] as? Bool ?? true, let attrPath = element["attrPath"] as? String else { continue }
            let attribute = attribute(attrPath)
            guard ToolchainValidation.isSafePackageName(attribute) else { continue }
            let source = element["originalUrl"] as? String ?? ""
            let fromNixpkgs = source == "flake:nixpkgs" || source.hasPrefix("github:NixOS/nixpkgs")
            result.append(ToolchainPackage(name: attribute, origin: fromNixpkgs ? .index : .vcs))
        }
        return result
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let json = Self.manifests(context).lazy.compactMap({ ToolchainFiles.json($0.resolvingSymlinksInPath()) }).first else { return nil }
        return ToolchainRecord(provider: .nix, location: "~/.nix-profile", packages: Self.parse(json))
    }

    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] {
        [ToolchainAction(provider: .nix, kind: .manager)]
            + record.packages.filter { $0.origin.isReinstallable }.map { ToolchainAction(provider: .nix, kind: .package, package: $0) }
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [Self.nixExecutable(context)] }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, package.origin.isReinstallable,
              ToolchainValidation.isSafePackageName(package.name),
              let nix = context.firstExecutable([Self.nixExecutable(context)]) else { return nil }
        return [ToolchainCommand(executable: nix, arguments: ["--extra-experimental-features", "nix-command flakes", "profile", "add",
                                                              "nixpkgs#\(package.name)"],
                                 environment: context.environment(prepending: [URL(fileURLWithPath: nix).deletingLastPathComponent().path]))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        switch action.kind {
        case .manager: return ToolchainFiles.exists(URL(fileURLWithPath: Self.nixExecutable(context)))
        case .package:
            guard let name = action.package?.name,
                  let json = Self.manifests(context).lazy.compactMap({ ToolchainFiles.json($0.resolvingSymlinksInPath()) }).first else { return false }
            return Self.parse(json).contains { $0.name == name }
        default: return false
        }
    }

    public func supportLevel(for action: ToolchainAction) -> SupportLevel {
        action.kind == .manager ? .guided : (action.package?.origin.isReinstallable == true ? .automatic : .guided)
    }
}

/// Pixi global environments from `~/.pixi/manifests/pixi-global.toml`, reinstalled with `pixi global install`.
public struct PixiProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .pixi, ecosystem: .packageManagers, name: "Pixi", managerFormula: "pixi", website: "https://pixi.sh",
                            environments: .automatic)
    }

    static func home(_ context: ToolchainContext) -> URL { context.homePath(".pixi") }

    /// Each `[envs.<name>]` table becomes an environment. Exposed commands with custom names are kept as `expose=a=b`.
    static func parse(_ text: String) -> [ToolchainEnvironment] {
        let document = MiniTOML.parse(text)
        guard let envs = document["envs"] as? [String: Any] else { return [] }
        return envs.keys.sorted().compactMap { name -> ToolchainEnvironment? in
            guard ToolchainValidation.isSafeVersion(name), let table = envs[name] as? [String: Any] else { return nil }
            let dependencies = table["dependencies"] as? [String: Any] ?? [:]
            var specs = dependencies.keys.sorted().compactMap { package -> String? in
                guard let spec = dependencies[package] as? String else { return nil }
                if spec == "*" { return package }
                return spec.first?.isNumber == true ? "\(package)=\(spec)" : "\(package)\(spec)"
            }.filter(ToolchainValidation.isSafeCondaSpec)
            let exposed = table["exposed"] as? [String: Any] ?? [:]
            specs += exposed.keys.sorted().compactMap { key in
                guard let target = exposed[key] as? String, key != target,
                      ToolchainValidation.isSafePackageName(key), ToolchainValidation.isSafePackageName(target) else { return nil }
                return "expose=\(key)=\(target)"
            }
            let channels = (table["channels"] as? [String] ?? []).filter(ToolchainValidation.isSafeChannel)
            return ToolchainEnvironment(name: name, path: "~/.pixi/envs/\(name)", requestedPackages: specs, channels: channels)
        }
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let text = try? String(contentsOf: Self.home(context).appendingPathComponent("manifests/pixi-global.toml"), encoding: .utf8) else { return nil }
        let environments = Self.parse(text)
        return environments.isEmpty ? nil : ToolchainRecord(provider: .pixi, location: "~/.pixi", environments: environments)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("pixi") + [Self.home(context).appendingPathComponent("bin/pixi").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .environment, let environment = action.environment, ToolchainValidation.isSafeVersion(environment.name),
              let pixi = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        var arguments = ["global", "install", "--environment", environment.name]
        for channel in environment.channels where ToolchainValidation.isSafeChannel(channel) { arguments += ["--channel", channel] }
        for spec in environment.requestedPackages where spec.hasPrefix("expose=") { arguments += ["--expose", String(spec.dropFirst(7))] }
        let packages = environment.requestedPackages.filter { !$0.hasPrefix("expose=") && ToolchainValidation.isSafeCondaSpec($0) }
        guard !packages.isEmpty else { return nil }
        return [ToolchainCommand(executable: pixi, arguments: arguments + packages,
                                 environment: context.environment(extra: ["PIXI_HOME": Self.home(context).path, "NO_COLOR": "1"]))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.environment?.name, ToolchainValidation.isSafeVersion(name) else { return false }
        return ToolchainFiles.exists(Self.home(context).appendingPathComponent("envs/\(name)/conda-meta"))
    }
}

/// mise: tools from the global configuration `~/.config/mise/config.toml`. Tools from mise's own
/// registry are restored with `mise use --global`; tools from other backends (`ubi:`, `aqua:`,
/// `github:` …) come from third-party sources and are guided.
public struct MiseProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .mise, ecosystem: .packageManagers, name: "mise", managerFormula: "mise", website: "https://mise.jdx.dev",
                            runtimes: .automatic)
    }

    static func config(_ context: ToolchainContext) -> URL { context.homePath(".config/mise/config.toml") }

    /// Reads `[tools]`: `node = "22"`, `python = ["3.12", "3.11"]` or `go = { version = "1.23" }`. The `[env]` table is never read.
    static func parse(_ text: String) -> [ToolchainRuntime] {
        guard let tools = MiniTOML.parse(text)["tools"] as? [String: Any] else { return [] }
        var result: [ToolchainRuntime] = []
        for tool in tools.keys.sorted() {
            var versions: [String] = []
            switch tools[tool] {
            case let value as String: versions = [value]
            case let value as [Any]: versions = value.compactMap { $0 as? String ?? ($0 as? [String: Any])?["version"] as? String }
            case let value as [String: Any]: versions = [value["version"] as? String].compactMap { $0 }
            default: break
            }
            for (index, version) in versions.enumerated() where ToolchainValidation.isSafeVersion(version) {
                let name = "\(tool)@\(version)"
                if ToolchainValidation.isSafePackageName(tool.replacingOccurrences(of: ":", with: "/")) {
                    result.append(ToolchainRuntime(version: name, isDefault: index == 0))
                }
            }
        }
        return result
    }

    static func isRegistryTool(_ runtime: ToolchainRuntime) -> Bool { !runtime.version.contains(":") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let text = try? String(contentsOf: Self.config(context), encoding: .utf8) else { return nil }
        let runtimes = Self.parse(text)
        return runtimes.isEmpty ? nil : ToolchainRecord(provider: .mise, location: "~/.config/mise", runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("mise") + [context.homePath(".local/bin/mise").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .runtime, let runtime = action.runtime, Self.isRegistryTool(runtime), runtime.isDefault,
              let mise = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        return [ToolchainCommand(executable: mise, arguments: ["use", "--global", "--yes", runtime.version],
                                 environment: context.environment(extra: ["MISE_YES": "1", "NO_COLOR": "1"]), timeout: 3600)]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let runtime = action.runtime, let at = runtime.version.firstIndex(of: "@") else { return false }
        let tool = String(runtime.version[..<at])
        let version = String(runtime.version[runtime.version.index(after: at)...])
        guard ToolchainValidation.isSafePackageName(tool), ToolchainValidation.isSafeVersion(version) else { return false }
        let installs = context.homePath(".local/share/mise/installs/\(tool)")
        return ToolchainFiles.directories(in: installs).contains { $0 == version || $0.hasPrefix(version + ".") }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
        return "mise use --global \(runtime.version)"
    }

    public func supportLevel(for action: ToolchainAction) -> SupportLevel {
        guard let runtime = action.runtime else { return .guided }
        return Self.isRegistryTool(runtime) && runtime.isDefault ? .automatic : .guided
    }
}

/// asdf: versions from `~/.tool-versions`. asdf plugins are Git repositories with their own scripts,
/// so MacReplica does not add them by itself; each version is a guided step.
public struct AsdfProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .asdf, ecosystem: .packageManagers, name: "asdf", managerFormula: "asdf", website: "https://asdf-vm.com",
                            runtimes: .guided)
    }

    static func parse(_ text: String) -> [ToolchainRuntime] {
        var result: [ToolchainRuntime] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "#").first?.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) ?? []
            guard fields.count >= 2, ToolchainValidation.isSafePackageName(fields[0]) else { continue }
            for (index, version) in fields.dropFirst().enumerated() where version != "system" && ToolchainValidation.isSafeVersion(version) {
                result.append(ToolchainRuntime(version: "\(fields[0])/\(version)", isDefault: index == 0))
            }
        }
        return result
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let text = try? String(contentsOf: context.homePath(".tool-versions"), encoding: .utf8),
              ToolchainFiles.exists(context.homePath(".asdf")) else { return nil }
        let runtimes = Self.parse(text)
        return runtimes.isEmpty ? nil : ToolchainRecord(provider: .asdf, location: "~/.asdf", runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return ToolchainFiles.exists(context.homePath(".asdf/installs/\(version)"))
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard let parts = action.runtime?.version.split(separator: "/", maxSplits: 1), parts.count == 2 else { return nil }
        return "asdf plugin add \(parts[0])\nasdf install \(parts[0]) \(parts[1])"
    }
}

/// pkgx / pkgm: packages in `~/.local/pkgs`. pkgx runs tools on demand and has no list of
/// requested packages, so they are recorded for reference only.
public struct PkgxProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .pkgx, ecosystem: .packageManagers, name: "pkgx", managerFormula: "pkgx", website: "https://pkgx.sh")
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        var packages: [ToolchainPackage] = []
        for root in [context.homePath(".local/pkgs")] {
            for project in ToolchainFiles.directories(in: root) where ToolchainValidation.isSafePackageName(project) {
                let versions = ToolchainFiles.directories(in: root.appendingPathComponent(project)).filter { $0.hasPrefix("v") }
                if let version = versions.last.map({ String($0.dropFirst()) }), ToolchainValidation.isSafeVersion(version) {
                    packages.append(ToolchainPackage(name: project, version: version))
                }
            }
        }
        let hasPkgx = context.homebrewExecutables("pkgx").contains { FileManager.default.isExecutableFile(atPath: $0) }
        guard hasPkgx || !packages.isEmpty else { return nil }
        return ToolchainRecord(provider: .pkgx, packages: packages)
    }

    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] { [] }
    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }
    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool { false }
}

/// Fink: installed packages from its dpkg database, for reference only (no release since 2022).
public struct FinkProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .fink, ecosystem: .packageManagers, name: "Fink", website: "https://www.finkproject.org")
    }

    /// Parses dpkg's `status` file: blocks of `Package:`, `Status:` and `Version:` lines.
    static func parseStatus(_ text: String) -> [ToolchainPackage] {
        var result: [ToolchainPackage] = []
        for block in text.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in block.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            guard let name = fields["Package"], fields["Status"]?.hasSuffix(" installed") == true,
                  ToolchainValidation.isSafePackageName(name) else { continue }
            result.append(ToolchainPackage(name: name, version: fields["Version"].flatMap { ToolchainValidation.isSafeVersion($0) ? $0 : nil }))
        }
        return result.sorted { $0.name < $1.name }
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        for prefix in ["/sw", "/opt/sw"] {
            let root = context.systemPath(prefix)
            guard ToolchainFiles.exists(root.appendingPathComponent("bin/fink")) else { continue }
            let status = (try? String(contentsOf: root.appendingPathComponent("var/lib/dpkg/status"), encoding: .utf8)) ?? ""
            return ToolchainRecord(provider: .fink, location: prefix, packages: Self.parseStatus(status))
        }
        return nil
    }

    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] { [] }
    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }
    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool { false }
}
