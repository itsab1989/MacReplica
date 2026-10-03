import Foundation

/// Localized, user-facing descriptions of model values. Shared by the app and the
/// generated reports so that both always use the same terminology.
extension Localizer {
    public func sourceText(_ source: InstallSource) -> String {
        switch source {
        case .homebrewCask: return t("source.homebrew")
        case .appStore: return t("source.appStore")
        case .package: return t("source.package")
        case .downloaded(let agent): return t("source.downloaded", agent)
        case .unknown: return t("source.unknown")
        }
    }

    public func methodText(_ method: RestoreMethod) -> String {
        switch method {
        case .homebrewCask: return t("method.homebrewCask")
        case .homebrewFormula: return t("method.homebrewFormula")
        case .appStore: return t("method.appStore")
        case .officialDownload: return t("method.officialDownload")
        case .manual: return t("method.manual")
        }
    }

    public func categoryText(_ category: RestoreCategory) -> String {
        switch category {
        case .homebrew: return t("category.homebrew")
        case .appStore: return t("category.appStore")
        case .officialDownload: return t("category.officialDownload")
        case .manual: return t("category.manual")
        }
    }

    public func componentText(_ component: RestoreComponent) -> String {
        switch component {
        case .applications: return t("component.applications")
        case .brewFormulae: return t("component.brewFormulae")
        case .brewCasks: return t("component.brewCasks")
        case .appStore: return t("component.appStore")
        case .python: return t("component.python")
        case .developerTools: return t("component.developerTools")
        case .packageManagers: return t("component.packageManagers")
        case .developerSettings: return t("component.developerSettings")
        case .applicationData: return t("component.applicationData")
        case .credentials: return t("component.credentials")
        case .fonts: return t("component.fonts")
        case .colorProfiles: return t("component.colorProfiles")
        }
    }

    public func componentHint(_ component: RestoreComponent) -> String {
        switch component {
        case .applications: return t("component.applications.hint")
        case .brewFormulae: return t("component.brewFormulae.hint")
        case .brewCasks: return t("component.brewCasks.hint")
        case .appStore: return t("component.appStore.hint")
        case .python: return t("component.python.hint")
        case .developerTools: return t("component.developerTools.hint")
        case .packageManagers: return t("component.packageManagers.hint")
        case .developerSettings: return t("component.developerSettings.hint")
        case .applicationData: return t("component.applicationData.hint")
        case .credentials: return t("component.credentials.hint")
        case .fonts: return t("component.fonts.hint")
        case .colorProfiles: return t("component.colorProfiles.hint")
        }
    }

    /// The method shown next to a step on the progress screen, e.g. "Homebrew Cask".
    public func itemMethodText(_ kind: RestoreItemKind) -> String {
        switch kind {
        case .commandLineTools: return t("kind.commandLineTools")
        case .homebrew: return t("kind.homebrew")
        case .tap: return t("kind.tap")
        case .masTool: return t("kind.masTool")
        case .formula: return t("method.homebrewFormula")
        case .cask: return t("method.homebrewCask")
        case .appStoreApp: return t("method.appStore")
        case .font: return t("kind.font")
        case .colorProfile: return t("kind.colorProfile")
        case .pythonEnvironment: return t("kind.pythonEnvironment")
        case .applicationData: return t("kind.applicationData")
        case .gitConfiguration: return t("kind.gitConfiguration")
        case .credential: return t("kind.credential")
        case .toolchainStep: return t("kind.toolchainStep")
        case .manualApp: return t("kind.manualApp")
        case .displayProfile: return t("kind.displayProfile")
        }
    }

