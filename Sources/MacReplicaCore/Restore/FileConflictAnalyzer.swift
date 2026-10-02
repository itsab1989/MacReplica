import CoreText
import Foundation

/// Where a font or profile exists on the destination Mac.
public enum FileLocation: String, Codable, Sendable {
    /// The user's own library (`~/Library/Fonts`, `~/Library/ColorSync/Profiles`).
    case user
    /// The shared library for all users (`/Library/…`).
    case shared
    /// Part of macOS (`/System/Library/…`), read-only.
    case macOS
}

/// What restoring one font or profile would mean on this Mac. Computed the same way for the
/// restore selection, the dry run and the restore itself.
public struct FileAssessment: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Not on this Mac yet.
        case ready
        /// The exact same file (same checksum) is already installed, possibly under another name.
        case identical
        /// The same font (same PostScript names and version) or profile (same Profile ID) is installed.
        case equivalent
        /// macOS itself already provides this font or profile.
        case providedByMacOS
        /// The same font or profile is installed in a different version.
        case differentVersion
        /// A different font or profile occupies the same file name.
        case differentFile
        /// macOS on this Mac cannot read the file.
        case incompatible
        /// An Apple-made profile that this macOS version does not ship any more.
        case obsoleteAppleProfile
        /// A profile macOS generated for a display of the old Mac. Never restored: macOS creates one
        /// for each display it sees.
        case displayProfile
        /// A classic suitcase or PostScript Type 1 font: may work, but Apple no longer recommends it.
        case legacyFormat
    }

    /// Extra facts shown with the status.
    public enum Advisory: String, Codable, Sendable {
        /// A display profile is only accurate for the display it was measured on.
        case displayCalibration
        /// Another profile with the same name stays installed; apps will list both.
        case sameNameListedTwice
        /// The backup copy is installed under a new file name next to the existing file.
        case installedUnderNewName
    }

    public var status: Status
    /// Where the matching or conflicting file is on this Mac.
    public var existingLocation: FileLocation?
    /// File name of the matching or conflicting file (never a full path).
    public var existingFileName: String?
    public var installedVersion: String?
    public var backupVersion: String?
    public var advisories: [Advisory]

    public init(status: Status, existingLocation: FileLocation? = nil, existingFileName: String? = nil,
                installedVersion: String? = nil, backupVersion: String? = nil, advisories: [Advisory] = []) {
        self.status = status
        self.advisories = advisories
        self.existingLocation = existingLocation
        self.existingFileName = existingFileName
        self.installedVersion = installedVersion
        self.backupVersion = backupVersion
    }

    /// Nothing needs to be copied: this Mac already has it.
    public var isSatisfied: Bool { status == .identical || status == .equivalent }
    /// The user decides between this Mac's version and the backup's.
    public var needsDecision: Bool { status == .differentVersion || status == .differentFile }
    /// Selected for restoring unless the user changes it.
    public var selectedByDefault: Bool {
        switch status {
        case .incompatible, .obsoleteAppleProfile, .displayProfile, .legacyFormat: return false
        default: return true
        }
    }

    /// Whether the user can choose to restore it at all.
    public var canBeRestored: Bool { status != .incompatible && status != .displayProfile }

    /// The choices offered when this Mac already has a different version or a different file of that name.
    public func conflictChoices(kind: RestoreItemKind) -> [ConflictResolution] {
        switch status {
        case .differentFile: return [.keepBoth, .keepExisting, .replace, .skip]
        case .differentVersion where kind == .colorProfile: return [.keepBoth, .keepExisting, .replace, .skip]
        // Two versions of one font must not be active at the same time.
        case .differentVersion: return [.keepExisting, .replace, .skip]
        case .providedByMacOS: return [.keepExisting, .replace]
        default: return []
        }
    }

    /// What happens with a conflict if the user does not decide: nothing existing is ever overwritten.
    /// A different file that only shares the name is installed next to it, as is a profile that differs
    /// from one with the same name; a different version of a font is not installed.
    public func defaultResolution(kind: RestoreItemKind) -> ConflictResolution {
        switch status {
        case .differentFile: return .keepBoth
        case .differentVersion where kind == .colorProfile: return .keepBoth
        default: return .keepExisting
        }
    }
}

/// Fonts and profiles that exist on the destination Mac, read once per check.
final class DestinationFileIndex: @unchecked Sendable {
    struct Entry {
        var url: URL
        var location: FileLocation
        var size: Int64
        var font: FontIdentity?
        var profile: ProfileIdentity?
    }

    private let lock = NSLock()
    private var storage: [Entry]
    private var hashes: [URL: String] = [:]

    init(entries: [Entry]) {
        storage = entries
    }

    var entries: [Entry] { lock.withLock { storage } }

    /// Records a file MacReplica just installed, so later checks in the same run see it.
    func record(installed url: URL, location: FileLocation, kind: BackupFileKind, sha256: String) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let entry = Entry(url: url, location: location, size: size,
                          font: kind == .font ? FileScanner.fontIdentity(url) : nil,
                          profile: kind == .colorProfile ? FileScanner.profileIdentity(url) : nil)
        lock.withLock {
            storage.removeAll { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
            storage.append(entry)
            hashes[url] = sha256
        }
    }

