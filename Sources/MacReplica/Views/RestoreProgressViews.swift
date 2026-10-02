import MacReplicaCore
import SwiftUI

struct DryRunView: View {
    @EnvironmentObject var model: AppModel

    private enum Group: CaseIterable { case change, present, conflict, skip }

    private func group(_ prediction: Prediction) -> Group {
        switch prediction {
        case .willInstall, .willCopy, .dependsOnEarlierStep, .checkedWhenRestoring, .willRecreateEnvironment, .willCompleteEnvironment: return .change
        case .alreadyPresent, .identicalFileExists, .equivalentFileExists, .keepsMacOSVersion: return .present
        case .conflict, .environmentConflict: return .conflict
        case .willSkip, .backupFileDamaged: return .skip
        }
    }

    private func title(_ group: Group, count: Int) -> String {
        switch group {
        case .change: return model.l.p("dryRun.group.change", count)
        case .present: return model.l.p("dryRun.group.present", count)
        case .conflict: return model.l.p("dryRun.group.conflict", count)
        case .skip: return model.l.p("dryRun.group.skip", count)
        }
    }

    var body: some View {
        let l = model.l
        ScreenLayout(title: l.t("dryRun.title"), subtitle: l.t("dryRun.subtitle")) {
            if model.dryRunInProgress {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(l.t("dryRun.checking")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(Group.allCases, id: \.self) { group in
                            let entries = model.dryRunEntries.filter { self.group($0.prediction) == group }
                            if !entries.isEmpty {
                                Section {
                                    ForEach(entries) { entry in DryRunRow(entry: entry) }
                                } header: {
                                    SectionHeader(title: title(group, count: entries.count))
                                }
                            }
                        }
                        if let manual = model.plan?.manualApps, !manual.isEmpty {
                            Section {
                                ForEach(manual) { app in
                                    HStack(alignment: .top) {
                                        Image(systemName: Symbols.category(app.restoreMethod.category)).foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(app.name)
                                            Text(l.manualHint(for: app)).font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 3)
                                }
                            } header: {
                                SectionHeader(title: l.p("dryRun.group.manual", manual.count))
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        } buttons: {
            Button(l.t("common.back")) { model.screen = .restoreSelection }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(l.t("dryRun.export")) { model.exportDryRunReport() }
                .accessibilityIdentifier("dryRun.export")
                .disabled(model.dryRunInProgress)
            Button(l.t("restore.select.start")) {
                model.screen = .restoreSelection
                model.requestRestoreStart()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("dryRun.start")
            .disabled(model.dryRunInProgress)
        }
    }
}

struct DryRunRow: View {
    @EnvironmentObject var model: AppModel
    var entry: DryRunEntry

    var body: some View {
        let l = model.l
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Symbols.kind(entry.item.kind)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.itemTitle(entry.item))
                Text(l.predictionText(entry.prediction, kind: entry.item.kind))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let assessment = entry.fileAssessment, assessment.status != .ready {
                    Text(l.fileStatusDetail(assessment, kind: entry.item.kind))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                    Text(l.noteText(note)).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if entry.requiresAdmin {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help(l.t("report.dryRun.needsAdmin"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

struct RestoreProgressView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var confirmStop = false

    var body: some View {
        let l = model.l
        let p = model.progress
        ScreenLayout(title: l.t("progress.title"), subtitle: l.t("progress.subtitle")) {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.t("progress.position", p.position, p.total))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .accessibilityIdentifier("progress.position")
                        Spacer()
                        if let remaining = p.estimator.remainingSeconds, p.currentItem != nil {
                            Text(l.t("progress.remaining", l.remainingTime(remaining)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let item = p.currentItem {
                        HStack(spacing: 10) {
                            Image(systemName: Symbols.kind(item.kind)).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.itemTitle(item)).font(.headline).lineLimit(1)
                                Text(l.itemMethodText(item.kind)).foregroundStyle(.secondary)
                            }
                        }
                        Text(l.activityText(p.activity))
                            .foregroundStyle(p.activity == .waitingForCommandLineTools || p.activity == .waitingForAdmin ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(p.stopping ? l.t("progress.stopping") : l.t("progress.finishing")).foregroundStyle(.secondary)
                    }
                    ProgressView(value: p.fraction)
                        .accessibilityIdentifier("progress.bar")
                    HStack(spacing: 18) {
                        Label(l.t("progress.succeeded", p.succeeded), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Label(l.t("progress.failed", p.failed), systemImage: "xmark.circle.fill").foregroundStyle(p.failed > 0 ? .red : .secondary)
                        Label(l.t("progress.skipped", p.skipped), systemImage: "minus.circle.fill").foregroundStyle(.secondary)
                        Spacer()
                        Text(l.percent(p.fraction)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                if !p.finished.isEmpty {
                    Text(l.t("progress.recent")).font(.headline)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(p.finished.enumerated()), id: \.offset) { index, entry in
                                    HStack(spacing: 8) {
                                        OutcomeIcon(outcome: entry.result.outcome)
                                        Text(l.itemTitle(entry.item)).lineLimit(1)
                                        Spacer()
                                        Text(l.outcomeText(entry.result.outcome))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .id(index)
                                }
                            }
                        }
                        .onChange(of: p.finished.count) { count in
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        } buttons: {
            Text(l.t("progress.keepOpen")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(l.t("progress.stop")) { confirmStop = true }
                .disabled(p.stopping)
                .accessibilityIdentifier("progress.stop")
        }
        .confirmationDialog(l.t("progress.stopConfirm.title"), isPresented: $confirmStop) {
            Button(l.t("progress.stop"), role: .destructive) { model.stopRestore() }
            Button(l.t("progress.continue"), role: .cancel) {}
        } message: {
            Text(l.t("progress.stopConfirm.message"))
        }
    }
}

struct RestoreSummaryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let plan = model.plan
        let session = model.session
        let results = plan?.items.compactMap { item in session?.results[item.id].map { (item, $0) } } ?? []
        let failed = results.filter { $0.1.outcome.isFailure }
        let skipped = results.filter { $0.1.outcome.isSkip }
        let notes = results.filter { !$0.1.notes.isEmpty && !$0.1.outcome.isFailure }
        let summary = RestoreSummary(results: results.map(\.1), total: plan?.items.count ?? 0)
        let complete = session?.status == .completed
        let title = !complete ? l.t("summary.title.stopped") : (failed.isEmpty ? l.t("summary.title.done") : l.t("summary.title.problems"))

        ScreenLayout(title: title, subtitle: nil) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SummaryTile(value: summary.succeeded, label: l.t("summary.succeeded"), color: .green)
                            .accessibilityIdentifier("summary.succeeded")
                        SummaryTile(value: summary.failed, label: l.t("summary.failed"), color: summary.failed > 0 ? .red : .secondary)
                            .accessibilityIdentifier("summary.failed")
                        SummaryTile(value: summary.skipped, label: l.t("summary.skipped"), color: .secondary)
                    }
                    if !complete {
                        NoticeView(style: .info, title: l.t("summary.stopped.title"), message: l.t("summary.stopped.message"))
                    } else if failed.isEmpty {
                        NoticeView(style: .success, title: l.t("summary.allDone.title"), message: l.t("summary.allDone.message"))
                    }
                    if !failed.isEmpty {
                        Text(l.t("summary.failedHeading")).font(.headline)
                        ForEach(failed, id: \.0.id) { item, result in FailureRow(item: item, result: result) }
                    }
                    if let manual = plan?.manualApps, !manual.isEmpty {
                        Text(l.t("summary.manualHeading")).font(.headline)
                        Text(l.t("summary.manualMessage")).foregroundStyle(.secondary).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(manual) { app in ManualAppRow(app: app) }
                    }
                    if !notes.isEmpty {
                        DisclosureGroup(l.p("summary.notesHeading", notes.count)) {
                            ForEach(notes, id: \.0.id) { item, result in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l.itemTitle(item))
                                    ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                                        Text(l.noteText(note)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if let guidance = model.manifest?.guidance, !guidance.isEmpty {
                        GuidanceList(records: guidance)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                    if !failed.isEmpty || !complete {
                        LogHint()
                    }
                    if !skipped.isEmpty {
                        DisclosureGroup(l.p("summary.skippedHeading", skipped.count)) {
                            ForEach(skipped, id: \.0.id) { item, result in
                                HStack {
                                    Text(l.itemTitle(item))
                                    Spacer()
                                    Text(l.outcomeText(result.outcome)).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
        } buttons: {
            if let report = model.lastReport {
                Button(l.t("summary.openReport")) { model.open(report) }
            }
            Spacer()
            if !complete, let session {
                Button(l.t("resume.continue")) { model.resumeRestore(session) }
            }
            if !failed.isEmpty {
                Button(l.t("summary.retry")) { model.retryFailed() }
                    .accessibilityIdentifier("summary.retry")
            }
            Button(l.t("common.done")) { model.goHome() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("summary.done")
        }
    }
}

struct SummaryTile: View {
    var value: Int
    var label: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct FailureRow: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem
    var result: ItemResult
    @ViewState private var expanded = false

    var body: some View {
        let l = model.l
        if case .failed(let failure) = result.outcome {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(l.itemTitle(item)) — \(l.failureTitle(failure.category))").fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l.failureExplanation(failure.category))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !failure.technicalDetail.isEmpty {
                    DisclosureGroup(l.t("common.technicalDetails"), isExpanded: $expanded) {
                        Text(failure.technicalDetail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .padding(.leading, 24)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))
        }
    }
}

struct ManualAppRow: View {
    @EnvironmentObject var model: AppModel
    var app: AppRecord

    var body: some View {
        let l = model.l
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).fontWeight(.medium)
                Text(l.manualHint(for: app)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let homepage = app.homepage {
                Button(l.t("summary.openWebsite")) { model.openWebPage(homepage) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
