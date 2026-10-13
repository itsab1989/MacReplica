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

/// Everything the corner tool can change. Windows and utility panels use AppKit's own (undocumented) keys and need
/// nothing else. Menus, popovers and Quick Look are only reachable with MacReplica's corner plugin, which runs only
/// with System Integrity Protection off (see `CornerPlugin`); their keys are read by that plugin and do nothing
/// without it. Classic menus are AppKit's own older menu style (no plugin needed).
public enum CornerSurface: String, CaseIterable, Sendable, Codable, Identifiable {
    public var id: String { rawValue }
    case windows
    case utilityPanels
    case menus
    case popovers
    case quickLook
    /// Toolbar groups (the glass “pills” in toolbars, e.g. view switchers).
    case toolbars
    /// Buttons in all apps (including Quick Look's): rounded rectangle instead of capsule (a shape, not a radius).
    case buttons

    public var key: String {
        switch self {
        case .windows: return "NSConvolutionOverride1"
        case .utilityPanels: return "NSConvolutionOverride2"
        case .menus: return "MacReplicaMenuCornerRadius"
        case .popovers: return "MacReplicaPopoverCornerRadius"
        case .quickLook: return "MacReplicaQuickLookCornerRadius"
        case .toolbars: return "MacReplicaToolbarCornerRadius"
        case .buttons: return "MacReplicaRoundedButtons"
        }
    }

    public var needsPlugin: Bool { self != .windows && self != .utilityPanels }
    /// The radius macOS draws this surface with by default (points), for the example preview; nil for buttons (a shape).
    public var exampleDefaultRadius: Int? {
        switch self {
        case .windows, .utilityPanels: return 16
        case .menus: return 12
        case .popovers, .quickLook: return 20
        case .toolbars: return 18
        case .buttons: return nil
        }
    }
    public var isRadius: Bool { self != .buttons }
    public static let radiusSurfaces = allCases.filter(\.isRadius)
}

/// What the user wants: a radius per surface (`.system` = leave macOS's own), the button shape and the
/// classic menu style.
public struct CornerConfiguration: Equatable, Sendable {
    public var radii: [CornerSurface: CornerSetting]
    public var roundedButtons: Bool
    public var classicMenus: Bool

    public init(radii: [CornerSurface: CornerSetting] = [:], roundedButtons: Bool = false, classicMenus: Bool = false) {
        self.radii = radii
        self.roundedButtons = roundedButtons
        self.classicMenus = classicMenus
    }

    public func radius(_ surface: CornerSurface) -> CornerSetting { radii[surface] ?? .system }

    /// Nothing changed from macOS's own look.
    public var isSystemDefault: Bool {
        CornerSurface.radiusSurfaces.allSatisfy { radius($0) == .system } && !roundedButtons && !classicMenus
    }

    /// The same radius for every chosen surface (the default in the app, so everything looks alike).
    public static func uniform(_ points: Int, surfaces: Set<CornerSurface>, classicMenus: Bool = false) -> CornerConfiguration {
        var radii: [CornerSurface: CornerSetting] = [:]
        for surface in CornerSurface.radiusSurfaces where surfaces.contains(surface) { radii[surface] = .radius(points) }
        return CornerConfiguration(radii: radii, roundedButtons: surfaces.contains(.buttons), classicMenus: classicMenus)
    }

    /// Surfaces that only change with the plugin.
    public var needsPlugin: Bool {
        CornerSurface.allCases.contains { $0.needsPlugin && ($0 == .buttons ? roundedButtons : radius($0) != .system) }
    }
}

/// The raw values of every key the tool manages, exactly as found – what a revert writes back (including “not set”).
public struct CornerSnapshot: Equatable, Sendable {
    public static let keys = CornerSurface.allCases.map(\.key) + [MenuAppearance.key]
    public var values: [String: String]

    public init(values: [String: String]) { self.values = values }

    /// `NSConvolutionOverride1=int:7|NSGlassMenusEnabled=bool:0` (keys not listed were not set).
    public var historyText: String {
        Self.keys.compactMap { key in values[key].map { "\(key)=\($0)" } }.joined(separator: "|")
    }

