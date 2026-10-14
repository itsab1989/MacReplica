import AppKit
import MacReplicaCore

/// Passwords, keys and other credentials: chosen item by item (any number, from any folder or volume), always encrypted,
/// and every one accounted for – preserved, not preserved with the reason, left out by the user, or a manual step.
extension AppModel {
    /// Something will go into the encrypted part of the backup.
    var credentialsWanted: Bool { !(inventory?.credentialSelection.isEmpty ?? true) || !selectedCredentialProviders.isEmpty }
    var credentialEncryptionReady: Bool { credentialPassphrase != nil && credentialRecoveryKey != nil }

    /// "Add keys or password files …": several files and folders at once, from anywhere this Mac can read.
    func addCredentialFilesFromPanel() {
        let urls: [URL]
        if services.simulationRoot != nil, defaults.bool(forKey: "stagingSkipPanels"), let paths = defaults.stringArray(forKey: "stagingCredentialFiles") {
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.showsHiddenFiles = true
            panel.treatsFilePackagesAsDirectories = true
            panel.prompt = l.t("credential.add.prompt")
            panel.message = l.t("credential.add.message")
            panel.directoryURL = services.layout.homeDirectory
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            urls = panel.urls
        }
        addCredentials(urls)
    }

    func addCredentials(_ urls: [URL]) {
        guard var current = inventory else { return }
        let report = current.addCredentialFiles(urls, layout: services.layout)
        inventory = current
        appLog.info("Credentials: \(report.added.count) added, \(report.alreadySelected.count) already selected, \(report.refused.count) not added",
                    component: .permissions)
        if !report.refused.isEmpty || !report.alreadySelected.isEmpty || !report.sameContents.isEmpty {
            credentialAddReport = report
        }
        if !report.added.isEmpty, !credentialEncryptionReady { credentialSetupPending = true }
    }

    /// A file that was found and left out because it looks like a credential: added to the encrypted backup.
    func addDetectedCredential(_ issue: BackupIssue) {
        // Plain-text exports and recovery codes are the most dangerous files there are: one more explicit confirmation.
        if let kind = issue.sensitive?.kind, kind == .passwordManagerExport || kind == .recoveryMaterial {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = l.t("credential.confirm.title", issue.fileName)
            alert.informativeText = l.t("credential.confirm.\(kind.rawValue)")
            alert.addButton(withTitle: l.t("credential.confirm.add"))
            alert.addButton(withTitle: l.t("common.cancel"))
            let staged = services.simulationRoot != nil && defaults.bool(forKey: "stagingSkipPanels")
            guard staged || alert.runModal() == .alertFirstButtonReturn else { return }
        }
        addCredentials([services.layout.resolve(displayPath: issue.path)])
        includedOnRequest.insert(issue.path)
    }

    func addAllUndecidedCredentials() {
        let issues = inventory?.manifest.undecidedCredentials ?? []
        // The extra-dangerous kinds keep their own confirmation; everything else is added at once.
        let plain = issues.filter { ![.passwordManagerExport, .recoveryMaterial].contains($0.sensitive?.kind) }
        addCredentials(plain.map { services.layout.resolve(displayPath: $0.path) })
        for issue in plain { includedOnRequest.insert(issue.path) }
    }

    func removeCredential(_ item: CredentialSelectionItem) {
        inventory?.removeCredentialFile(id: item.id, layout: services.layout)
        includedOnRequest.remove(item.originalPath)
        appLog.info("Credentials: one \(item.category.rawValue) item taken out by the user", component: .permissions)
    }

    func leaveOutCredential(_ issue: BackupIssue) {
        inventory?.leaveOutCredential(path: issue.path)
        appLog.info("Credentials: one file left out by the user", component: .permissions)
    }

    func reconsiderCredential(_ issue: BackupIssue) {
        inventory?.reconsiderCredential(path: issue.path)
    }

