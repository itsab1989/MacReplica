import MacReplicaCore
import SwiftUI

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        ScreenLayout(title: l.t("scan.title"), subtitle: l.t("scan.subtitle")) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: model.inventoryProgress.fraction)
                    .accessibilityIdentifier("scan.progress")
                Text(l.t("scan.phase.\(model.inventoryProgress.phase.rawValue)"))
                    .font(.headline)
                Text(model.inventoryProgress.detail ?? " ")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(l.t("scan.readOnly"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
        } buttons: {
            Button(l.t("common.cancel")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

struct InventoryResultsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showApps = false
    @ViewState private var showNotInBackup = true

    var body: some View {
        let l = model.l
        let manifest = model.inventory?.manifest
        let counts = manifest.map(InventoryCounts.init)
        ScreenLayout(title: l.t("results.title"), subtitle: l.p("results.subtitle", counts?.applications ?? 0)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let counts {
                        HStack(alignment: .top, spacing: 14) {
                            Card {
                                Text(l.t("results.appsHeading")).font(.headline)
                                CountRow(symbol: Symbols.category(.homebrew), color: .orange, label: l.t("category.homebrew"), value: counts.homebrew)
                                CountRow(symbol: Symbols.category(.appStore), color: .blue, label: l.t("category.appStore"), value: counts.appStore)
                                CountRow(symbol: Symbols.category(.officialDownload), color: .teal, label: l.t("category.officialDownload"), value: counts.officialDownload)
                                CountRow(symbol: Symbols.category(.manual), color: .secondary, label: l.t("category.manual"), value: counts.manual)
                            }
                            Card {
                                Text(l.t("results.moreHeading")).font(.headline)
                                CountRow(symbol: Symbols.component(.brewFormulae), color: .secondary, label: l.t("component.brewFormulae"), value: counts.formulae)
                                CountRow(symbol: Symbols.component(.brewCasks), color: .secondary, label: l.t("component.brewCasks"), value: counts.casks)
                                CountRow(symbol: Symbols.component(.fonts), color: .secondary, label: l.t("component.fonts"), value: counts.fonts)
                                CountRow(symbol: Symbols.component(.colorProfiles), color: .secondary, label: l.t("component.colorProfiles"), value: counts.colorProfiles)
                                CountRow(symbol: Symbols.component(.python), color: .secondary, label: l.t("component.python"),
                                         value: manifest?.python.environments.count ?? 0)
                                CountRow(symbol: Symbols.component(.developerTools), color: .secondary, label: l.t("component.developerTools"),
                                         value: manifest?.toolchains.filter { $0.ecosystem != .packageManagers }.count ?? 0)
                                CountRow(symbol: Symbols.component(.packageManagers), color: .secondary, label: l.t("component.packageManagers"),
                                         value: manifest?.toolchains.filter { $0.ecosystem == .packageManagers }.count ?? 0)
                            }
                        }
                    }

                    BackupSetupCard()

                    // Before the user erases this Mac: how well Homebrew supports the macOS they will set up again.
                    if let counts, counts.homebrew + counts.formulae + counts.casks > 0,
                       let notice = l.homebrewSupportNotice(macOSVersion: model.services.macOSVersion, architecture: model.services.architecture, beforeErasing: true) {
                        NoticeView(style: .warning, title: notice.title, message: notice.message)
                            .accessibilityIdentifier("homebrewSupport")
                    }

                    if let manifest = model.inventory?.manifest,
                       !manifest.backupIssues.isEmpty || !manifest.sensitiveFilesIncludedOnRequest.isEmpty {
                        DisclosureGroup(isExpanded: $showNotInBackup) {
                            NotInBackupView(manifest: manifest, editable: true, onThisMac: true).padding(.top, 6)
                        } label: {
                            LabelWithHelp(label: l.p("notInBackup.title", manifest.backupIssues.count), help: l.t("notInBackup.help"),
                                          id: "help.notInBackup", font: .headline)
                        }
                        .accessibilityElement(children: .contain).accessibilityIdentifier("results.notInBackup")
                    }

                    ForEach(Array((model.inventory?.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                        NoticeView(style: .warning, title: l.inventoryWarningText(warning))
                        if case .masNeeded(_, true) = warning {
                            HStack {
                                Spacer()
                                if model.installingMas { ProgressView().controlSize(.small); Text(l.t("inventory.mas.installing")).font(.callout) }
                                Button(l.t("inventory.mas.install")) { model.installMasAndRescan() }
                                    .disabled(model.installingMas)
                                    .accessibilityIdentifier("inventory.installMas")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        LabelWithHelp(label: l.t("ownInstaller.section.title"), help: l.t("ownInstaller.section.help"),
                                      id: "help.ownInstaller.section", font: .headline)
                        Text(l.t("ownInstaller.section.message")).foregroundStyle(.secondary).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            let count = model.ownInstallerFiles.values.reduce(0) { $0 + $1.count }
                            if count > 0 { Text(l.p("ownInstaller.section.count", count)).font(.callout) }
                            Spacer()
                            if model.inspectingInstallers {
                                ProgressView().controlSize(.small)
                                Text(l.t("ownInstaller.inspecting")).font(.caption).foregroundStyle(.secondary)
                            }
                            Button(l.t("ownInstaller.folder.choose")) { model.scanInstallerFolder() }
                                .disabled(model.inspectingInstallers)
                                .accessibilityIdentifier("ownInstaller.folder")
                        }
                        ForEach(model.ownInstallerProblems[""] ?? []) { problem in
                            InstallerProblemRow(appID: "", problem: problem)
                        }
                    }

                    // Apps with possible matches stay listed after a choice so it can be changed.
                    let undecided = (manifest?.applications ?? []).filter { !$0.candidates.isEmpty }
                    if !undecided.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(l.t("match.title")).font(.headline)
                            Text(l.t("match.message"))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(undecided) { app in
                                MatchDecisionRow(app: app)
                            }
                        }
                    }

                    FontsAndProfilesSection()
                    PythonSection()
                    DeveloperToolsSection()
                    DeveloperSettingsSection()
                    ApplicationDataSection()
                    PersonalFoldersSection()
                    PrintersSection()
                    SettingsSection()
                    CredentialsSection()
                    LocationsSection()

                    if let apps = manifest?.applications, !apps.isEmpty {
                        DisclosureGroup(isExpanded: $showApps) {
                            VStack(spacing: 0) {
                                // Companion apps (e.g. DisplayCAL's 3D LUT Maker) are listed with their main app.
                                let ids = Set(apps.map(\.id))
                                ForEach(apps.filter { $0.companionOf.map { !ids.contains($0) } ?? true }) { app in
                                    AppRow(app: app)
                                    Divider()
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            // On the label, not the group: an identifier on the group would hide those of the rows inside.
                            Text(l.t("results.showApps")).accessibilityIdentifier("results.showApps")
                        }
                        .onAppear { if model.stagingExpandLists { showApps = true } }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        } buttons: {
            Button(l.t("common.cancel")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
            Button(l.t(model.destinationInfo == nil ? "results.save" : "results.saveHere")) { model.saveBackupToDestination() }
                .keyboardShortcut(.defaultAction)
                .help(l.t("results.save.help"))
                .accessibilityIdentifier("results.save")
        }
    }
}

/// Lets the user pick one of several possible Homebrew packages for an app.
struct MatchDecisionRow: View {
    @EnvironmentObject var model: AppModel
    var app: AppRecord

    private var currentToken: String {
        switch app.restoreMethod {
        case .homebrewCask(let token), .homebrewFormula(let token): return token
        default: return ""
        }
    }

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(.medium)
                Text(app.version.map { l.t("common.version", $0) } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(l.t("match.pickerLabel"), selection: Binding(
                get: { currentToken },
                set: { model.decideMatch(appID: app.id, token: $0.isEmpty ? nil : $0) })) {
                ForEach(app.candidates, id: \.token) { candidate in
                    Text(l.t("match.candidate", candidate.name, candidate.token) + (candidate.summary.map { " – " + $0 } ?? "")).tag(candidate.token)
                }
                Divider()
                Text(l.t("match.none")).tag("")
            }
            .labelsHidden()
            .frame(maxWidth: 360)
            HelpButton(text: l.t(OfficeActivation.isOfficeApp(app) ? "match.office.help" : "match.help"), title: l.t("match.title"),
                       id: "help.match.\(app.id)")
        }
        if OfficeActivation.isOfficeApp(app) {
            Text(l.t("match.office.note")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("match.office.\(app.id)")
        }
        OwnInstallerControls(app: app)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// "Use my installer …" and the installers the user chose for an app (offline restore source). Every chosen file is
/// shown with what it is, whether it will be used and what happens with it; files that cannot be used are listed with the reason.
struct OwnInstallerControls: View {
    @EnvironmentObject var model: AppModel
    var app: AppRecord

    var body: some View {
        let l = model.l
        let current = model.inventory?.manifest.applications.first { $0.id == app.id } ?? app
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.ownInstallerFiles[app.id] ?? [], id: \.archive.id) { file in
                OwnInstallerRow(appID: app.id, app: current, file: file)
            }
            ForEach(model.ownInstallerProblems[app.id] ?? []) { problem in
                InstallerProblemRow(appID: app.id, problem: problem)
            }
            HStack(spacing: 6) {
                Spacer()
                if model.inspectingInstallers {
                    ProgressView().controlSize(.small)
                    Text(l.t("ownInstaller.inspecting")).font(.caption).foregroundStyle(.secondary)
                }
                Button(l.t("ownInstaller.add")) { model.chooseOwnInstallers(for: app.id) }
                    .controlSize(.small)
                    .disabled(model.inspectingInstallers)
                    .accessibilityIdentifier("ownInstaller.add.\(app.id)")
                HelpButton(text: l.t("ownInstaller.add.help"), title: l.t("ownInstaller.add"), id: "help.ownInstaller.add.\(app.id)")
            }
        }
    }
}

/// One installer the user chose: identity, contents, source, status and what happens on the new Mac.
struct OwnInstallerRow: View {
    @EnvironmentObject var model: AppModel
    var appID: String
    var app: AppRecord
    var file: OwnInstallerFile

    var body: some View {
        let l = model.l
        let archive = file.archive
        let description = l.installerDescription(archive, for: app)
        let color: Color = description.style == .ok ? .green : (description.style == .attention ? .orange : .red)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: description.style == .ok ? "checkmark.seal" : (description.style == .attention ? "exclamationmark.triangle" : "xmark.octagon"))
                    .foregroundStyle(color)
                Text(archive.fileName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("ownInstaller.name.\(archive.id)")
                Text(l.fileSize(archive.size)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.removeOwnInstaller(appID, archive.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help(l.t("ownInstaller.remove")).accessibilityLabel(l.t("ownInstaller.remove"))
                    .accessibilityIdentifier("ownInstaller.remove.\(archive.id)")
            }
            Group {
                Text(description.summary).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ownInstaller.summary.\(archive.id)")
                Text(l.t("ownInstaller.source", model.displayPath(file.source ?? file.url))).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(description.status).foregroundStyle(color)
                    .accessibilityIdentifier("ownInstaller.status.\(archive.id)")
                if let next = description.nextAction {
                    Text(l.t("ownInstaller.next", next)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ownInstaller.next.\(archive.id)")
                }
                if archive.contentsLimit != nil, let note = archive.inspectionNote {
                    Text(l.t("ownInstaller.details", note)).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("ownInstaller.details.\(archive.id)")
                }
                if !(file.include || archive.mustBeIncluded) {
                    Text(l.t("ownInstaller.notInBackup")).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 22)
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    Toggle(l.t("ownInstaller.include"), isOn: Binding(get: { file.include || archive.mustBeIncluded },
                                                                      set: { model.setOwnInstaller(appID, archive.id, include: $0) }))
                        .toggleStyle(.checkbox)
                        .disabled(archive.mustBeIncluded)
                        .accessibilityIdentifier("ownInstaller.include.\(archive.id)")
                    HelpButton(text: l.t(archive.mustBeIncluded ? "ownInstaller.include.helpApp" : "ownInstaller.include.help"),
                               title: l.t("ownInstaller.include"), id: "help.ownInstaller.include.\(archive.id)")
                }
                HStack(spacing: 2) {
                    Toggle(l.t("ownInstaller.licence"), isOn: Binding(get: { archive.containsLicence },
                                                                      set: { model.setOwnInstaller(appID, archive.id, licence: $0) }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("ownInstaller.licence.\(archive.id)")
                    HelpButton(text: l.t("ownInstaller.licence.help"), title: l.t("ownInstaller.licence"), id: "help.ownInstaller.licence.\(archive.id)")
                }
                if description.canApproveUnverified {
                    HStack(spacing: 2) {
                        Toggle(l.t("ownInstaller.approve"), isOn: Binding(get: { archive.userApprovedUnverified },
                                                                          set: { model.setOwnInstaller(appID, archive.id, approveUnverified: $0) }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("ownInstaller.approve.\(archive.id)")
                        HelpButton(text: l.t("ownInstaller.approve.help"), title: l.t("ownInstaller.approve"), id: "help.ownInstaller.approve.\(archive.id)")
                    }
                }
            }
            .font(.caption)
            .padding(.leading, 22)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}

/// A chosen file that cannot be used, with the reason.
struct InstallerProblemRow: View {
    @EnvironmentObject var model: AppModel
    var appID: String
    var problem: InstallerProblem

    var body: some View {
        let l = model.l
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.t("ownInstaller.problem.title", problem.fileName)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(l.installerProblemText(problem.error)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ownInstaller.problem.\(problem.fileName)")
                if let note = problem.note {
                    Text(l.t("ownInstaller.problem.details", note)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ownInstaller.problemDetails.\(problem.fileName)")
                }
                Text(problem.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(l.t("ownInstaller.problem.dismiss")) { model.dismissInstallerProblem(appID, problem.id) }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.06)))
    }
}

struct AppRow: View {
    static func needsInstaller(_ app: AppRecord) -> Bool {
        switch app.restoreMethod {
        case .manual, .officialDownload: return true
        default: return false
        }
    }

    @EnvironmentObject var model: AppModel
    var app: AppRecord

    var body: some View {
        let l = model.l
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !model.excludedApplications.contains(app.id) },
                                 set: { on in if on { model.excludedApplications.remove(app.id) } else { model.excludedApplications.insert(app.id) } })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(l.t("results.includeApp"))
            .accessibilityIdentifier("app.include.\(app.id)")
            Image(systemName: Symbols.category(app.restoreMethod.category))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name)
                    if let channel = app.channel, channel.isPrerelease { ChannelBadge(channel: channel) }
                }
                Text([app.version.map { l.t("common.version", $0) }, app.vendor].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                ForEach(app.otherCopies ?? [], id: \.path) { copy in
                    Text(l.t("apps.otherCopy", copy.path, copy.version ?? "–"))
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.middle)
                }
                AppRelationNotes(app: app)
            }
            Spacer()
            Text(l.methodText(app.restoreMethod))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        if app.candidates.isEmpty, Self.needsInstaller(app) { OwnInstallerControls(app: app).padding(.leading, 26) }
    }
}

struct SavingBackupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        ScreenLayout(title: l.t("saving.title"), subtitle: l.t("saving.subtitle")) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: model.backupProgress)
                Text(l.percent(model.backupProgress)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
        } buttons: {
            EmptyView()
        }
    }
}

/// Where the backup goes and the saved selection: chosen before anything is written.
struct BackupSetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let info = model.destinationInfo
        let needed = model.estimatedBackupSize
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("destination.heading")).font(.headline)
                Spacer()
                Button(l.t(info == nil ? "destination.choose" : "destination.change")) { model.chooseBackupDestination() }
                    .help(l.t("destination.choose.help"))
                    .accessibilityIdentifier("destination.choose")
            }
            if let info {
                HStack(spacing: 6) {
                    Image(systemName: info.isExternal ? "externaldrive" : "internaldrive").foregroundStyle(.secondary)
                    Text(info.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("destination.path")
                }
                let space = info.available.map { l.t("destination.space", l.fileSize(needed), l.fileSize($0)) } ?? l.t("destination.spaceUnknown", l.fileSize(needed))
                Text((info.volumeName.map { l.t("destination.volume", $0) + " · " } ?? "") + space)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("destination.space")
                if let available = info.available, available < needed {
                    Text(l.t("destination.notEnough")).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("destination.notEnough")
                }
            } else {
                Text(l.t("destination.none", l.fileSize(needed))).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(l.t("destination.nothingYet")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    LabelWithHelp(label: l.t("selection.heading"), help: l.t("selection.help"), id: "help.selection", font: .subheadline.weight(.semibold))
                    Text(l.t("selection.message")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(l.t("selection.load")) { model.loadSelection() }
                    .help(l.t("selection.load.help"))
                    .accessibilityIdentifier("selection.load")
                Button(l.t("selection.save")) { model.saveSelection() }
                    .help(l.t("selection.save.help"))
                    .accessibilityIdentifier("selection.save")
            }
            if let found = model.savedSelectionFound {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                    Text(l.t("selection.found", l.date(found.savedAt))).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("selection.found")
                    Spacer()
                    Button(l.t("selection.apply")) { model.applySelection(found) }
                        .accessibilityIdentifier("selection.apply")
                }
            }
        }
    }
}

/// Companion apps, why Homebrew cannot reinstall the app, and what a package-manager front end does not restore.
struct AppRelationNotes: View {
    @EnvironmentObject var model: AppModel
    var app: AppRecord
    var manifest: Manifest? = nil

    var body: some View {
        let l = model.l
        let manifest = manifest ?? model.inventory?.manifest ?? model.manifest
        let companions = (manifest?.applications ?? []).filter { $0.companionOf == app.id }.map(\.name)
        Group {
            if !companions.isEmpty {
                Text(l.companionsText(companions)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.companions.\(app.id)")
            }
            if case .homebrewCask(let token) = app.restoreMethod, let tap = BrewTapRecord.tapName(ofToken: token) {
                Text(l.t("app.fromTap", tap)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.fromTap.\(app.id)")
            }
            if let note = app.homebrewNote {
                Text(l.homebrewNoteText(note)).foregroundStyle(.orange)
                    .accessibilityIdentifier("app.homebrewNote.\(app.id)")
            }
            if OfficeActivation.isOfficeApp(app), let activation = manifest?.officeActivation {
                Text(l.t("office.activation.\(activation.rawValue)")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.office.\(app.id)")
            }
            if let frontEnd = PackageManagerFrontEnds.frontEnd(for: app), let manifest {
                Text(l.frontEndText(frontEnd, manifest: manifest)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.frontEnd.\(app.id)")
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
