import Foundation

/// What the user sees for one of their own installers: what it is, what is inside, whether MacReplica will use it
/// and what happens with it on the new Mac. Shared by the app and the reports.
public struct InstallerDescription: Equatable, Sendable {
    public enum Style: Sendable { case ok, attention, blocked }
    /// "Disk image · DisplayCAL 3.9.19 and 7 more apps · Intel · not signed with a Developer ID"
    public var summary: String
    /// Whether it will be used, and why (not).
    public var status: String
    /// What MacReplica does with it on the new Mac (nil when it is not used).
    public var nextAction: String?
    public var style: Style
    /// The user can confirm it as an unverified installer.
    public var canApproveUnverified: Bool
}

extension Localizer {
    public func installerKindText(_ kind: InstallerArchive.Kind) -> String { t("ownInstaller.kind.\(kind.rawValue)") }

    public func architecturesText(_ architectures: [CPUArchitecture]) -> String? {
        let known = architectures.filter { $0 != .unknown }
        if Set(known) == [.arm64, .x86_64] { return t("architecture.universal") }
        return known.first.map(architectureText)
    }

    public func installerDescription(_ archive: InstallerArchive, for app: AppRecord) -> InstallerDescription {
        var parts = [installerKindText(archive.kind)]
        if archive.hasLicenseAgreement {
            parts.append(t("ownInstaller.contents.notInspected"))
        } else if let main = InstallerArchiveInspector.mainApp(archive.containedApps) {
            let name = [main.name, main.version].compactMap { $0 }.joined(separator: " ")
            parts.append(archive.containedApps.count > 1 ? p("ownInstaller.contents.suite", archive.containedApps.count - 1, name) : t("ownInstaller.contents.app", name))
        } else if archive.containsPackage, archive.kind != .pkg {
            parts.append(t("ownInstaller.contents.package"))
        }
        if let architectures = architecturesText(archive.architectures) { parts.append(architectures) }
        parts.append(archive.trustedSignature ? (archive.signer ?? archive.teamIdentifier.map { t("ownInstaller.team", $0) } ?? t("ownInstaller.signed"))
                                              : t("ownInstaller.notSigned"))
        let summary = parts.joined(separator: " · ")

        switch archive.usability(for: app) {
        case .verified:
            return InstallerDescription(summary: summary, status: t("ownInstaller.status.verified"), nextAction: nextAction(archive, unverified: false),
                                        style: .ok, canApproveUnverified: false)
        case .unverified(let reason):
            let why = t(reason == .notSigned ? "ownInstaller.status.unverified.notSigned" : "ownInstaller.status.unverified.notInspected")
            if archive.userApprovedUnverified {
                return InstallerDescription(summary: summary, status: why + " " + t("ownInstaller.status.approved"),
                                            nextAction: nextAction(archive, unverified: true), style: .attention, canApproveUnverified: true)
            }
            return InstallerDescription(summary: summary, status: why + " " + t("ownInstaller.status.notApproved"), nextAction: nil,
                                        style: .attention, canApproveUnverified: true)
        case .otherDeveloper(let signer):
            return InstallerDescription(summary: summary, status: t("ownInstaller.status.otherDeveloper", signer ?? "–"), nextAction: nil,
                                        style: .blocked, canApproveUnverified: false)
        case .differentApp(let identifier):
            return InstallerDescription(summary: summary, status: t("ownInstaller.status.differentApp", identifier), nextAction: nil,
                                        style: .blocked, canApproveUnverified: false)
        }
    }

    func nextAction(_ archive: InstallerArchive, unverified: Bool) -> String {
        if archive.hasLicenseAgreement { return t("ownInstaller.next.licence") }
        if !archive.containedApps.isEmpty {
            let base = t(archive.containedApps.count > 1 ? "ownInstaller.next.suite" : "ownInstaller.next.app")
            return unverified ? base + " " + t("ownInstaller.next.gatekeeper") : base
        }
        return t(unverified ? "ownInstaller.next.packageUnverified" : "ownInstaller.next.package")
    }

    public func installerProblemText(_ error: InstallerInspectionError) -> String {
        switch error {
        case .unsupportedType: return t("ownInstaller.problem.unsupported")
        case .unreadable: return t("ownInstaller.problem.unreadable")
        case .damaged: return t("ownInstaller.problem.damaged")
        case .nothingInside: return t("ownInstaller.problem.nothingInside")
        case .licenseAgreement: return t("ownInstaller.contents.notInspected")
        }
    }
}

/// Texts for files left out of a backup and for how complete a backup is.
extension Localizer {
    public func sensitiveKindText(_ kind: SensitiveKind) -> String { t("sensitive.kind.\(kind.rawValue)") }
    public func sensitiveAdvice(_ kind: SensitiveKind) -> String { t("sensitive.advice.\(kind.rawValue)") }
    public func confidenceText(_ confidence: ClassificationConfidence) -> String { t("sensitive.confidence.\(confidence.rawValue)") }

    /// "Looks like: encrypted KeePass database (KDBX 4.1) · recognised by its file format"
    public func sensitiveDescription(_ issue: BackupIssue, header: KeePassHeader? = nil) -> String {
        guard let classification = issue.sensitive else { return t("backupIssue.refusedSensitive") }
        var kind = sensitiveKindText(classification.kind)
        if let header { kind += " (\(header.format))" }
        return t("sensitive.looksLike", kind) + " · " + confidenceText(classification.confidence)
    }

