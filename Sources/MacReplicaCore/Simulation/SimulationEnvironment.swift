import Foundation

/// A sandboxed stand-in for a Mac, used by integration tests and for validating
/// the real app without touching real installations.
///
/// A simulation root contains `simulation.json`, which maps every location of
/// `SystemLayout` to a folder inside the root, plus small stand-in tools
/// (`brew`, `mas`, `xcode-select` …) that behave like the real ones but only
/// change files inside the root. The app enters this mode only when launched
/// with `--simulation-root <folder>`; it is never used otherwise.
public struct SimulationEnvironment: Sendable {
    public struct Config: Codable, Sendable {
        public var home: String
        public var applicationFolders: [String]
        public var userFonts: String
        public var systemFonts: String
        public var userColorProfiles: String
        public var systemColorProfiles: String
        public var homebrewPrefixes: [String]
        public var xcodeSelect: String
        public var pkgutil: String
        public var mdls: String
        public var commandLineToolsMarkers: [String]
        public var caskCatalog: String
        public var formulaCatalog: String?
        public var homebrewPackage: String
        public var architecture: CPUArchitecture
        public var macosVersion: String
        /// The simulated Mac's model identifier (e.g. `MacBookPro16,1`); nil uses this Mac's.
        public var modelIdentifier: String?

        public init(home: String, applicationFolders: [String], userFonts: String, systemFonts: String, userColorProfiles: String,
                    systemColorProfiles: String, homebrewPrefixes: [String], xcodeSelect: String, pkgutil: String, mdls: String,
                    commandLineToolsMarkers: [String], caskCatalog: String, formulaCatalog: String?, homebrewPackage: String,
                    architecture: CPUArchitecture, macosVersion: String) {
            self.home = home
            self.applicationFolders = applicationFolders
            self.userFonts = userFonts
            self.systemFonts = systemFonts
            self.userColorProfiles = userColorProfiles
            self.systemColorProfiles = systemColorProfiles
            self.homebrewPrefixes = homebrewPrefixes
            self.xcodeSelect = xcodeSelect
            self.pkgutil = pkgutil
            self.mdls = mdls
            self.commandLineToolsMarkers = commandLineToolsMarkers
            self.caskCatalog = caskCatalog
            self.formulaCatalog = formulaCatalog
            self.homebrewPackage = homebrewPackage
            self.architecture = architecture
            self.macosVersion = macosVersion
        }
    }

    public static let configFileName = "simulation.json"
    public static let launchArgument = "--simulation-root"

    public var root: URL
    public var config: Config
    public var layout: SystemLayout

    public enum LoadError: Error, Equatable { case missingConfig, invalidConfig(String), pathOutsideRoot(String) }

    public init(root: URL) throws {
        let root = root.standardizedFileURL
        let data: Data
        do { data = try Data(contentsOf: root.appendingPathComponent(Self.configFileName)) } catch { throw LoadError.missingConfig }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config: Config
        do { config = try decoder.decode(Config.self, from: data) } catch { throw LoadError.invalidConfig(String(describing: error)) }

        func inside(_ relative: String) throws -> URL {
            guard let url = PathSafety.resolve(relative, inside: root) else { throw LoadError.pathOutsideRoot(relative) }
            return url
        }
        let home = try inside(config.home)
        self.root = root
        self.config = config
        self.layout = SystemLayout(
            homeDirectory: home,
            applicationFolders: try config.applicationFolders.map(inside),
            userFonts: try inside(config.userFonts),
            systemFonts: try inside(config.systemFonts),
            userColorProfiles: try inside(config.userColorProfiles),
            systemColorProfiles: try inside(config.systemColorProfiles),
            homebrewPrefixes: try config.homebrewPrefixes.map(inside),
            xcodeSelect: try inside(config.xcodeSelect).path,
            pkgutil: try inside(config.pkgutil).path,
            mdls: try inside(config.mdls).path,
            osascript: "/usr/bin/osascript",
            installer: "/usr/sbin/installer",
            commandLineToolsMarkers: try config.commandLineToolsMarkers.map { try inside($0).path },
            rosettaMarker: home.appendingPathComponent("rosetta-installed").path,
            applicationSupport: home.appendingPathComponent("Library/Application Support/MacReplica"),
            caches: home.appendingPathComponent("Library/Caches/MacReplica"),
            logs: home.appendingPathComponent("Library/Logs/MacReplica"),
            pythonFrameworks: root.appendingPathComponent("Library/Frameworks"),
            macOSFonts: root.appendingPathComponent("System/Library/Fonts"),
            macOSColorProfiles: root.appendingPathComponent("System/Library/ColorSync/Profiles"),
            macOSFontAssets: root.appendingPathComponent("System/Library/AssetsV2"),
            isSimulation: true)
        self.layout.simulationRoot = root
        self.layout.lpstat = root.appendingPathComponent("tools/lpstat").path
        self.layout.cupsPPDFolder = root.appendingPathComponent("etc/cups/ppd")
        self.layout.defaults = root.appendingPathComponent("tools/defaults").path
        self.layout.killall = root.appendingPathComponent("tools/killall").path
        // Tools section: the real (read-only) status tools and profiles, unless the simulated Mac brings stand-ins to
        // show states this Mac is not in (e.g. a managed Mac). Mixing both would show a state no Mac is in.
        let managed = root.appendingPathComponent("Library/Managed Preferences")
        if FileManager.default.fileExists(atPath: managed.path) { self.layout.managedPreferences = managed }
        self.layout.pluginTweaks = root.appendingPathComponent("opt/pluginplayground/tweaks")
        self.layout.pluginLoaderBin = root.appendingPathComponent("opt/pluginplayground/bin")
        self.layout.pluginLoaderDaemon = root.appendingPathComponent("Library/LaunchDaemons/com.pluginplayground.grant.plist")
        self.layout.pluginLoaderOptions = root.appendingPathComponent("opt/pluginplayground/current.options")
        self.layout.pluginLoaderLogs = root.appendingPathComponent("var/log/pluginplayground")
        // The simulated Mac never asks the real launchd: without stand-ins the loader's daemon reads as not running.
        self.layout.launchctl = root.appendingPathComponent("tools/launchctl").path
        self.layout.pgrep = root.appendingPathComponent("tools/pgrep").path
        // Drives: always the simulated Mac's stand-in, never the real diskutil – nothing in a simulation can erase a disk.
        self.layout.diskutil = root.appendingPathComponent("tools/diskutil").path
        self.layout.volumesRoot = root.appendingPathComponent("Volumes")
        self.layout.bless = root.appendingPathComponent("tools/bless").path
        for name in ["spctl", "csrutil", "profiles", "softwareupdate", "nvram", "codesign"] {
            let standIn = root.appendingPathComponent("tools/\(name)").path
            guard FileManager.default.isExecutableFile(atPath: standIn) else { continue }
            switch name {
            case "spctl": self.layout.spctl = standIn
            case "csrutil": self.layout.csrutil = standIn
            case "profiles": self.layout.profiles = standIn
            case "nvram": self.layout.nvram = standIn
            case "codesign": self.layout.codesign = standIn
            default: self.layout.softwareupdate = standIn
            }
        }
    }

