import AppKit
import MacReplicaCore

/// Saving and loading the backup selection (`BackupSelectionPreset`), and the backup location.
extension AppModel {
    /// The choices on the selection screen as they are now.
    func currentSelectionPreset(destination: URL? = nil) -> BackupSelectionPreset {
        let layout = services.layout
        let manifest = inventory?.manifest
        let apps = manifest?.applications.map(\.id) ?? []
        let files = (inventory?.fonts ?? []).map { InventoryResult.selectionID($0.record, kind: .font) }
            + (inventory?.colorProfiles ?? []).map { InventoryResult.selectionID($0.record, kind: .colorProfile) }
        let data = manifest?.applicationData.filter { !$0.isPersonal }.map(\.id) ?? []
        let toolchains = manifest?.toolchains.map(\.provider.rawValue) ?? []
        let environments = manifest?.python.environments.map(\.id) ?? []
        let personal = manifest?.applicationData.filter(\.isPersonal) ?? []
        var preset = BackupSelectionPreset(
            applications: BackupSelectionPreset.choices(ids: apps, excluded: excludedApplications),
            files: BackupSelectionPreset.choices(ids: files, excluded: excludedBackupFiles),
            applicationData: BackupSelectionPreset.choices(ids: data, excluded: excludedApplicationData),
            toolchains: BackupSelectionPreset.choices(ids: toolchains, excluded: Set(excludedToolchains.map(\.rawValue))),
            pythonEnvironments: BackupSelectionPreset.choices(ids: environments, excluded: Set(environments).subtracting(selectedPythonEnvironments)),
            preservedPythonEnvironments: preservedPythonEnvironments.sorted(),
            includePythonSettings: includePythonSettings, includeGitSettings: includeGitSettings, includeGitEmail: includeGitEmail,
            includeDisplayAssignments: includeDisplayAssignments, credentialProviders: selectedCredentialProviders.sorted(),
            matchChoices: matchChoices,
            personalFolders: personal.filter { !excludedApplicationData.contains($0.id) }.map(\.displayPath),
            ownInstallers: ownInstallerFiles.mapValues { files in
                files.map { BackupSelectionPreset.OwnInstaller(path: layout.displayPath($0.source ?? $0.url), include: $0.include,
                                                               licence: $0.archive.containsLicence ? true : nil,
                                                               approvedUnverified: $0.archive.userApprovedUnverified ? true : nil, sha256: $0.archive.sha256) }
            },
            destination: (destination ?? backupDestination).map { layout.displayPath($0) })
        preset.includedOnRequest = includedOnRequest.isEmpty ? nil : includedOnRequest.sorted()
        return preset
    }