    /// Forgets a file that was moved away.
    func remove(_ url: URL) {
        lock.withLock {
            storage.removeAll { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
            hashes[url] = nil
        }
    }

    func hash(of entry: Entry) -> String? {
        if let cached = lock.withLock({ hashes[entry.url] }) { return cached }
        guard let value = try? Hashing.sha256Hex(ofFile: entry.url) else { return nil }
        lock.withLock { hashes[entry.url] = value }
        return value
    }

    static func build(kind: BackupFileKind, layout: SystemLayout) -> DestinationFileIndex {
        let folders: [(URL, FileLocation)] = kind == .font
            ? [(layout.userFonts, .user), (layout.systemFonts, .shared), (layout.macOSFonts, .macOS)]
            : [(layout.userColorProfiles, .user), (layout.systemColorProfiles, .shared), (layout.macOSColorProfiles, .macOS)]
        var entries: [Entry] = []
        for (folder, location) in folders {
            entries += cachedEntries(kind: kind, folder: folder, location: location)
        }
        if kind == .font {
            // Downloadable fonts macOS manages itself, e.g. `com_apple_MobileAsset_Font8`.
            let assets = (try? FileManager.default.contentsOfDirectory(atPath: layout.macOSFontAssets.path)) ?? []
            for name in assets.sorted() where name.hasPrefix("com_apple_MobileAsset_Font") {
                entries += cachedEntries(kind: kind, folder: layout.macOSFontAssets.appendingPathComponent(name), location: .macOS)
            }
        }
        return DestinationFileIndex(entries: entries)
    }

    /// macOS's own folders never change while MacReplica runs, so they are read only once.
    private static let macOSCache = MacOSCache()

    private static func cachedEntries(kind: BackupFileKind, folder: URL, location: FileLocation) -> [Entry] {
        guard location == .macOS else { return scan(kind: kind, folder: folder, location: location) }
        return macOSCache.entries(for: folder.path) { scan(kind: kind, folder: folder, location: location) }
    }

    private static func scan(kind: BackupFileKind, folder: URL, location: FileLocation) -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [Entry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            switch kind {
            case .font:
                guard FileScanner.fontExtensions.contains(ext) || (ext.isEmpty && FileScanner.hasResourceFork(url)) else { continue }
                result.append(Entry(url: url, location: location, size: Int64(values.fileSize ?? 0), font: FileScanner.fontIdentity(url)))
            case .colorProfile:
                guard FileScanner.profileExtensions.contains(ext), let profile = FileScanner.profileIdentity(url) else { continue }
                result.append(Entry(url: url, location: location, size: Int64(values.fileSize ?? 0), profile: profile))
            }
        }
        return result
    }

    private final class MacOSCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: [Entry]] = [:]

        func entries(for key: String, load: () -> [Entry]) -> [Entry] {
            if let cached = lock.withLock({ storage[key] }) { return cached }
            let value = load()
            lock.withLock { storage[key] = value }
            return value
        }
    }
}

/// Decides how a font or profile from the backup relates to what this Mac already has.
///
/// The order of the checks matters: an exact copy is always recognized first, so nothing is copied
/// twice; identity (PostScript names and version, the computed ICC Profile ID) is used when the
/// bytes differ; names and descriptions only ever reveal a possible conflict, they never make two
/// files "the same". The policy follows docs/FONTS_AND_PROFILES.md.
struct FileConflictAnalyzer {
    struct Result {
        var assessment: FileAssessment
        /// The existing file in the restore folder that "Replace" would move aside (never one in another folder).
        var replaceTarget: URL?
    }

    let index: DestinationFileIndex

