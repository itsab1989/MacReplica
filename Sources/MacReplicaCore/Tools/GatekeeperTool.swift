import Foundation

/// Tool A: Gatekeeper and application security.
///
/// Everything here reads; nothing turns Gatekeeper off. Researched on macOS 13–27 (docs/TOOLS.md):
/// - `spctl --status` prints `assessments enabled` / `assessments disabled` without administrator rights.
/// - Since macOS 15, `spctl --global-disable` no longer turns Gatekeeper off; it only shows “Anywhere” in
///   Privacy & Security, where the user has to choose it (Apple Developer News, 2024-08-06; `man spctl`).
/// - A configuration profile with the `com.apple.systempolicy.control` payload (`EnableAssessment = false`) still
///   turns assessments off on macOS 27 (checked on a Mac with such a profile); its values are world-readable in
///   `/Library/Managed Preferences/com.apple.systempolicy.control.plist` (`_manualProfile` when installed by hand).
/// - Per app, Apple's supported route is “Open Anyway” in Privacy & Security after a first launch attempt
///   (support.apple.com/102445). MacReplica opens the app and the pane; the user decides there.
public struct GatekeeperStatus: Sendable, Equatable {
    public enum Assessments: String, Sendable, Codable { case enabled, disabled, unknown }
    public enum ProfileSource: String, Sendable, Codable { case none, manual, deviceManagement }
    public enum Enrollment: String, Sendable, Codable { case notEnrolled, enrolled, unknown }
    public enum SIP: String, Sendable, Codable { case enabled, disabled, unknown }

    public var assessments: Assessments
    /// A configuration profile sets Gatekeeper (`com.apple.systempolicy.control`), and how it was installed.
    public var profile: ProfileSource
    /// `EnableAssessment` of that profile, if it sets it.
    public var profileEnablesAssessment: Bool?
    /// `AllowIdentifiedDevelopers` of that profile, if it sets it.
    public var profileAllowsIdentifiedDevelopers: Bool?
    /// `DisableOverride` of `com.apple.systempolicy.managed`: the organisation forbids “Open Anyway”.
    public var overrideDisabled: Bool
    public var enrollment: Enrollment
    public var sip: SIP

    public init(assessments: Assessments, profile: ProfileSource = .none, profileEnablesAssessment: Bool? = nil,
                profileAllowsIdentifiedDevelopers: Bool? = nil, overrideDisabled: Bool = false,
                enrollment: Enrollment = .unknown, sip: SIP = .unknown) {
        self.assessments = assessments
        self.profile = profile
        self.profileEnablesAssessment = profileEnablesAssessment
        self.profileAllowsIdentifiedDevelopers = profileAllowsIdentifiedDevelopers
        self.overrideDisabled = overrideDisabled
        self.enrollment = enrollment
        self.sip = sip
    }

    /// What the dashboard says overall.
    public enum Summary: String, Sendable { case normal, disabledByProfile, disabledByUser, managed, unknown }

    public var summary: Summary {
        if profile == .deviceManagement || enrollment == .enrolled && profile != .none { return .managed }
        switch assessments {
        case .enabled: return .normal
        case .disabled: return profile == .manual ? .disabledByProfile : .disabledByUser
        case .unknown: return .unknown
        }
    }

    /// Who can turn Gatekeeper back on, and where.
    public var capability: ToolCapability {
        switch summary {
        case .normal: return .supported
        case .disabledByProfile, .disabledByUser: return .requiresUserAction
        case .managed: return .managedExternally
        case .unknown: return .unableToDetermine
        }
    }

    /// A short machine-readable form for the history.
    public var historyText: String { "assessments=\(assessments.rawValue);profile=\(profile.rawValue)" }
}

/// One app as Gatekeeper sees it.
public struct AppSecurityReport: Sendable, Equatable {
    public enum Signature: String, Sendable { case valid, adHoc, unsigned, invalid, unknown }
    public enum Verdict: String, Sendable {
        case accepted
        case rejected
        /// `accepted` only because assessments are off: says nothing about the app.
        case notAssessedGatekeeperOff
        case unknown
    }

