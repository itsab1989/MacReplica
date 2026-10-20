import Foundation

/// The installer apps on this Mac: which are Apple's, whether one is locked for running as root, moving one to the
/// Trash, and copying one the user chose elsewhere into Applications.
public enum InstallerFilesError: Error, Equatable, Sendable {
    /// Not an Apple installer (`com.apple.InstallAssistant…`) or not directly in Applications.
    case notAnInstaller
    case alreadyInApplications(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case copyFailed(String)
    case trashFailed(String)
    case passwordDenied
}

public struct InstallerFiles: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var privileged: PrivilegedExecuting
    /// Free space for new files on the volume of `url` (replaced in tests).
    public var freeSpace: @Sendable (URL) -> Int64?
    /// Whether the user can move the item without administrator rights (replaced in tests: nothing there is root's).
    public var movableByUser: @Sendable (URL) -> Bool

    public init(layout: SystemLayout, runner: CommandRunning, privileged: PrivilegedExecuting,
                freeSpace: @escaping @Sendable (URL) -> Int64? = InstallerFiles.availableSpace,
                movableByUser: @escaping @Sendable (URL) -> Bool = InstallerFiles.isMovableByUser) {
        self.layout = layout
        self.runner = runner
        self.privileged = privileged
        self.freeSpace = freeSpace
        self.movableByUser = movableByUser
    }

    /// Owned by this user, in a folder the user may change.
    public static func isMovableByUser(_ url: URL) -> Bool {
        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber)?.uint32Value
        return owner == getuid() && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    public static func availableSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public var applications: URL { layout.applicationFolders.first ?? URL(fileURLWithPath: "/Applications") }
    public var trash: URL { layout.homeDirectory.appendingPathComponent(".Trash") }

    /// Apple's installer apps carry `com.apple.InstallAssistant…` (Sonoma: `com.apple.InstallAssistant.macOSSonoma`,
    /// Mountain Lion: `com.apple.InstallAssistant.MountainLion`).
    public static func isAppleInstaller(_ app: URL) -> Bool {
        guard app.pathExtension == "app",
              let info = InstallerInspector.plist(app.appendingPathComponent("Contents/Info.plist")) else { return false }
        return (info["CFBundleIdentifier"] as? String)?.hasPrefix("com.apple.InstallAssistant") == true
    }

    /// Owned by root and writable by nobody else – the app, its Contents, the tool and the installer data – as
    /// Software Update leaves it. Anything else is locked before `createinstallmedia` runs as root.
    public static func isLockedForRoot(_ app: URL) -> Bool {
        let paths = [app, app.appendingPathComponent("Contents"), app.appendingPathComponent("Contents/Resources"),
                     app.appendingPathComponent("Contents/Resources/createinstallmedia"), app.appendingPathComponent("Contents/SharedSupport")]
        return paths.allSatisfy { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return !FileManager.default.fileExists(atPath: url.path) }
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            return owner == 0 && mode & 0o022 == 0
        }
    }

    /// The entry of an installer on this Mac, from what the installer itself says.
    public static func release(from report: InstallerAppReport) -> MacOSRelease {
        let name = report.displayName.hasPrefix("Install ") ? String(report.displayName.dropFirst("Install ".count)) : report.displayName
        let major = report.macOSVersion.map(MacOSInstallerCatalog.majorRelease(of:)) ?? "?"
        return MacOSRelease(name: name, major: major, version: report.macOSVersion, build: report.build, sizeBytes: report.sizeBytes,
                            source: .onThisMac(path: report.app.path), provenance: report.app.path)
    }

    /// Moves an installer from Applications to the Trash. Software Update's installers belong to root; then macOS asks
    /// for the administrator password (an installer the user owns is moved without it).
    public func moveToTrash(_ app: URL) async throws {
        guard PrivilegedOperation.isInstallerApp(app, applicationFolders: layout.applicationFolders), Self.isAppleInstaller(app) else {
            throw InstallerFilesError.notAnInstaller
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        var destination = trash.appendingPathComponent(app.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            destination = trash.appendingPathComponent(app.deletingPathExtension().lastPathComponent + " " + stamp + ".app")
        }
        if movableByUser(app) {
            do { try fm.moveItem(at: app, to: destination) } catch { throw InstallerFilesError.trashFailed(layout.redact(error.localizedDescription)) }
        } else {
            do {
                try await privileged.run([.trashInstaller(app: app, destination: destination)],
                                         reason: "MacReplica wants to move “\(app.lastPathComponent)” to the Trash.")
            } catch PrivilegedError.denied {
                throw InstallerFilesError.passwordDenied
            } catch {
                throw InstallerFilesError.trashFailed(layout.redact(String(describing: error)))
            }
        }
        guard !fm.fileExists(atPath: app.path) else { throw InstallerFilesError.trashFailed("still in Applications") }
    }

    /// Copies an installer the user chose (from Downloads, a drive, …) into Applications, where `createinstallmedia`
    /// may run from. Needs the installer's size plus 1 GiB free.
    public func copyIntoApplications(_ source: URL) async throws -> URL {
        guard Self.isAppleInstaller(source) else { throw InstallerFilesError.notAnInstaller }
        let destination = applications.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw InstallerFilesError.alreadyInApplications(destination.lastPathComponent) }
        let needed = InstallerInspector.allocatedSize(of: source) + 1_073_741_824
        if let available = freeSpace(applications), available < needed { throw InstallerFilesError.notEnoughSpace(needed: needed, available: available) }
        let result = try await runner.run(Command(executable: layout.ditto, arguments: [source.path, destination.path],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 3 * 3600))
        guard result.succeeded, Self.isAppleInstaller(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw InstallerFilesError.copyFailed(layout.redact(ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout, maxLines: 3)))
        }
        return destination
    }
}
