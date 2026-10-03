import Foundation

// MARK: - Ruby

/// rbenv: Ruby versions in `~/.rbenv/versions`, built with ruby-build.
public struct RbenvProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .rbenv, ecosystem: .ruby, name: "rbenv", managerFormula: "rbenv", website: "https://github.com/rbenv/rbenv",
                            runtimes: .automatic)
    }

    static func root(_ context: ToolchainContext) -> URL { context.homePath(".rbenv") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let versions = Self.root(context).appendingPathComponent("versions")
        guard ToolchainFiles.exists(versions) else { return nil }
        let global = ToolchainFiles.firstLine(Self.root(context).appendingPathComponent("version"))
        let runtimes = ToolchainFiles.directories(in: versions)
            .filter { !ToolchainFiles.isSymbolicLink(versions.appendingPathComponent($0)) && ToolchainValidation.isSafeVersion($0) }
            .map { ToolchainRuntime(version: $0, isDefault: $0 == global, path: context.layout.displayPath(versions.appendingPathComponent($0))) }
        return ToolchainRecord(provider: .rbenv, location: context.layout.displayPath(Self.root(context)), runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("rbenv") + [Self.root(context).appendingPathComponent("bin/rbenv").path]
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version),
              let rbenv = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        let environment = context.environment(extra: ["RBENV_ROOT": Self.root(context).path])
        var commands = [ToolchainCommand(executable: rbenv, arguments: ["install", "--skip-existing", runtime.version],
                                         environment: environment, timeout: 3600)]
        if runtime.isDefault, !ToolchainFiles.exists(Self.root(context).appendingPathComponent("version")) {
            commands.append(ToolchainCommand(executable: rbenv, arguments: ["global", runtime.version], environment: environment, timeout: 60))
        }
        return commands
    }

    /// ruby-build is a separate formula; both are needed to install versions.
    public func managerPackage(for record: ToolchainRecord) -> HomebrewPackageReference? { .formula("rbenv") }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .runtime, let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return ToolchainFiles.exists(Self.root(context).appendingPathComponent("versions/\(version)/bin/ruby"))
    }
}

/// RVM: installed with a shell script and used as a shell function, so versions are guided steps.
public struct RVMProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .rvm, ecosystem: .ruby, name: "RVM", website: "https://rvm.io/rvm/install", runtimes: .guided)
    }

    static func root(_ context: ToolchainContext) -> URL { context.homePath(".rvm") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let rubies = Self.root(context).appendingPathComponent("rubies")
        guard ToolchainFiles.exists(rubies) else { return nil }
        let alias = (try? String(contentsOf: Self.root(context).appendingPathComponent("config/alias"), encoding: .utf8)) ?? ""
        let defaultName = alias.split(whereSeparator: \.isNewline).first { $0.hasPrefix("default=") }.map { String($0.dropFirst(8)) }
        let runtimes = ToolchainFiles.directories(in: rubies).filter { $0 != "default" && ToolchainValidation.isSafeVersion($0) }
            .map { ToolchainRuntime(version: $0, isDefault: $0 == defaultName) }
        return ToolchainRecord(provider: .rvm, location: context.layout.displayPath(Self.root(context)), runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .runtime, let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return ToolchainFiles.exists(Self.root(context).appendingPathComponent("rubies/\(version)/bin/ruby"))
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
        return "rvm install \(runtime.version)" + (runtime.isDefault ? "\nrvm alias create default \(runtime.version)" : "")
    }
}

