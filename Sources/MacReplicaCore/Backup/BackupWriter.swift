import Foundation

public struct BackupProgress: Sendable, Equatable {
    public var fraction: Double
    public var currentFile: String?
}

public enum BackupError: Error, Equatable, Sendable {
    case destinationNotWritable(String)
    /// The destination has less free space than the backup needs (bytes).
    case notEnoughSpace(needed: Int64, available: Int64)
    case copyFailed(String)
    case verificationFailed(String)
}

/// How complete a saved backup is. A backup that could not be saved at all is not a `BackupOutcome` (it is removed).
public enum BackupCompleteness: String, Sendable {
    case complete
    /// Everything selected is in it, except files MacReplica leaves out on purpose because they look like secrets.
    case completeWithIntentionalExclusions
    /// Some selected items could not be included (unreadable, removed, changed while copying, only in iCloud …).
    case partial
}

/// The result of writing a backup.
public struct BackupOutcome: Sendable, Equatable {
    public var url: URL
    public var manifest: Manifest
    public var totalSize: Int64
    public var fileCount: Int
    /// True when everything that was selected is in the backup. Files left out on
    /// purpose because they look like secrets do not make a backup incomplete.
    public var isComplete: Bool { manifest.backupGaps.isEmpty }
}

extension Manifest {
    /// Selected items that could not be included (unreadable, changed while copying, too large).
    public var backupGaps: [BackupIssue] { backupIssues.filter { $0.reason != .refusedSensitive } }
    /// Files left out on purpose because they look like passwords, keys or cookies.
    public var excludedSensitiveFiles: [BackupIssue] { backupIssues.filter { $0.reason == .refusedSensitive } }

    /// Files that look like a secret and are in the backup because the user explicitly asked for them.
    public var sensitiveFilesIncludedOnRequest: [FileRecord] {
        applicationData.flatMap(\.files).filter { $0.metadata[AppDataScanner.includedOnRequestKey] != nil }
    }

    /// How complete the backup is: what was selected is all there; or all there except files left out on purpose
    /// (they look like secrets); or some selected items are missing.
    public var completeness: BackupCompleteness {
        if !backupGaps.isEmpty { return .partial }
        return excludedSensitiveFiles.isEmpty ? .complete : .completeWithIntentionalExclusions
    }

    /// Every file stored in the backup that has a recorded checksum.
    public var allFileRecords: [FileRecord] {
        fonts + iccProfiles + python.environments.flatMap(\.projectFiles) + applicationData.flatMap(\.files) + installerRecords + printers.compactMap(\.ppd)
    }

    /// The user's own installers that were copied into the backup.
    public var installerRecords: [FileRecord] {
        applications.flatMap { $0.ownInstallers ?? [] }.compactMap { archive in
            archive.includedPath.map { FileRecord(fileName: archive.fileName, domain: .user, relativePath: archive.fileName,
                                                  originalPath: archive.originalPath, backupPath: $0, sha256: archive.sha256, size: archive.size) }
        }
    }
}

/// Writes a self-contained, versioned backup folder:
///
///     MacReplica-Backup-2026-10-02-1530/
///     ├── README.txt                      what this folder is and how to use it
///     ├── manifest.json, manifest.json.sha256
///     ├── fonts/{user,system}/…
///     ├── icc_profiles/{user,system}/…
///     ├── development/python/<env>/requirements.txt, project/…
///     ├── application-data/<folder>/…
///     ├── restore/RESTORE_INSTRUCTIONS.html
///     ├── reports/inventory.html, manual_installations.html
///     ├── checksums/SHA256SUMS            checksum of every file above
///     └── logs/inventory.log
/// The user's explicit request to include encrypted credentials.
public struct CredentialExportRequest: Sendable {
    public var providerIDs: [String]
    /// Held in memory only for writing the vault; never stored or logged.
    public var passphrase: String

    public init(providerIDs: [String], passphrase: String) {
        self.providerIDs = providerIDs
        self.passphrase = passphrase
    }
}

public struct BackupWriter: Sendable {
    public var layout: SystemLayout
    public var localizer: Localizer

    public init(layout: SystemLayout, localizer: Localizer) {
        self.layout = layout
        self.localizer = localizer
    }

    public static let checksumsPath = "checksums/SHA256SUMS"
    public static let reinstallGuidePath = "restore/REINSTALL_MACOS.html"

