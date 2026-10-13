import Foundation

/// Tool B: macOS update preferences – stay on this macOS version and keep getting its updates.
///
/// Researched 2026-10-13 (docs/TOOLS.md):
/// - The Automatic Updates switches live in `/Library/Preferences/com.apple.SoftwareUpdate.plist`, readable by
///   everyone, writable only by root. A missing key does not always mean “on”: a missing
///   `AutomaticallyInstallMacOSUpdates` is shown as off, missing check/security keys as on (checked on macOS 27).
/// - Automatic installation covers updates of the installed macOS version; a new major version is installed only
///   after the user clicks “Upgrade” (Apple: “Update macOS on Mac”, support.apple.com/108382).
/// - Deferring a major upgrade: the `com.apple.SoftwareUpdate` payload and the deferral restrictions were deprecated
///   in macOS 26 and removed in 27; their replacement needs a supervised MDM enrolment. On 15.7.5 and later the
///   deferral also delays security updates; it never lasts longer than 90 days. MacReplica therefore does not
///   install deferral profiles.
/// - There is no supported way to hide the upgrade badge or banner.
/// MacReplica never writes these settings itself: the user changes them in System Settings (which asks for the
/// administrator password) and MacReplica reads them back.
public struct UpdateSettings: Sendable, Equatable, Codable {
    public var checkAutomatically: Bool
    public var downloadAutomatically: Bool
    public var installMacOSUpdates: Bool
    /// “Install system data files and security updates” (`CriticalUpdateInstall` and `ConfigDataInstall`).
    public var installSecurityUpdates: Bool
    /// App Store: automatic app updates (`com.apple.commerce AutoUpdate`), nil if not set.
    public var appStoreAutoUpdate: Bool?

    public init(checkAutomatically: Bool, downloadAutomatically: Bool, installMacOSUpdates: Bool, installSecurityUpdates: Bool,
                appStoreAutoUpdate: Bool? = nil) {
        self.checkAutomatically = checkAutomatically
        self.downloadAutomatically = downloadAutomatically
        self.installMacOSUpdates = installMacOSUpdates
        self.installSecurityUpdates = installSecurityUpdates
        self.appStoreAutoUpdate = appStoreAutoUpdate
    }

    /// Reads the plist with the defaults macOS shows for missing keys.
    public init(softwareUpdate plist: [String: Any], commerce: [String: Any]?) {
        func bool(_ key: String) -> Bool? {
            if let value = plist[key] as? Bool { return value }
            if let value = plist[key] as? Int { return value != 0 }
            return nil
        }
        checkAutomatically = bool("AutomaticCheckEnabled") ?? true
        downloadAutomatically = bool("AutomaticDownload") ?? true
        installMacOSUpdates = bool("AutomaticallyInstallMacOSUpdates") ?? false
        // The switch covers both keys; it is on only if neither is off.
        installSecurityUpdates = (bool("CriticalUpdateInstall") ?? true) && (bool("ConfigDataInstall") ?? true)
        appStoreAutoUpdate = (commerce?["AutoUpdate"] as? Bool) ?? (commerce?["AutoUpdate"] as? Int).map { $0 != 0 }
    }

    /// “Stay on this version and stay secure”: download and install updates of the installed version, and the
    /// security files. Upgrades to a new major version still need the user's click.
    public static let recommended = UpdateSettings(checkAutomatically: true, downloadAutomatically: true, installMacOSUpdates: true,
                                                   installSecurityUpdates: true)

    public enum Item: String, Sendable, CaseIterable { case check, download, installMacOS, installSecurity }

    public func value(_ item: Item) -> Bool {
        switch item {
        case .check: return checkAutomatically
        case .download: return downloadAutomatically
        case .installMacOS: return installMacOSUpdates
        case .installSecurity: return installSecurityUpdates
        }
    }

    /// The switches that differ from `target` (App Store is not part of the comparison).
    public func differences(to target: UpdateSettings) -> [Item] {
        Item.allCases.filter { value($0) != target.value($0) }
    }

    /// Security updates off is always worth a warning, whatever the user asked for.
    public var securityUpdatesOff: Bool { !installSecurityUpdates || !checkAutomatically }

    /// Compact form for the history (`check=1;download=1;installMacOS=0;installSecurity=1`).
    public var historyText: String {
        Item.allCases.map { "\($0.rawValue)=\(value($0) ? 1 : 0)" }.joined(separator: ";")
    }

    public init?(historyText: String) {
        var values: [String: Bool] = [:]
        for part in historyText.split(separator: ";") {
            let pair = part.split(separator: "=")
            guard pair.count == 2 else { return nil }
            values[String(pair[0])] = pair[1] == "1"
        }
        guard let check = values["check"], let download = values["download"], let mac = values["installMacOS"],
              let security = values["installSecurity"] else { return nil }
        self.init(checkAutomatically: check, downloadAutomatically: download, installMacOSUpdates: mac, installSecurityUpdates: security)
    }
}

/// Whether the installed macOS version still gets security updates, from Apple's own list of full installers
/// (`softwareupdate --list-full-installers`, no administrator rights; it asks Apple's servers).
public struct MacOSSupportStatus: Sendable, Equatable {
    public enum Support: String, Sendable { case current, securityUpdates, likelyEnded, unknown }

    public var installedVersion: String
    /// The newest version Apple offers for the installed major version.
    public var latestForThisMajor: String?
    /// The newest major version Apple offers this Mac.
    public var newestMajor: Int?
    public var support: Support