/// Gems installed into each recorded Ruby (Homebrew, rbenv, RVM), reinstalled with that Ruby's `gem`.
public struct GemProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .gem, ecosystem: .ruby, name: "RubyGems", website: "https://guides.rubygems.org", packages: .automatic)
    }

    /// Gems that ship with Ruby itself ("bundled gems"); they come back with the Ruby and are not listed.
    static let bundledGems: Set<String> = ["minitest", "power_assert", "rake", "test-unit", "rexml", "rss", "net-ftp", "net-imap", "net-pop",
                                           "net-smtp", "matrix", "prime", "rbs", "typeprof", "debug", "racc", "mutex_m", "getoptlong", "base64",
                                           "bigdecimal", "observer", "abbrev", "resolv-replace", "rinda", "drb", "nkf", "syslog", "csv",
                                           "repl_type_completor", "ostruct", "pstore", "benchmark", "logger", "rdoc", "win32ole", "irb", "reline",
                                           "readline", "fiddle"]

    struct RubyInstallation {
        var runtime: RuntimeReference
        var bin: URL
        /// `lib/ruby/gems` (one folder per ABI version below it), or an RVM gem folder.
        var gemRoots: [URL]
        var gemHome: URL?
    }

    static func installations(_ context: ToolchainContext) -> [RubyInstallation] {
        var result: [RubyInstallation] = []
        for prefix in context.layout.homebrewPrefixes where ToolchainFiles.exists(prefix.appendingPathComponent("opt/ruby/bin/ruby")) {
            result.append(RubyInstallation(runtime: RuntimeReference(source: .homebrew, version: "ruby"),
                                           bin: prefix.appendingPathComponent("opt/ruby/bin"),
                                           gemRoots: abiFolders(prefix.appendingPathComponent("lib/ruby/gems"))))
        }
        let rbenv = context.homePath(".rbenv/versions")
        for version in ToolchainFiles.directories(in: rbenv) where !ToolchainFiles.isSymbolicLink(rbenv.appendingPathComponent(version)) {
            let folder = rbenv.appendingPathComponent(version)
            result.append(RubyInstallation(runtime: RuntimeReference(source: .manager, provider: .rbenv, version: version),
                                           bin: folder.appendingPathComponent("bin"), gemRoots: abiFolders(folder.appendingPathComponent("lib/ruby/gems"))))
        }
        let rvm = context.homePath(".rvm")
        for version in ToolchainFiles.directories(in: rvm.appendingPathComponent("rubies")) where version != "default" {
            let gems = rvm.appendingPathComponent("gems/\(version)")
            result.append(RubyInstallation(runtime: RuntimeReference(source: .manager, provider: .rvm, version: version),
                                           bin: rvm.appendingPathComponent("rubies/\(version)/bin"), gemRoots: [gems], gemHome: gems))
        }
        return result
    }

    static func abiFolders(_ gems: URL) -> [URL] {
        ToolchainFiles.directories(in: gems).map { gems.appendingPathComponent($0) }
    }

    /// `nokogiri-1.16.7-arm64-darwin.gemspec` → (`nokogiri`, `1.16.7`).
    static func parseGemspecName(_ file: String) -> (String, String)? {
        guard file.hasSuffix(".gemspec") else { return nil }
        let stem = String(file.dropLast(8))
        let regex = try! NSRegularExpression(pattern: #"^(.+?)-(\d[A-Za-z0-9.]*)(-.+)?$"#)
        guard let result = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let name = Range(result.range(at: 1), in: stem), let version = Range(result.range(at: 2), in: stem) else { return nil }
        return (String(stem[name]), String(stem[version]))
    }

    /// Regular gems have their gemspec in `specifications/`; default gems in `specifications/default/` are skipped.
    static func gems(in roots: [URL]) -> [(String, String)] {
        var newest: [String: String] = [:]
        for root in roots {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("specifications").path)) ?? [] {
                guard let (name, version) = parseGemspecName(file), !bundledGems.contains(name),
                      ToolchainValidation.isSafePackageName(name), ToolchainValidation.isSafeVersion(version) else { continue }
                if let existing = newest[name], VersionComparison.compare(existing, version) != .orderedAscending { continue }
                newest[name] = version
            }
        }
        return newest.sorted { $0.key < $1.key }
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let packages = Self.installations(context).flatMap { installation in
            Self.gems(in: installation.gemRoots).map { ToolchainPackage(name: $0.0, version: $0.1, runtime: installation.runtime) }
        }
        return packages.isEmpty ? nil : ToolchainRecord(provider: .gem, packages: packages)
    }

    func installation(_ action: ToolchainAction, context: ToolchainContext) -> RubyInstallation? {
        guard let runtime = action.package?.runtime, ToolchainValidation.isSafeVersion(runtime.version) else { return nil }
        if let existing = Self.installations(context).first(where: { $0.runtime == runtime }) { return existing }
        switch (runtime.source, runtime.provider) {
        case (.homebrew, _):
            guard let prefix = context.layout.homebrewPrefixes.first else { return nil }
            return RubyInstallation(runtime: runtime, bin: prefix.appendingPathComponent("opt/ruby/bin"), gemRoots: [])
        case (.manager, .rbenv?):
            let folder = context.homePath(".rbenv/versions/\(runtime.version)")
            return RubyInstallation(runtime: runtime, bin: folder.appendingPathComponent("bin"), gemRoots: [])
        case (.manager, .rvm?):
            let gems = context.homePath(".rvm/gems/\(runtime.version)")
            return RubyInstallation(runtime: runtime, bin: context.homePath(".rvm/rubies/\(runtime.version)/bin"), gemRoots: [gems], gemHome: gems)
        default:
            return nil
        }
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        installation(action, context: context).map { [$0.bin.appendingPathComponent("gem").path] } ?? []
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let ruby = installation(action, context: context),
              let gem = context.firstExecutable([ruby.bin.appendingPathComponent("gem").path]) else { return nil }
        var arguments = ["install", "--no-document", package.name]
        if let version = package.version, ToolchainValidation.isSafeVersion(version) { arguments += ["--version", version] }
        var extra: [String: String] = [:]
        if let home = ruby.gemHome { extra = ["GEM_HOME": home.path, "GEM_PATH": home.path] }
        return [ToolchainCommand(executable: gem, arguments: arguments, environment: context.environment(prepending: [ruby.bin.path], extra: extra))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, let ruby = installation(action, context: context) else { return false }
        return Self.gems(in: Self.installations(context).first { $0.runtime == ruby.runtime }?.gemRoots ?? []).contains { $0.0 == name }
    }
}

