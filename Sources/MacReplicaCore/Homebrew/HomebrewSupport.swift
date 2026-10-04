import Foundation

/// How well Homebrew supports a macOS version on a processor, from Homebrew's support tiers
/// (https://docs.brew.sh/Support-Tiers, checked on `checkedOn`). Homebrew has one release for every macOS;
/// on Tier 3 systems it installs and usually works, but fewer prebuilt packages exist, so some formulae are
/// built from source (slower, sometimes failing).
public enum HomebrewSupport {
    public enum Level: String, Sendable, Equatable {
        /// Tier 1.
        case full
        /// Tier 3: works, no guarantees.
        case limited
        /// Homebrew no longer runs there.
        case unsupported
    }

    public static let checkedOn = "2026-10-04"
    public static let source = "https://docs.brew.sh/Support-Tiers"
    /// Apple silicon: the three newest macOS versions are Tier 1.
    static let oldestFullySupportedMajor = 15
    /// Homebrew's projection for Intel Macs.
    public static let intelEndExpected = "September 2027"

    public static func level(macOSVersion: String, architecture: CPUArchitecture) -> Level {
        guard let major = Int(macOSVersion.split(separator: ".").first ?? "") else { return .full }
        if major <= 10 { return .unsupported }
        if architecture == .x86_64 { return .limited }
        return major >= oldestFullySupportedMajor ? .full : .limited
    }
}

extension Localizer {
    /// The notice for a system Homebrew does not fully support, or nil. `beforeErasing`: shown on the old Mac,
    /// which the user may erase and set up again with the same macOS.
    public func homebrewSupportNotice(macOSVersion: String, architecture: CPUArchitecture, beforeErasing: Bool) -> (title: String, message: String)? {
        let level = HomebrewSupport.level(macOSVersion: macOSVersion, architecture: architecture)
        let system = t("homebrewSupport.system", macOSVersion, architectureText(architecture))
        switch level {
        case .full:
            return nil
        case .limited:
            var message = t(beforeErasing ? "homebrewSupport.limited.before" : "homebrewSupport.limited.here")
            if architecture == .x86_64 { message += " " + t("homebrewSupport.intelEnd", HomebrewSupport.intelEndExpected) }
            message += " " + t("homebrewSupport.asOf", day(Self.supportCheckedDate), HomebrewSupport.source)
            return (t("homebrewSupport.limited.title", system), message)
        case .unsupported:
            return (t("homebrewSupport.unsupported.title", system),
                    t("homebrewSupport.unsupported.message") + " " + t("homebrewSupport.asOf", day(Self.supportCheckedDate), HomebrewSupport.source))
        }
    }

    /// A date without the time of day, in the app's language.
    func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static var supportCheckedDate: Date {
        ISO8601DateFormatter().date(from: HomebrewSupport.checkedOn + "T12:00:00Z") ?? Date(timeIntervalSince1970: 0)
    }
}
