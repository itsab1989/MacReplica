import Foundation
import MachO

/// MacReplica's corner plugin for the Plugin Playground tweak loader (`Extras/CornerPlugin`): menus, popovers,
/// Quick Look, toolbar groups and capsule buttons with the radius chosen in the window-corner tool. Advanced and at
/// the user's own risk.
///
/// Plugin Playground (github.com/CoreBedtime/playground) injects every `.dylib` in `/opt/pluginplayground/tweaks/`
/// into matching GUI processes via `DYLD_INSERT_LIBRARIES`; a tweak needs a sidecar `<name>.dylib.options` plist
/// (which processes to inject into) or it is never loaded. It needs System Integrity Protection only partly off
/// (`csrutil enable --without debug`) and no boot argument when the loader's PAC-stripping mode is on. MacReplica
/// never changes SIP; it detects the state, shows the steps, downloads the pinned loader and installs or removes
/// exactly its own two files with the administrator password. The plugin never loads into non-AppKit or blacklisted
/// processes and does nothing without a chosen radius. On macOS builds other than `testedBuilds` it still loads, but
/// MacReplica warns and asks the user to acknowledge the risk before installing (an untested build's AppKit internals
/// may have changed, so a hook may do nothing or make apps crash; the plugin checks every class and method first).
public enum CornerPlugin {
    public static let dylibName = "MacReplicaCorners.dylib"
    public static let optionsName = "MacReplicaCorners.dylib.options"
    public static let fileNames: Set<String> = [dylibName, optionsName]
    /// The macOS builds MacReplica verified the hooks on. Not a gate any more (the plugin runs elsewhere too, behind a
    /// warning) – it decides whether the "tested" marker is green. Must match `TESTED_BUILDS` in
    /// `Extras/CornerPlugin/MacReplicaCorners.m` (a test compares them).
    public static let testedBuilds: Set<String> = ["26A434"]
    public static let loaderProject = "https://github.com/CoreBedtime/playground"
    public static let appleSIP = "https://support.apple.com/en-us/102149"

    public enum Readiness: String, Sendable, Equatable, CaseIterable {
        /// Plugin Playground's injector only exists for Apple silicon (it uses arm64 debug registers).
        case unsupportedHardware
        /// System Integrity Protection is fully on; the loader needs debugging allowed (`csrutil enable --without debug`).
        case sipFullyOn
        /// The loader (Plugin Playground) is not installed yet.
        case loaderMissing
        /// The loader was removed but its injector still runs until the next restart.
        case removedPendingRestart
        /// The loader is installed, but its background service (launch daemon) is not set up or not started.
        case serviceMissing
        /// The service is loaded, but its injector (`fangs`) is not running – it could not attach; a restart helps.
        case injectorNotRunning
        /// Apple's own apps (arm64e) need the loader's "Disable arm64e (PAC)" setting saved.
        case pacOff
        /// MacReplica's plugin is missing or outdated in the tweaks folder.
        case pluginMissing
        case ready
        case unknown
    }

    /// One step of the automatic setup; each is done only when the status shows it is still missing.
    public enum SetupStep: String, Sendable, Equatable, CaseIterable {
        case installLoader
        case installPlugin
        case savePACSetting
        case installService
        case startService
    }

    public struct Status: Sendable, Equatable {
        public var build: String?
        public var sip: GatekeeperStatus.SIP
        /// Debugging is allowed (partial SIP, `csrutil enable --without debug`, or SIP fully off). nil = could not tell.
        public var debuggingAllowed: Bool?
        /// Plugin Playground's programs are present (`/opt/pluginplayground/bin/grant` and `fangs`).
        public var loaderInstalled: Bool
        /// The loader's launch daemon file `/Library/LaunchDaemons/com.pluginplayground.grant.plist` exists.
        public var serviceInstalled: Bool
        /// launchd has the daemon loaded (`launchctl print system/com.pluginplayground.grant`). nil = could not tell.
        public var serviceLoaded: Bool?
        /// The injector `fangs` runs (`pgrep -x fangs`) – the only proof the loader is really active. nil = could not tell.
        public var injectorRunning: Bool?
        /// Apple silicon: the loader must strip arm64e (PAC) from new processes, or Apple's own apps never get the plugin.
        public var needsPACStripping: Bool
        /// `disablePAC` in the loader's `current.options` (false when the file is missing).
        public var pacStrippingOn: Bool
        /// Both of MacReplica's files are in the tweaks folder.
        public var installed: Bool
        /// The installed plugin is the one in this copy of MacReplica.
        public var current: Bool
        /// The plugin is loaded into this very MacReplica process – end-to-end proof that injection works.
        public var activeHere: Bool
        /// The service's last exit status reported by launchd, for diagnostics.
        public var serviceLastExit: String?

        public init(build: String?, sip: GatekeeperStatus.SIP, debuggingAllowed: Bool?, loaderInstalled: Bool,
                    serviceInstalled: Bool, serviceLoaded: Bool?, injectorRunning: Bool?, needsPACStripping: Bool,
                    pacStrippingOn: Bool, installed: Bool, current: Bool, activeHere: Bool = false, serviceLastExit: String? = nil) {
            self.build = build
            self.sip = sip
            self.debuggingAllowed = debuggingAllowed
            self.loaderInstalled = loaderInstalled
            self.serviceInstalled = serviceInstalled
            self.serviceLoaded = serviceLoaded
            self.injectorRunning = injectorRunning
            self.needsPACStripping = needsPACStripping
            self.pacStrippingOn = pacStrippingOn
            self.installed = installed
            self.current = current
            self.activeHere = activeHere
            self.serviceLastExit = serviceLastExit
        }