// MARK: - Rust

/// rustup: toolchains with their extra components and targets.
public struct RustupProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .rustup, ecosystem: .rust, name: "rustup", managerFormula: "rustup", website: "https://rustup.rs",
                            runtimes: .automatic)
    }

    static func home(_ context: ToolchainContext) -> URL { context.homePath(".rustup") }

    static let hostSuffixes = ["-aarch64-apple-darwin", "-x86_64-apple-darwin"]
    /// Components of rustup's default profile, installed anyway.
    static let defaultComponents: Set<String> = ["rustc", "cargo", "rust-std", "rust-docs", "rustfmt", "clippy"]

    /// `stable-aarch64-apple-darwin` → `stable`, so that the same channel is installed for the new Mac's processor.
    static func channel(of toolchain: String) -> String {
        for suffix in hostSuffixes where toolchain.hasSuffix(suffix) { return String(toolchain.dropLast(suffix.count)) }
        return toolchain
    }

    static func host(_ architecture: CPUArchitecture) -> String {
        architecture == .x86_64 ? "x86_64-apple-darwin" : "aarch64-apple-darwin"
    }

    /// Reads `lib/rustlib/components` (`clippy-preview-aarch64-apple-darwin`, `rust-std-wasm32-unknown-unknown` …).
    static func componentsAndTargets(_ text: String, toolchain: String) -> (components: [String], targets: [String]) {
        let host = hostSuffixes.first { toolchain.hasSuffix($0) }.map { String($0.dropFirst()) }
        var components = Set<String>()
        var targets = Set<String>()
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("rust-std-") {
                let target = String(line.dropFirst(9))
                if target != host, ToolchainValidation.isSafeVersion(target) { targets.insert(target) }
                continue
            }
            var name = line
            if let host, name.hasSuffix("-" + host) { name = String(name.dropLast(host.count + 1)) }
            if name.hasSuffix("-preview") { name = String(name.dropLast(8)) }
            if !defaultComponents.contains(name), ToolchainValidation.isSafeVersion(name) { components.insert(name) }
        }
        return (components.sorted(), targets.sorted())
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let toolchains = Self.home(context).appendingPathComponent("toolchains")
        guard ToolchainFiles.exists(toolchains) else { return nil }
        let settings = MiniTOML.parse((try? String(contentsOf: Self.home(context).appendingPathComponent("settings.toml"), encoding: .utf8)) ?? "")
        let defaultToolchain = (settings["default_toolchain"] as? String).map(Self.channel)
        var runtimes: [ToolchainRuntime] = []
        // Linked custom toolchains (`rustup toolchain link`) are symbolic links to local builds and are skipped.
        for name in ToolchainFiles.directories(in: toolchains) where !ToolchainFiles.isSymbolicLink(toolchains.appendingPathComponent(name)) {
            let channel = Self.channel(of: name)
            guard ToolchainValidation.isSafeVersion(channel) else { continue }
            let text = (try? String(contentsOf: toolchains.appendingPathComponent("\(name)/lib/rustlib/components"), encoding: .utf8)) ?? ""
            let (components, targets) = Self.componentsAndTargets(text, toolchain: name)
            runtimes.append(ToolchainRuntime(version: channel, isDefault: channel == defaultToolchain, components: components, targets: targets))
        }
        return ToolchainRecord(provider: .rustup, location: context.layout.displayPath(Self.home(context)), runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        [context.homePath(".cargo/bin/rustup").path] + context.homebrewExecutables("rustup", kegOnlyFormula: "rustup")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .runtime, let runtime = action.runtime, ToolchainValidation.isSafeVersion(runtime.version),
              let rustup = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        var arguments = ["toolchain", "install", runtime.version, "--profile", "default", "--no-self-update"]
        for component in runtime.components where ToolchainValidation.isSafeVersion(component) { arguments += ["--component", component] }
        for target in runtime.targets where ToolchainValidation.isSafeVersion(target) { arguments += ["--target", target] }
        let environment = context.environment(prepending: [URL(fileURLWithPath: rustup).deletingLastPathComponent().path])
        var commands = [ToolchainCommand(executable: rustup, arguments: arguments, environment: environment)]
        if runtime.isDefault { commands.append(ToolchainCommand(executable: rustup, arguments: ["default", runtime.version], environment: environment, timeout: 120)) }
        return commands
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard action.kind == .runtime, let channel = action.runtime?.version, ToolchainValidation.isSafeVersion(channel) else { return false }
        let folder = Self.home(context).appendingPathComponent("toolchains/\(channel)-\(Self.host(context.architecture))")
        return ToolchainFiles.exists(folder.appendingPathComponent("bin/rustc"))
    }
}