    public func activityText(_ activity: RestoreActivity) -> String {
        switch activity {
        case .checking: return t("activity.checking")
        case .downloading: return t("activity.downloading")
        case .installing: return t("activity.installing")
        case .copying: return t("activity.copying")
        case .verifying: return t("activity.verifying")
        case .waitingForCommandLineTools: return t("activity.waitingForCommandLineTools")
        case .waitingForAdmin: return t("activity.waitingForAdmin")
        case .creatingEnvironment: return t("activity.creatingEnvironment")
        case .installingPackages: return t("activity.installingPackages")
        }
    }

    public func failureTitle(_ category: FailureCategory) -> String { t("failure.\(category.rawValue).title") }
    public func failureExplanation(_ category: FailureCategory) -> String { t("failure.\(category.rawValue).explanation") }

    public func skipText(_ reason: SkipReason) -> String {
        switch reason {
        case .keptExisting: return t("skip.keptExisting")
        case .userSkipped: return t("skip.userSkipped")
        case .dependencyFailed(let title): return t("skip.dependencyFailed", title)
        case .tapNotEnabled(let tap): return t("skip.tapNotEnabled", tap)
        case .incompatibleArchitecture(let required):
            return t("skip.incompatibleArchitecture", required.map(architectureText).joined(separator: ", "))
        case .projectFolderMissing(let path): return t("skip.projectFolderMissing", path)
        case .passphraseNotProvided: return t("skip.passphraseNotProvided")
        case .fileNotSupported: return t("skip.fileNotSupported")
        case .displaySpecificProfile: return t("skip.displaySpecificProfile")
        case .cancelled: return t("skip.cancelled")
        case .manualStepRequired: return t("skip.manualStepRequired")
        case .waitingForManualStep(let title): return t("skip.waitingForManualStep", title)
        case .postponedByUser: return t("skip.postponedByUser")
        case .cancelledByUser: return t("skip.cancelledByUser")
        case .displayNotConnected(let name): return t("skip.displayNotConnected", name)
        case .displayOfAnotherMac: return t("skip.displayOfAnotherMac")
        case .profileNotAvailable: return t("skip.profileNotAvailable")
        }
    }

    public func ecosystemText(_ ecosystem: Ecosystem) -> String { t("ecosystem.\(ecosystem.rawValue)") }

    public func channelText(_ channel: ReleaseChannel) -> String { t("channel.\(channel.rawValue)") }

    public func trustText(_ trust: DownloadOffer.Trust) -> String { t("trust.\(trust.rawValue)") }

    /// "Vendor update feed: Nightly 130.0a2 (recommended)".
    public func offerText(_ offer: DownloadOffer) -> String {
        let version = offer.version ?? ""
        let text: String
        switch offer.kind {
        case .vendorFeed: text = t("offer.vendorFeed", offer.channel.map(channelText) ?? channelText(.stable), version)
        case .homebrewCask: text = t("offer.homebrewCask", offer.host, version)
        case .vendorWebsite: text = t("offer.website", offer.host)
        case .appStore: text = t("offer.appStore")
        }
        return offer.recommended ? t("offer.recommended", text) : text
    }

    public func guidedStepText(_ step: GuidedStep) -> String {
        switch step {
        case .finishInstaller: return t("guidedStep.finishInstaller")
        case .installFromDiskImage: return t("guidedStep.installFromDiskImage")
        case .installFromWebsite: return t("guidedStep.installFromWebsite")
        case .installFromAppStore: return t("guidedStep.installFromAppStore")
        case .installYourself: return t("guidedStep.installYourself")
        case .runCommand(let command): return t("guidedStep.runCommand", command)
        }
    }

    public func downloadErrorText(_ error: DownloadError) -> String {
        switch error {
        case .network, .httpStatus, .tooLarge: return t("downloadError.network")
        case .cancelled: return t("skip.cancelledByUser")
        case .incompatibleArchitecture: return t("downloadError.architecture")
        case .requiresNewerMacOS(let version): return t("downloadError.macOS", version)
        case .alreadyInstalled: return t("downloadError.alreadyInstalled")
        case .licenseAgreement: return t("downloadError.license")
        default: return t("downloadError.notTrusted")
        }
    }

