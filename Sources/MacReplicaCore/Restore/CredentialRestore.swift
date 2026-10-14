import Foundation

/// Restoring items of the encrypted credential store (see `CredentialStore`).
///
/// Every item is its own step: decrypted only now, into a new private file next to its destination (never a shared
/// temporary folder), checked against the SHA-256 inside the encryption, and only then moved into place. An existing
/// file is never overwritten without the user's decision; with "replace" it is moved aside first. The backup itself is
/// only read. Running the step again finds the identical file and does nothing.
extension Inspector {
    /// Where the item goes: its place below the home folder, or its absolute place on another volume when that volume
    /// is connected. Otherwise a folder of MacReplica's in the home folder (the result says where).
    func credentialTarget(_ item: RestoreItem) -> (url: URL, alternate: Bool)? {
        guard let record = item.credentialItem, PathSafety.isSafeRelativePath(record.fileName), !record.fileName.contains("/") else { return nil }
        if let relative = record.homeRelativePath {
            guard PathSafety.isSafeRelativePath(relative) else { return nil }
            return (layout.homeDirectory.appendingPathComponent(relative), false)
        }
        if let absolute = record.absolutePath, absolute.hasPrefix("/"), !absolute.split(separator: "/").contains("..") {
            let url = URL(fileURLWithPath: absolute)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue,
               FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
                return (url, false)
            }
        }
        return (layout.homeDirectory.appendingPathComponent("MacReplica Restored Credentials/\(record.id)/\(record.fileName)"), true)
    }

    func predictCredentialFile(_ item: RestoreItem) -> Prediction {
        guard let record = item.credentialItem, record.isPreserved, let path = record.encryptedPath else { return .willSkip(.fileNotSupported) }
        if damagedFiles.contains(path) { return .backupFileDamaged }
        guard let keyring = environment.credentialKeyring else { return .willSkip(.passphraseNotProvided) }
        guard let target = credentialTarget(item) else { return .backupFileDamaged }
        guard FileManager.default.fileExists(atPath: target.url.path) else { return .willCopy }
        // The keyed HMAC recognises the same contents without decrypting anything.
        if let expected = record.contentHmac, (try? keyring.contentHMAC(ofFile: target.url)) == expected { return .identicalFileExists }
        return .conflict(resolution: selection.resolution(for: item.id))
    }
}

extension RestoreExecutor {
    func restoreCredentialFile(_ item: RestoreItem, inspector: Inspector, session: RestoreSession,
                               onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        guard let record = item.credentialItem, let encrypted = record.encryptedPath,
              let source = PathSafety.resolve(encrypted, inside: backupRoot) else { return failed(item, .backupFileDamaged, item.identifier) }
        guard let keyring = environment.credentialKeyring else { return ItemResult(itemID: item.id, outcome: .skipped(.passphraseNotProvided)) }
        guard let (target, alternate) = inspector.credentialTarget(item) else { return failed(item, .backupFileDamaged, "unsafe destination") }
        // The encrypted file must be the one recorded in the manifest before anything is decrypted.
        guard let sha = record.encryptedSha256, (try? Hashing.sha256Hex(ofFile: source)) == sha else { return failed(item, .backupFileDamaged, encrypted) }

        var destination = target
        var notes: [ResultNote] = []
        switch inspector.predictCredentialFile(item) {
        case .identicalFileExists:
            return ItemResult(itemID: item.id, outcome: .alreadyPresent, notes: [.identicalFileExists])
        case .willSkip(let reason):
            return ItemResult(itemID: item.id, outcome: .skipped(reason))
        case .backupFileDamaged:
            return failed(item, .backupFileDamaged, encrypted)
        case .conflict(.keepExisting):
            return ItemResult(itemID: item.id, outcome: .skipped(.keptExisting))
        case .conflict(.skip):
            return ItemResult(itemID: item.id, outcome: .skipped(.userSkipped))
        case .conflict(.keepBoth):
            guard let other = Self.alternativeName(for: target) else { return failed(item, .unknown, "no free file name") }
            destination = other
            notes.append(.installedUnderNewName(name: other.lastPathComponent))
        default:
            break
        }
        onEvent(.activity(itemID: item.id, .copying))
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        do {
            if !fm.fileExists(atPath: folder.path) {
                // New folders for credentials are private (as `~/.ssh` must be).
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            return failed(item, .permissionDenied, layout.redact(error.localizedDescription))
        }
        // Decrypt into a new private file in the destination folder (same volume: the final move is atomic).
        let partial = folder.appendingPathComponent(".\(record.id).macreplica-partial")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return failed(item, .permissionDenied, layout.displayPath(folder))
        }
        let trailer: CredentialTrailer
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            trailer = try CredentialItemCipher.open(source, itemID: record.id, keyring: keyring, writingTo: handle)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: partial)
            log.warning("Credential item \(record.id) could not be decrypted", component: .permissions)
            return failed(item, Self.failureCategory(for: error))
        }
        guard (try? Hashing.sha256Hex(ofFile: partial)) == trailer.sha256 else {
            try? fm.removeItem(at: partial)
            return failed(item, .verificationFailed, record.fileName)
        }
        do {
            // As recorded when the backup was made (`CredentialPolicy.restoredPermissions`); never writable by others.
            let mode = trailer.permissions & 0o755
            try fm.setAttributes([.posixPermissions: mode & 0o600 == 0 ? 0o600 : mode], ofItemAtPath: partial.path)
            if fm.fileExists(atPath: destination.path) {
                // Only reached with the user's "replace": the existing file is kept in MacReplica's folder.
                let aside = layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/credentials/\(record.id)/\(destination.lastPathComponent)")
                try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.moveItem(at: destination, to: aside)
                notes.append(.existingFileMovedAside(path: layout.displayPath(aside.deletingLastPathComponent())))
            }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            return failed(item, .permissionDenied, layout.redact(error.localizedDescription))
        }
        // Verified where it now is: the same bytes as on the old Mac, and still the format it was recorded as.
        onEvent(.activity(itemID: item.id, .verifying))
        guard (try? Hashing.sha256Hex(ofFile: destination)) == trailer.sha256 else { return failed(item, .verificationFailed, record.fileName) }
        guard CredentialFormat.matches(destination, recorded: record.format) else { return failed(item, .verificationFailed, record.fileName) }
        if alternate { notes.append(.restoredToAlternateLocation(path: layout.displayPath(destination))) }
        notes.append(.credentialVerified(format: record.format))
        if !record.prerequisites.isEmpty { notes.append(.credentialNeeds(record.prerequisites)) }
        log.info("Restored and verified one \(record.category.rawValue) credential item", component: .permissions)
        return ItemResult(itemID: item.id, outcome: .succeeded, notes: notes)
    }

    /// A changed or foreign item is a damaged backup; anything else (an unknown format) cannot be opened by this version.
    static func failureCategory(for error: Error) -> FailureCategory {
        (error as? CredentialStoreError) == .itemDamaged ? .backupFileDamaged : .credentialCannotBeOpened
    }
}
