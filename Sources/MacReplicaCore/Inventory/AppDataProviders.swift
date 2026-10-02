import Foundation

/// A narrowly defined kind of user-created data for one app, e.g. Photoshop actions.
///
/// Profiles only name folders that hold data the user created (presets,
/// styles, LUTs …). Preferences, caches, licences and anything unknown are
/// never included. Locations follow the vendors' documented defaults; see
/// docs/APPLICATION_DATA.md for sources and limitations.
public struct AppDataProfile: Sendable, Equatable {
    public var id: String
    public var appName: String
    /// Path below the home folder to the app's data folder.
    public var base: String
    /// Optional pattern for a versioned sub-folder, e.g. `^Adobe Photoshop \d{4}$`.
    public var versionFolderPattern: String?
    /// Categories as (localization key suffix, sub-path below the (versioned) app folder).
    public var categories: [(key: String, path: String)]

    public static func == (lhs: AppDataProfile, rhs: AppDataProfile) -> Bool { lhs.id == rhs.id }
}

public struct DetectedAppData: Sendable {
    public var profile: AppDataProfileReference
    public var folder: URL
}

/// What a backed-up folder came from, stored in the manifest.
public struct AppDataProfileReference: Codable, Equatable, Hashable, Sendable {
    public var provider: String
    public var appName: String
    public var category: String
    /// The app version folder the data came from, e.g. "Adobe Photoshop 2025".
    public var appVersion: String?

    public init(provider: String, appName: String, category: String, appVersion: String? = nil) {
        self.provider = provider
        self.appName = appName
        self.category = category
        self.appVersion = appVersion
    }
}

public enum AppDataProviders {
    public static let profiles: [AppDataProfile] = [
        AppDataProfile(id: "adobe-photoshop", appName: "Adobe Photoshop", base: "Library/Application Support/Adobe",
                       versionFolderPattern: #"^Adobe Photoshop (\d{4}|CC \d{4}|CS\d)$"#,
                       categories: [("actions", "Presets/Actions"), ("brushes", "Presets/Brushes"), ("styles", "Presets/Styles"),
                                    ("gradients", "Presets/Gradients"), ("patterns", "Presets/Patterns"), ("swatches", "Presets/Swatches")]),
        AppDataProfile(id: "capture-one", appName: "Capture One", base: "Library/Application Support/Capture One",
                       versionFolderPattern: nil,
                       categories: [("styles", "Styles"), ("presets", "Presets60"), ("shortcuts", "KeyboardShortcuts")]),
        AppDataProfile(id: "davinci-resolve", appName: "DaVinci Resolve", base: "Library/Application Support/Blackmagic Design/DaVinci Resolve",
                       versionFolderPattern: nil,
                       categories: [("luts", "LUT"), ("fusionTemplates", "Fusion/Templates"), ("fusionMacros", "Fusion/Macros")]),
    ]

    /// Finds existing, non-empty data folders for all profiles. Only folder names are read.
    public static func detect(layout: SystemLayout) -> [DetectedAppData] {
        let fm = FileManager.default
        var result: [DetectedAppData] = []
        for profile in profiles {
            let base = layout.homeDirectory.appendingPathComponent(profile.base)
            var appFolders: [(URL, String?)] = []
            if let pattern = profile.versionFolderPattern {
                let names = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.range(of: pattern, options: .regularExpression) != nil }
                appFolders = names.sorted().map { (base.appendingPathComponent($0), $0) }
            } else if fm.fileExists(atPath: base.path) {
                appFolders = [(base, nil)]
            }
            for (folder, version) in appFolders {
                for category in profile.categories {
                    let url = folder.appendingPathComponent(category.path)
                    guard let items = try? fm.contentsOfDirectory(atPath: url.path), items.contains(where: { !$0.hasPrefix(".") }) else { continue }
                    result.append(DetectedAppData(
                        profile: AppDataProfileReference(provider: profile.id, appName: profile.appName, category: category.key, appVersion: version),
                        folder: url))
                }
            }
        }
        return result
    }
}
