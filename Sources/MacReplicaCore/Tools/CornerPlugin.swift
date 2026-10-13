import Foundation

/// MacReplica's corner plugin for the Plugin Playground tweak loader (`Extras/CornerPlugin`): menus, popovers,
/// Quick Look, toolbar groups and capsule buttons with the radius chosen in the window-corner tool. Advanced and at
/// the user's own risk.
///
/// Plugin Playground (github.com/CoreBedtime/playground) injects every `.dylib` in `/opt/pluginplayground/tweaks/`
/// into matching GUI processes via `DYLD_INSERT_LIBRARIES`; a tweak needs a sidecar `<name>.dylib.options` plist
/// (which processes to inject into) or it is never loaded. It needs System Integrity Protection only partly off
/// (`csrutil enable --without debug`) and no boot argument when the loader's PAC-stripping mode is on. MacReplica
/// never changes SIP; it detects the state, shows the steps, downloads the pinned loader and installs or removes
/// exactly its own two files with the administrator password. The plugin does nothing on macOS builds other than
/// `testedBuilds`, in non-AppKit or blacklisted processes, or without a chosen radius.
public enum CornerPlugin {
    public static let dylibName = "MacReplicaCorners.dylib"
    public static let optionsName = "MacReplicaCorners.dylib.options"
    public static let fileNames: Set<String> = [dylibName, optionsName]
    /// Must match `TESTED_BUILDS` in `Extras/CornerPlugin/MacReplicaCorners.m` (a test compares them).
    public static let testedBuilds: Set<String> = ["26A434"]
    public static let loaderProject = "https://github.com/CoreBedtime/playground"
    public static let appleSIP = "https://support.apple.com/en-us/102149"

    public enum Readiness: String, Sendable, Equatable {
        /// This macOS build was not tested: the plugin would do nothing, so MacReplica does not offer it.
        case untestedBuild
        /// System Integrity Protection is fully on; the loader needs debugging allowed (`csrutil enable --without debug`).
        case sipFullyOn
        /// The loader (Plugin Playground) is not installed yet.
        case loaderMissing
        /// The loader is installed but not enabled yet (the user enables it once in Plugin Playground).
        case loaderNotEnabled
        case ready
        case unknown
    }

    public struct Status: Sendable, Equatable {
        public var build: String?
        public var sip: GatekeeperStatus.SIP
        /// Debugging is allowed (partial SIP, `csrutil enable --without debug`, or SIP fully off). nil = could not tell.
        public var debuggingAllowed: Bool?
        /// Plugin Playground's files are present (`/opt/pluginplayground/bin`).
        public var loaderInstalled: Bool
        /// Plugin Playground is enabled: its `grant` launch daemon is set up.
        public var loaderEnabled: Bool
        /// Both of MacReplica's files are in the tweaks folder.
        public var installed: Bool
        /// The installed plugin is the one in this copy of MacReplica.
        public var current: Bool

        public init(build: String?, sip: GatekeeperStatus.SIP, debuggingAllowed: Bool?, loaderInstalled: Bool,
                    loaderEnabled: Bool, installed: Bool, current: Bool) {
            self.build = build
            self.sip = sip
            self.debuggingAllowed = debuggingAllowed
            self.loaderInstalled = loaderInstalled
            self.loaderEnabled = loaderEnabled
            self.installed = installed
            self.current = current
        }

        public var readiness: Readiness {
            guard let build, CornerPlugin.testedBuilds.contains(build) else { return .untestedBuild }
            switch debuggingAllowed {
            case .some(false): return .sipFullyOn
            case .none: return .unknown
            case .some(true): break
            }
            if !loaderInstalled { return .loaderMissing }
            if !loaderEnabled { return .loaderNotEnabled }
            return .ready
        }

        public var capability: ToolCapability {
            switch readiness {
            case .untestedBuild: return .unsupportedOnThisVersion
            case .sipFullyOn, .loaderMissing, .loaderNotEnabled: return .requiresUserAction
            case .ready: return .requiresAdministrator
            case .unknown: return .unableToDetermine
            }
        }
    }

    /// Whether `csrutil status` reports that debugging is allowed: either SIP is fully off, or it is a custom
    /// configuration with debugging not restricted (what `csrutil enable --without debug` leaves). nil if unreadable.
    public static func debuggingAllowed(csrutilOutput: String?) -> Bool? {
        guard let output = csrutilOutput?.lowercased() else { return nil }
        if output.contains("status: disabled") { return true }
        if output.contains("debugging restrictions: disabled") { return true }
        if output.contains("status: enabled"), !output.contains("custom configuration") { return false }
        if output.contains("debugging restrictions: enabled") { return false }
        return nil
    }

    public static func currentBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else { return nil }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The plugin and its options file inside this copy of MacReplica.
    public static func bundled(in appBundle: URL) -> (dylib: URL, options: URL)? {
        let folder = appBundle.appendingPathComponent("Contents/Library/CornerPlugin")
        let dylib = folder.appendingPathComponent(dylibName)
        let options = folder.appendingPathComponent(optionsName)
        let fm = FileManager.default
        return fm.fileExists(atPath: dylib.path) && fm.fileExists(atPath: options.path) ? (dylib, options) : nil
    }

    public static func status(layout: SystemLayout, runner: CommandRunning, sip: GatekeeperStatus.SIP, appBundle: URL,
                              build: String? = currentBuild()) async -> Status {
        let csr = try? await runner.run(Command(executable: layout.csrutil, arguments: ["status"],
                                                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: 15))
        let fm = FileManager.default
        let tweaks = layout.pluginTweaks
        let installedDylib = tweaks.appendingPathComponent(dylibName)
        let installed = fm.fileExists(atPath: installedDylib.path) && fm.fileExists(atPath: tweaks.appendingPathComponent(optionsName).path)
        var current = false
        if installed, let bundled = bundled(in: appBundle) {
            current = (try? Hashing.sha256Hex(ofFile: installedDylib)) == (try? Hashing.sha256Hex(ofFile: bundled.dylib))
        }
        // `csrutil status` from a stand-in overrides the value passed in (used in the simulation and tests).
        let debugging = debuggingAllowed(csrutilOutput: csr?.combinedOutput) ?? (sip == .disabled ? true : (sip == .enabled ? false : nil))
        return Status(build: build, sip: sip, debuggingAllowed: debugging,
                      loaderInstalled: fm.fileExists(atPath: layout.pluginLoaderBin.path),
                      loaderEnabled: fm.fileExists(atPath: layout.pluginLoaderDaemon.path),
                      installed: installed, current: current)
    }

    public static func installOperations(layout: SystemLayout, appBundle: URL) -> [PrivilegedOperation]? {
        guard let bundled = bundled(in: appBundle) else { return nil }
        let tweaks = layout.pluginTweaks
        // The options file first, so a half-finished install never leaves a dylib the loader would reject anyway.
        return [.installFile(source: bundled.options, destination: tweaks.appendingPathComponent(optionsName)),
                .installFile(source: bundled.dylib, destination: tweaks.appendingPathComponent(dylibName))]
    }

    /// The plugin first, so a half-finished removal never leaves a dylib without its options file.
    public static func removeOperations(layout: SystemLayout) -> [PrivilegedOperation] {
        [.removePluginFile(layout.pluginTweaks.appendingPathComponent(dylibName)),
         .removePluginFile(layout.pluginTweaks.appendingPathComponent(optionsName))]
    }
}
