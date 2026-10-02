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
            let font = kind == .font ? Self.fontIdentity(url) : nil
            let profile = kind == .colorProfile ? Self.profileIdentity(url) : nil
            let record = FileRecord(
                fileName: url.lastPathComponent,
                domain: domain,
                relativePath: relative,
                originalPath: layout.displayPath(url),
                backupPath: "\(folder)/\(domain.rawValue)/\(relative)",
                sha256: hash,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                metadata: kind == .font ? Self.fontMetadata(url) : Self.profileMetadata(url),
                font: font,
                profile: profile,
                origin: Self.origin(kind: kind, domain: domain, relativePath: relative, profile: profile))
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

    /// SHA-256 of the resource fork, or nil if there is none. Classic suitcases keep the font there.
    static func resourceForkHash(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.ResourceFork", &buffer, size, 0, 0) == size else { return nil }
        return Hashing.sha256Hex(of: Data(buffer))
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

    static func origin(kind: BackupFileKind, domain: FileDomain, relativePath: String, profile: ProfileIdentity?) -> FileOrigin {
        if kind == .colorProfile {
            if domain == .system, relativePath.lowercased().hasPrefix("displays/") { return .displayGenerated }
            if profile?.isAppleCreated == true { return .appleCreated }
        }
        return domain == .user ? .userInstalled : .sharedInstalled
    }

    /// Classic resource-fork suitcases and PostScript Type 1 files. Apple: they "might work but aren't
    /// recommended"; resource-fork fonts are never parsed, because reading them has been reported to
    /// crash some macOS versions.
    public static func isLegacyFontFormat(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["pfb", "pfm", "afm", "suit"].contains(ext) { return true }
        return ext.isEmpty && hasResourceFork(url)
    }

    /// Reads the identity of a font file; nil when Core Text on this Mac cannot read it.
    /// Legacy formats are not opened at all.
    public static func fontIdentity(_ url: URL) -> FontIdentity? {
        guard !isLegacyFontFormat(url) else { return nil }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty
        else { return nil }
        var families: [String] = []
        var styles: [String] = []
        var postScriptNames: [String] = []
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String, !families.contains(family) { families.append(family) }
            if let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String, !styles.contains(style) { styles.append(style) }
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String { postScriptNames.append(name) }
        }
        let font = CTFontCreateWithFontDescriptor(descriptors[0], 12, nil)
        let version = CTFontCopyName(font, kCTFontVersionNameKey) as String?
        return FontIdentity(postScriptNames: postScriptNames, families: families, styles: styles, version: version,
                            format: fontFormat(url))
    }

    static func fontFormat(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "otf": return "OpenType"
        case "ttf": return "TrueType"
        case "ttc", "otc": return "Collection"
        case "pfb", "pfm", "afm": return "PostScript Type 1"
        case "woff", "woff2": return "Web font"
        case "dfont", "suit", "": return "Suitcase"
        default: return url.pathExtension.uppercased()
        }
    }

    public static func profileIdentity(_ url: URL) -> ProfileIdentity? {
        guard let data = try? Data(contentsOf: url), let header = ICCProfileHeader.parse(data) else { return nil }
        return ProfileIdentity(header: header)
    }

    static func fontMetadata(_ url: URL) -> [String: String] {
        guard !isLegacyFontFormat(url), let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
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
