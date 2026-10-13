import Foundation

/// Finds an installed app in the application folders: by its bundle name, and – when the bundle identifier is
/// known – also one folder down, where suites keep their apps (e.g. `/Applications/DisplayCAL/DisplayCAL.app`).
public enum ApplicationLocator {
    public static func find(names: [String], bundleIdentifier: String?, in folders: [URL]) -> URL? {
        let expected = bundleIdentifier?.lowercased()
        func identifier(_ url: URL) -> String?? {
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
            return .some((info["CFBundleIdentifier"] as? String)?.lowercased())
        }
        for folder in folders {
            for name in names where PathSafety.isSafeRelativePath(name) && name.split(separator: "/").count <= 2 {
                let url = folder.appendingPathComponent(name)
                guard let found = identifier(url) else { continue }
                if expected == nil || found == expected { return url }
            }
        }
        guard let expected else { return nil }
        for folder in folders {
            for url in InstallerArchiveInspector.applications(in: folder) where identifier(url) == .some(expected) { return url }
        }
        return nil
    }

    public static func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}