/// Programs installed with `cargo install`, from Cargo's own record `~/.cargo/.crates2.json`.
public struct CargoProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .cargo, ecosystem: .rust, name: "Cargo", website: "https://doc.rust-lang.org/cargo/commands/cargo-install.html",
                            packages: .automatic)
    }

    static func record(_ context: ToolchainContext) -> URL { context.homePath(".cargo/.crates2.json") }

    /// Parses keys like `ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)`.
    /// Only crates.io packages are reinstallable; git and local sources are recorded by kind only.
    static func parse(_ json: [String: Any]) -> [ToolchainPackage] {
        guard let installs = json["installs"] as? [String: Any] else { return [] }
        var result: [ToolchainPackage] = []
        for (key, value) in installs {
            let parts = key.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, ToolchainValidation.isSafePackageName(parts[0]), ToolchainValidation.isSafeVersion(parts[1]) else { continue }
            let source = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            var origin: PackageOrigin = .local
            if source.hasPrefix("registry+https://github.com/rust-lang/crates.io-index") || source.hasPrefix("sparse+https://index.crates.io") { origin = .index }
            else if source.hasPrefix("git+") { origin = .vcs }
            var extras: [String] = []
            if let details = value as? [String: Any] {
                if let features = details["features"] as? [String], !features.isEmpty {
                    extras.append("features=" + features.filter(ToolchainValidation.isSafePackageName).joined(separator: ","))
                }
                if details["all_features"] as? Bool == true { extras.append("all-features") }
                if details["no_default_features"] as? Bool == true { extras.append("no-default-features") }
            }
            result.append(ToolchainPackage(name: parts[0], version: parts[1], origin: origin, extras: extras))
        }
        return result.sorted { $0.name < $1.name }
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        guard let json = ToolchainFiles.json(Self.record(context)) else { return nil }
        let packages = Self.parse(json)
        return packages.isEmpty ? nil : ToolchainRecord(provider: .cargo, location: "~/.cargo", packages: packages)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        [context.homePath(".cargo/bin/cargo").path] + context.homebrewExecutables("cargo", kegOnlyFormula: "rustup")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let cargo = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        var arguments = ["install", "--locked", package.name]
        if let version = package.version, ToolchainValidation.isSafeVersion(version) { arguments += ["--version", version] }
        for extra in package.extras {
            if extra.hasPrefix("features=") { arguments += ["--features", String(extra.dropFirst(9))] }
            if extra == "all-features" { arguments.append("--all-features") }
            if extra == "no-default-features" { arguments.append("--no-default-features") }
        }
        // Building takes a while; rustup's proxies need their own folder in PATH.
        return [ToolchainCommand(executable: cargo, arguments: arguments,
                                 environment: context.environment(prepending: [URL(fileURLWithPath: cargo).deletingLastPathComponent().path]),
                                 timeout: 3600)]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, let json = ToolchainFiles.json(Self.record(context)) else { return false }
        return Self.parse(json).contains { $0.name == name }
    }
}

