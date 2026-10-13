import Foundation

/// User-level macOS settings MacReplica can carry over, as explicit lists of preference keys per category.
///
/// Preferences are read and written only through `defaults` (cfprefsd): Apple treats the files in
/// `~/Library/Preferences` as a private implementation detail, and copying them can be ignored or overwritten. Settings
/// that belong to this Mac (`ByHost`), that macOS protects (Accessibility, privacy permissions) or that live in private
/// databases are never transferred – they are listed with the reason instead.
public struct SettingsCategory: Sendable, Equatable, Identifiable {
    public struct Domain: Sendable, Equatable {
        /// `NSGlobalDomain` for the global domain (`defaults … -g`).
        public var name: String
        /// Only these keys are transferred.
        public var keys: [String]
    }

    public enum Apply: String, Sendable, Codable {
        /// Takes effect after restarting the Dock / Finder / the menu bar (MacReplica restarts it).
        case restartDock, restartFinder, restartMenuBar
        /// Takes effect after logging out and in again.
        case logout
        /// Takes effect in newly opened windows.
        case immediately
    }

    /// Whether the keys keep their meaning across macOS versions.
    public enum CrossVersion: String, Sendable, Codable {
        /// Long-standing keys (Dock, Finder, keyboard repeat …): offered when the new Mac runs a newer macOS.
        case stable
        /// Keys whose meaning depends on the macOS release (shortcut IDs, input source IDs): offered by default only on the
        /// same major version.
        case sameMajorVersion
    }

    public var id: String
    public var domains: [Domain]
    public var apply: Apply
    public var selectedByDefault: Bool
    public var crossVersion: CrossVersion = .stable

    /// Recommended for a restore from `source` to `target` macOS: same major version, or a newer one for stable keys.
    /// A restore onto an older macOS is never recommended.
    public func recommended(from source: String, to target: String) -> Bool {
        let from = Int(source.split(separator: ".").first ?? "") ?? 0
        let to = Int(target.split(separator: ".").first ?? "") ?? 0
        if from == to { return true }
        return to > from && crossVersion == .stable
    }

    /// Processes that may be restarted after applying (only these names, nothing else).
    public static let restartableProcesses: [Apply: String] = [.restartDock: "Dock", .restartFinder: "Finder", .restartMenuBar: "SystemUIServer"]
}

public enum SettingsCatalog {
    public static let researched = "2026-10-13"
    public static let global = "NSGlobalDomain"