    /// Applies a saved selection to the current scan. Items that did not exist when it was saved keep their default.
    func applySelection(_ preset: BackupSelectionPreset) {
        guard let manifest = inventory?.manifest else { return }
        let layout = services.layout
        let defaultsOff = Set(manifest.applicationData.filter { $0.profile.map { !$0.classification.selectedByDefault } ?? false }.map(\.id))
        excludedApplications = BackupSelectionPreset.excluded(ids: manifest.applications.map(\.id), saved: preset.applications, excludedByDefault: [])
        let files = (inventory?.fonts ?? []).map { InventoryResult.selectionID($0.record, kind: .font) }
            + (inventory?.colorProfiles ?? []).map { InventoryResult.selectionID($0.record, kind: .colorProfile) }
        excludedBackupFiles = BackupSelectionPreset.excluded(ids: files, saved: preset.files, excludedByDefault: inventory?.filesNotSelectedByDefault ?? [])
        excludedApplicationData = BackupSelectionPreset.excluded(ids: manifest.applicationData.filter { !$0.isPersonal }.map(\.id),
                                                                 saved: preset.applicationData, excludedByDefault: defaultsOff)
        excludedToolchains = Set(BackupSelectionPreset.excluded(ids: manifest.toolchains.map(\.provider.rawValue), saved: preset.toolchains, excludedByDefault: [])
            .compactMap(ToolchainProviderID.init(rawValue:)))
        let environments = manifest.python.environments.map(\.id)
        selectedPythonEnvironments = Set(environments).subtracting(
            BackupSelectionPreset.excluded(ids: environments, saved: preset.pythonEnvironments, excludedByDefault: []))
        preservedPythonEnvironments = Set(preset.preservedPythonEnvironments).intersection(environments)
        includePythonSettings = preset.includePythonSettings
        includeGitSettings = preset.includeGitSettings
        includeGitEmail = preset.includeGitEmail
        includeDisplayAssignments = preset.includeDisplayAssignments
        let providers = Set(CredentialProviders.all.map(\.id))
        selectedCredentialProviders = Set(preset.credentialProviders).intersection(providers)
        for (appID, token) in preset.matchChoices where manifest.applications.contains(where: { $0.id == appID }) {
            decideMatch(appID: appID, token: token.isEmpty ? nil : token)
        }
        // Own folders and installers are read again from where they are now.
        let known = Set(manifest.applicationData.filter(\.isPersonal).map(\.displayPath))
        let folders = preset.personalFolders.filter { !known.contains($0) }.map { layout.resolve(displayPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        addPersonalFolders(folders)
        restoreOwnInstallers(preset.ownInstallers)
        // Files the user had included on purpose; applied again once their folders are scanned (also after own folders load).
        includedOnRequest = Set(preset.includedOnRequest ?? [])
        reapplySensitiveIncludes()
        if let destination = preset.destination.map({ layout.resolve(displayPath: $0) }), FileManager.default.fileExists(atPath: destination.path) {
            backupDestination = destination
        }
        savedSelectionFound = nil
        appLog.info("Applied a saved selection from \(preset.savedAt)", component: .inventory)
    }

    func saveSelection() {
        let preset = currentSelectionPreset()
        if services.simulationRoot != nil, defaults.bool(forKey: "stagingSkipPanels"), let folder = backupDestination {
            writeSelection(preset, to: folder.appendingPathComponent(BackupSelectionPreset.fileName))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupSelectionPreset.fileName
        panel.allowedContentTypes = [.json]
        panel.directoryURL = backupDestination ?? lastFolder(forSelection: true)
        panel.message = l.t("selection.save.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeSelection(preset, to: url)
    }

    private func writeSelection(_ preset: BackupSelectionPreset, to url: URL) {
        do {
            try preset.write(to: url)
            notice = ProblemInfo(title: l.t("selection.saved.title"), message: l.t("selection.saved.message", services.layout.displayPath(url)), detail: nil)
        } catch {
            notice = ProblemInfo(title: l.t("selection.failed.title"), message: l.t("selection.failed.message"), detail: services.layout.redact(String(describing: error)))
        }
    }

    func loadSelection() {
        let url: URL
        if services.simulationRoot != nil, defaults.bool(forKey: "stagingSkipPanels"), let folder = backupDestination {
            url = folder.appendingPathComponent(BackupSelectionPreset.fileName)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.json]
            panel.directoryURL = backupDestination ?? lastFolder(forSelection: true)
            panel.message = l.t("selection.load.message")
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        do {
            applySelection(try BackupSelectionPreset.read(from: url))
        } catch BackupSelectionPreset.PresetError.newerFormat {
            notice = ProblemInfo(title: l.t("selection.failed.title"), message: l.t("selection.failed.newer"), detail: nil)
        } catch {
            notice = ProblemInfo(title: l.t("selection.failed.title"), message: l.t("selection.failed.unreadable"), detail: nil)
        }
    }

    private func lastFolder(forSelection: Bool) -> URL? {
        defaults.string(forKey: "lastBackupParent").map { URL(fileURLWithPath: $0) }
    }

    /// The user's installers from a saved selection, inspected again (they may have changed or moved).
    func restoreOwnInstallers(_ saved: [String: [BackupSelectionPreset.OwnInstaller]]) {
        let layout = services.layout
        for (appID, entries) in saved where inventory?.manifest.applications.contains(where: { $0.id == appID }) == true {
            let existing = Set((ownInstallerFiles[appID] ?? []).map { ($0.source ?? $0.url).path })
            let wanted = entries.map { (layout.resolve(displayPath: $0.path), $0) }
                .filter { FileManager.default.fileExists(atPath: $0.0.path) && !existing.contains($0.0.path) }
            guard !wanted.isEmpty else { continue }
            let saved = Dictionary(wanted.map { ($0.0.path, $0.1) }, uniquingKeysWith: { first, _ in first })
            inspectOwnInstallers(wanted.map(\.0)) { [weak self] selections in
                guard let self else { return }
                for selection in selections {
                    guard case .success(let inspected) = selection.result else {
                        if case .failure(let error) = selection.result { self.ownInstallerProblems[appID, default: []].append(self.problem(selection.source, error)) }
                        continue
                    }
                    var archive = inspected.archive
                    let entry = saved[selection.source.path]
                    archive.containsLicence = entry?.licence ?? false
                    // A confirmation counts only for the very file it was given for.
                    archive.userApprovedUnverified = entry?.approvedUnverified == true && entry?.sha256 == archive.sha256
                    self.ownInstallerFiles[appID, default: []].append(OwnInstallerFile(archive: archive, url: inspected.file,
                                                                                      include: entry?.include ?? true, source: selection.source))
                }
                self.applyOwnInstallers(appID)
            }
        }
    }
}

extension AppModel {
    /// What the backup will roughly take: the selected files plus a margin (quick, for the selection screen).
    var estimatedBackupSize: Int64 {
        guard let inventory else { return 0 }
        let fonts = inventory.fonts.filter { !excludedBackupFiles.contains(InventoryResult.selectionID($0.record, kind: .font)) }
        let profiles = inventory.colorProfiles.filter { !excludedBackupFiles.contains(InventoryResult.selectionID($0.record, kind: .colorProfile)) }
        let data = inventory.manifest.applicationData.filter { !excludedApplicationData.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalSize }
        let python = inventory.manifest.python.environments.filter { selectedPythonEnvironments.contains($0.id) }
            .flatMap(\.projectFiles).reduce(Int64(0)) { $0 + $1.size }
        let installers = ownInstallerFiles.values.joined().filter(\.include).reduce(Int64(0)) { $0 + $1.archive.size }
        let files = (fonts + profiles).reduce(Int64(0)) { $0 + $1.record.size } + data + python + installers
        return files + files / 100 + 1_000_000
    }

    struct DestinationInfo {
        var path: String
        var volumeName: String?
        var isExternal: Bool
        var available: Int64?
    }

    var destinationInfo: DestinationInfo? {
        guard let folder = backupDestination, FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let values = try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                                          .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        let available = important ?? values?.volumeAvailableCapacity.map(Int64.init)
        let external = values?.volumeIsInternal == false || values?.volumeIsRemovable == true
        return DestinationInfo(path: services.layout.displayPath(folder), volumeName: values?.volumeLocalizedName, isExternal: external, available: available)
    }
}