// MARK: - Go

/// Reads the module information the Go linker embeds in every Go program (the same data
/// `go version -m` prints), without running anything.
public enum GoBuildInfo {
    static let start: [UInt8] = [0x30, 0x77, 0xaf, 0x0c, 0x92, 0x74, 0x08, 0x02, 0x41, 0xe1, 0xc1, 0x07, 0xe6, 0xd6, 0x18, 0xe6]
    static let end: [UInt8] = [0xf9, 0x32, 0x43, 0x31, 0x86, 0x18, 0x20, 0x72, 0x00, 0x82, 0x42, 0x10, 0x41, 0x16, 0xd8, 0xf2]

    public struct Info: Equatable, Sendable {
        /// The main package path, e.g. `golang.org/x/tools/gopls`.
        public var path: String
        public var module: String
        /// The module version, e.g. `v0.16.2`; `(devel)` for local builds.
        public var version: String
        public var replaced: Bool
    }

    public static func read(_ url: URL) -> Info? {
        guard MachO.architectures(ofFile: url).isEmpty == false,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let first = data.range(of: Data(start)),
              let last = data.range(of: Data(end), in: first.upperBound..<min(data.count, first.upperBound + 1_000_000)) else { return nil }
        return parse(String(decoding: data[first.upperBound..<last.lowerBound], as: UTF8.self))
    }

    public static func parse(_ text: String) -> Info? {
        var path: String?
        var module: String?
        var version: String?
        var replaced = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t").map(String.init)
            guard let kind = fields.first else { continue }
            if kind == "path", fields.count >= 2 { path = fields[1] }
            if kind == "mod", fields.count >= 3 { module = fields[1]; version = fields[2] }
            if kind == "=>" { replaced = true }
        }
        guard let path, let module, let version else { return nil }
        return Info(path: path, module: module, version: version, replaced: replaced)
    }
}

