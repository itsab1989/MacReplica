import Foundation

/// Finds application bundles and reads their metadata.
public struct AppScanner: Sendable {
    public var layout: SystemLayout
    /// Folders inside the application folders that are searched as well, e.g. `/Applications/Utilities`.
    public var maxDepth: Int

    public init(layout: SystemLayout, maxDepth: Int = 2) {
        self.layout = layout
        self.maxDepth = maxDepth
    }

    public func bundleURLs() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for folder in layout.applicationFolders {
            collect(in: folder, depth: 1, into: &result, seen: &seen)
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func collect(in folder: URL, depth: Int, into result: inout [URL], seen: inout Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            // Symbolic links are skipped: they point at apps that live somewhere else.
            if values.isSymbolicLink == true { continue }
            guard values.isDirectory == true else { continue }
            if item.pathExtension.lowercased() == "app" {
                let key = item.standardizedFileURL.path
                if seen.insert(key).inserted { result.append(item) }
            } else if depth < maxDepth, values.isPackage != true {
                collect(in: item, depth: depth + 1, into: &result, seen: &seen)
            }
        }
    }

    /// Reads one bundle. Returns nil for bundles without a readable Info.plist and
    /// for Apple's built-in apps, which come with macOS and need no restore.
    public func read(bundle: URL) -> AppRecord? {
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else { return nil }

        let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces)
        let hasReceipt = BundleInspection.hasAppStoreReceipt(bundle)
        if Self.isBuiltInAppleApp(bundleIdentifier: bundleIdentifier, hasAppStoreReceipt: hasReceipt) {
            return nil
        }

        var architectures: [CPUArchitecture] = []
        if let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
            architectures = MachO.architectures(ofFile: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
        }

        var vendor = BundleInspection.signingVendor(of: bundle)
        if vendor == nil, let copyright = info["NSHumanReadableCopyright"] as? String {
            vendor = BundleInspection.vendor(fromCopyright: copyright)
        }

        var source: InstallSource = .unknown
        if hasReceipt {
            source = .appStore
        } else if let agent = BundleInspection.quarantineAgent(of: bundle) {
            source = .downloaded(agent: agent)
        }

        let name = (bundle.lastPathComponent as NSString).deletingPathExtension
        var record = AppRecord(
            name: name,
            version: Self.nonEmpty(info["CFBundleShortVersionString"] as? String),
            buildVersion: Self.nonEmpty(info["CFBundleVersion"] as? String),
            bundleIdentifier: Self.nonEmpty(bundleIdentifier),
            path: layout.displayPath(bundle),
            vendor: vendor,
            architectures: architectures,
            minimumSystemVersion: Self.nonEmpty(info["LSMinimumSystemVersion"] as? String),
            source: source
        )
        // Only vendor-provided values from Info.plist and the signature; nothing user-specific.
        record.updateFeed = hasReceipt ? nil : UpdateFeed.from(info: info)
        record.teamIdentifier = BundleInspection.signingIdentity(of: bundle)?.teamIdentifier
        if let (channel, evidence) = ChannelDetector.detect(caskToken: nil, bundleIdentifier: record.bundleIdentifier, appName: name,
                                                            version: record.version, feedURL: record.updateFeed?.url) {
            record.channel = channel
            record.channelEvidence = evidence
        }
        return record
    }

    /// Safari and other Apple apps in /Applications are part of macOS itself.
    /// Apple apps from the App Store (Pages, Xcode …) have a receipt and are kept.
    static func isBuiltInAppleApp(bundleIdentifier: String?, hasAppStoreReceipt: Bool) -> Bool {
        guard let bundleIdentifier, bundleIdentifier.lowercased().hasPrefix("com.apple.") else { return false }
        return !hasAppStoreReceipt
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
