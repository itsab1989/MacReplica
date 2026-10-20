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
    /// Stops the chain unless MacReplica's random marker is on the volume it just erased (see `isInstallMediaMarker`),
    /// so the next step can only reach that volume, even if drives changed while the password dialog was open.
    case requireInstallMediaMarker(URL)
    /// Apple's `createinstallmedia` of an installer in Applications, onto the volume MacReplica just erased
    /// (see `isInstallMediaTool`, `isInstallMediaVolume`).
    case createInstallMedia(tool: URL, volume: URL, applicationPath: URL?)
    /// Makes an installer in Applications the system's own (as Software Update leaves it), so that nothing running as
    /// the user can change it between the signature check and `createinstallmedia` running as root.
    case lockInstallerOwner(URL)
    /// Removes write access for everyone but its owner (root) – the second half of locking the installer.
    case lockInstallerPermissions(URL)
    /// Apple's signature on `createinstallmedia`, checked again as root right before it runs.
    case verifyInstallerTool(URL)
    /// Moves an installer from Applications into the user's Trash (installers from Software Update belong to root).
    case trashInstaller(app: URL, destination: URL)
    /// Expert option: erases one partition – addressed by its partition UUID, which no other partition has – as Mac
    /// OS Extended with MacReplica's random name. Only directly before `createInstallMedia` on that name.
    case eraseVolumeForInstaller(partitionUUID: String, name: String)

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
        case .requireInstallMediaMarker(let url): return ["/bin/test", "-f", url.path]
        case .createInstallMedia(let tool, let volume, let applicationPath):
            return [tool.path, "--volume", volume.path, "--nointeraction"] + (applicationPath.map { ["--applicationpath", $0.path] } ?? [])
        case .eraseVolumeForInstaller(let uuid, let name): return ["/usr/sbin/diskutil", "eraseVolume", "JHFS+", name, uuid]
        case .lockInstallerOwner(let app): return ["/usr/sbin/chown", "-R", "root:wheel", app.path]
        case .lockInstallerPermissions(let app): return ["/bin/chmod", "-R", "go-w", app.path]
        case .verifyInstallerTool(let tool): return ["/usr/bin/codesign", "--verify", "--strict", "-R=" + InstallerInspector.appleRequirement, tool.path]
        case .trashInstaller(let app, let destination): return ["/bin/mv", app.path, destination.path]
        }
    }

    var paths: [URL] {
        switch self {
        case .createFolder(let url), .installPackage(let url), .removePluginFile(let url), .removeSystemItem(let url),
             .startLoaderService(let url): return [url]
        case .installFile(let source, let destination), .move(let source, let destination): return [source, destination]
        case .forgetLoaderReceipt: return []
        case .requireInstallMediaMarker(let url): return [url]
        case .createInstallMedia(let tool, let volume, let applicationPath): return [tool, volume] + (applicationPath.map { [$0] } ?? [])
        case .eraseVolumeForInstaller: return []
        case .lockInstallerOwner(let app), .lockInstallerPermissions(let app): return [app]
        case .verifyInstallerTool(let tool): return [tool]
        case .trashInstaller(let app, let destination): return [app, destination]
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

extension PrivilegedOperation {
    /// The volume names MacReplica gives a drive it erased for an installer: `MRINSTALL-` and 8 hex digits.
    public static func isInstallMediaVolumeName(_ name: String) -> Bool {
        name.range(of: #"^MRINSTALL-[0-9A-F]{8}$"#, options: .regularExpression) != nil
    }

    /// Only such a volume directly in `/Volumes` (in a simulation, its stand-in folder).
    public static func isInstallMediaVolume(_ url: URL, volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/..") else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.path == volumesRoot.standardizedFileURL.path
            && isInstallMediaVolumeName(url.lastPathComponent)
    }

    /// `.MacReplicaInstallTarget-<UUID>` at the top of such a volume.
    public static func isInstallMediaMarker(_ url: URL, volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Bool {
        isInstallMediaVolume(url.deletingLastPathComponent(), volumesRoot: volumesRoot)
            && url.lastPathComponent.range(of: #"^\.MacReplicaInstallTarget-[0-9A-F-]{36}$"#, options: .regularExpression) != nil
    }

    /// `Contents/Resources/createinstallmedia` of an `Install ….app` directly in an Applications folder.
    public static func isInstallMediaTool(_ url: URL, applicationFolders: [URL] = [URL(fileURLWithPath: "/Applications")]) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), url.lastPathComponent == "createinstallmedia" else { return false }
        let app = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard url.deletingLastPathComponent().path.hasSuffix(".app/Contents/Resources"), app.pathExtension == "app",
              app.lastPathComponent.hasPrefix("Install ") else { return false }
        return applicationFolders.map { $0.standardizedFileURL.path }.contains(app.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// An `Install ….app` directly in an Applications folder.
    public static func isInstallerApp(_ url: URL, applicationFolders: [URL] = [URL(fileURLWithPath: "/Applications")]) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/.."), url.pathExtension == "app",
              url.lastPathComponent.hasPrefix("Install ") else { return false }
        return applicationFolders.map { $0.standardizedFileURL.path }.contains(url.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// A free name for an installer directly in the user's Trash.
    public static func isTrashedInstaller(_ url: URL, trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) -> Bool {
        guard url.isFileURL, !url.path.contains("/../"), !url.path.hasSuffix("/.."), url.pathExtension == "app",
              url.lastPathComponent.hasPrefix("Install ") else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.path == trash.standardizedFileURL.path
    }

    /// The installer app the tool belongs to (what `--applicationpath` may name).
    static func isInstallMediaApplication(_ url: URL, tool: URL) -> Bool {
        url.standardizedFileURL.path == tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    }

    /// `createinstallmedia` only directly after the marker check of the same volume, or directly after erasing the
    /// partition that gets that volume's name, and only after its own signature was checked again as root earlier in
    /// the same step; a partition is erased only directly before `createinstallmedia`.
    static func checkInstallMediaOrder(_ operations: [PrivilegedOperation]) throws {
        for (index, operation) in operations.enumerated() {
            switch operation {
            case .createInstallMedia(let tool, let volume, _):
                guard index > 0 else { throw PrivilegedError.invalidPath(volume.path) }
                let verified = operations[..<index].contains {
                    if case .verifyInstallerTool(let checked) = $0 { return checked.standardizedFileURL.path == tool.standardizedFileURL.path }
                    return false
                }
                guard verified else { throw PrivilegedError.invalidPath(tool.path) }
                switch operations[index - 1] {
                case .requireInstallMediaMarker(let marker)
                    where marker.deletingLastPathComponent().standardizedFileURL.path == volume.standardizedFileURL.path: continue
                case .eraseVolumeForInstaller(_, let name) where volume.lastPathComponent == name: continue
                default: throw PrivilegedError.invalidPath(volume.path)
                }
            case .eraseVolumeForInstaller(let uuid, _):
                guard index + 1 < operations.count, case .createInstallMedia = operations[index + 1] else { throw PrivilegedError.invalidPath(uuid) }
            default: continue
            }
        }
    }

    /// Whether this operation may run: the checks of the operations that are narrowed to fixed items.
    func isAllowed(volumesRoot: URL = URL(fileURLWithPath: "/Volumes"), applicationFolders: [URL] = [URL(fileURLWithPath: "/Applications")],
                   trash: URL? = nil) -> Bool {
        switch self {
        case .removePluginFile(let url): return Self.isRemovablePlugin(url)
        case .removeSystemItem(let url): return Self.isRemovableLoaderItem(url)
        case .startLoaderService(let url): return Self.isLoaderService(url)
        case .requireInstallMediaMarker(let url): return Self.isInstallMediaMarker(url, volumesRoot: volumesRoot)
        case .createInstallMedia(let tool, let volume, let applicationPath):
            return Self.isInstallMediaTool(tool, applicationFolders: applicationFolders) && Self.isInstallMediaVolume(volume, volumesRoot: volumesRoot)
                && (applicationPath.map { Self.isInstallMediaApplication($0, tool: tool) } ?? true)
        case .eraseVolumeForInstaller(let uuid, let name):
            return InstallMediaDrive.isPartitionUUID(uuid) && Self.isInstallMediaVolumeName(name)
        case .lockInstallerOwner(let app), .lockInstallerPermissions(let app):
            return Self.isInstallerApp(app, applicationFolders: applicationFolders)
        case .verifyInstallerTool(let tool):
            return Self.isInstallMediaTool(tool, applicationFolders: applicationFolders)
        case .trashInstaller(let app, let destination):
            return Self.isInstallerApp(app, applicationFolders: applicationFolders)
                && Self.isTrashedInstaller(destination, trash: trash ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        default: return true
        }
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
        try PrivilegedOperation.checkInstallMediaOrder(operations)
        var arguments = ["-e", script, reason]
        for operation in operations {
            for url in operation.paths {
                try validate(url)
            }
            guard operation.isAllowed() else { throw PrivilegedError.invalidPath(operation.paths.first?.path ?? "\(operation)") }
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
        // Writing an installer to a slow USB 2 drive can take more than an hour.
        let createsMedia = operations.contains { if case .createInstallMedia = $0 { return true }; return false }
        let result = try await runner.run(Command(executable: osascript, arguments: arguments, timeout: createsMedia ? 3 * 3600 : 1800))
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

    /// Runs `createinstallmedia` in the simulation (the simulated installer's stand-in tool).
    public var toolRunner: (@Sendable ([String]) throws -> Void)?
    /// The simulated Mac's `/Volumes` and Applications folders, which the install-media operations are checked against.
    public var volumesRoot: URL
    public var applicationFolders: [URL]
    /// The simulated Mac's diskutil stand-in, which erases a simulated partition.
    public var diskutil: String
    /// The simulated Mac's codesign stand-in and Trash.
    public var codesign: String
    public var trash: URL?

    public init(packageInstaller: (@Sendable (URL) throws -> Void)? = nil, serviceStarter: (@Sendable (URL) throws -> Void)? = nil,
                toolRunner: (@Sendable ([String]) throws -> Void)? = nil, volumesRoot: URL = URL(fileURLWithPath: "/Volumes"),
                applicationFolders: [URL] = [URL(fileURLWithPath: "/Applications")], diskutil: String = "/usr/sbin/diskutil",
                codesign: String = "/usr/bin/codesign", trash: URL? = nil) {
        self.packageInstaller = packageInstaller
        self.serviceStarter = serviceStarter
        self.toolRunner = toolRunner
        self.volumesRoot = volumesRoot
        self.applicationFolders = applicationFolders
        self.diskutil = diskutil
        self.codesign = codesign
        self.trash = trash
    }

    public func run(_ operations: [PrivilegedOperation], reason: String) async throws {
        try PrivilegedOperation.checkInstallMediaOrder(operations)
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
            case .requireInstallMediaMarker(let url):
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders) else { throw PrivilegedError.invalidPath(url.path) }
                guard fm.fileExists(atPath: url.path) else { throw PrivilegedError.failed("marker missing: the volume is not the one MacReplica erased") }
            case .createInstallMedia:
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders) else {
                    throw PrivilegedError.invalidPath(operation.paths.last?.path ?? "")
                }
                guard let toolRunner else { throw PrivilegedError.failed("no tool runner") }
                try toolRunner(operation.argv)
            case .eraseVolumeForInstaller(let uuid, _):
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders) else { throw PrivilegedError.invalidPath(uuid) }
                guard let toolRunner else { throw PrivilegedError.failed("no tool runner") }
                try toolRunner([diskutil] + operation.argv.dropFirst())
            case .lockInstallerOwner(let app), .lockInstallerPermissions(let app):
                // Without root nothing can be handed to root; the paths are still checked.
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders) else { throw PrivilegedError.invalidPath(app.path) }
            case .verifyInstallerTool(let tool):
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders) else { throw PrivilegedError.invalidPath(tool.path) }
                guard let toolRunner else { throw PrivilegedError.failed("no tool runner") }
                try toolRunner([codesign] + operation.argv.dropFirst())
            case .trashInstaller(let app, let destination):
                guard operation.isAllowed(volumesRoot: volumesRoot, applicationFolders: applicationFolders, trash: trash) else {
                    throw PrivilegedError.invalidPath(app.path)
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: app, to: destination)
            }
        }
    }
}
