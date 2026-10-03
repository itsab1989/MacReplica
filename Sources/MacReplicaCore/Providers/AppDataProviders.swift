import Foundation

/// Finds user data of known applications. The detection is generic; all knowledge
/// about individual applications lives in `AppDataCatalog`.
public enum AppDataProviders {
    public static var providers: [AppDataProvider] { AppDataCatalog.providers }

    /// Existing, non-empty data for every offered category of every provider. Only
    /// folder and file names are read. Nothing depends on the app being installed;
    /// the data itself is what is detected.
    public static func detect(layout: SystemLayout, providers: [AppDataProvider] = AppDataProviders.providers) -> [DetectedAppData] {
        let fm = FileManager.default
        var result: [DetectedAppData] = []
        for provider in providers {
            let root = layout.root(of: provider.scope)
            let base = ([provider.base] + provider.alternateBases).filter(PathSafety.isSafeRelativePath).map { root.appendingPathComponent($0) }
                .first { fm.fileExists(atPath: $0.path) } ?? root.appendingPathComponent(provider.base)
            var appFolders: [(URL, String?)] = []
            if let pattern = provider.versionFolderPattern {
                let names = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
                    .filter { $0.range(of: pattern, options: .regularExpression) != nil }
                appFolders = names.sorted().map { (base.appendingPathComponent($0), $0) }
            } else if fm.fileExists(atPath: base.path) {
                appFolders = [(base, nil)]
            }
            for (folder, version) in appFolders {
                for category in provider.categories where category.classification.isOffered {
                    let candidates = ([category.path] + category.alternatePaths).filter { $0.isEmpty || PathSafety.isSafeRelativePath($0) }
                    guard let url = candidates.map({ $0.isEmpty ? folder : folder.appendingPathComponent($0) })
                        .first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates.first.map({ $0.isEmpty ? folder : folder.appendingPathComponent($0) })
                    else { continue }
                    guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
                    let folderName = version.map { $0.hasSuffix(" Settings") ? String($0.dropLast(" Settings".count)) : $0 } ?? ""
                    var wanted = category.files?.map { $0.replacingOccurrences(of: "{folder}", with: folderName) }
                    if let pattern = category.filePattern {
                        wanted = items.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted()
                    }
                    let present = wanted.map { names in names.filter { items.contains($0) } }
                    if let present, present.isEmpty { continue }
                    if present == nil, !items.contains(where: { !$0.hasPrefix(".") }) { continue }
                    let profile = AppDataProfileReference(
                        provider: provider.id, appName: provider.appName, category: category.key, appVersion: version,
                        bundleIdentifiers: provider.bundleIdentifiers, mustBeClosed: provider.mustBeClosed,
                        classification: category.classification,
                        versionFolderPattern: version == nil ? nil : provider.versionFolderPattern,
                        movesBetweenVersions: version != nil && category.movesBetweenVersions,
                        appMustBeInstalled: provider.appMustBeInstalled, notForOlderApp: provider.notForOlderApp)
                    var reference = profile
                    reference.confidence = provider.confidence(of: category.key)
                    reference.requiresFullDiskAccess = provider.requiresFullDiskAccess
                    reference.verification = provider.verification
                    result.append(DetectedAppData(profile: reference, folder: url, scope: provider.scope, shippedByPackage: provider.shippedByPackage,
                                                  files: present, excluding: category.excluding, rewritesHomeFolder: category.rewritesHomeFolder))
                }
            }
        }
        return result
    }

    public static func provider(id: String) -> AppDataProvider? { providers.first { $0.id == id } }
}

/// Detects services that need a new sign-in or a manual export on the new Mac.
public enum GuidanceDetector {
    public static func detect(layout: SystemLayout, installedBundleIDs: Set<String>,
                              catalog: [MigrationGuidance] = GuidanceCatalog.entries) -> [GuidanceRecord] {
        let lowered = Set(installedBundleIDs.map { $0.lowercased() })
        return catalog.compactMap { entry in
            let installed = entry.bundleIdentifiers.contains { lowered.contains($0.lowercased()) }
            let configured = entry.paths.contains { path in
                PathSafety.isSafeRelativePath(path)
                    && FileManager.default.fileExists(atPath: layout.homeDirectory.appendingPathComponent(path).path)
            }
            return installed || configured ? GuidanceRecord(id: entry.id, name: entry.name, kind: entry.kind) : nil
        }
    }
}