    /// Reads `--simulation-root <folder>` from the launch arguments.
    public static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SimulationEnvironment? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return nil }
        return try? SimulationEnvironment(root: URL(fileURLWithPath: arguments[index + 1]))
    }

    public func makeRunner() -> CommandRunning {
        ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                             baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
                                .merging(["MACREPLICA_SIMULATION_ROOT": root.path]) { $1 })
    }

    public func makeCatalogProvider() -> CatalogProviding {
        LocalCatalogProvider(caskFile: root.appendingPathComponent(config.caskCatalog),
                             formulaFile: config.formulaCatalog.map { root.appendingPathComponent($0) })
    }

    public func makeHomebrewSource() -> HomebrewPackageSource {
        LocalHomebrewPackageSource(package: root.appendingPathComponent(config.homebrewPackage))
    }

    /// The simulated Mac's administrator password is `state/admin-password` (default "macreplica"); the
    /// real `sudo` is never used in a simulation.
    public func makeAdminPasswordValidator() -> AdminPasswordValidating {
        SimulatedPasswordValidator(file: root.appendingPathComponent("state/admin-password"))
    }

    public func makePrivilegedExecutor() -> PrivilegedExecuting {
        let root = self.root
        let layout = self.layout
        return DirectPrivilegedExecutor(packageInstaller: { package in
            try SimulationEnvironment.installSimulatedPackage(package, root: root)
        }, serviceStarter: { _ in
            // The simulated Mac's stand-ins `tools/launchctl` and `tools/pgrep` report the service as running from now on.
            let marker = root.appendingPathComponent("state/loader-service-running")
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        }, toolRunner: { argv in
            // The simulated installer's createinstallmedia (a stand-in script inside the simulated Mac).
            guard let tool = argv.first, tool.hasPrefix(root.standardizedFileURL.path + "/") else { throw PrivilegedError.invalidPath(argv.first ?? "") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = Array(argv.dropFirst())
            process.environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil).merging(["MACREPLICA_SIMULATION_ROOT": root.path]) { $1 }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw PrivilegedError.failed(String(decoding: data, as: UTF8.self)) }
        }, volumesRoot: layout.volumesRoot, applicationFolders: layout.applicationFolders, diskutil: layout.diskutil)
    }

    /// A simulated installer package is JSON: `{"files": [{"source": "tools/brew", "destination": "opt/homebrew/bin/brew"}]}`.
    static func installSimulatedPackage(_ package: URL, root: URL) throws {
        struct Package: Codable { struct File: Codable { var source: String; var destination: String }; var files: [File] }
        let decoded = try JSONDecoder().decode(Package.self, from: Data(contentsOf: package))
        for file in decoded.files {
            guard let source = PathSafety.resolve(file.source, inside: root),
                  let destination = PathSafety.resolve(file.destination, inside: root) else {
                throw PrivilegedError.invalidPath(file.destination)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }
}

/// Supplies a local package file instead of downloading one (simulation and tests).
public struct LocalHomebrewPackageSource: HomebrewPackageSource {
    public var package: URL

    public init(package: URL) {
        self.package = package
    }

    public func fetchVerifiedPackage(into folder: URL) async throws -> URL {
        let destination = folder.appendingPathComponent(package.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: package, to: destination)
        } catch {
            throw HomebrewInstallError.downloadFailed("simulated package missing")
        }
        return destination
    }
}

/// Compares with the simulated Mac's administrator password.
public struct SimulatedPasswordValidator: AdminPasswordValidating {
    public var file: URL
    public init(file: URL) { self.file = file }
    public func isValid(_ password: String) async -> Bool {
        let expected = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "macreplica"
        return !password.isEmpty && password == expected
    }
}