    public func supportLevelText(_ level: SupportLevel) -> String { t("supportLevel.\(level.rawValue)") }

    public func architectureText(_ architecture: CPUArchitecture) -> String {
        switch architecture {
        case .arm64: return t("architecture.appleSilicon")
        case .x86_64: return t("architecture.intel")
        case .unknown: return t("architecture.unknown")
        }
    }

    public func noteText(_ note: ResultNote) -> String {
        switch note {
        case .newerVersionInstalled(let original, let installed): return t("note.newerVersion", installed, original)
        case .requiresRosetta: return t("note.requiresRosetta")
        case .existingFileMovedAside(let path): return t("note.movedAside", path)
        case .identicalFileExists: return t("note.identical")
        case .equivalentFileInstalled: return t("note.equivalentFile")
        case .providedByMacOS: return t("note.providedByMacOS")
        case .installedUnderNewName(let name): return t("note.installedUnderNewName", name)
        case .pythonPackagesNeedManualSetup(let names): return t("note.pythonManualPackages", names.joined(separator: ", "))
        case .pythonPackagesUpdated(let count): return p("note.pythonPackagesUpdated", count)
        case .pythonEnvironmentReused: return t("note.pythonEnvironmentReused")
        case .pythonLockFileUsed(let file): return t("note.pythonLockFileUsed", file)
        case .pythonSettingsToApply(let count): return p("note.pythonSettings", count)
        case .applicationDataCopied(let copied, let identical, let kept): return t("note.applicationData", copied, identical, kept)
        case .applicationVersionDiffers(let original): return t("note.applicationVersionDiffers", original)
        }
    }