    func assess(record: FileRecord, kind: BackupFileKind, source: URL, destination: URL, destinationLocation: FileLocation) -> Result {
        let legacy = kind == .font && FileScanner.isLegacyFontFormat(source)
        let backupFont = kind == .font && !legacy ? FileScanner.fontIdentity(source) : nil
        let backupProfile = kind == .colorProfile ? FileScanner.profileIdentity(source) : nil
        let backupVersion = kind == .font ? backupFont?.shortVersion : backupProfile?.version
        func result(_ status: FileAssessment.Status, _ entry: DestinationFileIndex.Entry? = nil, installed: String? = nil,
                    replace: URL? = nil, advisories: [FileAssessment.Advisory] = []) -> Result {
            var advisories = advisories
            if kind == .colorProfile, let backupProfile, backupProfile.isDisplayProfile, !backupProfile.isAppleCreated,
               [.ready, .differentFile, .differentVersion].contains(status) {
                advisories.append(.displayCalibration)
            }
            return Result(assessment: FileAssessment(status: status, existingLocation: entry?.location, existingFileName: entry?.url.lastPathComponent,
                                                     installedVersion: installed, backupVersion: backupVersion, advisories: advisories),
                          replaceTarget: replace)
        }
        let destinationPath = destination.standardizedFileURL.path
        let entries = index.entries
        var atDestination = entries.first { $0.url.standardizedFileURL.path == destinationPath }
        if atDestination == nil, FileManager.default.fileExists(atPath: destination.path) {
            // Something MacReplica does not recognize as a font or profile has the same name.
            atDestination = DestinationFileIndex.Entry(url: destination, location: destinationLocation, size: -1)
        }

        // Classic suitcases are never opened; their data-fork checksum says nothing about the font.
        if legacy {
            if let atDestination {
                // Identical only if both the data and the resource fork match.
                if index.hash(of: atDestination) == record.sha256,
                   FileScanner.resourceForkHash(atDestination.url) == FileScanner.resourceForkHash(source) {
                    return result(.identical, atDestination)
                }
                return result(.differentFile, atDestination, replace: atDestination.url)
            }
            return result(.legacyFormat)
        }

        // 1. The exact same bytes anywhere on this Mac: nothing to do, and no duplicate is created.
        if let atDestination, index.hash(of: atDestination) == record.sha256 { return result(.identical, atDestination) }
        if let same = entries.first(where: { $0.size == record.size && index.hash(of: $0) == record.sha256 }) {
            return result(.identical, same)
        }

        // Display profiles generated by macOS belong to the old Mac's displays.
        if record.origin == .displayGenerated { return result(.displayProfile) }

        // 2. macOS on this Mac must be able to read the file.
        if kind == .font, backupFont == nil { return result(.incompatible) }
        if kind == .colorProfile, backupProfile == nil { return result(.incompatible) }

        switch kind {
        case .font: return assessFont(backupFont!, atDestination: atDestination, entries: entries, destinationLocation: destinationLocation, result: result)
        case .colorProfile: return assessProfile(backupProfile!, record: record, atDestination: atDestination, entries: entries,
                                                 destinationLocation: destinationLocation, result: result)
        }
    }

    private typealias Make = (FileAssessment.Status, DestinationFileIndex.Entry?, String?, URL?, [FileAssessment.Advisory]) -> Result

    private func assessFont(_ font: FontIdentity, atDestination: DestinationFileIndex.Entry?, entries: [DestinationFileIndex.Entry],
                            destinationLocation: FileLocation,
                            result: Make) -> Result {
        let names = Set(font.postScriptNames)
        // macOS's own fonts are protected, and a copy in a library folder would take precedence over
        // them, so an older copy is not installed unless the user asks for it.
        let overlapping = entries.filter { entry in entry.font.map { !names.isDisjoint(with: $0.postScriptNames) } ?? false }
        if let system = overlapping.first(where: { $0.location == .macOS }) {
            return result(.providedByMacOS, system, system.font?.shortVersion, nil, [])
        }
        if let atDestination {
            guard let existing = atDestination.font, !names.isDisjoint(with: existing.postScriptNames) else {
                // Same file name, different font: installed next to it under a new name by default.
                return result(.differentFile, atDestination, atDestination.font?.shortVersion, atDestination.url, [])
            }
            if existing.version == font.version, Set(existing.postScriptNames) == names {
                return result(.equivalent, atDestination, existing.shortVersion, nil, [])
            }
            return result(.differentVersion, atDestination, existing.shortVersion, atDestination.url, [])
        }
        if let match = overlapping.first(where: { $0.font?.version == font.version && Set($0.font?.postScriptNames ?? []) == names }) {
            return result(.equivalent, match, match.font?.shortVersion, nil, [])
        }
        if let match = overlapping.first {
            // Only a file in the folder MacReplica restores into may be replaced.
            return result(.differentVersion, match, match.font?.shortVersion, match.location == destinationLocation ? match.url : nil, [])
        }
        return result(.ready, nil, nil, nil, [])
    }

    private func assessProfile(_ profile: ProfileIdentity, record: FileRecord, atDestination: DestinationFileIndex.Entry?,
                               entries: [DestinationFileIndex.Entry], destinationLocation: FileLocation,
                               result: Make) -> Result {
        // Same content apart from flags and rendering intent: the same profile.
        if let id = profile.computedID, let match = entries.first(where: { $0.profile?.computedID == id }) {
            return result(.equivalent, match, match.profile?.version, nil, [])
        }
        // ColorSync substitutes macOS's own profile for a copy of it; an older copy only adds a stale duplicate.
        if let system = entries.first(where: { $0.location == .macOS && $0.profile?.describesSameProfile(as: profile) == true }) {
            return result(.providedByMacOS, system, system.profile?.version, nil, [])
        }
        if let atDestination {
            if let existing = atDestination.profile, existing.describesSameProfile(as: profile) {
                return result(.differentVersion, atDestination, existing.version, atDestination.url, [.installedUnderNewName])
            }
            return result(.differentFile, atDestination, atDestination.profile?.version, atDestination.url, [.installedUnderNewName])
        }
        if profile.isAppleCreated { return result(.obsoleteAppleProfile, nil, nil, nil, []) }
        if let match = entries.first(where: { $0.location != .macOS && $0.profile?.describesSameProfile(as: profile) == true }) {
            return result(.differentVersion, match, match.profile?.version, match.location == destinationLocation ? match.url : nil, [.sameNameListedTwice])
        }
        return result(.ready, nil, nil, nil, [])
    }
}
