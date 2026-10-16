import Foundation

/// An operation that needs administrator rights.
public enum PrivilegedOperation: Equatable, Sendable {
    /// Creates a folder (and parents) owned by root.
    case createFolder(URL)
    /// Copies a file into place, owned by root and readable by everyone.
    case installFile(source: URL, destination: URL)
    /// Moves an existing file aside before it is replaced.
    case move(source: URL, destination: URL)
    /// Installs a signed installer package.
    case installPackage(URL)
    /// Removes MacReplica's own corner plugin from the Ammonia tweak folder – nothing else (see `isRemovablePlugin`).
    case removePluginFile(URL)
    /// Removes one of the tweak loader's own items when uninstalling it – only the fixed set (see `isRemovableLoaderItem`).
    case removeSystemItem(URL)
    /// Loads the tweak loader's launch daemon into launchd (what its own app's "Install" button does) – only its one
    /// fixed daemon file (see `isLoaderService`).
    case startLoaderService(URL)
    /// Forgets the tweak loader's installer receipt after uninstalling it – only its one fixed package identifier.
    case forgetLoaderReceipt

    /// The executable and arguments for this operation. Only these fixed system tools can ever be run with
    /// administrator rights.
    var argv: [String] {
        switch self {
        case .createFolder(let url): return ["/bin/mkdir", "-p", url.path]
        case .installFile(let source, let destination):
            // Classic suitcase fonts keep their data in the resource fork, which `install` would drop.
            if FileScanner.hasResourceFork(source) { return ["/usr/bin/ditto", "--rsrc", source.path, destination.path] }
            return ["/usr/bin/install", "-m", "0644", "-o", "root", "-g", "wheel", source.path, destination.path]
        case .move(let source, let destination): return ["/bin/mv", "-f", source.path, destination.path]
        case .installPackage(let url): return ["/usr/sbin/installer", "-pkg", url.path, "-target", "/"]
        case .removePluginFile(let url): return ["/bin/rm", "-f", url.path]
        case .removeSystemItem(let url): return ["/bin/rm", "-rf", url.path]
        case .startLoaderService(let url): return ["/bin/launchctl", "bootstrap", "system", url.path]
        case .forgetLoaderReceipt: return ["/usr/sbin/pkgutil", "--forget", PluginLoader.receiptIdentifier]
        }
    }

    var paths: [URL] {
        switch self {
        case .createFolder(let url), .installPackage(let url), .removePluginFile(let url), .removeSystemItem(let url),
             .startLoaderService(let url): return [url]
        case .installFile(let source, let destination), .move(let source, let destination): return [source, destination]
        case .forgetLoaderReceipt: return []
        }
    }
}

extension PrivilegedOperation {
    /// Only MacReplica's own corner-plugin files (`MacReplicaCorners.dylib` and its `.options`) directly inside a
    /// `pluginplayground/tweaks` folder.
    public static func isRemovablePlugin(_ url: URL) -> Bool {
        // The path as given: parent steps are refused outright (standardizing would hide them).
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/..") else { return false }
        return url.deletingLastPathComponent().path.hasSuffix("/pluginplayground/tweaks")
            && CornerPlugin.fileNames.contains(url.lastPathComponent)
    }

    /// Only Plugin Playground's own fixed items may be removed by `removeSystemItem` when uninstalling the loader.
    public static func isRemovableLoaderItem(_ url: URL) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/..") else { return false }
        let allowed = [PluginLoader.daemonPlist, PluginLoader.app, PluginLoader.installRoot, PluginLoader.logs].map(\.standardizedFileURL)
        return allowed.contains(url.standardizedFileURL)
    }

    /// Only the tweak loader's own daemon file (`…/Library/LaunchDaemons/com.pluginplayground.grant.plist`) may be loaded.
    public static func isLoaderService(_ url: URL) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/..") else { return false }
        return url.path.hasSuffix("/Library/LaunchDaemons/" + PluginLoader.serviceLabel + ".plist")
    }
}

public enum PrivilegedError: Error, Equatable, Sendable {
    case denied
    case failed(String)
    case invalidPath(String)
}

public protocol PrivilegedExecuting: Sendable {
    /// Runs all operations after a single administrator authentication.
    /// `reason` is shown in the system's password dialog.
    func run(_ operations: [PrivilegedOperation], reason: String) async throws
}

