import MacReplicaCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .home: HomeView()
            case .scanning: ScanningView()
            case .inventoryResults: InventoryResultsView()
            case .savingBackup: SavingBackupView()
            case .backupSaved: BackupSavedView()
            case .restoreSelection: RestoreSelectionView()
            case .dryRun: DryRunView()
            case .restoring: RestoreProgressView()
            case .restoreSummary: RestoreSummaryView()
            case .verifying: VerifyingView()
            case .verificationResult: VerificationResultView()
            case .problem: ProblemView()
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 540, idealHeight: 600)
        .environment(\.locale, model.language.locale)
        .onAppear {
            model.userInterfaceReady()
            model.automaticUpdateCheckIfDue()
        }
        .sheet(isPresented: Binding(get: { model.updateStatus != nil }, set: { if !$0 { model.updateStatus = nil } })) {
            UpdateSheet()
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(model.l.t("common.ok")) { model.notice = nil }
        } message: {
            Text(model.notice?.message ?? "")
        }
    }
}

/// Shown after a launch that did not finish starting up.
struct SafeModeBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 10) {
            NoticeView(style: .warning, title: l.t("safeMode.title"),
                       message: l.t("safeMode.message", model.startup.previousLaunch?.lastStage.map { l.t("startup.stage.\($0.rawValue)") } ?? "–"))
            HStack {
                Button(l.t("help.openLogs")) { model.openLogs() }
                Button(l.t("help.exportDiagnostics")) { model.exportDiagnosticReport() }
                Spacer()
                Button(l.t("safeMode.continue")) { model.leaveSafeMode() }
                    .accessibilityIdentifier("safeMode.continue")
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            AppIconView(size: 88)
            Text("MacReplica")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 6)
            Text(l.t("home.tagline"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.horizontal, 40)

            if model.showSafeModeNotice {
                SafeModeBanner()
                    .frame(maxWidth: 560)
                    .padding(.top, 14)
            } else if model.unfinishedSession != nil {
                ResumeBanner()
                    .frame(maxWidth: 520)
                    .padding(.top, 18)
            }

            VStack(spacing: 10) {
                ActionRow(symbol: "square.and.arrow.down.on.square", title: l.t("home.inventory.title"),
                          subtitle: l.t("home.inventory.subtitle")) { model.startInventory() }
                    .accessibilityIdentifier("home.inventory")
                ActionRow(symbol: "arrow.uturn.backward.circle", title: l.t("home.restore.title"),
                          subtitle: l.t("home.restore.subtitle")) { model.chooseBackup(for: .restore) }
                    .accessibilityIdentifier("home.restore")
                ActionRow(symbol: "checkmark.shield", title: l.t("home.verify.title"),
                          subtitle: l.t("home.verify.subtitle")) { model.chooseBackup(for: .verify) }
                    .accessibilityIdentifier("home.verify")
            }
            .frame(maxWidth: 520)
            .padding(.top, 22)

            Spacer(minLength: 16)
            HStack {
                LanguageMenu()
                Spacer()
                Text(l.t("home.dryRunHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 24)
    }
}

struct ActionRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: hovering ? .selectedContentBackgroundColor : .controlBackgroundColor).opacity(hovering ? 0.12 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

struct ResumeBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 10) {
            NoticeView(style: .info, title: l.t("resume.title"), message: l.t("resume.message"))
            HStack {
                Spacer()
                Button(l.t("resume.discard")) { model.discardUnfinished() }
                    .accessibilityIdentifier("resume.discard")
                Button(l.t("resume.continue")) { model.resumeUnfinished() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("resume.continue")
            }
        }
    }
}

/// Tells the user where the diagnostic log is and opens it.
struct LogHint: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            Text(model.l.t("logs.hint", model.logsDisplayPath))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(model.l.t("help.openLogs")) { model.openLogs() }
        }
    }
}

struct LanguageMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Picker(model.l.t("settings.language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.language.nativeName, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.l.t("settings.language"))
        .accessibilityIdentifier("home.language")
    }
}

struct ProblemView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showDetail = false

    var body: some View {
        let l = model.l
        ScreenLayout(title: model.problem?.title ?? "", subtitle: nil) {
            VStack(alignment: .leading, spacing: 14) {
                NoticeView(style: .error, title: model.problem?.title ?? "", message: model.problem?.message)
                LogHint()
                if let detail = model.problem?.detail, !detail.isEmpty {
                    DisclosureGroup(l.t("common.technicalDetails"), isExpanded: $showDetail) {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 28)
        } buttons: {
            Button(l.t("common.backToStart")) { model.goHome() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
