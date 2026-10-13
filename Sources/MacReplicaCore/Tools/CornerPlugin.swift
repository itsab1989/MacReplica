import Foundation

/// MacReplica's corner plugin for the Ammonia tweak loader (`Extras/CornerPlugin`): menus, popovers and Quick Look
/// with the radius chosen in the window-corner tool. Advanced and at the user's own risk.
///
/// Ammonia loads every `.dylib` in `/var/ammonia/core/tweaks/` that has a `.whitelist` or `.blacklist` file next to it
/// into every matching process (github.com/CoreBedtime/ammonia, opener.m). It only works with System Integrity
/// Protection off and the boot argument `-arm64e_preview_abi`. MacReplica never changes either; it detects them, shows
/// the steps, and installs or removes exactly its two files with the administrator password. The plugin itself does
/// nothing on macOS builds other than `testedBuilds`, in system processes (blacklist) or without a chosen radius.
public enum CornerPlugin {
    public static let dylibName = "MacReplicaCorners.dylib"
    public static let blacklistName = "MacReplicaCorners.dylib.blacklist"
    public static let fileNames: Set<String> = [dylibName, blacklistName]
    /// Must match `TESTED_BUILDS` in `Extras/CornerPlugin/MacReplicaCorners.m` (a test compares them).
    public static let testedBuilds: Set<String> = ["26A434"]
    public static let ammoniaReleases = "https://github.com/CoreBedtime/ammonia"
    public static let appleSIP = "https://support.apple.com/en-us/102149"

    public enum Readiness: String, Sendable, Equatable {
        /// This macOS build was not tested: the plugin would do nothing, so MacReplica does not offer it.
        case untestedBuild
        case sipOn
        case bootArgumentMissing
        case ammoniaMissing
        case ready
        case unknown
    }

    public struct Status: Sendable, Equatable {
        public var build: String?
        public var sip: GatekeeperStatus.SIP
        public var bootArgumentSet: Bool?
        public var ammoniaInstalled: Bool
        /// Both files are in the tweak folder.
        public var installed: Bool
        /// The installed plugin is the one in this copy of MacReplica.
        public var current: Bool

        public init(build: String?, sip: GatekeeperStatus.SIP, bootArgumentSet: Bool?, ammoniaInstalled: Bool, installed: Bool, current: Bool) {
            self.build = build
            self.sip = sip
            self.bootArgumentSet = bootArgumentSet
            self.ammoniaInstalled = ammoniaInstalled
            self.installed = installed
            self.current = current
        }

        public var readiness: Readiness {
            guard let build, CornerPlugin.testedBuilds.contains(build) else { return .untestedBuild }
            switch sip {
            case .enabled: return .sipOn
            case .unknown: return .unknown
            case .disabled: break
            }
            if bootArgumentSet == false { return .bootArgumentMissing }
            if !ammoniaInstalled { return .ammoniaMissing }
            return bootArgumentSet == nil ? .unknown : .ready
        }

        public var capability: ToolCapability {
            switch readiness {
            case .untestedBuild: return .unsupportedOnThisVersion
            case .sipOn, .bootArgumentMissing, .ammoniaMissing: return .requiresUserAction
            case .ready: return .requiresAdministrator
            case .unknown: return .unableToDetermine
            }
        }
    }

    /// `nvram boot-args` prints `boot-args\t-arm64e_preview_abi …`, or an error when none are set.
    public static func bootArgumentSet(nvramOutput: String?) -> Bool? {
        guard let output = nvramOutput else { return nil }
        if output.contains("boot-args") && output.contains("-arm64e_preview_abi") { return true }
        return false
    }

    public static func currentBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else { return nil }
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The plugin and blacklist inside this copy of MacReplica.
    public static func bundled(in appBundle: URL) -> (dylib: URL, blacklist: URL)? {
        let folder = appBundle.appendingPathComponent("Contents/Library/CornerPlugin")
        let dylib = folder.appendingPathComponent(dylibName)
        let blacklist = folder.appendingPathComponent(blacklistName)
        let fm = FileManager.default
        return fm.fileExists(atPath: dylib.path) && fm.fileExists(atPath: blacklist.path) ? (dylib, blacklist) : nil
    }

    public static func status(layout: SystemLayout, runner: CommandRunning, sip: GatekeeperStatus.SIP, appBundle: URL,
                              build: String? = currentBuild()) async -> Status {
        let nvram = try? await runner.run(Command(executable: layout.nvram, arguments: ["boot-args"],
                                                  environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: 15))
        let fm = FileManager.default
        let tweaks = layout.ammoniaTweaks
        let installedDylib = tweaks.appendingPathComponent(dylibName)
        let installed = fm.fileExists(atPath: installedDylib.path) && fm.fileExists(atPath: tweaks.appendingPathComponent(blacklistName).path)
        var current = false
        if installed, let bundled = bundled(in: appBundle) {
            current = (try? Hashing.sha256Hex(ofFile: installedDylib)) == (try? Hashing.sha256Hex(ofFile: bundled.dylib))
        }
        return Status(build: build, sip: sip, bootArgumentSet: bootArgumentSet(nvramOutput: nvram.map { $0.combinedOutput }),
                      ammoniaInstalled: fm.fileExists(atPath: tweaks.path), installed: installed, current: current)
    }

    public static func installOperations(layout: SystemLayout, appBundle: URL) -> [PrivilegedOperation]? {
        guard let bundled = bundled(in: appBundle) else { return nil }
        let tweaks = layout.ammoniaTweaks
        return [.installFile(source: bundled.blacklist, destination: tweaks.appendingPathComponent(blacklistName)),
                .installFile(source: bundled.dylib, destination: tweaks.appendingPathComponent(dylibName))]
    }

    /// The plugin first, so a half-finished removal never leaves a plugin without its blacklist.
    public static func removeOperations(layout: SystemLayout) -> [PrivilegedOperation] {
        [.removePluginFile(layout.ammoniaTweaks.appendingPathComponent(dylibName)),
         .removePluginFile(layout.ammoniaTweaks.appendingPathComponent(blacklistName))]
    }
}