    public var appName: String
    public var path: String
    /// `com.apple.quarantine` is set (downloaded, not opened yet or opened after approval).
    public var quarantined: Bool
    /// Which program downloaded it, from the quarantine attribute (e.g. `Safari`, `Homebrew Cask`).
    public var quarantineAgent: String?
    public var signature: Signature
    /// `Developer ID Application: Name (TEAMID)`, `Apple Mac OS Application Signing`, …
    public var signer: String?
    public var notarized: Bool?
    public var verdict: Verdict
    /// `source=` of `spctl --assess` (e.g. `Notarized Developer ID`, `Apple System`, `no usable signature`).
    public var assessmentSource: String?
    /// The user approved it before (`override=` other than “security disabled”).
    public var approvedByUser: Bool
    /// Problems from `syspolicy_check distribution` (macOS 14 and later), e.g. “Notary Ticket Missing”.
    public var policyFindings: [String]

    /// What MacReplica suggests for this app.
    public enum Advice: String, Sendable {
        /// Gatekeeper lets it open.
        case opensNormally
        /// Gatekeeper will ask once (downloaded app); opening it is enough.
        case firstOpenAsks
        /// Gatekeeper blocks it; only “Open Anyway” in Privacy & Security opens it.
        case needsOpenAnyway
        /// The signature is broken: the app was changed after signing. Do not open it; download it again.
        case damaged
        /// Gatekeeper is off, so it opens, but nothing was checked.
        case notChecked
    }

    public var advice: Advice {
        if signature == .invalid { return .damaged }
        switch verdict {
        case .notAssessedGatekeeperOff: return .notChecked
        case .accepted: return quarantined && !approvedByUser ? .firstOpenAsks : .opensNormally
        case .rejected: return approvedByUser ? .opensNormally : .needsOpenAnyway
        case .unknown: return signature == .valid && notarized == true ? .opensNormally : .needsOpenAnyway
        }
    }
}