/// Go: the toolchain comes back with Homebrew's `go` formula; programs installed with `go install`
/// are reinstalled from their module path and version.
public struct GoProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .go, ecosystem: .go, name: "Go", managerFormula: "go", website: "https://go.dev/doc/install",
                            runtimes: .automatic, packages: .automatic)
    }

    static func goRoots(_ context: ToolchainContext) -> [URL] {
        [context.systemPath("/usr/local/go")]
            + context.layout.homebrewPrefixes.map { $0.appendingPathComponent("opt/go/libexec") }
    }

    /// `GOBIN`/`GOPATH` from `go env -w` (only these two keys are read; the file can hold proxy credentials).
    static func binFolder(_ context: ToolchainContext) -> URL {
        let text = (try? String(contentsOf: context.homePath("Library/Application Support/go/env"), encoding: .utf8)) ?? ""
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, ["GOBIN", "GOPATH"].contains(parts[0]), parts[1].hasPrefix("/") || parts[1].hasPrefix("~") {
                values[parts[0]] = parts[1]
            }
        }
        let resolve: (String) -> URL = { value in
            value.hasPrefix("~/") ? context.homePath(String(value.dropFirst(2))) : URL(fileURLWithPath: value)
        }
        if let bin = values["GOBIN"] { return resolve(bin) }
        if let path = values["GOPATH"]?.split(separator: ":").first { return resolve(String(path)).appendingPathComponent("bin") }
        return context.homePath("go/bin")
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        var runtimes: [ToolchainRuntime] = []
        for root in Self.goRoots(context) {
            guard let version = ToolchainFiles.firstLine(root.appendingPathComponent("VERSION")), version.hasPrefix("go") else { continue }
            runtimes.append(ToolchainRuntime(version: String(version.dropFirst(2)), path: context.layout.displayPath(root)))
        }
        let bin = Self.binFolder(context)
        var packages: [ToolchainPackage] = []
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).sorted() where !name.hasPrefix(".") {
            guard let info = GoBuildInfo.read(bin.appendingPathComponent(name)), ToolchainValidation.isSafePackageName(info.path) else { continue }
            let reinstallable = !info.replaced && info.version != "(devel)" && ToolchainValidation.isSafeVersion(info.version)
            packages.append(ToolchainPackage(name: info.path, version: reinstallable ? info.version : nil, origin: reinstallable ? .index : .local))
        }
        guard !runtimes.isEmpty || !packages.isEmpty else { return nil }
        return ToolchainRecord(provider: .go, location: context.layout.displayPath(bin), runtimes: runtimes, packages: packages)
    }

    /// The Go toolchain itself comes from Homebrew, so runtimes are not separate steps.
    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] {
        record.packages.filter { $0.origin.isReinstallable }.map { ToolchainAction(provider: .go, kind: .package, package: $0) }
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        context.homebrewExecutables("go") + Self.goRoots(context).map { $0.appendingPathComponent("bin/go").path }
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let version = package.version, ToolchainValidation.isSafeVersion(version),
              let go = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        return [ToolchainCommand(executable: go, arguments: ["install", "\(package.name)@\(version)"],
                                 environment: context.environment(extra: ["GOBIN": Self.binFolder(context).path, "GOFLAGS": "-modcacherw",
                                                                          "GOTOOLCHAIN": "auto"]))]
    }

    /// The program's file name: the last path element, skipping a major-version suffix like `/v2`.
    static func binaryName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let last = parts.last, last.range(of: #"^v\d+$"#, options: .regularExpression) != nil, parts.count > 1 { return String(parts[parts.count - 2]) }
        return parts.last.map(String.init) ?? path
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name) else { return false }
        return ToolchainFiles.exists(Self.binFolder(context).appendingPathComponent(Self.binaryName(name)))
    }
}

// MARK: - Java