    public static let categories: [SettingsCategory] = [
        SettingsCategory(id: "dock", domains: [
            .init(name: "com.apple.dock", keys: ["orientation", "autohide", "autohide-delay", "autohide-time-modifier", "tilesize", "magnification",
                                                 "largesize", "mineffect", "minimize-to-application", "show-recents", "show-process-indicators",
                                                 "mru-spaces", "expose-group-apps", "wvous-tl-corner", "wvous-tr-corner", "wvous-bl-corner",
                                                 "wvous-br-corner", "wvous-tl-modifier", "wvous-tr-modifier", "wvous-bl-modifier", "wvous-br-modifier"])],
                         apply: .restartDock, selectedByDefault: true),
        SettingsCategory(id: "finder", domains: [
            .init(name: "com.apple.finder", keys: ["AppleShowAllFiles", "ShowPathbar", "ShowStatusBar", "FXPreferredViewStyle", "FXDefaultSearchScope",
                                                   "_FXShowPosixPathInTitle", "_FXSortFoldersFirst", "ShowExternalHardDrivesOnDesktop",
                                                   "ShowHardDrivesOnDesktop", "ShowMountedServersOnDesktop", "ShowRemovableMediaOnDesktop",
                                                   "NewWindowTarget", "NewWindowTargetPath", "FXEnableExtensionChangeWarning", "FXRemoveOldTrashItems",
                                                   "WarnOnEmptyTrash"]),
            .init(name: global, keys: ["AppleShowAllExtensions"])],
                         apply: .restartFinder, selectedByDefault: true),
        SettingsCategory(id: "keyboard", domains: [
            .init(name: global, keys: ["KeyRepeat", "InitialKeyRepeat", "ApplePressAndHoldEnabled", "AppleKeyboardUIMode",
                                       "NSAutomaticCapitalizationEnabled", "NSAutomaticDashSubstitutionEnabled", "NSAutomaticPeriodSubstitutionEnabled",
                                       "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticSpellingCorrectionEnabled", "com.apple.keyboard.fnState"])],
                         apply: .logout, selectedByDefault: true),
        SettingsCategory(id: "trackpadMouse", domains: [
            .init(name: "com.apple.AppleMultitouchTrackpad", keys: ["Clicking", "TrackpadRightClick", "TrackpadThreeFingerDrag", "TrackpadScroll",
                                                                    "TrackpadPinch", "TrackpadRotate", "TrackpadMomentumScroll", "FirstClickThreshold",
                                                                    "ForceSuppressed", "ActuateDetents"]),
            .init(name: "com.apple.driver.AppleBluetoothMultitouch.trackpad", keys: ["Clicking", "TrackpadRightClick", "TrackpadThreeFingerDrag",
                                                                                     "TrackpadScroll", "TrackpadPinch", "TrackpadRotate"]),
            .init(name: global, keys: ["com.apple.trackpad.scaling", "com.apple.mouse.scaling", "com.apple.swipescrolldirection"])],
                         apply: .logout, selectedByDefault: true),
        SettingsCategory(id: "languageRegion", domains: [
            .init(name: global, keys: ["AppleLanguages", "AppleLocale", "AppleMeasurementUnits", "AppleMetricUnits", "AppleTemperatureUnit",
                                       "AppleFirstWeekday", "AppleICUForce24HourTime", "AppleICUDateFormatStrings", "AppleICUNumberSymbols"])],
                         apply: .logout, selectedByDefault: true),
        SettingsCategory(id: "appearance", domains: [
            .init(name: global, keys: ["AppleInterfaceStyle", "AppleInterfaceStyleSwitchesAutomatically", "AppleAccentColor", "AppleHighlightColor",
                                       "AppleShowScrollBars", "NSTableViewDefaultSizeMode", "AppleReduceDesktopTinting", "NSQuitAlwaysKeepsWindows"])],
                         apply: .logout, selectedByDefault: true),
        SettingsCategory(id: "screenshots", domains: [
            .init(name: "com.apple.screencapture", keys: ["location", "type", "disable-shadow", "show-thumbnail", "include-date", "target"])],
                         apply: .restartMenuBar, selectedByDefault: true),
        SettingsCategory(id: "keyboardShortcuts", domains: [
            .init(name: "com.apple.symbolichotkeys", keys: ["AppleSymbolicHotKeys"]),
            .init(name: global, keys: ["NSUserKeyEquivalents"])],
                         apply: .logout, selectedByDefault: false, crossVersion: .sameMajorVersion),
        SettingsCategory(id: "inputSources", domains: [
            .init(name: "com.apple.HIToolbox", keys: ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleCurrentKeyboardLayoutInputSourceID"])],
                         apply: .logout, selectedByDefault: false, crossVersion: .sameMajorVersion),
        SettingsCategory(id: "menuBarClock", domains: [
            .init(name: "com.apple.menuextra.clock", keys: ["ShowSeconds", "ShowDayOfWeek", "ShowDate", "ShowAMPM", "IsAnalog", "FlashDateSeparators"])],
                         apply: .restartMenuBar, selectedByDefault: true),
    ]

    /// Settings MacReplica does not transfer, each with the reason (shown to the user).
    public static let notTransferred = ["accessibility", "wallpaper", "displays", "loginItems", "defaultApps", "privacy", "notifications",
                                        "wifi", "byHost", "dockApps"]

    public static func category(_ id: String) -> SettingsCategory? { categories.first { $0.id == id } }

    /// Restore steps of categories that are not recommended from the backup's macOS to this one (they start deselected).
    public static func notRecommendedItemIDs(_ manifest: Manifest, targetMacOS: String) -> Set<String> {
        Set(manifest.settings.compactMap { record in
            guard let category = category(record.category), !category.recommended(from: manifest.macosVersion, to: targetMacOS) else { return nil }
            return "settings:\(record.category)"
        })
    }
}

/// The recorded values of one category: per domain, the keys that were set on the old Mac.
public struct SettingsRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { category }
    public var category: String
    /// Domain → the values (a property list file in the backup, `settings/<category>/<domain>.plist`).
    public var files: [FileRecord]
    /// How many settings (keys) were recorded.
    public var keyCount: Int

    public init(category: String, files: [FileRecord], keyCount: Int) {
        self.category = category
        self.files = files
        self.keyCount = keyCount
    }
}

public enum SettingsError: Error, Equatable, Sendable {
    case exportFailed(String)
    case importFailed(String)
    case verificationFailed([String])
}

/// Reads and writes preference domains through `defaults` only.
public struct SettingsStore: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    private var environment: [String: String] { layout.processEnvironment(homebrewPrefix: nil, askpass: nil) }

