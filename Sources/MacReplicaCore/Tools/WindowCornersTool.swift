import Foundation

/// Tool C: window corner radius – experimental.
///
/// Researched 2026-10-13 on macOS 27.0.1 (docs/TOOLS.md): `NSConvolutionOverride1` in the global domain is a private,
/// undocumented AppKit setting. Its value is the corner radius in points of titled AppKit windows (also SwiftUI
/// windows, sheets and alerts); `NSConvolutionOverride2` does the same for utility panels and inspectors. Each app
/// reads them when it starts, so apps must be relaunched. They do not affect Quick Look, popovers, menu-bar extras,
/// menus or other system overlays: those draw their own frames. Measured on screen with a test window: default 16 pt;
/// 4 → ≈5 pt, 7 → ≈7 pt, 10 → ≈10 pt, 20 → ≈20 pt. Reported to work from macOS 26.4 (TinkerTool 11.7); before 26.4 the
/// key has no effect. Apple may change or remove it with any update.
public enum WindowCornerKey {
    public static let windows = "NSConvolutionOverride1"
    public static let utilityPanels = "NSConvolutionOverride2"
    public static let all = [windows, utilityPanels]
}

/// Reads and writes values of the global preferences domain (`NSGlobalDomain`) of the current user.
public protocol GlobalPreferenceStore: Sendable {
    func value(_ key: String) -> Any?
    /// nil removes the key.
    func set(_ key: String, _ value: Any?) throws
}

/// The real store: CFPreferences through cfprefsd, current user, any host – what `defaults write -g` writes.
/// `application` is the global domain in the app; validation passes a test app's own domain instead, so the real
/// write path can be checked on screen without changing the user's global setting.
public struct LiveGlobalPreferenceStore: GlobalPreferenceStore {
    public var application: String?

    public init(application: String? = nil) { self.application = application }

    private var domain: CFString { application.map { $0 as CFString } ?? kCFPreferencesAnyApplication }

    public func value(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func set(_ key: String, _ value: Any?) throws {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw WindowCornersError.writeFailed
        }
    }
}

/// A plist file instead of the real domain (simulated Macs and tests), so trying the tool never changes this Mac.
public struct FileGlobalPreferenceStore: GlobalPreferenceStore {
    public var file: URL

    public init(file: URL) { self.file = file }

    private func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return ((try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]) ?? [:]
    }

    public func value(_ key: String) -> Any? { load()[key] }

    public func set(_ key: String, _ value: Any?) throws {
        var all = load()
        all[key] = value
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: all, format: .binary, options: 0).write(to: file, options: .atomic)
    }
}

public enum WindowCornersError: Error, Equatable {
    case writeFailed
    case unsupported
    case invalidRadius
}

/// The corner setting: macOS's own radius (key absent), or a radius in points.
public enum CornerSetting: Equatable, Sendable, Codable {
    case system
    case radius(Int)

    /// The values that change something; 0 or text is ignored by AppKit (it then uses its default).
    public static let range = 2...24

    init(stored: Any?) {
        if let number = stored as? Int, number > 0 { self = .radius(number) }
        else if let text = stored as? String, let number = Int(text), number > 0 { self = .radius(number) }
        else if let number = stored as? Double, number > 0 { self = .radius(Int(number.rounded())) }
        else { self = .system }
    }

    var storedValue: Any? {
        switch self {
        case .system: return nil
        case .radius(let points): return points
        }
    }

    public var historyText: String {
        switch self {
        case .system: return "system"
        case .radius(let points): return String(points)
        }
    }

    public init?(historyText: String) {
        if historyText == "system" { self = .system }
        else if let points = Int(historyText), points > 0 { self = .radius(points) }
        else { return nil }
    }
}

/// The two keys together.
public struct CornerState: Equatable, Sendable {
    public var windows: CornerSetting
    public var utilityPanels: CornerSetting
    /// The raw stored values exactly as found (a value AppKit ignores, such as 0 or text, is kept for the revert).
    public var rawWindows: String?
    public var rawUtilityPanels: String?

    public init(windows: CornerSetting, utilityPanels: CornerSetting, rawWindows: String? = nil, rawUtilityPanels: String? = nil) {
        self.windows = windows
        self.utilityPanels = utilityPanels
        self.rawWindows = rawWindows
        self.rawUtilityPanels = rawUtilityPanels
    }

