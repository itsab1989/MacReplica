import Foundation

/// Every location MacReplica reads from or writes to.
///
/// The live layout points at the real system. Tests and the simulation
/// environment use a layout rooted in a sandbox folder, which keeps
/// destructive tests away from real user data.
public struct SystemLayout: Sendable, Equatable {
    public var homeDirectory: URL
    public var applicationFolders: [URL]
    public var userFonts: URL
    public var systemFonts: URL
    public var userColorProfiles: URL
    public var systemColorProfiles: URL
    /// Fonts and profiles that come with macOS (read-only, protected by System Integrity Protection).
    /// MacReplica only reads them to recognize what the destination Mac already provides.
    public var macOSFonts: URL
    public var macOSColorProfiles: URL
    /// Downloadable fonts that macOS manages itself (`com_apple_MobileAsset_Font*` below this folder).
    public var macOSFontAssets: URL
    /// Homebrew prefixes in order of preference for this Mac, e.g. `/opt/homebrew`.
    public var homebrewPrefixes: [URL]
    public var xcodeSelect: String
    public var pkgutil: String
    public var mdls: String
    public var osascript: String
    public var installer: String
    /// Disk image and archive tools used to unpack verified downloads (read-only mounts, no installation).
    public var hdiutil: String = "/usr/bin/hdiutil"
    public var ditto: String = "/usr/bin/ditto"
    /// Files that only exist when the Command Line Tools are fully installed.
    public var commandLineToolsMarkers: [String]
    public var rosettaMarker: String
    public var applicationSupport: URL
    public var caches: URL
    public var logs: URL
    /// Where python.org installers put `Python.framework`.
    public var pythonFrameworks: URL
    public var isSimulation: Bool
    /// In the simulation, the sandbox folder that stands in for `/`. Paths below it are
    /// displayed as on a real Mac, so reports and screenshots never show the sandbox location.
    public var simulationRoot: URL?

    public init(
        homeDirectory: URL,
        applicationFolders: [URL],
        userFonts: URL,
        systemFonts: URL,
        userColorProfiles: URL,
        systemColorProfiles: URL,
        homebrewPrefixes: [URL],
        xcodeSelect: String,
        pkgutil: String,
        mdls: String,
        osascript: String,
        installer: String,
        commandLineToolsMarkers: [String],
        rosettaMarker: String,
        applicationSupport: URL,
        caches: URL,
        logs: URL,
        pythonFrameworks: URL = URL(fileURLWithPath: "/Library/Frameworks"),
        macOSFonts: URL = URL(fileURLWithPath: "/System/Library/Fonts"),
        macOSColorProfiles: URL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
        macOSFontAssets: URL = URL(fileURLWithPath: "/System/Library/AssetsV2"),
        isSimulation: Bool
    ) {
        self.macOSFontAssets = macOSFontAssets
        self.macOSFonts = macOSFonts
        self.macOSColorProfiles = macOSColorProfiles
        self.homeDirectory = homeDirectory
        self.applicationFolders = applicationFolders
        self.userFonts = userFonts
        self.systemFonts = systemFonts
        self.userColorProfiles = userColorProfiles
        self.systemColorProfiles = systemColorProfiles
        self.homebrewPrefixes = homebrewPrefixes
        self.xcodeSelect = xcodeSelect
        self.pkgutil = pkgutil
        self.mdls = mdls
        self.osascript = osascript
        self.installer = installer
        self.commandLineToolsMarkers = commandLineToolsMarkers
        self.rosettaMarker = rosettaMarker
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.logs = logs
        self.pythonFrameworks = pythonFrameworks
        self.isSimulation = isSimulation
    }

