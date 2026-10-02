import Foundation

/// Everything MacReplica knows about the Python setup of a Mac.
///
/// Environments are *described*, not copied: a virtual environment contains
/// absolute paths and compiled, architecture-specific code, so it is rebuilt
/// on the new Mac from this description.
public struct PythonSnapshot: Codable, Equatable, Sendable {
    public var installations: [PythonInstallation]
    public var environments: [PythonEnvironment]
    /// Safe, non-secret Python-related settings, e.g. `PIP_REQUIRE_VIRTUALENV=true`.
    public var settings: [PythonSetting]

    public init(installations: [PythonInstallation] = [], environments: [PythonEnvironment] = [], settings: [PythonSetting] = []) {
        self.installations = installations
        self.environments = environments
        self.settings = settings
    }

    public var isEmpty: Bool { installations.isEmpty && environments.isEmpty && settings.isEmpty }
}

public enum PythonSource: String, Codable, Sendable, CaseIterable {
    case homebrew, pyenv, pythonOrg, system, unknown

    public init(from decoder: Decoder) throws {
        self = PythonSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Derives the source from an interpreter location.
    public static func from(path: String) -> PythonSource {
        let lower = path.lowercased()
        if lower.contains("/.pyenv/") { return .pyenv }
        if lower.contains("/library/frameworks/python.framework") { return .pythonOrg }
        if lower.contains("/cellar/python") || lower.contains("/opt/python@") || lower.hasPrefix("/opt/homebrew/") { return .homebrew }
        if lower.hasPrefix("/usr/bin") || lower.contains("commandlinetools") || lower.contains("xcode.app") { return .system }
        return .unknown
    }
}

public struct PythonInstallation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { executable }
    public var version: String
    /// Display path of the interpreter (home written as `~`).
    public var executable: String
    public var source: PythonSource
    public var architectures: [CPUArchitecture]

    public init(version: String, executable: String, source: PythonSource, architectures: [CPUArchitecture] = []) {
        self.version = version
        self.executable = executable
        self.source = source
        self.architectures = architectures
    }

    public var minorVersion: String { PythonVersion.minor(version) }
}

public enum EnvironmentManager: String, Codable, Sendable {
    case venv, virtualenvwrapper, pyenvVirtualenv, pipenv, unknown

    public init(from decoder: Decoder) throws {
        self = EnvironmentManager(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum PackageOrigin: String, Codable, Sendable {
    /// From the Python Package Index or another index: can be reinstalled by name and version.
    case index
    /// Installed in editable/development mode from a local folder.
    case editable
    /// Installed directly from a version control repository.
    case vcs
    /// Installed from a local file or folder.
    case local

    public init(from decoder: Decoder) throws {
        self = PackageOrigin(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .local
    }

    public var isReinstallable: Bool { self == .index }
}

public struct PythonPackage: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var version: String
    public var origin: PackageOrigin

    public init(name: String, version: String, origin: PackageOrigin = .index) {
        self.name = name
        self.version = version
        self.origin = origin
    }

    /// PEP 503 normalized name: lower case, runs of `-_.` become `-`.
    public var normalizedName: String { PythonPackage.normalize(name) }

    public static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression)
    }
}

public struct PythonEnvironment: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable identifier derived from the path, used for file names and restore steps.
    public var id: String
    public var name: String
    /// Display path of the environment folder (home written as `~`).
    public var path: String
    public var manager: EnvironmentManager
    public var pythonVersion: String
    public var baseInterpreter: String?
    public var baseSource: PythonSource
    public var architectures: [CPUArchitecture]
    public var packages: [PythonPackage]
    public var pipVersion: String?
    /// Backup-relative path of the generated `requirements.txt`.
    public var requirementsPath: String
    /// Dependency files found in the project, copied into the backup for reference.
    public var projectFiles: [FileRecord]

    public init(id: String, name: String, path: String, manager: EnvironmentManager, pythonVersion: String, baseInterpreter: String?,
                baseSource: PythonSource, architectures: [CPUArchitecture] = [], packages: [PythonPackage] = [], pipVersion: String? = nil,
                requirementsPath: String, projectFiles: [FileRecord] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.manager = manager
        self.pythonVersion = pythonVersion
        self.baseInterpreter = baseInterpreter
        self.baseSource = baseSource
        self.architectures = architectures
        self.packages = packages
        self.pipVersion = pipVersion
        self.requirementsPath = requirementsPath
        self.projectFiles = projectFiles
    }

    public var minorVersion: String { PythonVersion.minor(pythonVersion) }
    /// Packages that can be reinstalled automatically, excluding the installer tools themselves.
    public var installablePackages: [PythonPackage] {
        packages.filter { $0.origin.isReinstallable && !PythonVersion.toolPackages.contains($0.normalizedName) }
    }
    public var manualPackages: [PythonPackage] { packages.filter { !$0.origin.isReinstallable } }

    /// The `requirements.txt` MacReplica uses to rebuild the environment.
    public func requirementsText(header: String) -> String {
        var lines = header.split(separator: "\n").map { "# " + $0 }
        lines += installablePackages.sorted { $0.normalizedName < $1.normalizedName }.map { "\($0.name)==\($0.version)" }
        for package in manualPackages.sorted(by: { $0.normalizedName < $1.normalizedName }) {
            lines.append("# \(package.name)==\(package.version) (\(package.origin.rawValue), not reinstallable automatically)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct PythonSetting: Codable, Equatable, Sendable, Hashable {
    public var key: String
    public var value: String
    /// Where it was found, e.g. `~/.zshrc`.
    public var source: String

    public init(key: String, value: String, source: String) {
        self.key = key
        self.value = value
        self.source = source
    }
}

public enum PythonVersion {
    /// "3.12.4" → "3.12".
    public static func minor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The Homebrew formula that provides a minor version, e.g. `python@3.12`.
    public static func formula(forMinor minor: String) -> String { "python@\(minor)" }

    /// Minor versions MacReplica may ask Homebrew for (and the matching interpreters it may run).
    public static let supportedMinors = (8...20).map { "3.\($0)" }

    static let toolPackages: Set<String> = ["pip", "setuptools", "wheel", "distribute"]
}
