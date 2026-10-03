import Foundation

/// A copy of a virtual environment kept in the backup, in addition to its package list.
///
/// Virtual environments are not relocatable: they contain absolute paths (`pyvenv.cfg`, the links to
/// the base interpreter, script shebangs). A copy therefore only works unchanged when it comes back to
/// the same path in the same home folder, with the same base interpreter, on a Mac that can run its
/// native extensions. MacReplica checks all of that before using the copy, verifies the result by
/// running the environment, and otherwise rebuilds the environment from its package list.
public struct PythonPreservation: Codable, Equatable, Hashable, Sendable {
    /// Backup-relative path of the archive (`development/python/<id>/environment.zip`).
    public var archivePath: String
    public var sha256: String
    public var size: Int64
    /// Salted hash of the absolute home folder path (see `HardwareKeys`): the copy only fits the same home folder.
    public var homeKey: String
    /// Architectures of the native extensions inside the environment (empty: pure Python).
    public var nativeArchitectures: [CPUArchitecture]
    /// The highest minimum macOS version of those extensions.
    public var minimumMacOS: String?
    /// Packages installed from a local folder or in editable mode point to paths outside the environment.
    public var referencesLocalPaths: Bool

    public init(archivePath: String, sha256: String, size: Int64, homeKey: String, nativeArchitectures: [CPUArchitecture] = [],
                minimumMacOS: String? = nil, referencesLocalPaths: Bool = false) {
        self.archivePath = archivePath
        self.sha256 = sha256
        self.size = size
        self.homeKey = homeKey
        self.nativeArchitectures = nativeArchitectures
        self.minimumMacOS = minimumMacOS
        self.referencesLocalPaths = referencesLocalPaths
    }

    private enum CodingKeys: String, CodingKey {
        case archivePath, sha256 = "sha256", size, homeKey, nativeArchitectures, minimumMacOS = "minimumMacOs", referencesLocalPaths
    }
}

/// Why a saved copy was not used. Each reason is shown to the user; the environment is then rebuilt.
public enum PythonPreservationProblem: String, Codable, Sendable, Equatable {
    case differentHomeFolder
    case incompatibleArchitecture
    case requiresNewerMacOS
    case baseInterpreterMissing
    case archiveDamaged
    case extractionFailed
    case verificationFailed
}

public enum PythonPreserver {
    /// The archive name inside the environment's backup folder.
    public static func archivePath(for environment: PythonEnvironment) -> String { "development/python/\(environment.id)/environment.zip" }

    /// Packs an environment folder into a zip in `workFolder` (with `ditto`, which keeps symbolic links and
    /// permissions). Refuses environments that contain files that look like credentials.
    public enum Outcome: Sendable {
        case preserved(ScannedFile, PythonPreservation)
        case refused(BackupIssue)
    }

