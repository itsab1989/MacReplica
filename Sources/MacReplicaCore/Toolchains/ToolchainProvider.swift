import Foundation

/// How far MacReplica can bring something back on its own.
public enum SupportLevel: String, Codable, Sendable, CaseIterable {
    /// Installed and verified automatically.
    case automatic
    /// MacReplica shows the exact step, the user performs it, MacReplica verifies the result.
    case guided
    /// Recorded in the backup and listed in the restore instructions; nothing is installed.
    case inventoryOnly
}

/// Static facts about a provider: what it is, how its manager is installed and what can be restored.
public struct ToolchainDescriptor: Sendable, Equatable {
    public var id: ToolchainProviderID
    public var ecosystem: Ecosystem
    /// Product name, never translated (e.g. "pyenv", "MacPorts").
    public var name: String
    /// Homebrew formula that installs the manager on the new Mac, if Homebrew provides one.
    public var managerFormula: String?
    /// Homebrew cask that installs the manager, if Homebrew provides one as a cask.
    public var managerCask: String?
    /// The project's official website (installation instructions).
    public var website: String
    public var runtimes: SupportLevel
    public var packages: SupportLevel
    public var environments: SupportLevel

    public init(id: ToolchainProviderID, ecosystem: Ecosystem, name: String, managerFormula: String? = nil, managerCask: String? = nil,
                website: String, runtimes: SupportLevel = .inventoryOnly, packages: SupportLevel = .inventoryOnly,
                environments: SupportLevel = .inventoryOnly) {
        self.id = id
        self.ecosystem = ecosystem
        self.name = name
        self.managerFormula = managerFormula
        self.managerCask = managerCask
        self.website = website
        self.runtimes = runtimes
        self.packages = packages
        self.environments = environments
    }

    /// The best support level of anything this provider restores.
    public var overallSupport: SupportLevel {
        let levels = [runtimes, packages, environments]
        if levels.contains(.automatic) { return .automatic }
        if levels.contains(.guided) { return .guided }
        return .inventoryOnly
    }
}

/// One restore step for a provider, stored in the restore plan and the session.
public struct ToolchainAction: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Install the version or package manager itself (only when Homebrew cannot).
        case manager
        case runtime
        case package
        case environment
    }

    public var provider: ToolchainProviderID
    public var kind: Kind
    public var runtime: ToolchainRuntime?
    public var package: ToolchainPackage?
    public var environment: ToolchainEnvironment?

    public init(provider: ToolchainProviderID, kind: Kind, runtime: ToolchainRuntime? = nil, package: ToolchainPackage? = nil,
                environment: ToolchainEnvironment? = nil) {
        self.provider = provider
        self.kind = kind
        self.runtime = runtime
        self.package = package
        self.environment = environment
    }

    /// Stable restore item identifier, e.g. `toolchain:rustup:runtime:stable-aarch64-apple-darwin`.
    public var itemID: String {
        switch kind {
        case .manager: return "toolchain:\(provider.rawValue):manager"
        case .runtime: return "toolchain:\(provider.rawValue):runtime:\(runtime?.version ?? "")"
        case .package: return "toolchain:\(provider.rawValue):package:\(package?.id ?? "")"
        case .environment: return "toolchain:\(provider.rawValue):env:\(environment?.name ?? "")"
        }
    }

    /// Display title (product and version names only, never translated).
    public var title: String {
        let name = ToolchainCatalog.descriptor(provider).name
        switch kind {
        case .manager: return name
        case .runtime: return "\(name) \(runtime?.version ?? "")"
        case .package: return [package?.name, package?.version].compactMap { $0 }.joined(separator: " ")
        case .environment: return environment?.name ?? name
        }
    }
}

/// A concrete command for an action on this Mac. Executables are absolute paths that the command
/// policy allows; arguments are passed verbatim, never through a shell.
public struct ToolchainCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Added to MacReplica's controlled child environment (e.g. `PATH` with the runtime's `bin` folder).
    public var environment: [String: String]
    public var timeout: TimeInterval
    /// Files the command needs, written before it runs (e.g. a Conda `environment.yml`).
    public var inputFiles: [URL: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 1800,
                inputFiles: [URL: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.inputFiles = inputFiles
    }
}

/// What a provider needs to know about the Mac it is working on.
public struct ToolchainContext: Sendable {
    public var layout: SystemLayout
    /// Folder for temporary files the provider writes before running a command.
    public var workFolder: URL?
    /// Processor of the Mac the tools run on (selects Rust host toolchains and similar).
    public var architecture: CPUArchitecture

    public init(layout: SystemLayout, workFolder: URL? = nil, architecture: CPUArchitecture = SystemInfo.currentArchitecture) {
        self.layout = layout
        self.workFolder = workFolder
        self.architecture = architecture
    }

    public var home: URL { layout.homeDirectory }

    public func homePath(_ relative: String) -> URL { layout.homeDirectory.appendingPathComponent(relative) }

    /// A system location such as `/opt/local`; inside a simulation it is always below the simulation root,
    /// so a simulated Mac never reads the real one.
    public func systemPath(_ absolute: String) -> URL {
        guard let root = layout.simulationRoot else { return URL(fileURLWithPath: absolute) }
        return root.appendingPathComponent(String(absolute.drop { $0 == "/" }))
    }

    /// The first existing executable among `candidates`.
    public func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `bin/<name>` in every Homebrew prefix, plus `opt/<formula>/bin/<name>` for keg-only formulae.
    public func homebrewExecutables(_ name: String, kegOnlyFormula: String? = nil) -> [String] {
        layout.homebrewPrefixes.flatMap { prefix -> [String] in
            var paths = [prefix.appendingPathComponent("bin/\(name)").path]
            if let formula = kegOnlyFormula { paths.insert(prefix.appendingPathComponent("opt/\(formula)/bin/\(name)").path, at: 0) }
            return paths
        }
    }