    static func domainArgument(_ domain: String) -> String { domain == SettingsCatalog.global ? "-g" : domain }

    /// All values of a domain (empty if it does not exist).
    public func export(_ domain: String) async throws -> [String: Any] {
        let result = try await runner.run(Command(executable: layout.defaults, arguments: ["export", Self.domainArgument(domain), "-"],
                                                  environment: environment, timeout: 60))
        guard result.succeeded else {
            if result.combinedOutput.contains("does not exist") { return [:] }
            throw SettingsError.exportFailed(layout.redact(String(result.combinedOutput.prefix(200))))
        }
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }

    /// Replaces the domain with `values` (a whole-domain import, so callers merge first).
    public func importDomain(_ domain: String, values: [String: Any], work: URL) async throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: file)
        let result = try await runner.run(Command(executable: layout.defaults, arguments: ["import", Self.domainArgument(domain), file.path],
                                                  environment: environment, timeout: 60))
        guard result.succeeded else { throw SettingsError.importFailed(layout.redact(String(result.combinedOutput.prefix(200)))) }
    }

    /// Restarts the Dock, Finder or the menu bar so they read their settings again (only these three process names).
    public func restart(_ apply: SettingsCategory.Apply) async {
        guard let process = SettingsCategory.restartableProcesses[apply] else { return }
        _ = try? await runner.run(Command(executable: layout.killall, arguments: [process], environment: environment, timeout: 30))
    }
}

/// Home-folder paths inside recorded values (Finder's new-window folder, the screenshot location) are stored with the
/// placeholder and filled in with the new Mac's home folder.
enum SettingsValues {
    static func replacingHome(_ value: Any, from: String, to: String) -> Any {
        switch value {
        case let string as String:
            // Only the home folder as a whole path: `/Users/anna` must not change `/Users/annabelle`.
            if string == from { return to }
            if string == "file://" + from || string == "file://" + from + "/" { return "file://" + to + "/" }
            return string.replacingOccurrences(of: from + "/", with: to + "/")
        case let array as [Any]: return array.map { replacingHome($0, from: from, to: to) }
        case let dictionary as [String: Any]: return dictionary.mapValues { replacingHome($0, from: from, to: to) }
        default: return value
        }
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (a as AnyObject).isEqual(b)
    }
}

/// What applying a category does on this Mac, and what it did.
public struct SettingsChange: Equatable, Sendable {
    /// Keys whose value on this Mac differs and will be set (domain › key).
    public var toChange: [String]
    /// Keys left as they are because this Mac stores a different kind of value (e.g. a number instead of text) –
    /// the meaning may have changed between macOS versions.
    public var differentType: [String]
    public var unchanged: Int
}

public struct SettingsResult: Equatable, Sendable {
    public var applied: Int
    /// Written, but this macOS did not keep them (read back differently): reported, never counted as restored.
    public var notKept: [String]
    public var differentType: [String]
}

/// Applies a recorded category: merges only its keys into the current domain and verifies by reading back.
public struct SettingsRestorer: Sendable {
    public var store: SettingsStore
    public var backupRoot: URL

    public init(store: SettingsStore, backupRoot: URL) {
        self.store = store
        self.backupRoot = backupRoot
    }