/// Asks macOS for administrator rights via the standard authentication dialog
/// (AppleScript `do shell script … with administrator privileges`).
///
/// Paths are passed to `osascript` as separate arguments and quoted by
/// AppleScript's `quoted form of`, so no string is ever spliced into a shell
/// command by MacReplica. Paths are additionally validated beforehand.
public struct AppleScriptPrivilegedExecutor: PrivilegedExecuting {
    public var runner: CommandRunning
    public var osascript: String

    public init(runner: CommandRunning, osascript: String = "/usr/bin/osascript") {
        self.runner = runner
        self.osascript = osascript
    }

    static let script = """
    on run argv
        set promptText to item 1 of argv
        set commandText to ""
        set i to 2
        repeat while i is less than or equal to (count of argv)
            set wordCount to (item i of argv) as integer
            set part to ""
            repeat with j from 1 to wordCount
                set part to part & quoted form of (item (i + j) of argv) & " "
            end repeat
            if commandText is "" then
                set commandText to part
            else
                set commandText to commandText & "&& " & part
            end if
            set i to i + wordCount + 1
        end repeat
        do shell script commandText with prompt promptText with administrator privileges
    end run
    """

    /// Builds the `osascript` argument list. Exposed for tests.
    static func arguments(for operations: [PrivilegedOperation], reason: String) throws -> [String] {
        var arguments = ["-e", script, reason]
        for operation in operations {
            for url in operation.paths {
                try validate(url)
            }
            if case .removePluginFile(let url) = operation, !PrivilegedOperation.isRemovablePlugin(url) {
                throw PrivilegedError.invalidPath(url.path)
            }
            if case .removeSystemItem(let url) = operation, !PrivilegedOperation.isRemovableLoaderItem(url) {
                throw PrivilegedError.invalidPath(url.path)
            }
            if case .startLoaderService(let url) = operation, !PrivilegedOperation.isLoaderService(url) {
                throw PrivilegedError.invalidPath(url.path)
            }
            let argv = operation.argv
            arguments.append(String(argv.count))
            arguments.append(contentsOf: argv)
        }
        return arguments
    }

    static func validate(_ url: URL) throws {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PrivilegedError.invalidPath(path)
        }
    }

    public func run(_ operations: [PrivilegedOperation], reason: String) async throws {
        guard !operations.isEmpty else { return }
        let arguments = try Self.arguments(for: operations, reason: reason)
        let result = try await runner.run(Command(executable: osascript, arguments: arguments, timeout: 1800))
        guard result.succeeded else {
            if result.stderr.contains("-128") || result.stderr.lowercased().contains("user canceled") {
                throw PrivilegedError.denied
            }
            throw PrivilegedError.failed(result.stderr)
        }
    }
}

/// Performs the same operations without asking for rights. Used when the target
/// folders are writable anyway (simulation environment and tests).
public struct DirectPrivilegedExecutor: PrivilegedExecuting {
    /// Installs a "package" in the simulation: a JSON file describing files to create.
    public var packageInstaller: (@Sendable (URL) throws -> Void)?
    /// Starts a launch daemon in the simulation (the real launchd is never asked).
    public var serviceStarter: (@Sendable (URL) throws -> Void)?

    public init(packageInstaller: (@Sendable (URL) throws -> Void)? = nil, serviceStarter: (@Sendable (URL) throws -> Void)? = nil) {
        self.packageInstaller = packageInstaller
        self.serviceStarter = serviceStarter
    }

    public func run(_ operations: [PrivilegedOperation], reason: String) async throws {
        let fm = FileManager.default
        for operation in operations {
            switch operation {
            case .createFolder(let url):
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .installFile(let source, let destination):
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
            case .move(let source, let destination):
                try fm.moveItem(at: source, to: destination)
            case .installPackage(let url):
                guard let packageInstaller else { throw PrivilegedError.failed("no package installer") }
                try packageInstaller(url)
            case .removePluginFile(let url):
                guard PrivilegedOperation.isRemovablePlugin(url) else { throw PrivilegedError.invalidPath(url.path) }
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            case .removeSystemItem(let url):
                guard PrivilegedOperation.isRemovableLoaderItem(url) else { throw PrivilegedError.invalidPath(url.path) }
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            case .startLoaderService(let url):
                guard PrivilegedOperation.isLoaderService(url) else { throw PrivilegedError.invalidPath(url.path) }
                guard let serviceStarter else { throw PrivilegedError.failed("no service starter") }
                try serviceStarter(url)
            case .forgetLoaderReceipt:
                // The simulated Mac has no package database.
                break
            }
        }
    }
}