        /// Plugin Playground is enabled: its service is set up and its injector is verifiably running.
        public var loaderEnabled: Bool { serviceInstalled && injectorRunning == true }

        /// Whether this macOS build is one MacReplica verified the plugin's hooks on. When false the plugin is still
        /// offered, but behind an extra warning and acknowledgement: on an untested build a hook may do nothing or, in
        /// the worst case, make apps crash (the plugin checks every class and method first, so it skips what changed).
        /// A build MacReplica cannot read at all counts as not verified.
        public var tested: Bool { build.map { CornerPlugin.testedBuilds.contains($0) } ?? false }

        public var readiness: Readiness {
            if !needsPACStripping { return .unsupportedHardware }
            switch debuggingAllowed {
            case .some(false): return .sipFullyOn
            case .none: return .unknown
            case .some(true): break
            }
            if !loaderInstalled { return injectorRunning == true ? .removedPendingRestart : .loaderMissing }
            if !serviceInstalled { return .serviceMissing }
            switch (serviceLoaded, injectorRunning) {
            case (.some(false), _): return .serviceMissing
            case (_, .some(true)): break
            case (.some(true), .some(false)): return .injectorNotRunning
            default: return .unknown
            }
            if needsPACStripping, !pacStrippingOn { return .pacOff }
            if !installed || !current { return .pluginMissing }
            return .ready
        }

        public var capability: ToolCapability {
            switch readiness {
            case .unsupportedHardware: return .unsupportedOnThisVersion
            case .sipFullyOn, .removedPendingRestart, .injectorNotRunning: return .requiresUserAction
            case .loaderMissing, .serviceMissing, .pacOff, .pluginMissing, .ready: return .requiresAdministrator
            case .unknown: return .unableToDetermine
            }
        }

        /// A one-line, path-free summary for the log and the tool history.
        public var diagnostics: String {
            func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "?" }
            return "readiness=\(readiness.rawValue) tested=\(tested ? "1" : "0") debug=\(flag(debuggingAllowed)) loader=\(flag(loaderInstalled)) "
                + "service=\(flag(serviceInstalled)) loaded=\(flag(serviceLoaded)) injector=\(flag(injectorRunning)) "
                + "pac=\(needsPACStripping ? flag(pacStrippingOn) : "n/a") plugin=\(flag(installed && current)) active=\(flag(activeHere))"
                + (serviceLastExit.map { " lastExit=\($0)" } ?? "")
        }

        /// What the automatic setup still has to do, in order. Empty when nothing is missing or the user has to act
        /// first (SIP, restart). Never repeats a step that is already done. An untested build does not stop setup – it
        /// only adds a warning the user has to acknowledge in the UI first.
        public var missingSteps: [SetupStep] {
            switch readiness {
            case .loaderMissing, .serviceMissing, .pacOff, .pluginMissing: break
            default: return []
            }
            var steps: [SetupStep] = []
            if !loaderInstalled { steps.append(.installLoader) }
            if !installed || !current { steps.append(.installPlugin) }
            if needsPACStripping, !pacStrippingOn { steps.append(.savePACSetting) }
            if !serviceInstalled { steps.append(.installService) }
            // A daemon launchd already has loaded (e.g. its file was removed earlier, without a restart) is not loaded twice.
            if serviceLoaded != true { steps.append(.startService) }
            return steps
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

    /// Reads the real state; nothing is changed. `activeHere` is passed in by the app (it checks its own loaded images).
    public static func status(layout: SystemLayout, runner: CommandRunning, sip: GatekeeperStatus.SIP, appBundle: URL,
                              build: String? = currentBuild(), architecture: CPUArchitecture = SystemInfo.currentArchitecture,
                              activeHere: Bool = false) async -> Status {
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let csr = try? await runner.run(Command(executable: layout.csrutil, arguments: ["status"], environment: env, timeout: 15))
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
        // launchctl print: exit 0 = loaded; 113 = no such service. Anything else (or not runnable) = unknown.
        let printed = try? await runner.run(Command(executable: layout.launchctl, arguments: ["print", "system/\(PluginLoader.serviceLabel)"],
                                                    environment: env, timeout: 15))
        let loaded: Bool? = printed.map { $0.exitCode == 0 ? true : ($0.exitCode == 113 ? false : nil) } ?? nil
        let pgrep = try? await runner.run(Command(executable: layout.pgrep, arguments: ["-x", "fangs"], environment: env, timeout: 15))
        let running: Bool? = pgrep.map { $0.exitCode == 0 ? true : ($0.exitCode == 1 ? false : nil) } ?? nil
        let loaderFiles = ["grant", "fangs"].allSatisfy { fm.isExecutableFile(atPath: layout.pluginLoaderBin.appendingPathComponent($0).path) }
        return Status(build: build, sip: sip, debuggingAllowed: debugging, loaderInstalled: loaderFiles,
                      serviceInstalled: fm.fileExists(atPath: layout.pluginLoaderDaemon.path),
                      serviceLoaded: loaded, injectorRunning: running, needsPACStripping: architecture == .arm64,
                      pacStrippingOn: PluginLoader.pacStrippingOn(optionsFile: layout.pluginLoaderOptions),
                      installed: installed, current: current, activeHere: activeHere,
                      serviceLastExit: printed.flatMap { PluginLoader.lastExit(launchctlPrint: $0.stdout) })
    }

    /// Whether a library with the plugin's name is loaded into this process (dyld's image list).
    public static func loadedInThisProcess() -> Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).hasSuffix("/" + dylibName)
        }
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