    public init?(historyText: String) {
        var values: [String: String] = [:]
        for part in historyText.split(separator: "|") {
            guard let index = part.firstIndex(of: "="), Self.keys.contains(String(part[..<index])) else { return nil }
            values[String(part[..<index])] = String(part[part.index(after: index)...])
        }
        self.init(values: values)
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
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:\(number.boolValue ? 1 : 0)" }
        if let number = value as? Int { return "int:\(number)" }
        if let number = value as? Double { return "real:\(number)" }
        if let text = value as? String { return "string:\(text)" }
        return "other"
    }

    static func value(fromRaw raw: String) -> Any? {
        if raw.hasPrefix("bool:") { return raw.dropFirst(5) == "1" }
        if raw.hasPrefix("int:") { return Int(raw.dropFirst(4)) }
        if raw.hasPrefix("real:") { return Double(raw.dropFirst(5)) }
        if raw.hasPrefix("string:") { return String(raw.dropFirst(7)) }
        return nil
    }

    public func snapshot() -> CornerSnapshot {
        var values: [String: String] = [:]
        for key in CornerSnapshot.keys { if let raw = Self.raw(store.value(key)) { values[key] = raw } }
        return CornerSnapshot(values: values)
    }

    public func state() -> CornerConfiguration {
        var radii: [CornerSurface: CornerSetting] = [:]
        for surface in CornerSurface.radiusSurfaces { radii[surface] = CornerSetting(stored: store.value(surface.key)) }
        let buttons = store.value(CornerSurface.buttons.key)
        return CornerConfiguration(radii: radii, roundedButtons: (buttons as? Bool) == true || (buttons as? Int).map { $0 != 0 } == true,
                                   classicMenus: MenuAppearance(stored: store.value(MenuAppearance.key)) == .classic)
    }

    /// Writes the whole configuration and reads it back. The look changes only in apps opened afterwards (and the
    /// plugin surfaces only where the plugin runs), so a correct read-back is at most “partly checked”.
    public func apply(_ configuration: CornerConfiguration) throws -> (before: CornerSnapshot, after: CornerConfiguration, outcome: ToolVerification) {
        guard capability.allowsChange else { throw WindowCornersError.unsupported }
        for surface in CornerSurface.radiusSurfaces {
            if case .radius(let points) = configuration.radius(surface), !CornerSetting.range.contains(points) { throw WindowCornersError.invalidRadius }
        }
        let before = snapshot()
        for surface in CornerSurface.radiusSurfaces { try store.set(surface.key, configuration.radius(surface).storedValue) }
        try store.set(CornerSurface.buttons.key, configuration.roundedButtons ? true : nil)
        try store.set(MenuAppearance.key, configuration.classicMenus ? false : nil)
        let after = state()
        return (before, after, after == normalized(configuration) ? .partiallyVerified : .failed)
    }

    /// Writes back exactly what was there before, key by key (including “not set”), not a guessed default.
    public func restore(_ previous: CornerSnapshot) throws -> (after: CornerSnapshot, outcome: ToolVerification) {
        for key in CornerSnapshot.keys { try store.set(key, previous.values[key].flatMap(Self.value(fromRaw:))) }
        let after = snapshot()
        return (after, after == previous ? .partiallyVerified : .failed)
    }

    /// The configuration as `state()` reads it back (every radius surface present).
    public func normalized(_ configuration: CornerConfiguration) -> CornerConfiguration {
        var radii: [CornerSurface: CornerSetting] = [:]
        for surface in CornerSurface.radiusSurfaces { radii[surface] = configuration.radius(surface) }
        return CornerConfiguration(radii: radii, roundedButtons: configuration.roundedButtons, classicMenus: configuration.classicMenus)
    }
}

/// Menus: `NSGlassMenusEnabled = NO` (private AppKit default) makes AppKit use its older, non-glass menu window with
/// ≈6 pt corners instead of the ≈12 pt Liquid Glass menus (measured on macOS 27.0.1 in a test app: 11.9 → 6.8 pt).
/// A fixed style, not a radius; it also changes the menu material. Needs no plugin.
public enum MenuAppearance: String, Sendable, Equatable, Codable {
    case glass
    case classic

    public static let key = "NSGlassMenusEnabled"

    init(stored: Any?) {
        if let flag = stored as? Bool { self = flag ? .glass : .classic }
        else if let number = stored as? Int { self = number == 0 ? .classic : .glass }
        else if let text = stored as? String, ["no", "false", "0"].contains(text.lowercased()) { self = .classic }
        else { self = .glass }
    }
}
