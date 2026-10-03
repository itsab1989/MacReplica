import MacReplicaCore
import SwiftUI

struct RestoreSelectionView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showItems = false

    var body: some View {
        let l = model.l
        let items = model.candidateItems
        ScreenLayout(title: l.t("restore.select.title"), subtitle: backupSubtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reviewing = model.reviewingSession {
                        NoticeView(style: .info, title: l.t("restore.review.title"),
                                   message: l.p("restore.review.message", reviewing.finishedItemIDs.count))
                    } else {
                        Text(l.t("restore.select.intro"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    warnings

                    Card {
                        ForEach(RestoreComponent.allCases) { component in
                            let group = items.filter { $0.component == component }
                            let count = group.count
                            ComponentToggle(component: component, count: count, status: componentStatus(group))
                            if component != RestoreComponent.allCases.last { Divider() }
                        }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Button(l.t("restore.select.individual")) { showItems = true }
                            .accessibilityIdentifier("restore.individual")
                        Spacer()
                        Text(summaryText(items))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("restore.summary")
                    }

                    TapSection()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        } buttons: {
            Button(l.t("common.back")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(l.t("restore.select.dryRun")) { model.startDryRun() }
                .accessibilityIdentifier("restore.dryRun")
            Button(l.t("restore.select.start")) { model.requestRestoreStart() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.currentPlan().map { $0.items.isEmpty } ?? true)
                .accessibilityIdentifier("restore.start")
        }
        .sheet(isPresented: $showItems) { ItemSelectionSheet() }
        .sheet(isPresented: Binding(get: { !model.pendingConflicts.isEmpty }, set: { if !$0 { model.pendingConflicts = [] } })) {
            ConflictSheet(conflicts: model.pendingConflicts)
        }
        .sheet(isPresented: Binding(get: { model.adminNotice != nil }, set: { if !$0 { model.adminNotice = nil } })) {
            AdminNoticeSheet()
        }
    }

    /// "24 items in the backup · 22 selected · 6 already on this Mac"
    private func summaryText(_ items: [RestoreItem]) -> String {
        let l = model.l
        let selected = model.currentPlan()?.items.filter { $0.component != nil } ?? []
        var parts = [l.p("restore.select.backedUp", items.count), l.p("restore.select.selectedCount", selected.count)]
        if model.assessing {
            parts.append(l.t("restore.select.checking"))
        } else {
            let present = selected.filter { model.assessments[$0.id].map { ItemStatus.isSatisfied($0, model: model) } ?? false }.count
            if present > 0 { parts.append(l.p("restore.select.presentCount", present)) }
        }
        return parts.joined(separator: " · ")
    }

    /// For fonts and profiles: "3 ready · 1 already installed · 1 needs a decision".
    private func componentStatus(_ group: [RestoreItem]) -> String? {
        let l = model.l
        guard let first = group.first, first.kind.isFile, !model.assessing else { return nil }
        let entries = group.compactMap { model.assessments[$0.id] }
        guard !entries.isEmpty else { return nil }
        let excluded = model.selection.excludedItemIDs
        let counts: [(String, Int)] = [
            ("restore.select.status.ready", entries.filter { [.ready].contains($0.fileAssessment?.status) && !excluded.contains($0.id) }.count),
            ("restore.select.status.present", entries.filter { ItemStatus.isSatisfied($0, model: model) }.count),
            ("restore.select.status.decide", entries.filter { $0.fileAssessment?.needsDecision == true }.count),
            ("restore.select.status.notRecommended", entries.filter { model.notRecommendedItemIDs.contains($0.id) }.count),
        ]
        let text = counts.filter { $0.1 > 0 }.map { l.p($0.0, $0.1) }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    private var backupSubtitle: String {
        guard let manifest = model.manifest else { return "" }
        return model.l.t("restore.select.subtitle", model.l.date(manifest.createdAt), manifest.macosVersion,
                         model.l.architectureText(manifest.architecture))
    }

    @ViewBuilder private var warnings: some View {
        let l = model.l
        if let damaged = model.verification?.damagedFiles, !damaged.isEmpty {
            NoticeView(style: .warning, title: l.p("restore.select.damaged", damaged.count), message: l.t("restore.select.damagedHint"))
        }
        if let manifest = model.manifest, !manifest.displayProfiles.isEmpty, let keys = manifest.hardwareKeys {
            let same = keys.isSameMac(platformIdentifier: model.services.layout.displayColorManager.platformIdentifier())
            NoticeView(style: .info, title: l.t(same == true ? "restore.select.sameMac" : (same == false ? "restore.select.otherMac" : "restore.select.unknownMac")),
                       message: l.t("restore.select.displayHint"))
        }
        if let manifest = model.manifest, manifest.architecture != .unknown, manifest.architecture != model.services.architecture {
            NoticeView(style: .info, title: l.t("restore.select.otherArchitecture"),
                       message: l.t("restore.select.otherArchitectureHint", l.architectureText(manifest.architecture),
                                    l.architectureText(model.services.architecture)))
        }
    }
}

struct ComponentToggle: View {
    @EnvironmentObject var model: AppModel
    var component: RestoreComponent
    var count: Int
    var status: String? = nil

    var body: some View {
        let l = model.l
        Toggle(isOn: Binding(
            get: { model.selection.components.contains(component) },
            set: { on in
                if on { model.selection.components.insert(component) } else { model.selection.components.remove(component) }
            })) {
            HStack(spacing: 10) {
                Image(systemName: Symbols.component(component)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.componentText(component))
                    Text(l.componentHint(component)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status, model.selection.components.contains(component) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("component.\(component.rawValue).status")
                    }
                }
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(count == 0)
        .accessibilityIdentifier("component.\(component.rawValue)")
    }
}

/// Third-party Homebrew taps must be allowed explicitly.
struct TapSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let taps = (model.manifest?.brewTaps ?? []).filter { !$0.isBuiltIn }
        if !taps.isEmpty, model.selection.components.contains(.brewFormulae) || model.selection.components.contains(.brewCasks) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("taps.title")).font(.headline)
                Text(l.t("taps.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(taps) { tap in
                    Toggle(isOn: Binding(
                        get: { model.selection.enabledTaps.contains(tap.name.lowercased()) },
                        set: { on in
                            if on { model.selection.enabledTaps.insert(tap.name.lowercased()) } else { model.selection.enabledTaps.remove(tap.name.lowercased()) }
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tap.name).font(.system(.body, design: .monospaced))
                            if let remote = tap.remote {
                                Text(remote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

struct ItemSelectionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var search = ""

    var body: some View {
        let l = model.l
        let items = model.candidateItems.filter {
            search.isEmpty || l.itemTitle($0).localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)
                || $0.identifier.localizedCaseInsensitiveContains(search)
        }
        let undecided = (model.manifest?.applications ?? []).filter { $0.needsMatchDecision }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.t("items.title")).font(.title3.weight(.semibold))
                    Text(l.t("items.subtitle")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(l.t("items.search"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if !undecided.isEmpty, search.isEmpty {
                        Section {
                            ForEach(undecided) { app in RestoreMatchRow(app: app) }
                        } header: {
                            SectionHeader(title: l.t("match.title"))
                        }
                    }
                    ForEach(RestoreComponent.allCases) { component in
                        let group = items.filter { $0.component == component }
                        if !group.isEmpty, model.selection.components.contains(component) {
                            Section {
                                ForEach(group) { item in RestoreItemRow(item: item) }
                            } header: {
                                SectionHeader(title: l.componentText(component), toggleAll: { on in
                                    for item in group where !ItemStatus.isLocked(item, model: model) {
                                        if on, ItemStatus.canBeRestored(item, model: model) {
                                            model.selection.excludedItemIDs.remove(item.id)
                                        } else if !on {
                                            model.selection.excludedItemIDs.insert(item.id)
                                        }
                                    }
                                }, l: l)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                if model.assessing {
                    ProgressView().controlSize(.small)
                    Text(l.t("restore.select.checking")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l.t("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("individual.done")
            }
            .padding(12)
        }
        .frame(width: 680)
        .frame(minHeight: 460, idealHeight: 720, maxHeight: 900)
    }
}

/// How an item stands on this Mac, as shown in the restore selection.
@MainActor
enum ItemStatus {
    static func isSatisfied(_ entry: DryRunEntry, model: AppModel) -> Bool {
        switch model.filePrediction(entry) ?? entry.prediction {
        case .alreadyPresent, .identicalFileExists, .equivalentFileExists, .keepsMacOSVersion: return true
        default: return false
        }
    }

    /// Finished in the interrupted restore that is being continued.
    static func isLocked(_ item: RestoreItem, model: AppModel) -> Bool {
        model.reviewingSession?.results[item.id] != nil
    }

    static func canBeRestored(_ item: RestoreItem, model: AppModel) -> Bool {
        model.assessments[item.id]?.fileAssessment?.canBeRestored ?? true
    }

    /// A short status and its color.
    static func label(_ item: RestoreItem, model: AppModel) -> (String, Color)? {
        let l = model.l
        if let result = model.reviewingSession?.results[item.id] {
            return (l.t("items.status.done", l.outcomeText(result.outcome)), .secondary)
        }
        guard let entry = model.assessments[item.id] else { return model.assessing ? (l.t("items.status.checking"), .secondary) : nil }
        if let assessment = entry.fileAssessment {
            let color: Color
            switch assessment.status {
            case .ready: color = .green
            case .identical, .equivalent, .providedByMacOS: color = .secondary
            case .differentVersion, .differentFile, .legacyFormat, .obsoleteAppleProfile: color = .orange
            case .incompatible, .displayProfile: color = .red
            }
            return (l.fileStatusText(assessment, kind: item.kind), color)
        }
        switch entry.prediction {
        case .alreadyPresent, .identicalFileExists, .equivalentFileExists, .keepsMacOSVersion:
            return (l.t(item.kind.isFile || item.kind == .applicationData || item.kind == .gitConfiguration ? "items.status.present" : "items.status.installed"), .secondary)
        case .conflict, .environmentConflict: return (l.t("items.status.conflict"), .orange)
        case .willSkip(.applicationNotInstalled(let name)): return (l.t("items.status.waitsForApp", name), .orange)
        case .willSkip(.needsFullDiskAccess): return (l.t("items.status.needsFullDiskAccess"), .orange)
        case .willSkip(.applicationVersionOlder(let name, _, let backup)): return (l.t("items.status.needsNewerApp", name, backup), .orange)
        case .willSkip(let reason): return (l.skipText(reason), .secondary)
        case .backupFileDamaged: return (l.t("items.status.cannotVerify"), .red)
        case .checkedWhenRestoring: return (l.t("items.status.checkedLater"), .secondary)
        case .manualStep: return (l.t("items.status.guided"), .orange)
        default:
            if item.applicationData?.profile?.mustBeClosed == true { return (l.t("items.status.closeApp"), .green) }
            return (l.t(entry.requiresAdmin ? "items.status.readyAdmin" : "items.status.ready"), .green)
        }
    }
}

/// One item in the restore selection: checkbox, name, status, and for fonts and profiles the
/// decision and details.
struct RestoreItemRow: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem
    @ViewState private var showDetails = false

    var body: some View {
        let l = model.l
        let locked = ItemStatus.isLocked(item, model: model)
        let restorable = ItemStatus.canBeRestored(item, model: model)
        let entry = model.assessments[item.id]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { !model.selection.excludedItemIDs.contains(item.id) && restorable },
                    set: { on in
                        if on { model.selection.excludedItemIDs.remove(item.id) } else { model.selection.excludedItemIDs.insert(item.id) }
                    })) {
                    HStack(spacing: 6) {
                        Text(l.itemTitle(item)).lineLimit(1)
                        if item.kind == .applicationData { ConfidenceBadge(level: item.applicationData?.profile?.effectiveConfidence) }
                        if item.title != item.identifier, !item.kind.isFile, item.kind != .applicationData {
                            Text(item.identifier).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(locked || !restorable)
                .accessibilityIdentifier("item.\(item.id)")
                Spacer(minLength: 8)
                if let (text, color) = ItemStatus.label(item, model: model) {
                    Text(text).font(.caption).foregroundStyle(color).lineLimit(1)
                        .accessibilityIdentifier("item.status.\(item.id)")
                }
                if item.kind == .applicationData, let comparison = entry?.appDataComparison, !comparison.differentFiles.isEmpty {
                    Button { showDetails.toggle() } label: {
                        Image(systemName: showDetails ? "chevron.up.circle" : "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(l.t("items.details"))
                    .accessibilityLabel(l.t("items.details"))
                    .accessibilityIdentifier("item.details.\(item.id)")
                }
                if item.kind.isFile, entry?.fileAssessment != nil {
                    Button { showDetails.toggle() } label: {
                        Image(systemName: showDetails ? "chevron.up.circle" : "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(l.t("items.details"))
                    .accessibilityLabel(l.t("items.details"))
                    .accessibilityIdentifier("item.details.\(item.id)")
                }
            }
            if let entry, let assessment = entry.fileAssessment, !locked, !model.selection.excludedItemIDs.contains(item.id) {
                let choices = assessment.conflictChoices(kind: item.kind)
                if !choices.isEmpty {
                    HStack {
                        Text(l.t(assessment.status == .providedByMacOS ? "items.decision.macOS" : "items.decision"))
                            .font(.caption).foregroundStyle(.secondary)
                        Picker(l.t("items.decision"), selection: Binding(
                            get: { model.selection.conflictOverrides[item.id] ?? assessment.defaultResolution(kind: item.kind) },
                            set: { model.selection.conflictOverrides[item.id] = $0 })) {
                            ForEach(choices, id: \.self) { choice in
                                Text(choiceText(choice, assessment: assessment)).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("item.decision.\(item.id)")
                    }
                    .padding(.leading, 22)
                }
            }
            if item.kind == .pythonEnvironment, item.pythonEnvironment?.preservation != nil, !locked,
               !model.selection.excludedItemIDs.contains(item.id) {
                HStack {
                    Text(l.t("items.pythonStrategy")).font(.caption).foregroundStyle(.secondary)
                    Picker(l.t("items.pythonStrategy"), selection: Binding(get: { model.selection.sourceChoices[item.id] ?? "rebuild" },
                                                                           set: { model.selection.sourceChoices[item.id] = $0 == "rebuild" ? nil : $0 })) {
                        Text(l.t("items.pythonStrategy.rebuild")).tag("rebuild")
                        Text(l.t("items.pythonStrategy.preserve")).tag("preserve")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("item.pythonStrategy.\(item.id)")
                }
                .padding(.leading, 22)
            }
            if item.kind == .applicationData, let comparison = entry?.appDataComparison, !locked,
               !model.selection.excludedItemIDs.contains(item.id) {
                AppDataChoicesView(item: item, comparison: comparison, showDetails: showDetails)
                    .padding(.leading, 22)
            }
            if item.kind == .formula, item.originalVersion?.hasPrefix("HEAD") == true, !locked,
               !model.selection.excludedItemIDs.contains(item.id) {
                HStack {
                    Text(l.t("items.source")).font(.caption).foregroundStyle(.secondary)
                    Picker(l.t("items.source"), selection: Binding(get: { model.selection.sourceChoices[item.id] ?? "head" },
                                                                   set: { model.selection.sourceChoices[item.id] = $0 == "head" ? nil : $0 })) {
                        Text(l.t("items.source.head")).tag("head")
                        Text(l.t("items.source.stable")).tag("stable")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("item.source.\(item.id)")
                }
                .padding(.leading, 22)
            }
            if showDetails, let entry, let assessment = entry.fileAssessment {
                FileDetailsView(item: item, assessment: assessment)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private func choiceText(_ choice: ConflictResolution, assessment: FileAssessment) -> String {
        let l = model.l
        if assessment.status == .providedByMacOS {
            return l.t(choice == .replace ? "conflict.macOS.restore" : "conflict.macOS.keep")
        }
        return l.conflictChoiceText(choice, kind: item.kind)
    }
}

/// Technical details of a font or profile, shown on request.
/// For application data: which app version the data goes into, what happens with files that differ
/// from this Mac's, and (with details) which files those are.
struct AppDataChoicesView: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem
    var comparison: AppDataComparison
    var showDetails: Bool

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 4) {
            if let version = comparison.version, !version.alternatives.isEmpty {
                HStack {
                    Text(l.t("items.appVersion")).font(.caption).foregroundStyle(.secondary)
                    Picker(l.t("items.appVersion"), selection: Binding(
                        get: { version.chosen },
                        set: { choice in
                            model.selection.sourceChoices[item.id] = choice
                            model.assessDestination(applyDefaults: false)
                        })) {
                        ForEach(version.alternatives + [version.original], id: \.self) { name in
                            Text(name == version.original && !version.originalExists ? l.t("items.appVersion.notInstalled", name) : name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("item.appVersion.\(item.id)")
                }
            }
            if !comparison.differentFiles.isEmpty {
                HStack {
                    Text(l.p("items.differ", comparison.differentFiles.count)).font(.caption).foregroundStyle(.secondary)
                    Picker(l.t("items.decision"), selection: Binding(
                        get: { model.selection.conflictOverrides[item.id] ?? .keepExisting },
                        set: { model.selection.conflictOverrides[item.id] = $0 })) {
                        Text(l.t("items.decision.appData.keep")).tag(ConflictResolution.keepExisting)
                        Text(l.t("items.decision.appData.replace")).tag(ConflictResolution.replace)
                        Text(l.t("items.decision.appData.skip")).tag(ConflictResolution.skip)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("item.decision.\(item.id)")
                }
            }
            if showDetails, !comparison.differentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.t("items.appData.summary", comparison.newFiles, comparison.identicalFiles, comparison.differentFiles.count))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    ForEach(comparison.differentFiles.prefix(20), id: \.path) { file in
                        Text(l.t("items.appData.differentFile", file.path, l.fileSize(file.backupSize), date(file.backupModified, l),
                                 l.fileSize(file.existingSize), date(file.existingModified, l)))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if comparison.differentFiles.count > 20 {
                        Text(l.t("items.appData.moreFiles", comparison.differentFiles.count - 20)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private func date(_ value: Date?, _ l: Localizer) -> String {
        guard let value else { return "–" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: l.language.rawValue)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
}

struct FileDetailsView: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem
    var assessment: FileAssessment

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 2) {
            Text(l.fileStatusDetail(assessment, kind: item.kind))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(assessment.advisories, id: \.self) { advisory in
                Text(l.fileAdvisoryText(advisory)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file = item.file {
                Group {
                    detail(l.t("details.file"), file.fileName)
                    if let origin = file.origin { detail(l.t("details.origin"), l.fileOriginText(origin)) }
                    if let font = file.font {
                        if !font.styles.isEmpty { detail(l.t("details.styles"), font.styles.joined(separator: ", ")) }
                        if let version = font.shortVersion { detail(l.t("details.version"), version) }
                        detail(l.t("details.format"), font.format)
                        detail(l.t("details.postScript"), font.postScriptNames.prefix(4).joined(separator: ", "))
                    }
                    if let profile = file.profile {
                        detail(l.t("details.profileClass"), l.profileClassText(profile.deviceClass))
                        detail(l.t("details.colorSpace"), profile.colorSpace)
                        detail(l.t("details.version"), profile.version)
                        if let creator = profile.creator { detail(l.t("details.creator"), creator) }
                    }
                    detail(l.t("details.size"), l.fileSize(file.size))
                    if let installed = assessment.installedVersion, assessment.existingLocation != nil {
                        detail(l.t("details.installedVersion"), installed)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var toggleAll: ((Bool) -> Void)? = nil
    var l: Localizer? = nil

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let toggleAll, let l {
                Button(l.t("items.selectAll")) { toggleAll(true) }.buttonStyle(.link)
                Button(l.t("items.selectNone")) { toggleAll(false) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Match choice inside the restore selection; stored in the selection, not the backup.
struct RestoreMatchRow: View {
    @EnvironmentObject var model: AppModel
    var app: AppRecord

    var body: some View {
        let l = model.l
        HStack {
            Text(app.name)
            Spacer()
            Picker(l.t("match.pickerLabel"), selection: Binding(
                get: { model.selection.matchDecisions[app.path] ?? "" },
                set: { model.selection.matchDecisions[app.path] = $0 })) {
                ForEach(app.candidates, id: \.token) { candidate in
                    Text(l.t("match.candidate", candidate.name, candidate.token)).tag(candidate.token)
                }
                Divider()
                Text(l.t("match.none")).tag("")
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

struct ConflictSheet: View {
    @EnvironmentObject var model: AppModel
    var conflicts: [DryRunEntry]
    @ViewState private var choices: [String: ConflictResolution] = [:]

    init(conflicts: [DryRunEntry]) {
        self.conflicts = conflicts
        _choices = ViewState(initialValue: Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, Self.defaultChoice($0)) }))
    }

    static func choices(_ entry: DryRunEntry) -> [ConflictResolution] {
        entry.fileAssessment?.conflictChoices(kind: entry.item.kind) ?? [.keepExisting, .replace, .skip]
    }

    static func defaultChoice(_ entry: DryRunEntry) -> ConflictResolution {
        entry.fileAssessment?.defaultResolution(kind: entry.item.kind) ?? .keepExisting
    }

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l.p("conflict.title", conflicts.count)).font(.title3.weight(.semibold))
                Text(l.t("conflict.message")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(conflicts) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: Symbols.kind(entry.item.kind)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.itemTitle(entry.item))
                                Text(entry.fileAssessment.map { l.fileStatusDetail($0, kind: entry.item.kind) }
                                     ?? (entry.item.file.map { $0.domain == .user ? l.t("location.user") : l.t("location.system") } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker(entry.item.title, selection: Binding(get: { choices[entry.id] ?? Self.defaultChoice(entry) }, set: { choices[entry.id] = $0 })) {
                                ForEach(Self.choices(entry), id: \.self) { choice in
                                    Text(l.conflictChoiceText(choice, kind: entry.item.kind)).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: CGFloat(min(conflicts.count, 5)) * 74)
            Text(l.t("conflict.replaceHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Menu(l.t("conflict.applyToAll")) {
                    ForEach([ConflictResolution.keepBoth, .keepExisting, .replace, .skip], id: \.self) { choice in
                        Button(l.conflictChoiceText(choice, kind: .font)) { setAll(choice) }
                    }
                }
                .fixedSize()
                Spacer()
                Button(l.t("common.cancel")) { model.pendingConflicts = [] }
                    .keyboardShortcut(.cancelAction)
                Button(l.t("common.continue")) { model.resolveConflicts(choices) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("conflict.continue")
            }
            .padding(12)
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Applies a choice to every conflict that offers it.
    private func setAll(_ resolution: ConflictResolution) {
        for entry in conflicts where Self.choices(entry).contains(resolution) { choices[entry.id] = resolution }
    }
}

struct AdminNoticeSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let notice = model.adminNotice
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("admin.title")).font(.title3.weight(.semibold))
            if notice?.installsCommandLineTools == true {
                NoticeView(style: .info, title: l.t("admin.clt.title"), message: l.t("admin.clt.message"))
            }
            if notice?.installsHomebrew == true || notice?.copiesSharedFiles == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l.t("admin.password.message")).fixedSize(horizontal: false, vertical: true)
                    if notice?.installsHomebrew == true {
                        Label(l.t("admin.password.homebrew"), systemImage: "mug").fixedSize(horizontal: false, vertical: true)
                    }
                    if notice?.copiesSharedFiles == true {
                        Label(l.t("admin.password.files"), systemImage: "folder").fixedSize(horizontal: false, vertical: true)
                    }
                    Text(l.t("admin.password.privacy"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(l.t("common.cancel")) { model.adminNotice = nil }
                    .keyboardShortcut(.cancelAction)
                Button(l.t("admin.continue")) { model.startRestore() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("admin.continue")
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