    /// `windows=7;panels=system` – plus the raw values so a revert writes back exactly what was there.
    public var historyText: String {
        "windows=\(windows.historyText);panels=\(utilityPanels.historyText);rawWindows=\(rawWindows ?? "-");rawPanels=\(rawUtilityPanels ?? "-")"
    }

    public init?(historyText: String) {
        var parts: [String: String] = [:]
        for part in historyText.split(separator: ";") {
            guard let index = part.firstIndex(of: "=") else { return nil }
            parts[String(part[..<index])] = String(part[part.index(after: index)...])
        }
        guard let w = parts["windows"].flatMap(CornerSetting.init(historyText:)),
              let p = parts["panels"].flatMap(CornerSetting.init(historyText:)) else { return nil }
        self.init(windows: w, utilityPanels: p,
                  rawWindows: parts["rawWindows"].flatMap { $0 == "-" ? nil : $0 },
                  rawUtilityPanels: parts["rawPanels"].flatMap { $0 == "-" ? nil : $0 })
    }
}

public struct WindowCornersTool: Sendable {
    public var store: GlobalPreferenceStore
    public var environment: ToolEnvironment

    public init(store: GlobalPreferenceStore, environment: ToolEnvironment) {
        self.store = store
        self.environment = environment
    }

    /// From macOS 26.4 (the version that made the key work, per TinkerTool 11.7); verified on 27.0.1.
    public static func capability(_ environment: ToolEnvironment) -> ToolCapability {
        environment.isAtLeast("26.4") ? .experimental : .unsupportedOnThisVersion
    }

    public var capability: ToolCapability { Self.capability(environment) }

    /// The default radius macOS uses for a normal window (measured on 27.0.1); nil where it was not measured.
    public var systemRadius: Int? { environment.majorVersion >= 27 ? 16 : nil }

    static func raw(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? Int { return "int:\(number)" }
        if let number = value as? Double { return "real:\(number)" }
        if let text = value as? String { return "string:\(text)" }
        return "other"
    }

    static func value(fromRaw raw: String) -> Any? {
        if raw.hasPrefix("int:") { return Int(raw.dropFirst(4)) }
        if raw.hasPrefix("real:") { return Double(raw.dropFirst(5)) }
        if raw.hasPrefix("string:") { return String(raw.dropFirst(7)) }
        return nil
    }

    public func state() -> CornerState {
        let w = store.value(WindowCornerKey.windows)
        let p = store.value(WindowCornerKey.utilityPanels)
        return CornerState(windows: CornerSetting(stored: w), utilityPanels: CornerSetting(stored: p), rawWindows: Self.raw(w), rawUtilityPanels: Self.raw(p))
    }

    /// Writes the setting and reads it back. The visual effect shows only in apps started afterwards, so a correct
    /// read-back is at most “partly checked”.
    public func apply(windows: CornerSetting, utilityPanels: CornerSetting) throws -> (before: CornerState, after: CornerState, outcome: ToolVerification) {
        guard capability.allowsChange else { throw WindowCornersError.unsupported }
        for setting in [windows, utilityPanels] {
            if case .radius(let points) = setting, !CornerSetting.range.contains(points) { throw WindowCornersError.invalidRadius }
        }
        let before = state()
        try store.set(WindowCornerKey.windows, windows.storedValue)
        try store.set(WindowCornerKey.utilityPanels, utilityPanels.storedValue)
        let after = state()
        let matches = after.windows == windows && after.utilityPanels == utilityPanels
        return (before, after, matches ? .partiallyVerified : .failed)
    }

    /// Writes back exactly what was there before (including “not set”), not a guessed default.
    public func restore(_ previous: CornerState) throws -> (after: CornerState, outcome: ToolVerification) {
        try store.set(WindowCornerKey.windows, previous.rawWindows.flatMap(Self.value(fromRaw:)) ?? previous.windows.storedValue)
        try store.set(WindowCornerKey.utilityPanels, previous.rawUtilityPanels.flatMap(Self.value(fromRaw:)) ?? previous.utilityPanels.storedValue)
        let after = state()
        let matches = after.windows == previous.windows && after.utilityPanels == previous.utilityPanels
        return (after, matches ? .partiallyVerified : .failed)
    }
}
