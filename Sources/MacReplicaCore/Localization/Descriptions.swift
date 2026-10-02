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
        case .cancelled: return t("skip.cancelled")
        }
    }

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
        case .pythonPackagesNeedManualSetup(let names): return t("note.pythonManualPackages", names.joined(separator: ", "))
        case .pythonPackagesUpdated(let count): return p("note.pythonPackagesUpdated", count)
        case .pythonEnvironmentReused: return t("note.pythonEnvironmentReused")
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

    public func predictionText(_ prediction: Prediction, kind: RestoreItemKind) -> String {
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
        case .conflict(let resolution):
            switch resolution {
            case .keepExisting: return t("prediction.conflictKeep")
            case .replace: return t("prediction.conflictReplace")
            case .skip: return t("prediction.conflictSkip")
            }
        case .willSkip(let reason): return skipText(reason)
        case .backupFileDamaged: return t("prediction.damaged")
        case .dependsOnEarlierStep: return t("prediction.afterPrerequisite")
        case .willRecreateEnvironment: return t("prediction.recreateEnvironment")
        case .willCompleteEnvironment: return t("prediction.completeEnvironment")
        case .environmentConflict: return t("prediction.environmentConflict")
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
