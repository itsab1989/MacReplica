import MacReplicaCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        Form {
            Picker(l.t("settings.language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .accessibilityIdentifier("settings.language")
            Text(l.t("settings.languageHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text(l.t("settings.logs"))
                Spacer()
                Button(l.t("settings.openLogs")) { model.openLogs() }
                Button(l.t("help.exportDiagnostics")) { model.exportDiagnosticReport() }
            }
            Divider()
            Toggle(l.t("update.automatic"), isOn: Binding(get: { model.checkAutomatically }, set: { model.checkAutomatically = $0 }))
            Toggle(l.t("update.prereleases"), isOn: Binding(get: { model.includePrereleases }, set: { model.includePrereleases = $0 }))
            HStack {
                Text(l.t("about.versionBuild", SystemInfo.appVersion, SystemInfo.buildNumber)).foregroundStyle(.secondary)
                Spacer()
                Button(l.t("update.check")) { model.checkForUpdates(userInitiated: true) }
                    .disabled(model.checkingForUpdates)
            }
            Divider()
            HStack {
                Text(l.t("help.support"))
                Spacer()
                Button(l.t("about.kofiButton")) { model.openWebPage(AboutView.kofiURL) }
            }
        }
        .padding(20)
        .frame(width: 520)
        .environment(\.locale, model.language.locale)
    }
}

struct AboutView: View {
    @EnvironmentObject var model: AppModel

    static let repositoryURL = "https://github.com/itsab1989/MacReplica"
    static let kofiURL = "https://ko-fi.com/itsab1989"

    var body: some View {
        let l = model.l
        VStack(spacing: 10) {
            AppIconView(size: 96)
            Text("MacReplica").font(.title.weight(.semibold))
            Text(l.t("about.versionBuild", SystemInfo.appVersion, SystemInfo.buildNumber))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("about.version")
            Text(l.t("about.platform", MacReplicaVersion.minimumMacOS))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(l.t("about.description"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            Divider().padding(.vertical, 4)
            Text(l.t("about.kofi"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(l.t("about.kofiButton")) { model.openWebPage(Self.kofiURL) }
                Button(l.t("about.github")) { model.openWebPage(Self.repositoryURL) }
                Button(l.t("update.check")) { model.checkForUpdates(userInitiated: true) }
                    .accessibilityIdentifier("about.checkUpdates")
            }
            Text(l.t("about.license"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
        .environment(\.locale, model.language.locale)
    }
}

struct UpdateSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 12) {
            switch model.updateStatus {
            case .upToDate(let current)?:
                NoticeView(style: .success, title: l.t("update.upToDate"), message: l.t("update.currentVersion", current))
            case .available(let release, let current)?:
                NoticeView(style: .info, title: l.t("update.available", release.version, current),
                           message: l.t("update.availableHint"))
            default:
                NoticeView(style: .warning, title: l.t("update.unable"))
            }
            HStack {
                Spacer()
                if case .available(let release, _)? = model.updateStatus {
                    Button(l.t("update.viewRelease")) {
                        model.openWebPage(release.pageURL.absoluteString)
                        model.updateStatus = nil
                    }
                }
                Button(l.t("common.ok")) { model.updateStatus = nil }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("update.ok")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
