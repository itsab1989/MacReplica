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
    public static let serviceLabel = "com.pluginplayground.grant"

    /// The launch daemon exactly as Plugin Playground's own app writes it ("Install" in its Daemon box): it runs `grant`,
    /// which patches amfid for half a second, starts the injector `fangs` and restores amfid.
    public static func serviceDefinition(layout: SystemLayout) -> [String: Any] {
        ["Label": serviceLabel,
         "ProgramArguments": [layout.pluginLoaderBin.appendingPathComponent("grant").path],
         "RunAtLoad": true,
         "KeepAlive": true,
         "StandardOutPath": layout.pluginLoaderLogs.appendingPathComponent("grant.log").path,
         "StandardErrorPath": layout.pluginLoaderLogs.appendingPathComponent("grant.err").path]
    }

    /// Whether the loader's global settings have "Disable arm64e (PAC)" on. A missing or unreadable file means off –
    /// that is what the injector itself assumes.
    public static func pacStrippingOn(optionsFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: optionsFile),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return (plist["disablePAC"] as? Bool) == true
    }

    /// The loader's settings with `disablePAC` on. Every other key the user set (blacklist, pause, legacy folder) is
    /// kept; a missing file starts from the defaults Plugin Playground's own app writes.
    public static func optionsWithPACStripping(existing: Data?) throws -> Data {
        // `disablePAC` is set unconditionally below, so it is deliberately not seeded here (no dead store).
        var options: [String: Any] = ["pauseInjection": false, "useLegacyAmmonia": false, "globalBlacklist": [String]()]
        if let existing, let plist = try? PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any] {
            options.merge(plist) { _, new in new }
        }
        options["disablePAC"] = true
        return try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
    }

    /// `last exit code = …` from `launchctl print`, for diagnostics.
    public static func lastExit(launchctlPrint: String) -> String? {
        for line in launchctlPrint.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("last exit code = ") { return String(trimmed.dropFirst("last exit code = ".count)) }
        }
        return nil
    }

    /// The privileged operations for the missing steps (one administrator prompt). Files MacReplica writes (settings,
    /// daemon definition) are prepared in `staging` first. `package` is the verified download for `.installLoader`.
    /// Order: loader, plugin, settings, daemon file, start – so a cancelled or failed run leaves every finished step
    /// usable and the next run continues where this one stopped.
    public static func setupOperations(_ steps: [CornerPlugin.SetupStep], layout: SystemLayout, appBundle: URL,
                                       package: URL?, staging: URL) throws -> [PrivilegedOperation] {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var operations: [PrivilegedOperation] = []
        for step in steps {
            switch step {
            case .installLoader:
                guard let package else { throw InstallError.downloadFailed("no package") }
                operations.append(.installPackage(package))
            case .installPlugin:
                guard let plugin = CornerPlugin.installOperations(layout: layout, appBundle: appBundle) else {
                    throw InstallError.pluginMissingInApp
                }
                operations += plugin
            case .savePACSetting:
                let file = staging.appendingPathComponent("current.options")
                try optionsWithPACStripping(existing: try? Data(contentsOf: layout.pluginLoaderOptions)).write(to: file)
                operations.append(.installFile(source: file, destination: layout.pluginLoaderOptions))
            case .installService:
                let file = staging.appendingPathComponent(serviceLabel + ".plist")
                try PropertyListSerialization.data(fromPropertyList: serviceDefinition(layout: layout), format: .xml, options: 0).write(to: file)
                operations += [.createFolder(layout.pluginLoaderLogs), .installFile(source: file, destination: layout.pluginLoaderDaemon)]
            case .startService:
                operations.append(.startLoaderService(layout.pluginLoaderDaemon))
            }
        }
        return operations
    }

    public enum InstallError: Error, Equatable {
        case downloadFailed(String)
        case checksumMismatch(expected: String, got: String)
        case pluginMissingInApp
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
    /// launch daemon. Each is tolerant of the target already being gone (`rm -rf`). The running injector is
    /// deliberately not stopped: launchd would kill it without letting it remove its breakpoints from launchd, which can
    /// crash the Mac. It stops for good at the next restart, which the user does anyway to turn System Integrity
    /// Protection back on. No boot argument or library-validation change has to be reversed – Playground makes none
    /// that persist.
    /// `receiptPresent`: the installer's receipt is forgotten too (last, because `pkgutil --forget` fails without one).
    public static func uninstallOperations(receiptPresent: Bool = false) -> [PrivilegedOperation] {
        [.removeSystemItem(daemonPlist), .removeSystemItem(app), .removeSystemItem(installRoot), .removeSystemItem(logs)]
            + (receiptPresent ? [.forgetLoaderReceipt] : [])
    }

    /// Whether macOS still has the loader's installer receipt (`pkgutil --pkg-info`, read-only). nil = could not tell.
    public static func receiptPresent(layout: SystemLayout, runner: CommandRunning) async -> Bool? {
        guard let result = try? await runner.run(Command(executable: layout.pkgutil, arguments: ["--pkg-info", receiptIdentifier],
                                                          environment: ["LC_ALL": "C"], timeout: 15)) else { return nil }
        return result.exitCode == 0
    }
}