    /// The recorded values per domain, with this Mac's home folder filled in.
    func recordedValues(_ record: SettingsRecord) -> [(domain: String, values: [String: Any])] {
        record.files.compactMap { file in
            guard let url = PathSafety.resolve(file.backupPath, inside: backupRoot), (try? Hashing.sha256Hex(ofFile: url)) == file.sha256,
                  let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            let home = store.layout.homeDirectory.standardizedFileURL.path
            let filled = values.mapValues { SettingsValues.replacingHome($0, from: AppDataScanner.homePlaceholder, to: home) }
            return (file.metadata["domain"] ?? (file.fileName as NSString).deletingPathExtension, filled)
        }
    }

    public func changes(_ record: SettingsRecord) async throws -> SettingsChange {
        var change = SettingsChange(toChange: [], differentType: [], unchanged: 0)
        for (domain, values) in recordedValues(record) {
            let current = try await store.export(domain)
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                if SettingsValues.equal(current[key], value) { change.unchanged += 1; continue }
                if let existing = current[key], !SettingsValues.sameKind(existing, value) { change.differentType.append("\(domain) › \(key)"); continue }
                change.toChange.append("\(domain) › \(key)")
            }
        }
        return change
    }

    public func apply(_ record: SettingsRecord, work: URL) async throws -> SettingsResult {
        var result = SettingsResult(applied: 0, notKept: [], differentType: [])
        for (domain, values) in recordedValues(record) {
            var merged = try await store.export(domain)
            var written: [String: Any] = [:]
            for (key, value) in values {
                if let existing = merged[key], !SettingsValues.sameKind(existing, value) { result.differentType.append("\(domain) › \(key)"); continue }
                if SettingsValues.equal(merged[key], value) { continue }
                merged[key] = value
                written[key] = value
            }
            guard !written.isEmpty else { continue }
            try await store.importDomain(domain, values: merged, work: work)
            let check = try await store.export(domain)
            for (key, value) in written.sorted(by: { $0.key < $1.key }) {
                if SettingsValues.equal(check[key], value) { result.applied += 1 } else { result.notKept.append("\(domain) › \(key)") }
            }
        }
        if let category = SettingsCatalog.category(record.category), result.applied > 0 { await store.restart(category.apply) }
        return result
    }
}

extension SettingsValues {
    /// Same property-list kind (text, number/boolean, date, data, list, dictionary).
    static func sameKind(_ a: Any, _ b: Any) -> Bool {
        func kind(_ v: Any) -> Int {
            switch v {
            case is String: return 0
            case is NSNumber: return 1
            case is Date: return 2
            case is Data: return 3
            case is [Any]: return 4
            case is [String: Any]: return 5
            default: return 6
            }
        }
        return kind(a) == kind(b)
    }
}

/// Records the categories' values on the old Mac (read through `defaults export`, home folder as a placeholder).
public struct SettingsRecorder: Sendable {
    public var store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    public func record() async -> (records: [SettingsRecord], files: [ScannedFile]) {
        var cache: [String: [String: Any]] = [:]
        var records: [SettingsRecord] = []
        var files: [ScannedFile] = []
        let home = store.layout.homeDirectory.standardizedFileURL.path
        for category in SettingsCatalog.categories {
            var categoryFiles: [FileRecord] = []
            var count = 0
            for domain in category.domains {
                if cache[domain.name] == nil { cache[domain.name] = (try? await store.export(domain.name)) ?? [:] }
                let all = cache[domain.name] ?? [:]
                var values: [String: Any] = [:]
                for key in domain.keys { if let value = all[key] { values[key] = SettingsValues.replacingHome(value, from: home, to: AppDataScanner.homePlaceholder) } }
                guard !values.isEmpty,
                      let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0) else { continue }
                let name = "\(domain.name).plist"
                var file = FileRecord(fileName: name, domain: .user, relativePath: name, originalPath: "defaults: \(domain.name)",
                                      backupPath: "settings/\(category.id)/\(name)", sha256: Hashing.sha256Hex(of: data), size: Int64(data.count))
                file.metadata["domain"] = domain.name
                categoryFiles.append(file)
                files.append(ScannedFile(url: store.layout.homeDirectory, record: file, contents: data))
                count += values.count
            }
            if !categoryFiles.isEmpty { records.append(SettingsRecord(category: category.id, files: categoryFiles, keyCount: count)) }
        }
        return (records, files)
    }
}