    public static func preserve(_ environment: PythonEnvironment, layout: SystemLayout, runner: CommandRunning, workFolder: URL,
                                keys: HardwareKeys) async throws -> Outcome {
        let folder = layout.resolve(displayPath: environment.path)
        guard environment.path.hasPrefix("~/"), FileManager.default.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path) else {
            return .refused(BackupIssue(path: environment.path, reason: .unreadable))
        }
        var architectures = Set<CPUArchitecture>()
        var minimum: String?
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            if AppDataScanner.isRefusedFile(url.lastPathComponent) {
                return .refused(BackupIssue(path: layout.displayPath(url), reason: .refusedSensitive))
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "so" || ext == "dylib", (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            MachO.architectures(ofFile: url).forEach { architectures.insert($0) }
            if let version = MachO.minimumMacOS(ofFile: url),
               minimum.map({ VersionComparison.compare($0, version) == .orderedAscending }) ?? true { minimum = version }
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let archive = workFolder.appendingPathComponent("\(environment.id).zip")
        let result = try await runner.run(Command(executable: layout.ditto,
                                                  arguments: ["-c", "-k", "--keepParent", "--sequesterRsrc", folder.path, archive.path],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 3600))
        guard result.succeeded else { return .refused(BackupIssue(path: environment.path, reason: .unreadable)) }
        let sha = try Hashing.sha256Hex(ofFile: archive)
        let size = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let record = FileRecord(fileName: "environment.zip", domain: .user, relativePath: "environment.zip", originalPath: environment.path,
                                backupPath: archivePath(for: environment), sha256: sha, size: size)
        let preservation = PythonPreservation(
            archivePath: record.backupPath, sha256: sha, size: size, homeKey: keys.key(for: layout.homeDirectory.standardizedFileURL.path),
            nativeArchitectures: architectures.sorted { $0.rawValue < $1.rawValue }, minimumMacOS: minimum,
            referencesLocalPaths: environment.packages.contains { $0.origin == .editable || $0.origin == .local })
        return .preserved(ScannedFile(url: archive, record: record), preservation)
    }

    /// What the restored environment reports about itself when its own Python runs.
    public struct ProbeResult: Codable, Equatable, Sendable {
        public var version: String
        public var prefix: String
        public var machine: String
        /// Installed distributions: PEP 503 normalized name → version.
        public var dists: [String: String]
        /// Modules that could not be imported.
        public var failed: [String]
    }

    /// Runs inside the environment with `-I` (isolated): reports version, prefix and packages and imports the
    /// given modules, so that broken paths and incompatible native extensions show up. The marker comment
    /// lets the simulated Python recognise the probe.
    public static let probeScript = """
        import sys, json, platform, re, importlib, importlib.metadata as md  # MACREPLICA_PROBE
        names = json.loads(sys.argv[1])
        dists = {}
        for d in md.distributions():
            n = d.metadata.get('Name')
            if n:
                dists[re.sub(r'[-_.]+', '-', n).lower()] = d.version
        failed = []
        for m in names:
            try:
                importlib.import_module(m)
            except Exception:
                failed.append(m)
        print(json.dumps({'version': '%d.%d.%d' % sys.version_info[:3], 'prefix': sys.prefix, 'machine': platform.machine(), 'dists': dists, 'failed': failed}))
        """

    public static func parseProbe(_ output: String) -> ProbeResult? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONDecoder().decode(ProbeResult.self, from: Data(line.utf8))
    }

    /// Top-level module names of the recorded packages, from `top_level.txt` in their metadata (at most 50).
    public static func importNames(in environment: URL, packages: [PythonPackage]) -> [String] {
        guard let site = PythonScanner.sitePackages(in: environment) else { return [] }
        let wanted = Set(packages.map(\.normalizedName))
        var names: [String] = []
        for entry in ((try? FileManager.default.contentsOfDirectory(atPath: site.path)) ?? []).sorted() where entry.hasSuffix(".dist-info") {
            let distribution = String(entry.dropLast(10)).split(separator: "-").dropLast().joined(separator: "-")
            guard wanted.contains(PythonPackage.normalize(distribution)) else { continue }
            let text = (try? String(contentsOf: site.appendingPathComponent("\(entry)/top_level.txt"), encoding: .utf8)) ?? ""
            for name in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            where name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil && !names.contains(name) {
                names.append(name)
            }
        }
        return Array(names.prefix(50))
    }

    /// Compares what the environment reports with what was recorded: same minor version, the expected
    /// prefix, every reinstallable package in the recorded version, and all imports working.
    public static func verify(_ probe: ProbeResult, environment: PythonEnvironment, target: URL) -> Bool {
        guard PythonVersion.minor(probe.version) == environment.minorVersion,
              URL(fileURLWithPath: probe.prefix).standardizedFileURL.resolvingSymlinksInPath().path
                == target.standardizedFileURL.resolvingSymlinksInPath().path,
              probe.failed.isEmpty else { return false }
        return environment.installablePackages.allSatisfy { probe.dists[$0.normalizedName] == $0.version }
    }
}