public struct GatekeeperInspector: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var environment: ToolEnvironment

    public init(layout: SystemLayout, runner: CommandRunning, environment: ToolEnvironment = .current) {
        self.layout = layout
        self.runner = runner
        self.environment = environment
    }

    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async -> CommandResult? {
        try? await runner.run(Command(executable: executable, arguments: arguments,
                                      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: timeout))
    }

    public func status() async -> GatekeeperStatus {
        let spctl = await run(layout.spctl, ["--status"])
        let csr = await run(layout.csrutil, ["status"])
        let enrollment = await run(layout.profiles, ["status", "-type", "enrollment"])
        let control = Self.readPlist(layout.managedPreferences.appendingPathComponent("com.apple.systempolicy.control.plist"))
        let managed = Self.readPlist(layout.managedPreferences.appendingPathComponent("com.apple.systempolicy.managed.plist"))
        return Self.interpret(spctl: spctl?.combinedOutput, csrutil: csr?.combinedOutput, enrollment: enrollment?.combinedOutput,
                              controlProfile: control, managedProfile: managed)
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Reads the text, not the exit code: `spctl --status` exits 1 when assessments are disabled, and
    /// `profiles` exits 0 even when it refuses.
    public static func interpret(spctl: String?, csrutil: String?, enrollment: String?,
                                 controlProfile: [String: Any]?, managedProfile: [String: Any]?) -> GatekeeperStatus {
        let assessments: GatekeeperStatus.Assessments
        let text = spctl?.lowercased() ?? ""
        if text.contains("assessments enabled") { assessments = .enabled }
        else if text.contains("assessments disabled") { assessments = .disabled }
        else { assessments = .unknown }

        var profile = GatekeeperStatus.ProfileSource.none
        var enables: Bool?
        var identified: Bool?
        if let control = controlProfile {
            let keys = Set(control.keys).subtracting(["PayloadUUID", "_manualProfile"])
            if !keys.isEmpty {
                profile = (control["_manualProfile"] as? Bool) == true ? .manual : .deviceManagement
                enables = control["EnableAssessment"] as? Bool
                identified = control["AllowIdentifiedDevelopers"] as? Bool
            }
        }
        let overrideDisabled = (managedProfile?["DisableOverride"] as? Bool) == true
        if overrideDisabled, profile == .none {
            profile = (managedProfile?["_manualProfile"] as? Bool) == true ? .manual : .deviceManagement
        }

        var state = GatekeeperStatus.Enrollment.unknown
        if let enrollment, enrollment.contains("MDM enrollment:") {
            let line = enrollment.split(separator: "\n").first { $0.contains("MDM enrollment:") } ?? ""
            state = line.contains("Yes") ? .enrolled : .notEnrolled
        }

        let sip: GatekeeperStatus.SIP
        let csr = csrutil?.lowercased() ?? ""
        // `status: enabled.` or, with a custom configuration, `status: unknown (Custom Configuration).`
        if csr.contains("status: enabled") { sip = .enabled }
        else if csr.contains("status: disabled") { sip = .disabled }
        else { sip = .unknown }

        return GatekeeperStatus(assessments: assessments, profile: profile, profileEnablesAssessment: enables,
                                profileAllowsIdentifiedDevelopers: identified, overrideDisabled: overrideDisabled,
                                enrollment: state, sip: sip)
    }

    /// Inspects one app the user chose. Reads only; `spctl` and `codesign -R=notarized` may ask Apple online.
    public func inspect(app: URL) async -> AppSecurityReport {
        let path = app.path
        let quarantine = Self.quarantine(of: app)
        let verify = await run(layout.codesign, ["--verify", "--deep", "--strict", path], timeout: 120)
        let details = await run(layout.codesign, ["-dv", "--verbose=2", path])
        let notarized = await run(layout.codesign, ["--verify", "--strict", "-R=notarized", path], timeout: 60)
        let assess = await run(layout.spctl, ["--assess", "--type", "execute", "-vv", path], timeout: 60)
        var findings: [String] = []
        if environment.isAtLeast("14"), let check = await run(layout.syspolicyCheck, ["distribution", path, "--json"], timeout: 120) {
            findings = Self.policyFindings(check.stdout)
        }
        return Self.report(app: app, quarantine: quarantine, verify: verify, details: details?.combinedOutput,
                           notarized: notarized, assess: assess?.combinedOutput, findings: findings)
    }

    static func report(app: URL, quarantine: String?, verify: CommandResult?, details: String?, notarized: CommandResult?,
                       assess: String?, findings: [String]) -> AppSecurityReport {
        let detailText = details ?? ""
        let signature: AppSecurityReport.Signature
        if detailText.contains("Signature=adhoc") { signature = .adHoc }
        else if detailText.contains("code object is not signed at all") { signature = .unsigned }
        else if let verify { signature = verify.succeeded ? .valid : .invalid }
        else { signature = .unknown }
        let signer = detailText.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }

        let assessText = assess ?? ""
        let lines = assessText.split(separator: "\n").map(String.init)
        let source = lines.first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) }
        let override = lines.first { $0.hasPrefix("override=") }.map { String($0.dropFirst("override=".count)) }
        let verdict: AppSecurityReport.Verdict
        if override == "security disabled" { verdict = .notAssessedGatekeeperOff }
        else if assessText.contains(": accepted") { verdict = .accepted }
        else if assessText.contains(": rejected") { verdict = .rejected }
        else { verdict = .unknown }

        let agent = quarantine.flatMap { value -> String? in
            let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            // The agent name is stored with escaped spaces (`Homebrew\x20Cask`).
            return parts.count > 2 && !parts[2].isEmpty ? String(parts[2]).replacingOccurrences(of: "\\x20", with: " ") : nil
        }
        // `syspolicy_check` reports a missing *stapled* ticket as fatal even when Apple's online check confirms the
        // notarisation; that finding is only shown when the app is not notarised.
        let notarizedNow = notarized.map { $0.succeeded }
        let shownFindings = notarizedNow == true ? findings.filter { !$0.hasPrefix("Notary Ticket Missing") } : findings
        let name = app.deletingPathExtension().lastPathComponent
        return AppSecurityReport(appName: name, path: app.path, quarantined: quarantine != nil, quarantineAgent: agent,
                                 signature: signature, signer: signer,
                                 notarized: notarizedNow,
                                 verdict: verdict, assessmentSource: source,
                                 approvedByUser: override != nil && override != "security disabled",
                                 policyFindings: shownFindings)
    }

    /// `syspolicy_check distribution --json` exits 0 even with a fatal finding, so the JSON is read.
    static func policyFindings(_ json: String) -> [String] {
        guard let start = json.firstIndex(of: "{"), let data = String(json[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else { return [] }
        return output.compactMap { item in
            guard let short = item["SyspolicyCheckShortError"] as? String else { return nil }
            let level = item["SyspolicyCheckErrorLevel"] as? String
            return level.map { "\(short) (\($0))" } ?? short
        }
    }

    /// The quarantine attribute (`flags;time;agent;id`), read with getxattr (no command, nothing changed).
    public static func quarantine(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// System Settings addresses the Gatekeeper tool opens. The pane identifiers are Apple's; MacReplica falls back
/// to the plain pane if a deeper address does not open.
public enum SecuritySettingsLinks {
    /// Privacy & Security (macOS 13 and later); “Open Anyway” and “Allow applications from” are on this pane.
    public static let privacySecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    /// Privacy & Security, scrolled to the Security section.
    public static let securitySection = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security"
    /// General › Device Management, where configuration profiles are listed and removed.
    public static let deviceManagement = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
    /// Apple: “Safely open apps on your Mac”.
    public static let appleSafelyOpenApps = "https://support.apple.com/en-us/102445"
}

/// Removing the quarantine mark from one app the user chose – at their explicit request, after a warning. This skips
/// Gatekeeper's first-launch check (including Apple's malware check) for that app only; Gatekeeper stays on for
/// everything else. The exact previous mark is returned so it can be put back. Never used for `/System`, never for an
/// app whose signature is broken, never for more than the one bundle.
public enum QuarantineEditor {
    public static let attribute = "com.apple.quarantine"

    public enum Failure: Error, Equatable {
        case notAnApp
        case systemLocation
        case damaged
        case notQuarantined
        /// The bundle belongs to another user or root; MacReplica does not use administrator rights for this.
        case notWritable(String)
    }

    public static func check(_ app: URL, report: AppSecurityReport?) throws {
        guard app.pathExtension == "app" else { throw Failure.notAnApp }
        let path = app.standardizedFileURL.path
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") { throw Failure.systemLocation }
        if report?.signature == .invalid { throw Failure.damaged }
    }

    /// Removes the mark from the bundle and every item inside that carries it; returns the bundle's previous mark.
    @discardableResult
    public static func remove(from app: URL, report: AppSecurityReport?) throws -> String {
        try check(app, report: report)
        guard let previous = GatekeeperInspector.quarantine(of: app) else { throw Failure.notQuarantined }
        var items = [app]
        if let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil, options: []) {
            for case let url as URL in enumerator { items.append(url) }
        }
        for url in items where getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) > 0 {
            if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 {
                // Undo what was done so far: the bundle keeps its mark if not everything could be changed.
                if url != app { _ = setxattr(app.path, attribute, previous, previous.utf8.count, 0, XATTR_NOFOLLOW) }
                throw Failure.notWritable(String(cString: strerror(errno)))
            }
        }
        return previous
    }

    /// Puts the recorded mark back on the bundle (enough for Gatekeeper to check the app again at its next launch).
    public static func restore(_ value: String, to app: URL) throws {
        try check(app, report: nil)
        guard setxattr(app.path, attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw Failure.notWritable(String(cString: strerror(errno)))
        }
    }
}
