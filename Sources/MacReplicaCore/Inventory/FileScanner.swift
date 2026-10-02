import CoreText
import Foundation

/// A font or ICC profile found on this Mac, before it is copied into a backup.
public struct ScannedFile: Sendable, Equatable {
    public var url: URL
    public var record: FileRecord
}

/// Finds fonts and color profiles in the user and shared library folders.
public struct FileScanner: Sendable {
    public var layout: SystemLayout

    public static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "pfb", "pfm", "afm", "woff", "woff2", "suit"]
    public static let profileExtensions: Set<String> = ["icc", "icm"]

    public init(layout: SystemLayout) {
        self.layout = layout
    }

    public func scan(_ kind: BackupFileKind) -> [ScannedFile] {
        FileDomain.allCases.flatMap { scan(kind, domain: $0) }
    }

    public func scan(_ kind: BackupFileKind, domain: FileDomain) -> [ScannedFile] {
        let base = layout.baseFolder(for: kind, domain: domain).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            guard accepts(url, kind: kind) else { continue }
            guard let relative = Self.relativePath(of: url, below: base) else { continue }
            guard let hash = try? Hashing.sha256Hex(ofFile: url) else { continue }
            let folder = kind == .font ? "fonts" : "icc_profiles"
            let record = FileRecord(
                fileName: url.lastPathComponent,
                domain: domain,
                relativePath: relative,
                originalPath: layout.displayPath(url),
                backupPath: "\(folder)/\(domain.rawValue)/\(relative)",
                sha256: hash,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                metadata: kind == .font ? Self.fontMetadata(url) : Self.profileMetadata(url))
            result.append(ScannedFile(url: url, record: record))
        }
        return result.sorted { $0.record.relativePath.localizedStandardCompare($1.record.relativePath) == .orderedAscending }
    }

    func accepts(_ url: URL, kind: BackupFileKind) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .font:
            if Self.fontExtensions.contains(ext) { return true }
            // Classic font suitcases have no extension and keep their data in the resource fork.
            return ext.isEmpty && Self.hasResourceFork(url)
        case .colorProfile:
            guard Self.profileExtensions.contains(ext) else { return false }
            guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 40) else { return false }
            try? handle.close()
            return header.count >= 40 && String(decoding: header[36..<40], as: UTF8.self) == "acsp"
        }
    }

    static func hasResourceFork(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, 0) > 0
    }

    /// The path of `url` relative to `base`, or nil if it is not inside `base`.
    public static func relativePath(of url: URL, below base: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    static func fontMetadata(_ url: URL) -> [String: String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty
        else { return [:] }
        var families = Set<String>()
        var postScriptNames: [String] = []
        var styles = Set<String>()
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String { families.insert(family) }
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String { postScriptNames.append(name) }
            if let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String { styles.insert(style) }
        }
        var metadata: [String: String] = ["face_count": String(descriptors.count)]
        if !families.isEmpty { metadata["family"] = families.sorted().joined(separator: ", ") }
        if !postScriptNames.isEmpty { metadata["postscript_names"] = postScriptNames.joined(separator: ", ") }
        if !styles.isEmpty { metadata["styles"] = styles.sorted().joined(separator: ", ") }
        return metadata
    }

    static func profileMetadata(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), let header = ICCProfileHeader.parse(data) else { return [:] }
        var metadata = [
            "icc_version": header.version,
            "device_class": header.deviceClass,
            "color_space": header.colorSpace,
            "connection_space": header.connectionSpace,
        ]
        if let description = header.description { metadata["description"] = description }
        return metadata
    }
}