    public func outcomeText(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .succeeded: return t("outcome.succeeded")
        case .alreadyPresent: return t("outcome.alreadyPresent")
        case .skipped(let reason): return skipText(reason)
        case .failed(let failure): return failureTitle(failure.category)
        }
    }

    /// The name shown for a restore step: localized for application data, otherwise the item's own name.
    public func itemTitle(_ item: RestoreItem) -> String {
        if let file = item.file { return fileTitle(file) }
        guard let profile = item.applicationData?.profile else { return item.title }
        let version = profile.appVersion.flatMap { $0 == profile.appName ? nil : " (\($0))" } ?? ""
        return profileText(profile) + version
    }

    /// "Example Sans Bold" for a font, the profile description for an ICC profile, else the file name.
    public func fileTitle(_ file: FileRecord) -> String {
        if let name = file.font?.displayName, !name.isEmpty { return name }
        if let description = file.profile?.description, !description.isEmpty { return description }
        return file.fileName
    }

    public func fileLocationText(_ location: FileLocation) -> String { t("fileLocation.\(location.rawValue)") }

    public func fileOriginText(_ origin: FileOrigin) -> String { t("fileOrigin.\(origin.rawValue)") }

    /// A short status such as "Already installed" or "Different version on this Mac".
    public func fileStatusText(_ assessment: FileAssessment, kind: RestoreItemKind) -> String {
        let suffix = kind == .font ? "font" : "profile"
        switch assessment.status {
        case .ready: return t("fileStatus.ready")
        case .identical: return t("fileStatus.identical")
        case .equivalent: return t("fileStatus.equivalent.\(suffix)")
        case .providedByMacOS: return t("fileStatus.providedByMacOS")
        case .differentVersion: return t("fileStatus.differentVersion")
        case .differentFile: return t("fileStatus.differentFile.\(suffix)")
        case .incompatible: return t("fileStatus.incompatible")
        case .obsoleteAppleProfile: return t("fileStatus.obsoleteAppleProfile")
        case .displayProfile: return t("fileStatus.displayProfile")
        case .legacyFormat: return t("fileStatus.legacyFormat")
        }
    }

    /// One or two sentences explaining the status and what MacReplica will do by default.
    public func fileStatusDetail(_ assessment: FileAssessment, kind: RestoreItemKind) -> String {
        let suffix = kind == .font ? "font" : "profile"
        let location = assessment.existingLocation.map(fileLocationText) ?? ""
        let name = assessment.existingFileName ?? ""
        switch assessment.status {
        case .ready: return t("fileDetail.ready")
        case .identical: return t("fileDetail.identical", name, location)
        case .equivalent: return t("fileDetail.equivalent.\(suffix)", name, location)
        case .providedByMacOS: return t("fileDetail.providedByMacOS.\(suffix)")
        case .differentVersion where kind == .colorProfile:
            return t("fileDetail.differentVersion.profile", name, location)
        case .differentVersion:
            return t("fileDetail.differentVersion", assessment.installedVersion ?? "?", assessment.backupVersion ?? "?", location)
        case .differentFile: return t("fileDetail.differentFile", name, location)
        case .incompatible: return t("fileDetail.incompatible.\(suffix)")
        case .obsoleteAppleProfile: return t("fileDetail.obsoleteAppleProfile")
        case .displayProfile: return t("fileDetail.displayProfile")
        case .legacyFormat: return t("fileDetail.legacyFormat")
        }
    }

    /// "Display", "Printer", "Input device" … for an ICC profile class signature.
    public func profileClassText(_ signature: String) -> String {
        let known = ["mntr", "prtr", "scnr", "spac", "link", "abst", "nmcl"]
        return known.contains(signature) ? t("profileClass.\(signature)") : signature
    }

    public func fileAdvisoryText(_ advisory: FileAssessment.Advisory) -> String { t("fileAdvisory.\(advisory.rawValue)") }

    public func conflictChoiceText(_ resolution: ConflictResolution, kind: RestoreItemKind) -> String {
        switch resolution {
        case .keepExisting: return t("conflict.keep")
        case .replace: return t("conflict.replace")
        case .skip: return t("conflict.skip")
        case .keepBoth: return t("conflict.keepBoth")
        }
    }

    public func predictionText(_ prediction: Prediction, kind: RestoreItemKind) -> String {
        if prediction == .dependsOnEarlierStep, kind == .pythonEnvironment { return t("prediction.recreateEnvironment") }
        if prediction == .dependsOnEarlierStep, kind == .toolchainStep { return t("prediction.afterToolchain") }
        switch prediction {
        case .willInstall:
            switch kind {
            case .commandLineTools: return t("prediction.installCommandLineTools")
            case .homebrew: return t("prediction.installHomebrew")
            case .tap: return t("prediction.addTap")
            default: return t("prediction.install", itemMethodText(kind))
            }
        case .willCopy: return t("prediction.copy")
        case .alreadyPresent(let version):
            if let version { return t("prediction.alreadyPresentVersion", version) }
            return t("prediction.alreadyPresent")
        case .identicalFileExists: return t("prediction.identical")
        case .equivalentFileExists: return t("prediction.equivalent")
        case .keepsMacOSVersion: return t("prediction.keepsMacOSVersion")
        case .conflict(let resolution):
            switch resolution {
            case .keepExisting: return t("prediction.conflictKeep")
            case .replace: return t("prediction.conflictReplace")
            case .skip: return t("prediction.conflictSkip")
            case .keepBoth: return t("prediction.conflictKeepBoth")
            }
        case .willSkip(let reason): return skipText(reason)
        case .backupFileDamaged: return t("prediction.damaged")
        case .dependsOnEarlierStep: return t("prediction.afterPrerequisite")
        case .willRecreateEnvironment: return t("prediction.recreateEnvironment")
        case .willCompleteEnvironment: return t("prediction.completeEnvironment")
        case .environmentConflict: return t("prediction.environmentConflict")
        case .manualStep: return kind == .appStoreApp ? t("prediction.manualAppStore") : t("prediction.manualStep")
        case .checkedWhenRestoring: return t("prediction.checkedWhenRestoring")
        }
    }

    public func verificationIssueText(_ issue: VerificationIssue) -> String {
        switch issue {
        case .manifestUnreadable: return t("verify.issue.manifestUnreadable")
        case .unsupportedVersion(let found, let supported): return t("verify.issue.unsupportedVersion", found, supported)
        case .checksumMissing: return t("verify.issue.checksumMissing")
        case .checksumMismatch: return t("verify.issue.checksumMismatch")
        case .unsafePath(let path): return t("verify.issue.unsafePath", path)
        case .fileMissing(let path): return t("verify.issue.fileMissing", path)
        case .sizeMismatch(let path): return t("verify.issue.sizeMismatch", path)
        case .hashMismatch(let path): return t("verify.issue.hashMismatch", path)
        }
    }

    public func inventoryWarningText(_ warning: InventoryWarning) -> String {
        switch warning {
        case .homebrewNotInstalled: return t("inventory.warning.homebrewNotInstalled")
        case .homebrewBroken: return t("inventory.warning.homebrewBroken")
        case .homebrewListFailed: return t("inventory.warning.homebrewListFailed")
        case .masNotInstalled: return t("inventory.warning.masNotInstalled")
        case .masListFailed: return t("inventory.warning.masListFailed")
        case .catalogUnavailable: return t("inventory.warning.catalogUnavailable")
        }
    }

    public func pythonSourceText(_ source: PythonSource) -> String {
        switch source {
        case .homebrew: return t("python.source.homebrew")
        case .pyenv: return t("python.source.pyenv")
        case .pythonOrg: return t("python.source.pythonOrg")
        case .system: return t("python.source.system")
        case .unknown: return t("source.unknown")
        }
    }

    public func accessStatusText(_ status: AccessStatus) -> String { t("access.\(status.rawValue)") }
    public func accessAreaText(_ area: AccessArea) -> String { t("access.area.\(area.rawValue)") }

    /// "Adobe Photoshop – Actions" for a folder suggested by an application data profile.
    public func profileText(_ profile: AppDataProfileReference) -> String {
        t("appData.profileName", profile.appName, t("appData.category.\(profile.category)"))
    }

    public func backupIssueText(_ reason: BackupIssue.Reason) -> String { t("backupIssue.\(reason.rawValue)") }

    public func manualHint(for app: AppRecord) -> String {
        if app.source == .appStore || app.restoreMethod.category == .appStore { return t("manual.hint.appStore") }
        if !app.candidates.isEmpty { return t("manual.hint.candidates", app.candidates.map(\.token).joined(separator: ", ")) }
        if case .officialDownload = app.restoreMethod { return t("manual.hint.officialDownload") }
        return t("manual.hint.manual")
    }
}

/// Counts shown on the inventory summary and in the report.
public struct InventoryCounts: Equatable, Sendable {
    public var applications: Int
    public var homebrew: Int
    public var appStore: Int
    public var officialDownload: Int
    public var manual: Int
    public var needsDecision: Int
    public var formulae: Int
    public var casks: Int
    public var fonts: Int
    public var colorProfiles: Int

    public init(_ manifest: Manifest) {
        let apps = manifest.applications
        applications = apps.count
        homebrew = apps.filter { $0.restoreMethod.category == .homebrew }.count
        appStore = apps.filter { $0.restoreMethod.category == .appStore }.count
        officialDownload = apps.filter { $0.restoreMethod.category == .officialDownload }.count
        manual = apps.filter { $0.restoreMethod.category == .manual }.count
        needsDecision = apps.filter(\.needsMatchDecision).count
        formulae = manifest.brewFormulae.filter(\.installedOnRequest).count
        casks = manifest.brewCasks.count
        fonts = manifest.fonts.count
        colorProfiles = manifest.iccProfiles.count
    }
}
