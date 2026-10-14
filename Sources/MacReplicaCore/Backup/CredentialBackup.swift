import Foundation

/// The credential part of a backup: every chosen item encrypted on its own into the store (see `CredentialStore`).
extension BackupWriter {
    /// One credential to encrypt: a file the user chose, or a file of a credential provider the user switched on.
    struct CredentialSource {
        var item: CredentialSelectionItem
        var url: URL
    }

    func credentialSources(_ inventory: InventoryResult, providerIDs: [String]) -> [CredentialSource] {
        var sources = inventory.credentialSelection.map { CredentialSource(item: $0, url: layout.resolve(displayPath: $0.originalPath)) }
        var identities = Set(sources.compactMap { InventoryResult.fileIdentity($0.url) })
        for id in providerIDs {
            guard let provider = CredentialProviders.provider(id: id) else { continue }
            for name in provider.detect(layout: layout) {
                guard let url = provider.sourceURL(for: name, layout: layout) else { continue }
                // The same file chosen by hand and through its provider is backed up once.
                if let identity = InventoryResult.fileIdentity(url), !identities.insert(identity).inserted { continue }
                let kind = SensitiveFileClassifier.classify(url)?.kind
                let format = CredentialFormat.describe(url, kind: kind)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                sources.append(CredentialSource(item: CredentialSelectionItem(
                    id: CredentialSelectionItem.identity(of: url), category: CredentialCategory.of(kind: kind, format: format, provider: id), kind: kind,
                    provider: id, fileName: url.lastPathComponent, originalPath: layout.displayPath(url), format: format, size: Int64(size)), url: url))
            }
        }
        return sources
    }

    /// Encrypts every chosen credential into the store and records each one's result. A file that cannot be preserved
    /// is recorded as failed and listed as a gap (the backup is partial) – it never counts as backed up.
    func writeCredentials(_ inventory: InventoryResult, request: CredentialExportRequest?, into root: URL, manifest: inout Manifest, log: LogStore) throws {
        let sources = credentialSources(inventory, providerIDs: request?.providerIDs ?? [])
        guard !sources.isEmpty else { return }
        let home = layout.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        func record(_ source: CredentialSource, status: CredentialItemRecord.Status, problem: CredentialProblem? = nil) -> CredentialItemRecord {
            let path = source.url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : nil
            return CredentialItemRecord(id: source.item.id, category: source.item.category, kind: source.item.kind, provider: source.item.provider,
                                        fileName: source.item.fileName, originalPath: source.item.originalPath, homeRelativePath: relative,
                                        absolutePath: relative == nil ? path : nil, format: source.item.format, size: source.item.size,
                                        status: status, problem: problem)
        }
        func gap(_ source: CredentialSource, _ problem: CredentialProblem) {
            manifest.backupIssues.append(Self.gapIssue(path: source.item.originalPath, problem: problem))
        }
        guard let request else {
            for source in sources {
                manifest.credentialItems.append(record(source, status: .failed, problem: .noEncryptionKey))
                gap(source, .noEncryptionKey)
            }
            log.warning("\(sources.count) credential items not preserved: no encryption was set up", component: .permissions)
            return
        }
        let keyring = try CredentialKeyring.generate()
        let keys = try keyring.keyFile(passphrase: request.passphrase, recoveryKey: request.recoveryKey)
        let items = root.appendingPathComponent(CredentialStore.itemsFolder)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try keys.write(to: root.appendingPathComponent(CredentialStore.keysPath), options: .atomic)
        manifest.credentialStore = CredentialStoreRecord(format: CredentialStore.keysFormat, version: CredentialStore.formatVersion,
                                                         keysPath: CredentialStore.keysPath, algorithm: CredentialStore.algorithmDescription,
                                                         unlockMethods: ["passphrase", "recoveryKey"], keyId: keyring.keyID)
        for source in sources {
            let fm = FileManager.default
            var problem: CredentialProblem?
            if !fm.fileExists(atPath: source.url.path) { problem = .missing }
            else if AppDataScanner.isDataless(source.url) { problem = .notDownloaded }
            else if !fm.isReadableFile(atPath: source.url.path) { problem = .unreadable }
            if let problem {
                manifest.credentialItems.append(record(source, status: .failed, problem: problem))
                gap(source, problem)
                log.warning("Credential not preserved (\(problem.rawValue)): \(source.item.originalPath)", component: .permissions)
                continue
            }
            let mode = ((try? fm.attributesOfItem(atPath: source.url.path)[.posixPermissions] as? Int) ?? 0o600) ?? 0o600
            let permissions = CredentialPolicy.restoredPermissions(mode, item: source.item)
            let path = CredentialStore.itemPath(source.item.id)
            do {
                let sealed = try CredentialItemCipher.seal(source: source.url, to: root.appendingPathComponent(path), itemID: source.item.id,
                                                           keyring: keyring, permissions: permissions)
                var entry = record(source, status: .encryptedBackupVerified)
                entry.size = sealed.plaintextSize
                entry.encryptedPath = path
                entry.encryptedSize = sealed.encryptedSize
                entry.encryptedSha256 = sealed.encryptedSHA256
                entry.contentHmac = sealed.contentHMAC
                manifest.credentialItems.append(entry)
            } catch {
                let problem = Self.problem(for: error)
                manifest.credentialItems.append(record(source, status: .failed, problem: problem))
                gap(source, problem)
                log.warning("Credential not preserved (\(problem.rawValue)): \(source.item.originalPath)", component: .permissions)
            }
        }
        let preserved = manifest.credentialItems.filter(\.isPreserved)
        let categories = Dictionary(grouping: preserved, by: \.category).map { "\($0.value.count) \($0.key.rawValue)" }.sorted()
        log.info("Encrypted and verified \(preserved.count) of \(sources.count) credential items (\(categories.joined(separator: ", ")))", component: .permissions)
    }

    /// Why an item could not be encrypted, from the error of `CredentialItemCipher.seal`.
    static func problem(for error: Error) -> CredentialProblem {
        switch error as? CredentialStoreError {
        case .sourceChanged?: return .changedDuringBackup
        case .sourceUnreadable?: return .unreadable
        default: return .encryptionFailed
        }
    }

    /// The backup gap recorded for an item that could not be preserved (it makes the backup partial).
    static func gapIssue(path: String, problem: CredentialProblem) -> BackupIssue {
        switch problem {
        case .changedDuringBackup: return BackupIssue(path: path, reason: .changedDuringBackup)
        case .notDownloaded: return BackupIssue(path: path, reason: .notDownloaded)
        case .missing: return BackupIssue(path: path, reason: .unreadable, detail: .missing)
        default: return BackupIssue(path: path, reason: .unreadable)
        }
    }
}
