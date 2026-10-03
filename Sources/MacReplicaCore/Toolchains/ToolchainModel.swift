import Foundation

/// Developer ecosystems MacReplica describes in addition to Homebrew and the App Store.
public enum Ecosystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case packageManagers, python, node, ruby, rust, go, java, dotnet

    public var id: String { rawValue }
}

/// A package manager or version manager MacReplica knows how to describe.
///
/// Raw values are stable manifest identifiers. A manifest written by a newer version may contain
/// providers this version does not know; those records are dropped when reading (see `ToolchainRecord`).
public enum ToolchainProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    // Package managers
    case macports, nix, pixi, pkgx, fink
    // Python
    case conda, pyenv, uv, pipx
    // Node.js
    case nvm, fnm, volta, npm, pnpm, yarn
    // Ruby
    case rbenv, rvm, gem
    // Rust
    case rustup, cargo
    // Go
    case go
    // Java
    case jdk, sdkman
    // .NET
    case dotnet
    // Multi-language version managers
    case mise, asdf

    public var id: String { rawValue }
}

/// Where a runtime that global packages belong to comes from, e.g. Node 20.11.1 installed by nvm.
public struct RuntimeReference: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// A version installed by the version manager of the record (nvm, rbenv, rustup …).
        case manager
        /// The runtime of a Homebrew formula (`node`, `ruby`, `go` …).
        case homebrew
        /// Installed some other way (official installer, macOS itself).
        case other
    }

    public var source: Source
    public var provider: ToolchainProviderID?
    public var version: String

    public init(source: Source, provider: ToolchainProviderID? = nil, version: String) {
        self.source = source
        self.provider = provider
        self.version = version
    }
}

/// One installed runtime version, e.g. Node `20.11.1` or the Rust toolchain `stable-aarch64-apple-darwin`.
public struct ToolchainRuntime: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { version }
    /// The version or toolchain name exactly as the manager names it.
    public var version: String
    /// True for the version the manager uses by default (global version).
    public var isDefault: Bool
    /// Vendor or distribution, e.g. `Eclipse Adoptium` for a JDK.
    public var vendor: String?
    /// Display path of the installation.
    public var path: String?
    /// Rust: installed components and targets beyond the defaults.
    public var components: [String]
    public var targets: [String]
    public var architectures: [CPUArchitecture]

    public init(version: String, isDefault: Bool = false, vendor: String? = nil, path: String? = nil, components: [String] = [],
                targets: [String] = [], architectures: [CPUArchitecture] = []) {
        self.version = version
        self.isDefault = isDefault
        self.vendor = vendor
        self.path = path
        self.components = components
        self.targets = targets
        self.architectures = architectures
    }

    private enum CodingKeys: String, CodingKey { case version, isDefault, vendor, path, components, targets, architectures }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        components = try c.decodeIfPresent([String].self, forKey: .components) ?? []
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        architectures = try c.decodeIfPresent([CPUArchitecture].self, forKey: .architectures) ?? []
    }
}

/// A globally installed tool or package, e.g. an npm package, a gem or a crate installed with `cargo install`.
public struct ToolchainPackage: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { [runtime.map { "\($0.source.rawValue)-\($0.version)" }, name].compactMap { $0 }.joined(separator: "/") }
    public var name: String
    public var version: String?
    /// The runtime the package was installed into; nil when the package manager has no runtimes.
    public var runtime: RuntimeReference?
    /// Only packages from the public registry can be reinstalled automatically. Git and local
    /// sources are recorded by kind only, never with their URL or path.
    public var origin: PackageOrigin
    /// Additional install options in the manager's own terms: Cargo features, packages installed
    /// alongside a uv or pipx tool, or a pinned Python version (`python=3.12`).
    public var extras: [String]

    public init(name: String, version: String? = nil, runtime: RuntimeReference? = nil, origin: PackageOrigin = .index,
                extras: [String] = []) {
        self.name = name
        self.version = version
        self.runtime = runtime
        self.origin = origin
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey { case name, version, runtime, origin, extras }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        runtime = try c.decodeIfPresent(RuntimeReference.self, forKey: .runtime)
        origin = try c.decodeIfPresent(PackageOrigin.self, forKey: .origin) ?? .index
        extras = try c.decodeIfPresent([String].self, forKey: .extras) ?? []
    }
}

/// A named environment of a package manager, e.g. a Conda environment.
public struct ToolchainEnvironment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Display path of the environment folder.
    public var path: String
    /// The packages the user asked for (not every dependency), with version constraints as recorded.
    public var requestedPackages: [String]
    public var channels: [String]
    public var pythonVersion: String?
    /// Number of installed packages including dependencies, for information.
    public var installedCount: Int

    public init(name: String, path: String, requestedPackages: [String] = [], channels: [String] = [], pythonVersion: String? = nil,
                installedCount: Int = 0) {
        self.name = name
        self.path = path
        self.requestedPackages = requestedPackages
        self.channels = channels
        self.pythonVersion = pythonVersion
        self.installedCount = installedCount
    }

    private enum CodingKeys: String, CodingKey { case name, path, requestedPackages, channels, pythonVersion, installedCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        requestedPackages = try c.decodeIfPresent([String].self, forKey: .requestedPackages) ?? []
        channels = try c.decodeIfPresent([String].self, forKey: .channels) ?? []
        pythonVersion = try c.decodeIfPresent(String.self, forKey: .pythonVersion)
        installedCount = try c.decodeIfPresent(Int.self, forKey: .installedCount) ?? 0
    }
}

/// Everything recorded about one package or version manager.
public struct ToolchainRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { provider.rawValue }
    public var provider: ToolchainProviderID
    /// Display path of the manager's executable or root folder.
    public var location: String?
    public var version: String?
    /// How the manager itself was installed, e.g. the Homebrew formula `uv`.
    public var homebrewFormula: String?
    public var runtimes: [ToolchainRuntime]
    public var packages: [ToolchainPackage]
    public var environments: [ToolchainEnvironment]

    public init(provider: ToolchainProviderID, location: String? = nil, version: String? = nil, homebrewFormula: String? = nil,
                runtimes: [ToolchainRuntime] = [], packages: [ToolchainPackage] = [], environments: [ToolchainEnvironment] = []) {
        self.provider = provider
        self.location = location
        self.version = version
        self.homebrewFormula = homebrewFormula
        self.runtimes = runtimes
        self.packages = packages
        self.environments = environments
    }

    private enum CodingKeys: String, CodingKey { case provider, location, version, homebrewFormula, runtimes, packages, environments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(ToolchainProviderID.self, forKey: .provider)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        homebrewFormula = try c.decodeIfPresent(String.self, forKey: .homebrewFormula)
        runtimes = try c.decodeIfPresent([ToolchainRuntime].self, forKey: .runtimes) ?? []
        packages = try c.decodeIfPresent([ToolchainPackage].self, forKey: .packages) ?? []
        environments = try c.decodeIfPresent([ToolchainEnvironment].self, forKey: .environments) ?? []
    }

    public var ecosystem: Ecosystem { ToolchainCatalog.descriptor(provider).ecosystem }
    public var isEmpty: Bool { runtimes.isEmpty && packages.isEmpty && environments.isEmpty }
}

/// Decodes a list and silently drops entries this version cannot read (e.g. providers added later).
struct LenientList<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        elements = result
    }
}