    /// The layout of the Mac MacReplica is running on.
    public static func live(architecture: CPUArchitecture = SystemInfo.currentArchitecture) -> SystemLayout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let appleSilicon = URL(fileURLWithPath: "/opt/homebrew")
        let intel = URL(fileURLWithPath: "/usr/local")
        return SystemLayout(
            homeDirectory: home,
            applicationFolders: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            userFonts: library.appendingPathComponent("Fonts"),
            systemFonts: URL(fileURLWithPath: "/Library/Fonts"),
            userColorProfiles: library.appendingPathComponent("ColorSync/Profiles"),
            systemColorProfiles: URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
            homebrewPrefixes: architecture == .x86_64 ? [intel] : [appleSilicon, intel],
            xcodeSelect: "/usr/bin/xcode-select",
            pkgutil: "/usr/sbin/pkgutil",
            mdls: "/usr/bin/mdls",
            osascript: "/usr/bin/osascript",
            installer: "/usr/sbin/installer",
            commandLineToolsMarkers: [
                "/Library/Developer/CommandLineTools/usr/bin/git",
                "/Library/Developer/CommandLineTools/usr/bin/clang",
            ],
            rosettaMarker: "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
            applicationSupport: library.appendingPathComponent("Application Support/MacReplica"),
            caches: library.appendingPathComponent("Caches/MacReplica"),
            logs: library.appendingPathComponent("Logs/MacReplica"),
            isSimulation: false
        )
    }

    /// Where a fresh Homebrew installation ends up on this Mac.
    public var preferredHomebrewPrefix: URL { homebrewPrefixes[0] }

    public func brewExecutable(in prefix: URL) -> String {
        prefix.appendingPathComponent("bin/brew").path
    }

    public var brewCandidates: [String] { homebrewPrefixes.map { brewExecutable(in: $0) } }
    public var masCandidates: [String] { homebrewPrefixes.map { $0.appendingPathComponent("bin/mas").path } }

    /// Homebrew's Python interpreters, e.g. `/opt/homebrew/opt/python@3.12/bin/python3.12`.
    public func homebrewPython(minor: String, prefix: URL) -> String {
        prefix.appendingPathComponent("opt/python@\(minor)/bin/python\(minor)").path
    }

    /// The only executables the command runner may start. Python interpreters are
    /// listed one by one (no patterns), and only Homebrew's own.
    public var allowedExecutables: Set<String> {
        let pythons = homebrewPrefixes.flatMap { prefix in PythonVersion.supportedMinors.map { homebrewPython(minor: $0, prefix: prefix) } }
        return Set(brewCandidates + masCandidates + pythons + [xcodeSelect, pkgutil, mdls, osascript, installer, hdiutil, ditto])
    }

    public func baseFolder(for kind: BackupFileKind, domain: FileDomain) -> URL {
        switch (kind, domain) {
        case (.font, .user): return userFonts
        case (.font, .system): return systemFonts
        case (.colorProfile, .user): return userColorProfiles
        case (.colorProfile, .system): return systemColorProfiles
        }
    }

    /// Replaces the home directory with `~` so that manifests, logs and reports
    /// never contain the user's account name.
    /// `/Library`, the folder shared by all users (in a simulation or test sandbox, its stand-in next to the shared fonts).
    public var sharedLibrary: URL { systemFonts.deletingLastPathComponent() }

    /// The folder application data paths of a scope are relative to.
    public func root(of scope: AppDataScope) -> URL { scope == .home ? homeDirectory : sharedLibrary }

    public func displayPath(_ url: URL) -> String {
        let redacted = Self.redactHome(url.standardizedFileURL.path, home: homeDirectory.standardizedFileURL.path)
        guard let root = simulationRoot?.standardizedFileURL.path, redacted.hasPrefix(root + "/") else { return redacted }
        return String(redacted.dropFirst(root.count))
    }

    public static func redactHome(_ path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return path }
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }

    /// Redacts every occurrence of the home directory inside free text, e.g. tool output.
    public func redact(_ text: String) -> String {
        let home = homeDirectory.standardizedFileURL.path
        guard home.count > 1 else { return text }
        var result = text.replacingOccurrences(of: home, with: "~")
        if let root = simulationRoot?.standardizedFileURL.path { result = result.replacingOccurrences(of: root + "/", with: "/") }
        return result
    }

    /// Resolves a display path (with `~`) back to a file URL on this Mac.
    public func resolve(displayPath: String) -> URL {
        if displayPath == "~" { return homeDirectory }
        if displayPath.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(displayPath.dropFirst(2)))
        }
        if let root = simulationRoot, !FileManager.default.fileExists(atPath: displayPath) {
            return root.appendingPathComponent(String(displayPath.drop { $0 == "/" }))
        }
        return URL(fileURLWithPath: displayPath)
    }

    /// Child process environment. `PATH` is set explicitly instead of trusting the
    /// environment MacReplica was launched with, which for apps started from the
    /// Finder does not contain Homebrew.
    public func processEnvironment(homebrewPrefix: URL?, askpass: String?) -> [String: String] {
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let homebrewPrefix {
            path.insert(contentsOf: [homebrewPrefix.appendingPathComponent("bin").path,
                                     homebrewPrefix.appendingPathComponent("sbin").path], at: 0)
        }
        var environment: [String: String] = [
            "PATH": path.joined(separator: ":"),
            "HOME": homeDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "NONINTERACTIVE": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["USER", "LOGNAME", "TMPDIR", "SHELL"] {
            if let value = inherited[key] { environment[key] = value }
        }
        if let askpass { environment["SUDO_ASKPASS"] = askpass }
        return environment
    }
}

public enum BackupFileKind: String, Codable, Sendable, CaseIterable {
    case font
    case colorProfile
}