/// Installed JDKs. Distributions with an official Homebrew cask (Temurin, Zulu, Corretto, Oracle,
/// Microsoft, SapMachine) are reinstalled in the same major version; others are listed with their vendor.
public struct JDKProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .jdk, ecosystem: .java, name: "Java (JDK)", website: "https://adoptium.net", runtimes: .automatic)
    }

    static func folders(_ context: ToolchainContext) -> [URL] {
        [context.systemPath("/Library/Java/JavaVirtualMachines"), context.homePath("Library/Java/JavaVirtualMachines")]
    }

    /// Reads `Contents/Home/release` (`JAVA_VERSION="21.0.4"`, `IMPLEMENTOR="Eclipse Adoptium"`).
    static func parseRelease(_ text: String) -> (version: String?, vendor: String?) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (values["JAVA_VERSION"], values["IMPLEMENTOR"])
    }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        var runtimes: [ToolchainRuntime] = []
        for folder in Self.folders(context) {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where name.hasSuffix(".jdk") {
                let jdk = folder.appendingPathComponent(name)
                let release = (try? String(contentsOf: jdk.appendingPathComponent("Contents/Home/release"), encoding: .utf8)) ?? ""
                let (version, vendor) = Self.parseRelease(release)
                guard let version, ToolchainValidation.isSafeVersion(version) else { continue }
                runtimes.append(ToolchainRuntime(version: version, vendor: vendor, path: context.layout.displayPath(jdk)))
            }
        }
        return runtimes.isEmpty ? nil : ToolchainRecord(provider: .jdk, runtimes: runtimes)
    }

    /// The major version: `21.0.4` → `21`, `1.8.0_412` → `8`.
    static func major(_ version: String) -> String {
        let parts = version.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "+" }).map(String.init)
        if parts.first == "1", parts.count > 1 { return parts[1] }
        return parts.first ?? version
    }

    public func homebrewPackage(for runtime: ToolchainRuntime) -> HomebrewPackageReference? {
        let major = Self.major(runtime.version)
        guard major.allSatisfy(\.isNumber), let vendor = runtime.vendor?.lowercased() else { return nil }
        let prefix: String
        if vendor.contains("adoptium") || vendor.contains("temurin") { prefix = "temurin" }
        else if vendor.contains("azul") { prefix = "zulu" }
        else if vendor.contains("amazon") { prefix = "corretto" }
        else if vendor.contains("oracle") { prefix = "oracle-jdk" }
        else if vendor.contains("microsoft") { prefix = "microsoft-openjdk" }
        else { return nil }
        return .cask("\(prefix)@\(major)")
    }

    public func managerPackage(for record: ToolchainRecord) -> HomebrewPackageReference? { nil }

    /// JDKs come back as Homebrew casks; those without one are listed in the instructions.
    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] {
        record.runtimes.filter { homebrewPackage(for: $0) == nil }.map { ToolchainAction(provider: .jdk, kind: .runtime, runtime: $0) }
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let wanted = action.runtime?.version else { return false }
        return (scan(context)?.runtimes ?? []).contains { Self.major($0.version) == Self.major(wanted) }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard let runtime = action.runtime else { return nil }
        return [runtime.vendor, "JDK \(Self.major(runtime.version))"].compactMap { $0 }.joined(separator: " ")
    }

    /// Without a matching cask the step is guided: the user installs the JDK from its vendor.
    public func supportLevel(for action: ToolchainAction) -> SupportLevel { .guided }
}

/// SDKMAN: candidates (Java, Gradle, Maven …) in `~/.sdkman/candidates`. `sdk` is a shell function,
/// so these are guided steps.
public struct SDKMANProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .sdkman, ecosystem: .java, name: "SDKMAN!", website: "https://sdkman.io/install", runtimes: .guided)
    }

    static func candidates(_ context: ToolchainContext) -> URL { context.homePath(".sdkman/candidates") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        let root = Self.candidates(context)
        guard ToolchainFiles.exists(root) else { return nil }
        var runtimes: [ToolchainRuntime] = []
        for candidate in ToolchainFiles.directories(in: root) where ToolchainValidation.isSafePackageName(candidate) {
            let folder = root.appendingPathComponent(candidate)
            let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("current").path))
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            for version in ToolchainFiles.directories(in: folder) where version != "current" && ToolchainValidation.isSafeVersion(version) {
                runtimes.append(ToolchainRuntime(version: "\(candidate)/\(version)", isDefault: version == current))
            }
        }
        return runtimes.isEmpty ? nil : ToolchainRecord(provider: .sdkman, location: "~/.sdkman", runtimes: runtimes)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] { [] }
    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? { nil }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
        return ToolchainFiles.exists(Self.candidates(context).appendingPathComponent(version))
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard let parts = action.runtime?.version.split(separator: "/", maxSplits: 1), parts.count == 2 else { return nil }
        return "sdk install \(parts[0]) \(parts[1])" + (action.runtime?.isDefault == true ? "\nsdk default \(parts[0]) \(parts[1])" : "")
    }
}

