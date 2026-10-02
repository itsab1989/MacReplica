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
struct ApplicationDataSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let folders = model.inventory?.manifest.applicationData ?? []
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
                Text(l.p("appData.refused", refused.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(folder.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if folder.profile?.classification == .compatibilitySensitive {
                        Text(l.t("appData.compatibilityNote")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.classification == .mayContainSecrets {
                        Text(l.t("appData.secretsNote")).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if folder.profile?.mustBeClosed == true {
                        Text(l.t("appData.mustBeClosed", folder.profile?.appName ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
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
                        if outcome.isComplete {
                            NoticeView(style: .success, title: l.t("saved.verified"), message: l.t("saved.message"))
                        } else {
                            NoticeView(style: .warning, title: l.p("saved.partial", outcome.manifest.backupGaps.count), message: l.t("saved.partialMessage"))
                            Card {
                                ForEach(Array(outcome.manifest.backupGaps.prefix(8).enumerated()), id: \.offset) { _, issue in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(issue.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(l.backupIssueText(issue.reason)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if outcome.manifest.backupGaps.count > 8 {
                                    Text(l.t("saved.moreIssues", outcome.manifest.backupGaps.count - 8)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !outcome.manifest.excludedSensitiveFiles.isEmpty {
                            NoticeView(style: .info, title: l.p("appData.refused", outcome.manifest.excludedSensitiveFiles.count))
                        }
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

/// Credentials & accounts: opt-in encrypted credentials per provider, and the services
/// that will ask for a new sign-in. Collapsed, and nothing selected, by default.
struct CredentialsSection: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var expanded = false
    @ViewState private var pendingProvider: String?

    var body: some View {
        let l = model.l
        let detected = model.detectedCredentials
        let guidance = model.inventory?.manifest.guidance ?? []
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t("credentials.section.message"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if detected.isEmpty {
                    Text(l.t("credentials.none")).foregroundStyle(.secondary)
                }
                ForEach(detected, id: \.provider.id) { entry in
                    Toggle(isOn: Binding(
                        get: { model.selectedCredentialProviders.contains(entry.provider.id) },
                        set: { on in
                            if !on {
                                model.selectedCredentialProviders.remove(entry.provider.id)
                                if model.selectedCredentialProviders.isEmpty { model.credentialPassphrase = nil }
                            } else if model.credentialPassphrase == nil {
                                pendingProvider = entry.provider.id
                            } else {
                                model.selectedCredentialProviders.insert(entry.provider.id)
                            }
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.t(entry.provider.titleKey))
                            Text(entry.items.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(l.t(entry.provider.riskKey)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("credentials.\(entry.provider.id)")
                }
                if !model.selectedCredentialProviders.isEmpty {
                    Label(l.t("credentials.enabled"), systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                }
                if !guidance.isEmpty {
                    GuidanceList(records: guidance)
                }
            }
            .padding(.top, 6)
        } label: {
            // The identifier sits on the label so it is not inherited by the controls inside.
            Text(l.t("credentials.section.title")).accessibilityIdentifier("credentials.section")
        }
        .sheet(isPresented: Binding(get: { pendingProvider != nil }, set: { if !$0 { pendingProvider = nil } })) {
            CredentialOptInSheet(providerID: pendingProvider ?? "")
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
                Text(reauth.map(\.name).joined(separator: ", ")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l.t("guidance.reauth.message")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !manual.isEmpty {
                Text(l.t("guidance.manual.title")).font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(manual) { record in
                    Text("\(record.name): \(l.t("guidance.manual.\(record.id)"))").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CredentialOptInSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var providerID: String
    @ViewState private var passphrase = ""
    @ViewState private var confirmation = ""
    @ViewState private var understood = false

    var valid: Bool {
        passphrase.count >= CredentialVault.minimumPassphraseLength && passphrase == confirmation && understood
    }

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("credentials.optIn.title")).font(.title3.weight(.semibold))
            NoticeView(style: .warning, title: l.t("credentials.optIn.warningTitle"), message: l.t("credentials.optIn.warning"))
            if let provider = CredentialProviders.provider(id: providerID) {
                Text(l.t(provider.descriptionKey)).fixedSize(horizontal: false, vertical: true)
            }
            Text(l.t("credentials.optIn.storage")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(l.t("credentials.passphrase"), text: $passphrase).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("credentials.passphrase")
            SecureField(l.t("credentials.passphraseConfirm"), text: $confirmation).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("credentials.passphraseConfirm")
            Text(l.t("credentials.passphraseRules", CredentialVault.minimumPassphraseLength))
                .font(.caption).foregroundStyle(passphrase.isEmpty || passphrase.count >= CredentialVault.minimumPassphraseLength ? Color.secondary : Color.orange)
            Toggle(l.t("credentials.optIn.understood"), isOn: $understood).toggleStyle(.checkbox)
                .accessibilityIdentifier("credentials.understood")
            HStack {
                Spacer()
                Button(l.t("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l.t("credentials.optIn.enable")) {
                    model.credentialPassphrase = passphrase
                    model.selectedCredentialProviders.insert(providerID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
                .accessibilityIdentifier("credentials.enable")
            }
        }
        .padding(20)
        .frame(width: 520)
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

/// Asks for the vault passphrase right before restoring credentials.
struct RestorePassphraseSheet: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var passphrase = ""

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("credentials.restore.title")).font(.title3.weight(.semibold))
            Text(l.t("credentials.restore.message")).fixedSize(horizontal: false, vertical: true)
            SecureField(l.t("credentials.passphrase"), text: $passphrase).textFieldStyle(.roundedBorder)
            HStack {
                Button(l.t("credentials.restore.skip")) { model.restorePassphraseEntered(nil) }
                Spacer()
                Button(l.t("common.cancel")) { model.cancelRestorePassphrase() }.keyboardShortcut(.cancelAction)
                Button(l.t("common.continue")) { model.restorePassphraseEntered(passphrase) }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
