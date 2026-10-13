import Foundation

/// The one-click helper that sets up the Plugin Playground tweak loader for the corner plugin. The user still turns on
/// partial System Integrity Protection (`csrutil enable --without debug`) in recoveryOS themselves — MacReplica never
/// changes SIP — and enables the loader once in Plugin Playground's own app; everything else MacReplica can do for
/// them, with a warning, the administrator password and a full undo.
///
/// MacReplica's only privileged install action is `installer -pkg` on a pinned, checksum-verified download of Plugin
/// Playground, plus copying its own plugin into the loader's tweaks folder. Unlike the older Ammonia loader, Playground
/// changes no boot argument and disables no library validation persistently (its `grant` daemon patches amfid only
/// while injecting), so undo is just: remove the plugin, uninstall the loader, restart and turn SIP back on.
public enum PluginLoader {
    /// A pinned Plugin Playground release. Downloaded over HTTPS, then checked against this exact SHA-256 before it is
    /// installed; a mismatch stops the install. The `.pkg` is unsigned (it is a tweak loader), so the checksum is the
    /// only trust. Its project has no licence, so MacReplica only links to and downloads it – never forks or bundles it.
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: URL
        public var sha256: String
        public var size: Int64
        public init(version: String, url: URL, sha256: String, size: Int64) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    /// Verified on 2026-10-14 (downloaded from the GitHub release and hashed locally; see docs/TOOLS.md).
    public static let release = Release(
        version: "1.1.0",
        url: URL(string: "https://github.com/CoreBedtime/playground/releases/download/1.1.0/PluginPlayground-1.1.0.pkg")!,
        sha256: "283c3b87e8861e158d726b3742e0bb42ea8d9677eaf9955eb541db88a7252b00",
        size: 1_186_472)

    public static let receiptIdentifier = "com.pluginplayground.core"
    public static let app = URL(fileURLWithPath: "/Applications/Plugin Playground.app")
    public static let binFolder = URL(fileURLWithPath: "/opt/pluginplayground/bin")
    public static let installRoot = URL(fileURLWithPath: "/opt/pluginplayground")
    public static let tweaks = URL(fileURLWithPath: "/opt/pluginplayground/tweaks")
    public static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.pluginplayground.grant.plist")
    public static let logs = URL(fileURLWithPath: "/var/log/pluginplayground")

    public enum InstallError: Error, Equatable {
        case downloadFailed(String)
        case checksumMismatch(expected: String, got: String)
    }

    /// Downloads the pinned Plugin Playground package into `work` and verifies its SHA-256. Returns the local file,
    /// ready to be installed with `PrivilegedOperation.installPackage`. Never installs anything by itself.
    public static func downloadVerifiedPackage(_ release: Release = release, transport: DownloadTransport, work: URL,
                                               progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent("PluginPlayground-\(release.version).pkg")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let file: URL
        do {
            file = try await transport.download(from: release.url, resumeData: nil, to: destination, progress: progress)
        } catch {
            throw InstallError.downloadFailed(String(describing: error))
        }
        let hash = try Hashing.sha256Hex(ofFile: file)
        guard hash.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError.checksumMismatch(expected: release.sha256, got: hash)
        }
        return file
    }

    /// The privileged steps that uninstall Plugin Playground: remove the app, its binaries and tweaks folder, and its
    /// launch daemon. Each is tolerant of the target already being gone (`rm -rf`). The daemon stops for good at the
    /// next restart, which the user does anyway to turn System Integrity Protection back on. No boot argument or
    /// library-validation change has to be reversed – Playground makes none that persist.
    public static func uninstallOperations() -> [PrivilegedOperation] {
        [.removeSystemItem(daemonPlist), .removeSystemItem(app), .removeSystemItem(installRoot), .removeSystemItem(logs)]
    }
}