    /// Apple usually fixes security issues in the current major version and the two before it, the older ones only
    /// partly (Apple Platform Deployment, “Software updates”); Apple publishes no end date. So “likely ended” is
    /// derived from the versions Apple still offers, and stated as such.
    public var updateAvailable: Bool {
        guard let latest = latestForThisMajor else { return false }
        return VersionComparison.compare(installedVersion, latest) == .orderedAscending
    }

    public static func evaluate(installedVersion: String, installers: [String]) -> MacOSSupportStatus {
        let installedMajor = Int(installedVersion.split(separator: ".").first ?? "") ?? 0
        let byMajor = Dictionary(grouping: installers) { Int($0.split(separator: ".").first ?? "") ?? 0 }.filter { $0.key > 0 }
        let majors = byMajor.keys.sorted(by: >)
        guard let newest = majors.first, installedMajor > 0 else {
            return MacOSSupportStatus(installedVersion: installedVersion, latestForThisMajor: nil, newestMajor: nil, support: .unknown)
        }
        let latest = byMajor[installedMajor]?.max { VersionComparison.compare($0, $1) == .orderedAscending }
        let support: Support
        if installedMajor >= newest { support = .current }
        else if let index = majors.firstIndex(of: installedMajor), index <= 2 { support = .securityUpdates }
        else if installedMajor < newest, majors.prefix(3).allSatisfy({ $0 > installedMajor }) { support = .likelyEnded }
        else { support = .unknown }
        return MacOSSupportStatus(installedVersion: installedVersion, latestForThisMajor: latest, newestMajor: newest, support: support)
    }

    /// Versions from `softwareupdate --list-full-installers`
    /// (`* Title: macOS Tahoe, Version: 26.7.1, Size: …, Build: …, Deferred: NO`).
    public static func parseInstallers(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "Version: ") else { return nil }
            let rest = line[range.upperBound...]
            let version = rest.prefix { $0 != "," && $0 != " " }
            return version.isEmpty ? nil : String(version)
        }
    }
}

public struct UpdatePreferencesStatus: Sendable, Equatable {
    public var settings: UpdateSettings?
    /// A configuration profile or MDM sets Software Update (`/Library/Managed Preferences/com.apple.SoftwareUpdate.plist`).
    public var managed: Bool

    public var capability: ToolCapability {
        if managed { return .managedExternally }
        return settings == nil ? .unableToDetermine : .requiresUserAction
    }
}

/// What macOS lets a personal Mac do about major upgrades, per version.
public enum MajorUpgradeDeferral: String, Sendable {
    /// macOS 27 and later: only device management (supervised) can defer.
    case onlyDeviceManagement
    /// macOS 13–26: a hand-installed profile can delay a major upgrade by up to 90 days per release; deprecated in 26,
    /// and from 15.7.5 it also delays security updates. MacReplica does not offer it.
    case deprecatedProfileOnly

    public static func forVersion(_ environment: ToolEnvironment) -> MajorUpgradeDeferral {
        environment.majorVersion >= 27 ? .onlyDeviceManagement : .deprecatedProfileOnly
    }

    /// The 15.7.5+ / 26 change: one deferral for all updates, security included.
    public static func delaysSecurityUpdates(_ environment: ToolEnvironment) -> Bool {
        environment.majorVersion >= 26 || environment.isAtLeast("15.7.5")
    }
}

public struct UpdatePreferencesInspector: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    /// `/Library/Preferences` (a stand-in folder in a simulation).
    public var preferencesFolder: URL

    public init(layout: SystemLayout, runner: CommandRunning, preferencesFolder: URL? = nil) {
        self.layout = layout
        self.runner = runner
        self.preferencesFolder = preferencesFolder ?? layout.sharedLibrary.appendingPathComponent("Preferences")
    }

    public func status() -> UpdatePreferencesStatus {
        let managedFile = layout.managedPreferences.appendingPathComponent("com.apple.SoftwareUpdate.plist")
        let managed = GatekeeperInspector.readPlist(managedFile).map { !Set($0.keys).subtracting(["PayloadUUID", "_manualProfile"]).isEmpty } ?? false
        let plistURL = preferencesFolder.appendingPathComponent("com.apple.SoftwareUpdate.plist")
        let commerce = GatekeeperInspector.readPlist(preferencesFolder.appendingPathComponent("com.apple.commerce.plist"))
        // A missing file is a Mac that never changed a switch: all defaults.
        let settings: UpdateSettings?
        if let plist = GatekeeperInspector.readPlist(plistURL) {
            settings = UpdateSettings(softwareUpdate: plist, commerce: commerce)
        } else if !FileManager.default.fileExists(atPath: plistURL.path) {
            settings = UpdateSettings(softwareUpdate: [:], commerce: commerce)
        } else {
            settings = nil
        }
        return UpdatePreferencesStatus(settings: settings, managed: managed)
    }

    public func supportStatus(installedVersion: String) async -> MacOSSupportStatus {
        let result = try? await runner.run(Command(executable: layout.softwareupdate, arguments: ["--list-full-installers"],
                                                   environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: 120))
        let versions = result.map { MacOSSupportStatus.parseInstallers($0.stdout) } ?? []
        return MacOSSupportStatus.evaluate(installedVersion: installedVersion, installers: versions)
    }
}

public enum UpdateSettingsLinks {
    public static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    /// Apple: “Update macOS on Mac” (update vs. upgrade).
    public static let appleUpdateMacOS = "https://support.apple.com/en-us/108382"
    /// Apple: Background Security Improvements (macOS 26.1 and later).
    public static let appleBackgroundSecurity = "https://support.apple.com/en-us/102657"
    /// Apple security releases.
    public static let appleSecurityReleases = "https://support.apple.com/en-us/100100"
}
