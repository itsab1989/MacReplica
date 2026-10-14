import MacReplicaCore
import SwiftUI

/// "Passwords, keys and credentials" on the selection screen: what was found, what goes into the encrypted part of the
/// backup, what the user left out, what cannot be copied, and what needs a step on the new Mac.
struct CredentialsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let manifest = model.inventory?.manifest
        let selected = model.inventory?.credentialSelection ?? []
        let undecided = manifest?.undecidedCredentials ?? []
        let leftOut = manifest?.credentialsLeftOutByUser ?? []
        let notCopyable = manifest?.uncopyableCredentials ?? []
        let guidance = manifest?.guidance ?? []
        let credentialGuidance = guidance.filter { GuidanceCatalog.credentialIDs.contains($0.id) }
        let detected = model.detectedCredentials
        DisclosureGroup(isExpanded: $model.expandCredentials) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(l.t("credential.section.message")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HelpButton(text: l.t("credential.section.help"), title: l.t("credential.section.title"), id: "help.credentials")
                }
                HStack {
                    Button(l.t("credential.add.button")) { model.addCredentialFilesFromPanel() }
                        .accessibilityIdentifier("credential.add")
                    Spacer()
                    if model.credentialsWanted || model.credentialEncryptionReady {
                        if model.credentialEncryptionReady {
                            Label(l.t("credential.encryption.ready"), systemImage: "lock.fill").font(.caption).foregroundStyle(.green)
                                .accessibilityIdentifier("credential.encryption.ready")
                        } else {
                            Label(l.t("credential.encryption.missing"), systemImage: "lock.open").font(.caption).foregroundStyle(.orange)
                        }
                        Button(model.credentialEncryptionReady ? l.t("credential.encryption.change") : l.t("credential.encryption.setUp")) {
                            model.credentialSetupPending = true
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("credential.encryption.setUp")
                    }
                }

                if !selected.isEmpty {
                    LabelWithHelp(label: l.p("credential.selected.title", selected.count), help: l.t("credential.selected.help"),
                                  id: "help.credential.selected", font: .subheadline.weight(.semibold))
                    ForEach(selected) { item in
                        IssueRow(symbol: "lock.fill", color: .green, title: item.fileName, path: item.originalPath,
                                 lines: [l.credentialSummary(category: item.category, format: item.format),
                                         l.credentialNeedsText(CredentialPolicy.prerequisites(item.category))], onThisMac: true) {
                            Button(l.t("credential.remove")) { model.removeCredential(item) }
                                .controlSize(.small)
                                .accessibilityIdentifier("credential.remove.\(item.fileName)")
                        }
                    }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("credential.selected")
                }

                if !undecided.isEmpty {
                    HStack {
                        LabelWithHelp(label: l.p("credential.undecided.title", undecided.count), help: l.t("credential.undecided.help"),
                                      id: "help.credential.undecided", font: .subheadline.weight(.semibold))
                        Spacer()
                        if undecided.count > 1 {
                            Button(l.t("credential.addAll")) { model.addAllUndecidedCredentials() }
                                .controlSize(.small).accessibilityIdentifier("credential.addAll")
                        }
                    }
                    ForEach(Array(undecided.enumerated()), id: \.element.path) { _, issue in
                        IssueRow(symbol: "exclamationmark.lock.fill", color: .orange, title: issue.fileName, path: issue.path,
                                 lines: [l.sensitiveDescription(issue), l.sensitiveExplanation(issue)], onThisMac: true) {
                            Button(l.t("credential.addOne")) { model.addDetectedCredential(issue) }
                                .controlSize(.small).accessibilityIdentifier("credential.addOne.\(issue.fileName)")
                            Button(l.t("credential.leaveOut")) { model.leaveOutCredential(issue) }
                                .controlSize(.small).accessibilityIdentifier("credential.leaveOut.\(issue.fileName)")
                        }
                    }
                }

                if !leftOut.isEmpty {
                    Text(l.p("credential.leftOut.title", leftOut.count)).font(.subheadline.weight(.semibold))
                    ForEach(Array(leftOut.enumerated()), id: \.element.path) { _, issue in
                        IssueRow(symbol: "lock.slash", color: .secondary, title: issue.fileName, path: issue.path,
                                 lines: [l.sensitiveDescription(issue), l.t("credential.report.leftOut.reason")], onThisMac: true) {
                            Button(l.t("credential.reconsider")) { model.reconsiderCredential(issue) }
                                .controlSize(.small).accessibilityIdentifier("credential.reconsider.\(issue.fileName)")
                        }
                    }
                }

                if !notCopyable.isEmpty {
                    Text(l.p("credential.report.notCopyable", notCopyable.count)).font(.subheadline.weight(.semibold))
                    ForEach(Array(notCopyable.enumerated()), id: \.element.path) { _, issue in
                        IssueRow(symbol: "xmark.octagon", color: .orange, title: issue.fileName, path: issue.path,
                                 lines: [l.sensitiveDescription(issue), l.sensitiveExplanation(issue)], onThisMac: true)
                    }
                }

                if !detected.isEmpty {
                    Text(l.t("credential.providers.title")).font(.subheadline.weight(.semibold))
                    ForEach(detected, id: \.provider.id) { entry in
                        Toggle(isOn: Binding(
                            get: { model.selectedCredentialProviders.contains(entry.provider.id) },
                            set: { on in
                                if on {
                                    model.selectedCredentialProviders.insert(entry.provider.id)
                                    if !model.credentialEncryptionReady { model.credentialSetupPending = true }
                                } else {
                                    model.selectedCredentialProviders.remove(entry.provider.id)
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
                }

                if !credentialGuidance.isEmpty {
                    LabelWithHelp(label: l.t("credential.report.manual"), help: l.t("credential.manual.help"),
                                  id: "help.credential.manual", font: .subheadline.weight(.semibold))
                    ForEach(credentialGuidance) { record in
                        IssueRow(symbol: "person.badge.key", color: .blue, title: l.guidanceName(record), path: "",
                                 lines: [l.t("guidance.credential.\(record.id)")], onThisMac: false)
                    }
                }
                let other = guidance.filter { !GuidanceCatalog.credentialIDs.contains($0.id) }
                if !other.isEmpty { GuidanceList(records: other) }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                // The identifier sits on the label so it is not inherited by the controls inside.
                Text(l.t("credential.section.title")).font(.headline).accessibilityIdentifier("credentials.section")
                if !selected.isEmpty {
                    Text(l.p("credential.badge.encrypted", selected.count)).font(.caption).foregroundStyle(.green)
                }
                if !undecided.isEmpty {
                    Text(l.p("credential.badge.undecided", undecided.count)).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("credential.badge.undecided")
                }
            }
        }
        .sheet(isPresented: $model.credentialSetupPending) { CredentialSetupSheet() }
        .sheet(isPresented: $model.undecidedCredentialsWarning) { UndecidedCredentialsSheet() }
        .sheet(item: Binding(get: { model.credentialAddReport.map(IdentifiedReport.init) }, set: { model.credentialAddReport = $0?.report })) { wrapper in
            CredentialAddReportSheet(report: wrapper.report)
        }
        .onAppear {
            if !undecided.isEmpty || !selected.isEmpty { model.expandCredentials = true }
        }
    }
}

struct IdentifiedReport: Identifiable {
    let report: CredentialAddReport
    let id = UUID()
}

/// Sets up the encryption of the credential part: a passphrase the user chooses and a recovery key MacReplica
/// generates. Either opens the backup; neither is stored anywhere. Explains why the Mac's login password is not used.
struct CredentialSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var passphrase = ""
    @ViewState private var confirmation = ""
    @ViewState private var recoveryKey: RecoveryKey?
    @ViewState private var keyStored = false
    @ViewState private var understood = false

    var valid: Bool {
        passphrase.count >= CredentialStore.minimumPassphraseLength && passphrase == confirmation && keyStored && understood && recoveryKey != nil
    }

    var body: some View {
        let l = model.l
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(l.t("credential.setup.title")).font(.title3.weight(.semibold))
                Text(l.t("credential.setup.message")).fixedSize(horizontal: false, vertical: true)
                SecureField(l.t("credentials.passphrase"), text: $passphrase).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("credentials.passphrase")
                SecureField(l.t("credentials.passphraseConfirm"), text: $confirmation).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("credentials.passphraseConfirm")
                Text(l.t("credentials.passphraseRules", CredentialStore.minimumPassphraseLength))
                    .font(.caption)
                    .foregroundStyle(passphrase.isEmpty || passphrase.count >= CredentialStore.minimumPassphraseLength ? Color.secondary : Color.orange)
                if !confirmation.isEmpty, passphrase != confirmation {
                    Text(l.t("credential.setup.mismatch")).font(.caption).foregroundStyle(.orange)
                }
                Divider()
                Text(l.t("credential.setup.recoveryTitle")).font(.headline)
                Text(l.t("credential.setup.recoveryMessage")).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let recoveryKey {
                    Text(recoveryKey.text)
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .accessibilityIdentifier("credential.recoveryKey")
                    HStack {
                        Button(l.t("credential.setup.copyKey")) { model.copyRecoveryKey(recoveryKey) }
                            .accessibilityIdentifier("credential.copyKey")
                        Button(l.t("credential.setup.saveKey")) { model.saveRecoveryKey(recoveryKey) }
                            .accessibilityIdentifier("credential.saveKey")
                    }
                }
                Toggle(l.t("credential.setup.keyStored"), isOn: $keyStored).toggleStyle(.checkbox)
                    .accessibilityIdentifier("credential.keyStored")
                NoticeView(style: .warning, title: l.t("credential.setup.lossTitle"), message: l.t("credential.setup.loss"))
                Toggle(l.t("credential.setup.understood"), isOn: $understood).toggleStyle(.checkbox)
                    .accessibilityIdentifier("credentials.understood")
                DisclosureGroup(l.t("credential.setup.loginPassword.title")) {
                    Text(l.t("credential.setup.loginPassword")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                .accessibilityIdentifier("credential.loginPassword")
                HStack {
                    Spacer()
                    Button(l.t("common.cancel")) { model.credentialSetupCancelled() }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("credential.setup.cancel")
                    Button(l.t("credential.setup.enable")) {
                        if let recoveryKey { model.credentialSetupFinished(passphrase: passphrase, recoveryKey: recoveryKey) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
                    .accessibilityIdentifier("credentials.enable")
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            // A new key each time the sheet opens: an earlier one the user may have written down is replaced only when
            // they confirm again.
            recoveryKey = try? RecoveryKey.generate()
        }
    }
}

/// Before saving: credential files that were found but are neither in the backup nor deliberately left out.
struct UndecidedCredentialsSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let undecided = model.inventory?.manifest.undecidedCredentials ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(l.p("credential.warning.title", undecided.count)).font(.title3.weight(.semibold))
            Text(l.t("credential.warning.message")).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(undecided.enumerated()), id: \.element.path) { _, issue in
                        IssueRow(symbol: "exclamationmark.lock.fill", color: .orange, title: issue.fileName, path: issue.path,
                                 lines: [l.sensitiveDescription(issue)], onThisMac: false)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Button(l.t("credential.warning.saveWithout")) { model.saveWithoutUndecidedCredentials() }
                    .accessibilityIdentifier("credential.warning.saveWithout")
                Spacer()
                Button(l.t("credential.warning.review")) { model.reviewUndecidedCredentials() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("credential.warning.review")
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// What was not added (with the reason), what was already selected, and files with the same contents.
struct CredentialAddReportSheet: View {
    @EnvironmentObject var model: AppModel
    var report: CredentialAddReport

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 10) {
            Text(l.p("credential.report.added", report.added.count)).font(.title3.weight(.semibold))
            if !report.refused.isEmpty {
                Text(l.p("credential.report.refused", report.refused.count)).font(.subheadline.weight(.semibold))
                ForEach(Array(report.refused.enumerated()), id: \.offset) { _, entry in
                    IssueRow(symbol: "xmark.circle", color: .orange, title: (entry.path as NSString).lastPathComponent, path: entry.path,
                             lines: [l.credentialProblemText(entry.problem)], onThisMac: false)
                }
            }
            if !report.alreadySelected.isEmpty {
                Text(l.p("credential.report.alreadySelected", report.alreadySelected.count)).font(.subheadline.weight(.semibold))
                Text(report.alreadySelected.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !report.sameContents.isEmpty {
                Text(l.t("credential.report.sameContents")).font(.subheadline.weight(.semibold))
                Text(report.sameContents.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if report.unrecognisedInFolders > 0 {
                Text(l.p("credential.report.unrecognised", report.unrecognisedInFolders)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(l.t("common.ok")) { model.credentialAddReport = nil }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("credential.report.ok")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// After saving and in the restore selection: every credential and what happened to it.
struct CredentialReadinessCard: View {
    @EnvironmentObject var model: AppModel
    var manifest: Manifest

    var body: some View {
        let l = model.l
        let preserved = manifest.preservedCredentials
        let failed = manifest.failedCredentials
        let undecided = manifest.undecidedCredentials
        let manual = manifest.guidance.filter { GuidanceCatalog.credentialIDs.contains($0.id) }
        let risky = !failed.isEmpty || !undecided.isEmpty || !manifest.uncopyableCredentials.isEmpty
        if !preserved.isEmpty || risky || !manual.isEmpty || !manifest.credentials.isEmpty {
            Card {
                Text(l.t("credential.report.title")).font(.headline)
                if !preserved.isEmpty {
                    NoticeView(style: .success, title: l.p("credential.report.preserved", preserved.count), message: l.t("credential.report.unlock"))
                        .accessibilityIdentifier("credential.readiness.preserved")
                    ForEach(preserved) { record in
                        IssueRow(symbol: "lock.fill", color: .green, title: record.fileName, path: record.originalPath,
                                 lines: [l.credentialSummary(category: record.category, format: record.format) + " · " + l.credentialStatusText(record),
                                         l.credentialNeedsText(record.prerequisites)], onThisMac: false)
                    }
                }
                if !failed.isEmpty {
                    NoticeView(style: .warning, title: l.p("credential.report.failed", failed.count), message: l.t("credential.report.failed.message"))
                        .accessibilityIdentifier("credential.readiness.failed")
                    ForEach(failed) { record in
                        IssueRow(symbol: "exclamationmark.triangle.fill", color: .orange, title: record.fileName, path: record.originalPath,
                                 lines: [l.credentialStatusText(record)], onThisMac: false)
                    }
                }
                if !undecided.isEmpty {
                    NoticeView(style: .warning, title: l.p("credential.report.undecided", undecided.count), message: l.t("credential.report.undecided.advice"))
                        .accessibilityIdentifier("credential.readiness.undecided")
                }
                if !manifest.uncopyableCredentials.isEmpty {
                    NoticeView(style: .warning, title: l.p("credential.report.notCopyable", manifest.uncopyableCredentials.count),
                               message: l.t("credential.report.notCopyable.message"))
                }
                if !manual.isEmpty {
                    Text(l.t("credential.report.manual")).font(.subheadline.weight(.semibold))
                    ForEach(manual) { record in
                        Text("\(l.guidanceName(record)): \(l.t("guidance.credential.\(record.id)"))").font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("credential.readiness")
        }
    }
}

/// Asks for the passphrase or the recovery key right before restoring credentials; a wrong one is reported here.
struct RestorePassphraseSheet: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var secret = ""
    @ViewState private var useRecoveryKey = false

    var body: some View {
        let l = model.l
        let hasRecoveryKey = model.manifest?.credentialStore?.unlockMethods.contains("recoveryKey") == true
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("credentials.restore.title")).font(.title3.weight(.semibold))
            Text(l.t(hasRecoveryKey ? "credential.restore.message" : "credentials.restore.message")).fixedSize(horizontal: false, vertical: true)
            if hasRecoveryKey {
                Picker("", selection: $useRecoveryKey) {
                    Text(l.t("credentials.passphrase")).tag(false)
                    Text(l.t("credential.restore.recoveryKey")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("credential.restore.method")
            }
            if useRecoveryKey {
                TextField(l.t("credential.restore.recoveryKeyPlaceholder"), text: $secret).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("credential.restore.field")
            } else {
                SecureField(l.t("credentials.passphrase"), text: $secret).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("credential.restore.field")
            }
            if let error = model.restoreSecretError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("credential.restore.error")
            }
            Text(l.t("credential.restore.lost")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(l.t("credentials.restore.skip")) { model.restoreSecretEntered(nil) }
                    .accessibilityIdentifier("credential.restore.skip")
                Spacer()
                Button(l.t("common.cancel")) { model.cancelRestorePassphrase() }.keyboardShortcut(.cancelAction)
                Button(l.t("common.continue")) { model.restoreSecretEntered(useRecoveryKey ? .recoveryKey(secret) : .passphrase(secret)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
                    .accessibilityIdentifier("credential.restore.continue")
            }
        }
        .padding(20)
        .frame(width: 500)
        .onChange(of: useRecoveryKey) { _ in secret = ""; model.restoreSecretError = nil }
    }
}
