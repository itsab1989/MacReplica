import Foundation

public enum ManifestError: Error, Equatable, Sendable {
    /// The file is not valid JSON or does not look like a MacReplica manifest.
    case unreadable(String)
    /// The manifest was written by a newer MacReplica that uses an incompatible format.
    case unsupportedVersion(found: Int, supported: Int)
    /// A required field is missing or has an invalid value.
    case invalid(String)
}

/// Reads and writes `manifest.json`, including version checks and migrations.
public enum ManifestIO {
    public static let fileName = "manifest.json"
    public static let checksumFileName = "manifest.json.sha256"

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ manifest: Manifest) throws -> Data {
        try makeEncoder().encode(manifest)
    }

    /// Decodes a manifest of any supported version and migrates it to the current model.
    public static func decode(_ data: Data) throws -> Manifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManifestError.unreadable("not valid JSON")
        }
        guard var dictionary = object as? [String: Any] else {
            throw ManifestError.unreadable("top level is not an object")
        }
        guard let version = dictionary["manifest_version"] as? Int else {
            throw ManifestError.unreadable("manifest_version is missing")
        }
        guard version >= 1 else {
            throw ManifestError.invalid("manifest_version must be 1 or higher")
        }
        guard version <= Manifest.currentVersion else {
            throw ManifestError.unsupportedVersion(found: version, supported: Manifest.currentVersion)
        }
        dictionary = try migrate(dictionary, from: version)
        let migrated = try JSONSerialization.data(withJSONObject: dictionary)
        do {
            return try makeDecoder().decode(Manifest.self, from: migrated)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ManifestError.invalid("missing field \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context) {
            throw ManifestError.invalid("wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw ManifestError.invalid("missing value at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw ManifestError.invalid("could not decode manifest")
        }
    }

    /// Migration hook: each step lifts a manifest dictionary by one version, so old
    /// backups keep working when the format changes.
    static func migrate(
        _ dictionary: [String: Any],
        from version: Int,
        steps: [Int: @Sendable ([String: Any]) throws -> [String: Any]] = migrationSteps,
        targetVersion: Int = Manifest.currentVersion
    ) throws -> [String: Any] {
        var current = dictionary
        var currentVersion = version
        while currentVersion < targetVersion {
            guard let step = steps[currentVersion] else {
                throw ManifestError.invalid("no migration from version \(currentVersion)")
            }
            current = try step(current)
            currentVersion += 1
            current["manifest_version"] = currentVersion
        }
        return current
    }

    /// Keyed by the version a step migrates *from*.
    static let migrationSteps: [Int: @Sendable ([String: Any]) throws -> [String: Any]] = [
        // 1 → 2: every field version 2 adds is optional and means "as before" when absent
        // (application data in the home folder, no display assignments, no saved Python copies).
        1: { $0 },
    ]

    public static func read(from backupRoot: URL) throws -> Manifest {
        let url = backupRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw ManifestError.unreadable("manifest.json not found")
        }
        return try decode(data)
    }

    /// Writes `manifest.json` atomically together with its SHA-256 checksum file.
    public static func write(_ manifest: Manifest, to backupRoot: URL) throws {
        let data = try encode(manifest)
        try data.write(to: backupRoot.appendingPathComponent(fileName), options: .atomic)
        let checksum = Hashing.sha256Hex(of: data) + "  " + fileName + "\n"
        try Data(checksum.utf8).write(to: backupRoot.appendingPathComponent(checksumFileName), options: .atomic)
    }
}
