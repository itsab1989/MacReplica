import MacReplicaCore
import SwiftUI

struct VerifyingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        ScreenLayout(title: l.t("verify.progress.title"), subtitle: l.t("verify.progress.subtitle")) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: model.verificationProgress)
                Text(l.percent(model.verificationProgress)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
        } buttons: {
            Button(l.t("common.cancel")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

struct VerificationResultView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let report = model.verification
        ScreenLayout(title: l.t("verify.result.title"), subtitle: model.backupURL.map(model.displayPath)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let report {
                        if report.isIntact {
                            NoticeView(style: .success, title: l.t("verify.result.intact"),
                                       message: l.p("verify.result.intactMessage", report.checkedFiles))
                        } else if report.isUsable {
                            NoticeView(style: .warning, title: l.p("verify.result.issues", report.issues.count),
                                       message: l.t("verify.result.issuesMessage"))
                        } else {
                            NoticeView(style: .error, title: l.t("verify.result.unusable"), message: l.t("verify.result.unusableMessage"))
                        }
                        if report.issues.contains(.checksumMissing) {
                            NoticeView(style: .info, title: l.t("verify.issue.checksumMissing"))
                        }
                        let listed = report.issues.filter { $0 != .checksumMissing }
                        if !listed.isEmpty {
                            Card {
                                ForEach(Array(listed.enumerated()), id: \.offset) { _, issue in
                                    Label(l.verificationIssueText(issue), systemImage: "exclamationmark.triangle")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let manifest = report.manifest {
                            let counts = InventoryCounts(manifest)
                            Card {
                                Text(l.t("verify.result.contents")).font(.headline)
                                CountRow(symbol: Symbols.component(.applications), color: .secondary, label: l.t("component.applications"), value: counts.applications)
                                CountRow(symbol: Symbols.component(.brewFormulae), color: .secondary, label: l.t("component.brewFormulae"), value: counts.formulae)
                                CountRow(symbol: Symbols.component(.brewCasks), color: .secondary, label: l.t("component.brewCasks"), value: counts.casks)
                                CountRow(symbol: Symbols.component(.appStore), color: .secondary, label: l.t("component.appStore"), value: manifest.masApps.count)
                                CountRow(symbol: Symbols.component(.fonts), color: .secondary, label: l.t("component.fonts"), value: counts.fonts)
                                CountRow(symbol: Symbols.component(.colorProfiles), color: .secondary, label: l.t("component.colorProfiles"), value: counts.colorProfiles)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
        } buttons: {
            if let url = model.backupURL, report?.isUsable == true {
                Button(l.t("verify.result.restore")) { model.openBackupForRestore(url) }
            }
            Button(l.t("common.done")) { model.goHome() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