    /// Why the file was left out and what the user can do.
    public func sensitiveExplanation(_ issue: BackupIssue) -> String {
        var parts: [String] = []
        if issue.detail == .rememberedByApp { parts.append(t("sensitive.rememberedByApp")) }
        parts.append(issue.sensitive.map { sensitiveAdvice($0.kind) } ?? t("sensitive.advice.nameSuggestsSecret"))
        return parts.joined(separator: " ")
    }

    public func completenessTitle(_ manifest: Manifest) -> String {
        switch manifest.completeness {
        case .complete: return t("completeness.complete")
        case .completeWithIntentionalExclusions: return p("completeness.withExclusions", manifest.excludedSensitiveFiles.count)
        case .partial: return p("completeness.partial", manifest.backupGaps.count)
        }
    }

    public func completenessMessage(_ manifest: Manifest) -> String {
        switch manifest.completeness {
        case .complete: return t("completeness.complete.message")
        case .completeWithIntentionalExclusions: return t("completeness.withExclusions.message")
        case .partial: return t("completeness.partial.message")
        }
    }
}

/// Texts about the copy of MacReplica in a backup.
extension Localizer {
    /// "MacReplica 1.0.5 is in this backup (Apple silicon and Intel)."
    public func bootstrapSummary(_ app: BootstrapAppRecord) -> String {
        let processors = architecturesText(app.architectures) ?? t("architecture.unknown")
        return t("bootstrap.summary", app.version, processors) + (app.isUniversal ? "" : " " + t("bootstrap.notUniversal", processors))
    }

    /// The first lines of the backup's README.txt.
    public func bootstrapReadme(_ app: BootstrapAppRecord) -> String {
        bootstrapSummary(app) + "\n" + t("bootstrap.readme", app.path, MacReplicaLinks.releases.absoluteString)
    }
}

/// Notes about how an app relates to Homebrew and to other apps.
extension Localizer {
    /// Why Homebrew cannot reinstall the app, and what MacReplica does instead.
    public func homebrewNoteText(_ note: HomebrewNote) -> String {
        let reason = note.availability.reason.map { has("cask.reason.\($0)") ? t("cask.reason.\($0)") : $0 }
        switch note.availability.state {
        case .removed:
            return t("cask.removed", note.token)
        case .disabled:
            let date = note.availability.date ?? "–"
            return t("cask.disabled", note.token, date, reason ?? t("cask.reason.unknown"))
        case .deprecated, .available:
            return t("cask.deprecated", note.token)
        }
    }

    /// For Cakebrew and other front ends: restoring the app does not restore the package manager or its packages.
    public func frontEndText(_ frontEnd: PackageManagerFrontEnd, manifest: Manifest) -> String {
        guard manifest.homebrew != nil else { return t("frontEnd.homebrew.missing") }
        let packages = manifest.brewFormulae.filter(\.installedOnRequest).count + manifest.brewCasks.count
        return p("frontEnd.homebrew", packages)
    }

    public func companionsText(_ names: [String]) -> String { t("companions.includes", names.joined(separator: ", ")) }
}

/// Which version a source installs compared with the old Mac.
extension Localizer {
    /// "Installs 2.5 – newer than the 2.4 you had", "Installs 2.4 – the same version as before" …; nil if unknown.
    public func installedVersionText(_ offer: DownloadOffer, original: String?) -> String? {
        guard let version = offer.version, !version.isEmpty else { return nil }
        guard let original, !original.isEmpty else { return t("version.installs", version) }
        switch VersionComparison.compare(version, original) {
        case .orderedSame: return t("version.same", version)
        case .orderedDescending: return t("version.newer", version, original)
        case .orderedAscending: return t("version.older", version, original)
        }
    }
}

extension Localizer {
    /// A translated name for generic entries (“Passwords in the keychain”); product names stay as they are.
    public func guidanceName(_ record: GuidanceRecord) -> String {
        has("guidance.name.\(record.id)") ? t("guidance.name.\(record.id)") : record.currentName
    }
}

/// Printers and scanner drivers: what was found on the old Mac and what to do on the new one.
extension Localizer {
    public func printerSummary(_ printer: PrinterRecord) -> String {
        var parts = [printer.model ?? printer.queue]
        if let connection = printer.connection { parts.append(t("printer.connection.\(has("printer.connection.\(connection)") ? connection : "other")")) }
        parts.append(t("printer.driver.\(printer.driver.rawValue)", printer.manufacturer ?? "–"))
        return parts.joined(separator: " · ")
    }

    /// The guided step on the new Mac.
    public func printerInstruction(_ item: RestoreItem) -> String? {
        if let scanner = item.scannerDriver {
            return t("printer.scanner.instruction", scanner.name, scanner.version ?? "–")
        }
        guard let printer = item.printer else { return nil }
        let name = printer.model ?? printer.queue
        var text: String
        switch printer.driver {
        case .driverless: text = t("printer.instruction.driverless", name)
        case .vendor: text = t("printer.instruction.vendor", printer.manufacturer ?? "–", name, printer.vendorDriverFolders.joined(separator: ", "))
        case .builtIn, .unknown: text = t("printer.instruction.other", name)
        }
        if let uri = printer.deviceURI { text += " " + t("printer.instruction.uri", uri) }
        return text + " " + t("printer.instruction.notTested")
    }
}