    public static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "MacReplica-Backup-\(formatter.string(from: date))"
    }

    /// Creates the backup inside `parent`. Files that cannot be read are left out
    /// and recorded as backup issues (a partial backup). Anything that would make
    /// the backup unusable removes the incomplete folder again and throws.
    /// The files plus a margin for the manifest, checksums and reports.
    static func estimatedSize(of inventory: InventoryResult, selfCopy: URL? = nil) -> Int64 {
        let files = (inventory.fonts + inventory.colorProfiles + inventory.extraFiles).reduce(Int64(0)) { $0 + $1.record.size }
        return files + files / 100 + 50_000_000 + (selfCopy.map(BootstrapApp.size(of:)) ?? 0)
    }

    /// Free space of the volume (nil if it cannot be read, e.g. some network shares; then the copy itself reports a full disk).
    static func availableSpace(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    public func write(_ inventory: InventoryResult, into parent: URL, log: LogStore, credentials: CredentialExportRequest? = nil,
                      selfCopy: URL? = nil,
                      progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupOutcome {
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw BackupError.destinationNotWritable(layout.displayPath(parent))
        }
        // Checked before anything is written: own folders have no size limit.
        let needed = Self.estimatedSize(of: inventory, selfCopy: selfCopy)
        if let available = Self.availableSpace(at: parent), needed > available {
            throw BackupError.notEnoughSpace(needed: needed, available: available)
        }
        let root = Self.uniqueFolder(in: parent, baseName: Self.folderName(for: inventory.manifest.createdAt))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try OwnershipMarker(kind: .backup).write(into: root)
        let cleaner = SafeCleaner(homeDirectory: layout.homeDirectory)
        var manifest = inventory.manifest

        do {
            // 1. Files
            let files = inventory.fonts + inventory.colorProfiles + inventory.extraFiles
            var failed = Set<String>()
            for (index, file) in files.enumerated() {
                progress(BackupProgress(fraction: Double(index) / Double(max(files.count, 1)) * 0.85, currentFile: file.record.fileName))
                if let issue = try copy(file, into: root) {
                    failed.insert(file.record.backupPath)
                    manifest.backupIssues.append(issue)
                    log.warning("Not included (\(issue.detail?.rawValue ?? issue.reason.rawValue)): \(file.record.originalPath)", component: .backup)
                }
            }
            manifest.fonts.removeAll { failed.contains($0.backupPath) }
            manifest.iccProfiles.removeAll { failed.contains($0.backupPath) }
            for index in manifest.python.environments.indices {
                manifest.python.environments[index].projectFiles.removeAll { failed.contains($0.backupPath) }
            }
            for index in manifest.applicationData.indices {
                manifest.applicationData[index].files.removeAll { failed.contains($0.backupPath) }
            }
            for index in manifest.printers.indices where manifest.printers[index].ppd.map({ failed.contains($0.backupPath) }) == true {
                manifest.printers[index].ppd = nil
            }
            for index in manifest.applications.indices {
                guard var installers = manifest.applications[index].ownInstallers else { continue }
                for i in installers.indices where installers[i].includedPath.map(failed.contains) == true { installers[i].includedPath = nil }
                manifest.applications[index].ownInstallers = installers
            }
            log.info("Copied \(files.count - failed.count) of \(files.count) files", component: .backup)

            // 2. Python dependency lists
            for environment in manifest.python.environments {
                guard let url = PathSafety.resolve(environment.requirementsPath, inside: root) else { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header = localizer.t("python.requirements.header", environment.name, environment.pythonVersion)
                try Data(environment.requirementsText(header: header).utf8).write(to: url, options: .atomic)
            }

            // 3. Encrypted credentials, only on explicit request, kept apart in credentials/.
            manifest.credentials = []
            if let credentials {
                for id in credentials.providerIDs {
                    guard let provider = CredentialProviders.provider(id: id) else { continue }
                    let files = try provider.export(layout: layout)
                    guard !files.isEmpty else { continue }
                    let vault = try CredentialVault.seal(files, passphrase: credentials.passphrase)
                    let path = "credentials/\(id).macreplica-vault"
                    try FileManager.default.createDirectory(at: root.appendingPathComponent("credentials"), withIntermediateDirectories: true)
                    try vault.write(to: root.appendingPathComponent(path), options: .atomic)
                    manifest.credentials.append(CredentialRecord(provider: id, items: files.map(\.name), vaultPath: path))
                    log.info("Encrypted \(files.count) \(id) credential files", component: .permissions)
                }
            }

            // 4. A copy of MacReplica itself, to start the restore on the new Mac without a download. A problem with it
            //    is logged and shown; it never stops the backup of the user's data.
            if let selfCopy {
                do {
                    manifest.bootstrapApp = try BootstrapApp.copy(selfCopy, into: root)
                    if let app = manifest.bootstrapApp {
                        log.info("MacReplica \(app.version) copied into the backup (\(app.architectures.map(\.rawValue).joined(separator: ", ")))", component: .backup)
                    }
                } catch {
                    log.warning("MacReplica could not be copied into the backup: \(error)", component: .backup)
                }
            }

            // 5. Manifest, reports, instructions
            try ManifestIO.write(manifest, to: root)
            log.info("Wrote manifest version \(manifest.manifestVersion)", component: .backup)
            let builder = ReportBuilder(localizer: localizer)
            try writeText(builder.inventoryReport(manifest), to: root.appendingPathComponent("reports/inventory.html"))
            try writeText(builder.manualInstallationsReport(manifest), to: root.appendingPathComponent("reports/manual_installations.html"))
            try writeText(builder.restoreInstructions(manifest, folderName: root.lastPathComponent),
                          to: root.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"))
            let profile = MacProfile(architecture: manifest.architecture, modelIdentifier: manifest.modelIdentifier, macOSVersion: manifest.macosVersion)
            try writeText(builder.reinstallGuide(profile: profile, manifest: manifest, backupFolderName: root.lastPathComponent),
                          to: root.appendingPathComponent(Self.reinstallGuidePath))
            var readme = localizer.t("backup.readme", root.lastPathComponent)
            if let app = manifest.bootstrapApp { readme = localizer.bootstrapReadme(app) + "\n\n" + readme }
            try writeText(readme, to: root.appendingPathComponent("README.txt"))

            // 4. Checksums over everything, then verify the finished backup.
            progress(BackupProgress(fraction: 0.9, currentFile: nil))
            try writeChecksums(root: root)
            let verification = BackupVerifier(layout: layout).verify(backupAt: root)
            guard verification.isIntact else {
                throw BackupError.verificationFailed(verification.issues.map(String.init(describing:)).joined(separator: "; "))
            }
            log.info("Backup verified: \(verification.checkedFiles) files", component: .verification)
            if !manifest.backupGaps.isEmpty {
                log.warning("Backup is partial: \(manifest.backupGaps.count) items could not be included", component: .backup)
            }

            let logs = root.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data(log.allLines.joined(separator: "\n").utf8).write(to: logs.appendingPathComponent("inventory.log"), options: .atomic)
            progress(BackupProgress(fraction: 1, currentFile: nil))
            let (size, count) = Self.measure(root)
            return BackupOutcome(url: root, manifest: manifest, totalSize: size, fileCount: count)
        } catch {
            log.error("Backup failed, removing incomplete backup: \(error)", component: .backup)
            try? cleaner.removeOwnedFolder(root, kind: .backup)
            throw error
        }
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Copies one file. Returns the issue if the file could not be included.
    ///
    /// The names are checked with the same rules the verifier and the restore use: a file whose name the backup cannot
    /// hold (for example one starting with `~`) is left out and reported here, so it can never make the verification
    /// of the whole backup fail afterwards.
    private func copy(_ file: ScannedFile, into root: URL) throws -> BackupIssue? {
        let original = file.record.originalPath
        guard PathSafety.isSafeRelativePath(file.record.relativePath),
              let destination = PathSafety.resolve(file.record.backupPath, inside: root) else {
            return BackupIssue(path: original, reason: .unreadable, detail: .unsupportedName)
        }
        // Files with prepared contents (home folder replaced by a placeholder) were read during the scan.
        guard file.contents != nil || FileManager.default.fileExists(atPath: file.url.path) else {
            return BackupIssue(path: original, reason: .unreadable, detail: .missing)
        }
        guard file.contents != nil || FileManager.default.isReadableFile(atPath: file.url.path) else { return BackupIssue(path: original, reason: .unreadable) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if let contents = file.contents {
                try contents.write(to: destination)
            } else {
                try FileManager.default.copyItem(at: file.url, to: destination)
            }
        } catch {
            let gone = !FileManager.default.fileExists(atPath: file.url.path)
            return BackupIssue(path: original, reason: .unreadable, detail: gone ? .missing : nil)
        }
        // The copy must match the checksum recorded during the scan.
        guard (try? Hashing.sha256Hex(ofFile: destination)) == file.record.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            return BackupIssue(path: original, reason: .changedDuringBackup)
        }
        return nil
    }

    /// Writes `checksums/SHA256SUMS` in the format of `shasum -a 256`, so the
    /// backup can also be checked without MacReplica.
    func writeChecksums(root: URL) throws {
        var lines: [String] = []
        for relative in Self.allFiles(in: root) where !relative.hasPrefix("logs/") && !relative.hasPrefix("checksums/") {
            lines.append("\(try Hashing.sha256Hex(ofFile: root.appendingPathComponent(relative)))  \(relative)")
        }
        try writeText(lines.joined(separator: "\n") + "\n", to: root.appendingPathComponent(Self.checksumsPath))
    }

    static func allFiles(in root: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var result: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != OwnershipMarker.fileName,
                  let relative = FileScanner.relativePath(of: url, below: root) else { continue }
            result.append(relative)
        }
        return result.sorted()
    }

    static func measure(_ root: URL) -> (Int64, Int) {
        var size: Int64 = 0
        var count = 0
        for relative in allFiles(in: root) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
            size += (attributes?[.size] as? Int64) ?? 0
            count += 1
        }
        return (size, count)
    }

    static func uniqueFolder(in parent: URL, baseName: String) -> URL {
        var candidate = parent.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName)-\(counter)")
            counter += 1
        }
        return candidate
    }
}