    /// The encryption was set up (passphrase confirmed, recovery key shown and confirmed as stored).
    func credentialSetupFinished(passphrase: String, recoveryKey: RecoveryKey) {
        credentialPassphrase = passphrase
        credentialRecoveryKey = recoveryKey
        credentialSetupPending = false
        appLog.info("Credential encryption set up (passphrase and recovery key; neither is stored)", component: .permissions)
        if let parent = pendingCredentialSave {
            pendingCredentialSave = nil
            saveBackup(into: parent)
        }
    }

    func credentialSetupCancelled() {
        credentialSetupPending = false
        pendingCredentialSave = nil
    }

    /// Writes the recovery key into a text file the user chooses (to print, or to keep on another device).
    func saveRecoveryKey(_ key: RecoveryKey) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacReplica Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = l.t("credential.setup.saveKey.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = l.t("credential.setup.saveKey.file", key.text) + "\n"
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            notice = ProblemInfo(title: l.t("credential.setup.saveKey.failed"), message: services.layout.redact(error.localizedDescription), detail: nil)
        }
    }

    func copyRecoveryKey(_ key: RecoveryKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.text, forType: .string)
    }

    /// Before the backup is written: encryption must be set up for chosen credentials, and credential files that were
    /// found but not decided on are shown once more (the user may still add them or continue without them).
    /// Returns true when saving may go ahead now.
    func credentialChecksBeforeSaving(into parent: URL) -> Bool {
        if credentialsWanted, !credentialEncryptionReady {
            pendingCredentialSave = parent
            credentialSetupPending = true
            return false
        }
        if !(inventory?.manifest.undecidedCredentials.isEmpty ?? true), !undecidedCredentialsConfirmed {
            pendingCredentialSave = parent
            undecidedCredentialsWarning = true
            return false
        }
        return true
    }

    /// From the warning about undecided credentials: save without them (they stay listed as not in the backup).
    func saveWithoutUndecidedCredentials() {
        undecidedCredentialsWarning = false
        undecidedCredentialsConfirmed = true
        if let parent = pendingCredentialSave {
            pendingCredentialSave = nil
            saveBackup(into: parent)
        }
    }

    func reviewUndecidedCredentials() {
        undecidedCredentialsWarning = false
        pendingCredentialSave = nil
        expandCredentials = true
    }

    // MARK: Restore

    /// The backup holds credentials that need the passphrase or recovery key.
    var backupHasCredentials: Bool {
        guard let manifest else { return false }
        return !manifest.credentials.isEmpty || !manifest.preservedCredentials.isEmpty
    }

    var credentialsUnlocked: Bool { restorePassphrase != nil || restoreKeyring != nil }

    /// Checks the passphrase or recovery key right away (wrong ones are reported in the sheet, nothing starts).
    /// `nil` means the user chose to restore without the credentials.
    func restoreSecretEntered(_ secret: CredentialSecret?) {
        restoreSecretError = nil
        guard let secret else {
            restorePassphraseEntered(nil)
            return
        }
        if let store = manifest?.credentialStore, let backupURL, PathSafety.isSafeRelativePath(store.keysPath) {
            do {
                let keys = try Data(contentsOf: backupURL.appendingPathComponent(store.keysPath))
                restoreKeyring = try CredentialKeyring.unlock(keyFile: keys, with: secret)
            } catch CredentialStoreError.recoveryKeyMalformed {
                restoreSecretError = l.t("credential.restore.malformed")
                return
            } catch CredentialStoreError.wrongSecret {
                restoreSecretError = l.t("credential.restore.wrong")
                appLog.warning("Credential store: wrong passphrase or recovery key entered", component: .permissions)
                return
            } catch {
                restoreSecretError = l.t("credential.restore.unreadable")
                appLog.warning("Credential store could not be read: \(error)", component: .permissions)
                return
            }
        }
        if case .passphrase(let passphrase) = secret {
            restorePassphraseEntered(passphrase)
        } else {
            // Unlocked with the recovery key (version 1 vaults of older backups have no recovery key).
            restorePassphraseEntered(nil)
        }
    }
}
