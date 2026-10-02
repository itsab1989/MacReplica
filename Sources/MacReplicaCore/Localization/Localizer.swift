import Foundation

/// Languages MacReplica ships complete translations for.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case german = "de"
    case norwegianBokmal = "nb"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case dutch = "nl"

    public var id: String { rawValue }

    /// The language's name in that language, as shown in the language picker.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .norwegianBokmal: return "Norsk bokmål"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    /// The CLDR plural category for `count` in this language (only the cases MacReplica needs).
    public func pluralCategory(_ count: Int) -> String {
        switch self {
        case .french:
            return (count == 0 || count == 1) ? "one" : "other"
        default:
            return count == 1 ? "one" : "other"
        }
    }
}

/// Looks up translated text. Strings live in `<language>.lproj/Localizable.strings`,
/// separate from the code. A missing translation falls back to English, and a key
/// missing even in English is replaced by a neutral text, so users never see raw keys.
public final class Localizer: Sendable {
    public let language: AppLanguage
    private let table: [String: String]
    private let fallback: [String: String]

    public init(language: AppLanguage, table: [String: String], fallback: [String: String]) {
        self.language = language
        self.table = table
        self.fallback = fallback
    }

    /// Loads the tables for `language` from the folder that contains the `.lproj` directories.
    public convenience init(language: AppLanguage, resourcesFolder: URL) {
        let english = Self.loadTable(language: .english, resourcesFolder: resourcesFolder)
        let table = language == .english ? english : Self.loadTable(language: language, resourcesFolder: resourcesFolder)
        self.init(language: language, table: table, fallback: english)
    }

    /// Loads using the bundled resources (app bundle first, then the package resource bundle).
    public convenience init(language: AppLanguage) {
        self.init(language: language, resourcesFolder: LocalizationResources.folder)
    }

    public static func loadTable(language: AppLanguage, resourcesFolder: URL) -> [String: String] {
        let url = resourcesFolder.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return parseStrings(data)
    }

    /// Parses the `.strings` format (old-style property list) with Foundation.
    public static func parseStrings(_ data: Data) -> [String: String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            return [:]
        }
        return plist
    }

    public func hasTranslation(_ key: String) -> Bool { table[key] != nil }

    /// The translated string for `key`.
    public func t(_ key: String) -> String {
        if let value = table[key], !value.isEmpty { return value }
        if let value = fallback[key], !value.isEmpty { return value }
        return Self.missingText
    }

    /// The translated format string for `key`, filled with `arguments`.
    /// Use positional placeholders (`%1$@`, `%2$d`) so translations can reorder them.
    public func t(_ key: String, _ arguments: CVarArg...) -> String {
        format(t(key), arguments)
    }

    /// Picks `key.one` or `key.other` for `count`. The count is always the first argument.
    public func p(_ key: String, _ count: Int, _ arguments: CVarArg...) -> String {
        let category = language.pluralCategory(count)
        let specific = "\(key).\(category)"
        let template: String
        if let value = table[specific], !value.isEmpty {
            template = value
        } else if let value = fallback["\(key).\(AppLanguage.english.pluralCategory(count))"], !value.isEmpty {
            template = value
        } else {
            template = t("\(key).other")
        }
        return format(template, [count] + arguments)
    }

    private func format(_ template: String, _ arguments: [CVarArg]) -> String {
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }

    /// Shown instead of a raw key if a string is missing everywhere. Tests ensure this never happens.
    static let missingText = "…"

    // MARK: - Formatting helpers

    public func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(max(fraction, 0), 1))) ?? "\(Int(fraction * 100)) %"
    }

    public func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A file size in the selected language, e.g. "1,5 MB" in German or "1,5 Mo" in French.
    public func fileSize(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        let value = Double(bytes)
        let (amount, key): (Double, String) = switch value {
        case ..<1_000: (value, "size.bytes")
        case ..<1_000_000: (value / 1_000, "size.kb")
        case ..<1_000_000_000: (value / 1_000_000, "size.mb")
        default: (value / 1_000_000_000, "size.gb")
        }
        return t(key, formatter.string(from: NSNumber(value: amount)) ?? String(amount))
    }

    /// A short remaining-time text such as "about 3 minutes".
    public func remainingTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return t("time.lessThanMinute") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return p("time.minutes", minutes) }
        let hours = Int((seconds / 3600).rounded(.down))
        let rest = minutes - hours * 60
        return rest == 0 ? p("time.hours", hours) : t("time.hoursMinutes", hours, rest)
    }
}

public enum LocalizationResources {
    /// The folder containing the `.lproj` directories.
    /// In the app bundle this is `Contents/Resources`; during development the package resource bundle.
    public static var folder: URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("en.lproj/Localizable.strings").path) {
            return resources
        }
        return Bundle.module.resourceURL!.appendingPathComponent("Localization")
    }
}
