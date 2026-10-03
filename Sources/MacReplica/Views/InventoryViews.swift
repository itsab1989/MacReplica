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
                    CredentialsSection()
                    LocationsSection()

                    if let apps = manifest?.applications, !apps.isEmpty {
                        DisclosureGroup(l.t("results.showApps"), isExpanded: $showApps) {
                            VStack(spacing: 0) {
                                ForEach(apps) { app in
                                    AppRow(app: app)
                                    Divider()
                                }
                            }
                            .padding(.top, 6)
                        }
                        .accessibilityIdentifier("results.showApps")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        } buttons: {
            Button(l.t("common.cancel")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
            Button(l.t("results.save")) { model.chooseBackupLocation() }
                .keyboardShortcut(.defaultAction)
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
                    Text(l.t("match.candidate", candidate.name, candidate.token)).tag(candidate.token)
                }
                Divider()
                Text(l.t("match.none")).tag("")
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct AppRow: View {
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
            }
            Spacer()
            Text(l.methodText(app.restoreMethod))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
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