    /// The controlled environment for a tool run, with extra folders put in front of `PATH`.
    public func environment(prepending folders: [String] = [], extra: [String: String] = [:]) -> [String: String] {
        let prefix = layout.homebrewPrefixes.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bin/brew").path) }
        var environment = layout.processEnvironment(homebrewPrefix: prefix, askpass: nil)
        if !folders.isEmpty { environment["PATH"] = (folders + [environment["PATH"] ?? ""]).joined(separator: ":") }
        environment["CI"] = "1"
        return environment.merging(extra) { $1 }
    }
}

/// A package or version manager MacReplica can describe and, depending on its support level, restore.
///
/// Providers read installed state from files only; no tool is started while scanning. Restore
/// commands are built from validated names and versions and run without a shell.
public protocol ToolchainProvider: Sendable {
    var descriptor: ToolchainDescriptor { get }

    /// Reads what is installed, or nil if the manager is not present.
    func scan(_ context: ToolchainContext) -> ToolchainRecord?

    /// The steps that bring `record` back, in order.
    func restoreActions(for record: ToolchainRecord) -> [ToolchainAction]

    /// Every executable the provider may start for `action`. The command policy allows exactly these.
    func executableCandidates(for action: ToolchainAction, context: ToolchainContext) -> [String]

    /// The commands for `action`, run in order, or nil when the step has to be done by the user
    /// (guided) or the tool it needs is missing on this Mac.
    func commands(for action: ToolchainAction, context: ToolchainContext) -> [ToolchainCommand]?

    /// True when the result of `action` is present on this Mac (checked through files).
    func isSatisfied(_ action: ToolchainAction, context: ToolchainContext) -> Bool

    /// The step the user performs for a guided action, shown as text to copy; MacReplica never runs it.
    func manualInstruction(for action: ToolchainAction) -> String?

    /// The Homebrew package that installs the manager for `record` on the new Mac, if any.
    func managerPackage(for record: ToolchainRecord) -> HomebrewPackageReference?

    /// Runtimes that are restored as Homebrew packages instead of by the manager (e.g. a JDK as a cask).
    func homebrewPackage(for runtime: ToolchainRuntime) -> HomebrewPackageReference?

    /// How `action` is restored: automatically, as a guided step, or not at all.
    func supportLevel(for action: ToolchainAction) -> SupportLevel
}

/// A Homebrew formula or cask that a toolchain step needs.
public struct HomebrewPackageReference: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case formula, cask }
    public var kind: Kind
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static func formula(_ name: String) -> HomebrewPackageReference { HomebrewPackageReference(kind: .formula, name: name) }
    public static func cask(_ name: String) -> HomebrewPackageReference { HomebrewPackageReference(kind: .cask, name: name) }

    /// The restore item that installs it, e.g. `formula:uv`.
    public var itemID: String { "\(kind.rawValue):\(name)" }
}

extension ToolchainProvider {
    public var id: ToolchainProviderID { descriptor.id }

    public func restoreActions(for record: ToolchainRecord) -> [ToolchainAction] {
        record.runtimes.map { ToolchainAction(provider: id, kind: .runtime, runtime: $0) }
            + record.packages.filter { $0.origin.isReinstallable }.map { ToolchainAction(provider: id, kind: .package, package: $0) }
            + record.environments.map { ToolchainAction(provider: id, kind: .environment, environment: $0) }
    }

    public func manualInstruction(for action: ToolchainAction) -> String? { nil }

    public func managerPackage(for record: ToolchainRecord) -> HomebrewPackageReference? {
        if let formula = descriptor.managerFormula { return .formula(formula) }
        if let cask = descriptor.managerCask { return .cask(cask) }
        return nil
    }

    public func homebrewPackage(for runtime: ToolchainRuntime) -> HomebrewPackageReference? { nil }

    /// The support level that applies to `action`.
    public func supportLevel(for action: ToolchainAction) -> SupportLevel {
        switch action.kind {
        case .manager: return .guided
        case .runtime: return descriptor.runtimes
        case .package: return descriptor.packages
        case .environment: return descriptor.environments
        }
    }
}

/// Validation for names and versions that end up as command arguments.
public enum ToolchainValidation {
    /// Versions and toolchain names: letters, digits and `._+-@/` (no spaces, no leading dash).
    public static func isSafeVersion(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+@/-]{0,100}$"#, options: .regularExpression) != nil && !value.contains("..")
    }

    /// Package names, including npm scopes (`@scope/name`) and Go module paths (`example.com/a/b`).
    public static func isSafePackageName(_ value: String) -> Bool {
        value.range(of: #"^@?[A-Za-z0-9][A-Za-z0-9._~/-]{0,200}$"#, options: .regularExpression) != nil && !value.contains("..")
    }

    /// Conda match specs such as `numpy`, `python=3.12`, `scipy>=1.11,<2` or `conda-forge::xarray`.
    public static func isSafeCondaSpec(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:=<>!,*+\[\]' -]{0,200}$"#, options: .regularExpression) != nil
    }

    /// Conda channel names (`conda-forge`, `bioconda`, `defaults`). URLs are refused: they may carry tokens.
    public static func isSafeChannel(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$"#, options: .regularExpression) != nil
    }
}

/// Small file helpers shared by the scanners.
enum ToolchainFiles {
    static func directories(in folder: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { VersionComparison.compare($0, $1) == .orderedAscending }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func firstLine(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 5_000_000 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