// MARK: - .NET

/// .NET SDKs (guided: the exact version comes from Microsoft's download page) and global tools (automatic).
public struct DotnetProvider: ToolchainProvider {
    public init() {}

    public var descriptor: ToolchainDescriptor {
        ToolchainDescriptor(id: .dotnet, ecosystem: .dotnet, name: ".NET", managerCask: "dotnet-sdk",
                            website: "https://dotnet.microsoft.com/download/dotnet", runtimes: .guided, packages: .automatic)
    }

    static func roots(_ context: ToolchainContext) -> [URL] {
        [context.systemPath("/usr/local/share/dotnet"), context.homePath(".dotnet")]
    }

    static func toolStore(_ context: ToolchainContext) -> URL { context.homePath(".dotnet/tools/.store") }

    public func scan(_ context: ToolchainContext) -> ToolchainRecord? {
        var runtimes: [ToolchainRuntime] = []
        for root in Self.roots(context) {
            for version in ToolchainFiles.directories(in: root.appendingPathComponent("sdk")) where version.first?.isNumber == true {
                guard ToolchainValidation.isSafeVersion(version), !runtimes.contains(where: { $0.version == version }) else { continue }
                runtimes.append(ToolchainRuntime(version: version, path: context.layout.displayPath(root)))
            }
        }
        // Global tools: `.store/<lower-case package id>/<version>/`.
        var packages: [ToolchainPackage] = []
        let store = Self.toolStore(context)
        for id in ToolchainFiles.directories(in: store) where ToolchainValidation.isSafePackageName(id) {
            guard let version = ToolchainFiles.directories(in: store.appendingPathComponent(id)).last(where: ToolchainValidation.isSafeVersion) else { continue }
            packages.append(ToolchainPackage(name: id, version: version))
        }
        guard !runtimes.isEmpty || !packages.isEmpty else { return nil }
        return ToolchainRecord(provider: .dotnet, runtimes: runtimes, packages: packages)
    }

    public func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String] {
        Self.roots(context).map { $0.appendingPathComponent("dotnet").path } + context.homebrewExecutables("dotnet")
    }

    public func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]? {
        guard action.kind == .package, let package = action.package, ToolchainValidation.isSafePackageName(package.name),
              let dotnet = context.firstExecutable(executableCandidates(for: action, context: context)) else { return nil }
        var arguments = ["tool", "install", "--global", package.name]
        if let version = package.version, ToolchainValidation.isSafeVersion(version) { arguments += ["--version", version] }
        // The .NET command-line interface is localized; English output keeps the logs readable.
        return [ToolchainCommand(executable: dotnet, arguments: arguments, environment: context.environment(extra: [
            "DOTNET_CLI_UI_LANGUAGE": "en", "DOTNET_NOLOGO": "1", "DOTNET_CLI_TELEMETRY_OPTOUT": "1"]))]
    }

    public func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool {
        switch action.kind {
        case .runtime:
            guard let version = action.runtime?.version, ToolchainValidation.isSafeVersion(version) else { return false }
            return Self.roots(context).contains { ToolchainFiles.exists($0.appendingPathComponent("sdk/\(version)")) }
        case .package:
            guard let name = action.package?.name, ToolchainValidation.isSafePackageName(name) else { return false }
            return ToolchainFiles.exists(Self.toolStore(context).appendingPathComponent(name.lowercased()))
        default:
            return false
        }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? {
        guard action.kind == .runtime, let version = action.runtime?.version else { return nil }
        let channel = version.split(separator: ".").prefix(2).joined(separator: ".")
        return "https://dotnet.microsoft.com/download/dotnet/\(channel)"
    }
}
