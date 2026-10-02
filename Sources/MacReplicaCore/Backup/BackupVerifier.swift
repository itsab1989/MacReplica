import Foundation

public enum VerificationIssue: Equatable, Sendable {
    case manifestUnreadable(String)
    case unsupportedVersion(found: Int, supported: Int)
    case checksumMissing
    case checksumMismatch
    case unsafePath(String)
    case fileMissing(String)
    case sizeMismatch(String)
    case hashMismatch(String)

    /// Problems that make the backup unusable as a whole.
    public var isFatal: Bool {
        switch self {
        case .manifestUnreadable, .unsupportedVersion, .checksumMismatch: return true
        default: return false
        }
    }
}

public struct VerificationReport: Sendable, Equatable {
    public var manifest: Manifest?
    public var issues: [VerificationIssue]
    public var checkedFiles: Int

    /// True when no problem at all was found. A missing checksum file alone is tolerated.
    public var isIntact: Bool {
        manifest != nil && issues.allSatisfy { $0 == .checksumMissing }
    }

    public var isUsable: Bool { manifest != nil && !issues.contains(where: \.isFatal) }

    /// Backup paths of files that failed verification and must not be restored.
    public var damagedFiles: Set<String> {
        Set(issues.compactMap {
            switch $0 {
            case .fileMissing(let p), .sizeMismatch(let p), .hashMismatch(let p), .unsafePath(let p): return p
            default: return nil
            }
        })
    }
}

/// Checks a backup folder: manifest readable and supported, manifest checksum,
/// and every stored font and profile present with the recorded size and SHA-256.
public struct BackupVerifier: Sendable {
    public var layout: SystemLayout

    public init(layout: SystemLayout) {
        self.layout = layout
    }

    public func verify(backupAt root: URL, progress: @Sendable (Double) -> Void = { _ in }) -> VerificationReport {
        let manifestURL = root.appendingPathComponent(ManifestIO.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return VerificationReport(manifest: nil, issues: [.manifestUnreadable("manifest.json not found")], checkedFiles: 0)
        }
        var issues: [VerificationIssue] = []

        if let checksumText = try? String(contentsOf: root.appendingPathComponent(ManifestIO.checksumFileName), encoding: .utf8) {
            let expected = checksumText.split(separator: " ").first.map(String.init)?.lowercased()
            if expected != Hashing.sha256Hex(of: data) { issues.append(.checksumMismatch) }
        } else {
            issues.append(.checksumMissing)
        }

        let manifest: Manifest
        do {
            manifest = try ManifestIO.decode(data)
        } catch ManifestError.unsupportedVersion(let found, let supported) {
            return VerificationReport(manifest: nil, issues: issues + [.unsupportedVersion(found: found, supported: supported)], checkedFiles: 0)
        } catch {
            return VerificationReport(manifest: nil, issues: issues + [.manifestUnreadable(String(describing: error))], checkedFiles: 0)
        }

        let records = manifest.allFileRecords
        var checked = 0
        for (index, record) in records.enumerated() {
            progress(Double(index) / Double(max(records.count, 1)))
            checked += 1
            guard PathSafety.isSafeRelativePath(record.relativePath),
                  let url = PathSafety.resolve(record.backupPath, inside: root) else {
                issues.append(.unsafePath(record.backupPath))
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes, (attributes[.type] as? FileAttributeType) == .typeRegular else {
                issues.append(.fileMissing(record.backupPath))
                continue
            }
            if let size = attributes[.size] as? Int64, size != record.size {
                issues.append(.sizeMismatch(record.backupPath))
                continue
            }
            if (try? Hashing.sha256Hex(ofFile: url)) != record.sha256.lowercased() {
                issues.append(.hashMismatch(record.backupPath))
            }
        }
        // The package-wide checksum list also covers instructions, reports and Python files.
        if let text = try? String(contentsOf: root.appendingPathComponent(BackupWriter.checksumsPath), encoding: .utf8) {
            let recorded = Set(records.map(\.backupPath))
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { issues.append(.checksumMismatch); break }
                let path = parts[1].trimmingCharacters(in: .whitespaces)
                if recorded.contains(path) || path == ManifestIO.fileName || path == ManifestIO.checksumFileName { continue }
                guard let url = PathSafety.resolve(path, inside: root) else { issues.append(.unsafePath(path)); continue }
                checked += 1
                guard FileManager.default.fileExists(atPath: url.path) else { issues.append(.fileMissing(path)); continue }
                if (try? Hashing.sha256Hex(ofFile: url)) != String(parts[0]).lowercased() { issues.append(.hashMismatch(path)) }
            }
        }
        progress(1)
        return VerificationReport(manifest: manifest, issues: issues, checkedFiles: checked)
    }
}
