import MacReplicaCore
import SwiftUI

/// "Development environments": Python interpreters and the environments to preserve.
struct PythonSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let python = model.inventory?.manifest.python ?? PythonSnapshot()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("python.section.title")).font(.headline)
                Spacer()
                Button(l.t("python.search.button")) { model.addPythonSearchFolder() }
                    .accessibilityIdentifier("python.search")
            }
            Text(l.t("python.section.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if python.isEmpty {
                Text(l.t("python.none")).foregroundStyle(.secondary)
            } else {
                Card {
                    ForEach(python.installations) { installation in
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary).frame(width: 20)
                            Text("Python \(installation.version)")
                            Text(l.pythonSourceText(installation.source)).foregroundStyle(.secondary)
                            Spacer()
                            Text(installation.architectures.map(l.architectureText).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !python.installations.isEmpty && !python.environments.isEmpty { Divider() }
                    ForEach(python.environments) { environment in
                        Toggle(isOn: Binding(
                            get: { model.selectedPythonEnvironments.contains(environment.id) },
                            set: { on in
                                if on { model.selectedPythonEnvironments.insert(environment.id) } else { model.selectedPythonEnvironments.remove(environment.id) }
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.t("python.environment", environment.name))
                                Text(l.t("python.environmentDetail", environment.pythonVersion, l.number(environment.installablePackages.count), environment.path))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if !environment.manualPackages.isEmpty {
                                    Text(l.t("python.manualPackages", environment.manualPackages.map(\.name).joined(separator: ", ")))
                                        .font(.caption).foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        if model.selectedPythonEnvironments.contains(environment.id) {
                            Toggle(isOn: Binding(
                                get: { model.preservedPythonEnvironments.contains(environment.id) },
                                set: { on in
                                    if on { model.preservedPythonEnvironments.insert(environment.id) } else { model.preservedPythonEnvironments.remove(environment.id) }
                                })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    LabelWithHelp(label: l.t("python.keepCopy"), help: l.t("python.keepCopy.help"), id: "help.python.keepCopy.\(environment.id)")
                                    Text(l.t("python.keepCopy.hint")).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.leading, 22)
                            .accessibilityIdentifier("python.keepCopy.\(environment.id)")
                        }
                    }
                    if !python.settings.isEmpty {
                        Divider()
                        Toggle(isOn: $model.includePythonSettings) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.p("python.settings", python.settings.count))
                                Text(python.settings.map(\.key).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
}

/// Application settings and customizations: detected app data (per item) and folders the user added.
/// macOS settings by category, and what is never transferred (with the reason).
struct SettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showNotTransferred = false

    var body: some View {
        let l = model.l
        let records = model.inventory?.manifest.settings ?? []
        VStack(alignment: .leading, spacing: 6) {
            LabelWithHelp(label: l.t("settings.section.title"), help: l.t("settings.section.help"), id: "help.settings", font: .headline)
            Text(l.t("settings.section.message")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                ForEach(SettingsCatalog.categories) { category in
                    let record = records.first { $0.category == category.id }
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: Binding(get: { record != nil && !model.excludedSettings.contains(category.id) },
                                             set: { on in if on { model.excludedSettings.remove(category.id) } else { model.excludedSettings.insert(category.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.t("settings.category.\(category.id)"))
                                Text(l.t("settings.category.\(category.id).hint") + " " + l.t("settings.apply.\(category.apply.rawValue)"))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(record == nil)
                        .accessibilityIdentifier("settings.\(category.id)")
                        Spacer()
                        Text(record.map { l.p("settings.count", $0.keyCount) } ?? l.t("settings.none")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(l.t("settings.notTransferred.title"), isExpanded: $showNotTransferred) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsCatalog.notTransferred, id: \.self) { id in
                        Text("• " + l.t("settings.not.\(id)")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("settings.notTransferred")
        }
    }
}

/// Printers and scanner drivers: recorded so they can be set up again on the new Mac (with the user, never automatically).
struct PrintersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let manifest = model.inventory?.manifest
        let printers = manifest?.printers ?? []
        let scanners = manifest?.scannerDrivers ?? []
        if !printers.isEmpty || !scanners.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    LabelWithHelp(label: l.t("printer.section.title"), help: l.t("printer.section.help"), id: "help.printers", font: .headline)
                    Spacer()
                    Toggle(l.t("printer.section.include"), isOn: $model.includePrinters)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("printers.include")
                }
                Card {
                    ForEach(printers) { printer in
                        Label(l.printerSummary(printer), systemImage: "printer")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("printer.\(printer.queue)")
                    }
                    ForEach(scanners) { scanner in
                        Label(l.t("printer.scanner.summary", scanner.name, scanner.version ?? "–"), systemImage: "scanner")
                            .accessibilityIdentifier("scanner.\(scanner.name)")
                    }
                    Text(l.t("printer.section.message")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ApplicationDataSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let folders = (model.inventory?.manifest.applicationData ?? []).filter { !$0.isPersonal }
        let groups = Dictionary(grouping: folders) { $0.profile?.appName ?? l.t("appData.group.custom") }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("appData.section.title")).font(.headline)
                Spacer()
                if !folders.isEmpty {
                    Button(l.t("items.selectAll")) { model.excludedApplicationData = [] }.buttonStyle(.link)
                    Button(l.t("items.selectNone")) { model.excludedApplicationData = Set(folders.map(\.id)) }.buttonStyle(.link)
                }
                if model.addingApplicationData { ProgressView().controlSize(.small) }
                Button(l.t("appData.add.button")) { model.addApplicationDataFolder() }
                    .disabled(model.addingApplicationData)
                    .accessibilityIdentifier("appData.add")
            }
            Text(l.t("appData.section.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !folders.isEmpty {
                Card {
                    ForEach(groups.keys.sorted(), id: \.self) { app in
                        Text(app).font(.subheadline.weight(.semibold))
                        ForEach(groups[app] ?? []) { folder in
                            AppDataRow(folder: folder)
                        }
                    }
                }
            }
            let refused = (model.inventory?.manifest.backupIssues ?? []).filter { $0.reason == .refusedSensitive }
            if !refused.isEmpty {
                Text(l.p("appData.refused", refused.count) + " " + l.t("appData.refused.where"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Your own folders": folders of the user's own files, each on its own, without a size limit.
struct PersonalFoldersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let folders = (model.inventory?.manifest.applicationData ?? []).filter(\.isPersonal)
        let notDownloaded = (model.inventory?.manifest.backupIssues ?? []).filter { $0.reason == .notDownloaded }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("personal.section.title")).font(.headline)
                Spacer()
                if model.addingApplicationData { ProgressView().controlSize(.small) }
                Button(l.t("appData.add.button")) { model.addPersonalFolder() }
                    .disabled(model.addingApplicationData)
                    .accessibilityIdentifier("personal.add")
            }
            Text(l.t("personal.section.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !folders.isEmpty {
                Card {
                    ForEach(folders) { folder in AppDataRow(folder: folder) }
                    let total = folders.filter { !model.excludedApplicationData.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalSize }
                    Text(l.t("personal.total", l.fileSize(total))).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("personal.total")
                }
            }
            if !notDownloaded.isEmpty {
                Text(l.p("personal.notDownloaded", notDownloaded.count))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AppDataRow: View {
    @EnvironmentObject var model: AppModel
    var folder: AppDataFolder

    var body: some View {
        let l = model.l
        HStack(alignment: .top) {
            Toggle(isOn: Binding(
                get: { !model.excludedApplicationData.contains(folder.id) },
                set: { on in
                    if on { model.excludedApplicationData.remove(folder.id) } else { model.excludedApplicationData.insert(folder.id) }
                })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.profile.map { profile in
                        let version = profile.appVersion.flatMap { $0 == profile.appName ? nil : " · \($0)" } ?? ""
                        return l.t("appData.category.\(profile.category)") + version
                    } ?? folder.name)
                    HStack(spacing: 6) {
                        ConfidenceBadge(level: folder.profile?.effectiveConfidence)
                        Text(folder.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if folder.profile?.classification == .compatibilitySensitive {
                        Text(l.t("appData.compatibilityNote")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.classification == .containsCode {
                        Text(l.t("appData.codeNote")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.requiresFullDiskAccess == true {
                        Text(l.t("appData.fullDiskAccessNote")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.classification == .mayContainSecrets {
                        Text(l.t("appData.secretsNote")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.mustBeClosed == true {
                        Text(l.t("appData.mustBeClosed", folder.profile?.appName ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let shipped = folder.shippedFilesLeftOut {
                        Text(l.t("appData.shippedLeftOut", shipped, folder.profile?.appName ?? "")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help(l.appDataHelp(folder))
            .accessibilityIdentifier("appData.\(folder.profile.map { "\($0.provider).\($0.category)" } ?? folder.id)")
            // Visible help: hover tooltips alone were not found (beta feedback 1.0.4).
            HelpButton(text: l.appDataHelp(folder), title: folder.name,
                       id: "help.appData.\(folder.profile.map { "\($0.provider).\($0.category)" } ?? folder.id)")
            Spacer()
            Text(l.t("appData.summary", l.p("guide.appData.files", folder.files.count), l.fileSize(folder.totalSize)))
                .font(.callout).foregroundStyle(.secondary)
            if folder.profile == nil {
                Button {
                    model.removeApplicationData(id: folder.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(l.t("appData.remove"))
                .accessibilityLabel(l.t("appData.remove"))
            }
        }
    }
}

struct BackupSavedView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showTransfer = true

    var body: some View {
        let l = model.l
        let outcome = model.backupOutcome
        ScreenLayout(title: outcome?.isComplete == false ? l.t("saved.titlePartial") : l.t("saved.title"), subtitle: nil) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let outcome {
                        NoticeView(style: .success, title: l.t("saved.verified"), message: l.t("saved.message"))
                        CompletenessNotice(manifest: outcome.manifest)
                        if let app = outcome.manifest.bootstrapApp {
                            let runsHere = app.runs(on: outcome.manifest.architecture)
                            NoticeView(style: app.isUniversal ? .info : .warning, title: l.bootstrapSummary(app),
                                       message: runsHere ? l.t("bootstrap.saved.message") : l.t("bootstrap.notThisMac"))
                                .accessibilityIdentifier("saved.bootstrap")
                        } else {
                            NoticeView(style: .warning, title: l.t("bootstrap.missing"), message: l.t("bootstrap.missing.message", MacReplicaLinks.releases.absoluteString))
                                .accessibilityIdentifier("saved.bootstrap")
                        }
                        if outcome.manifest.completeness != .complete || !outcome.manifest.sensitiveFilesIncludedOnRequest.isEmpty {
                            Card {
                                NotInBackupView(manifest: outcome.manifest, editable: false, onThisMac: true)
                            }
                            .accessibilityElement(children: .contain).accessibilityIdentifier("saved.notInBackup")
                        }
                        CredentialReadinessCard(manifest: outcome.manifest)
                        Card {
                            Text(l.t("saved.location")).font(.caption).foregroundStyle(.secondary)
                            Text(model.displayPath(outcome.url))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("saved.path")
                            Text(l.t("saved.size", l.fileSize(outcome.totalSize), l.number(outcome.fileCount)))
                                .foregroundStyle(.secondary)
                            Text(savedContents(outcome.manifest))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup(l.t("saved.transfer.title"), isExpanded: $showTransfer) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(l.t("saved.transfer.intro")).fixedSize(horizontal: false, vertical: true)
                                ForEach(["saved.transfer.drive", "saved.transfer.network", "saved.transfer.cloud", "saved.transfer.airdrop"], id: \.self) { key in
                                    Label(l.t(key), systemImage: "circle.fill")
                                        .labelStyle(BulletLabelStyle())
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(l.t("saved.nextSteps"))
                                    .padding(.top, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
        } buttons: {
            if let url = model.savedBackup {
                Button(l.t("saved.reinstallGuide")) { model.open(url.appendingPathComponent(BackupWriter.reinstallGuidePath)) }
                    .help(l.t("saved.reinstallGuide.help"))
                    .accessibilityIdentifier("saved.reinstallGuide")
                Button(l.t("saved.openInstructions")) { model.open(url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html")) }
                    .accessibilityIdentifier("saved.instructions")
                Button(l.t("saved.openReport")) { model.open(url.appendingPathComponent("reports/inventory.html")) }
                Button(l.t("saved.showInFinder")) { model.revealInFinder(url) }
            }
            Button(l.t("common.done")) { model.goHome() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saved.done")
        }
    }

    private func savedContents(_ manifest: Manifest) -> String {
        let l = model.l
        return l.t("saved.contents", l.number(manifest.applications.count), l.number(manifest.brewFormulae.filter(\.installedOnRequest).count
            + manifest.brewCasks.count), l.number(manifest.python.environments.count), l.number(manifest.applicationData.count),
            l.number(manifest.fonts.count), l.number(manifest.iccProfiles.count))
            + (manifest.toolchains.isEmpty ? "" : " · " + l.t("saved.developerTools", l.number(manifest.toolchains.count)))
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// Git settings: kept by default, email only when the user asks for it.
struct DeveloperSettingsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let developer = model.inventory?.manifest.developer ?? DeveloperSettings()
        if !developer.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("component.developerSettings")).font(.headline)
                Card {
                    Toggle(isOn: $model.includeGitSettings) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.t("developer.git"))
                            Text(l.t("developer.git.detail")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("developer.git")
                    Toggle(l.t("developer.git.email"), isOn: $model.includeGitEmail)
                        .toggleStyle(.checkbox)
                        .disabled(!model.includeGitSettings)
                        .padding(.leading, 20)
                }
            }
        }
    }
}

/// Services that need a new sign-in, or their own export, on the new Mac.
struct GuidanceList: View {
    @EnvironmentObject var model: AppModel
    var records: [GuidanceRecord]

    var body: some View {
        let l = model.l
        let reauth = records.filter { $0.kind == .reauthenticationRequired }
        let manual = records.filter { $0.kind == .manualMigration }
        VStack(alignment: .leading, spacing: 4) {
            if !reauth.isEmpty {
                Text(l.t("guidance.reauth.title")).font(.subheadline.weight(.semibold))
                Text(reauth.map { l.guidanceName($0) }.joined(separator: ", ")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.t("guidance.reauth.message")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !manual.isEmpty {
                Text(l.t("guidance.manual.title")).font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(manual) { record in
                    Text("\(l.guidanceName(record)): \(l.t("guidance.manual.\(record.id)"))").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows what could not be read and offers to open System Settings; never asks on its own.
struct LocationsSection: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var expanded = false

    var body: some View {
        let l = model.l
        let locations = model.inventory?.manifest.locations ?? []
        VStack(alignment: .leading, spacing: 8) {
            if !model.blockedLocations.isEmpty {
                NoticeView(style: .warning, title: l.t("access.blocked.title"), message: l.t("access.blocked.message"))
                HStack {
                    Spacer()
                    Button(l.t("access.openSettings")) { model.openPrivacySettings() }
                }
            }
            DisclosureGroup(l.t("access.section.title"), isExpanded: $expanded) {
                VStack(spacing: 0) {
                    ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                        HStack {
                            Text(l.accessAreaText(location.area))
                            Text(location.location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(l.accessStatusText(location.status))
                                .font(.callout)
                                .foregroundStyle(location.status == .noPermission ? .orange : .secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

/// How far support for a kind of application data goes (see `DataConfidence`).
struct ConfidenceBadge: View {
    @EnvironmentObject var model: AppModel
    var level: DataConfidence?

    var body: some View {
        if let level {
            let color: Color = level == .full ? .green : (level == .experimental ? .orange : (level == .notSupported ? .secondary : .blue))
            Text(model.l.t("confidence.\(level.rawValue)"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().strokeBorder(color.opacity(0.6)))
                .help(model.l.t("confidence.\(level.rawValue).help"))
                .accessibilityLabel(model.l.t("confidence.\(level.rawValue)"))
        }
    }
}
