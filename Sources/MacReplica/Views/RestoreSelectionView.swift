import MacReplicaCore
import SwiftUI

struct RestoreSelectionView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showItems = false

    var body: some View {
        let l = model.l
        let items = model.candidateItems
        let manualCount = model.currentPlan()?.manualApps.count ?? 0
        ScreenLayout(title: l.t("restore.select.title"), subtitle: backupSubtitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    warnings

                    Card {
                        ForEach(RestoreComponent.allCases) { component in
                            let count = items.filter { $0.component == component }.count + (component == .applications ? manualCount : 0)
                            ComponentToggle(component: component, count: count)
                            if component != RestoreComponent.allCases.last { Divider() }
                        }
                    }

                    HStack {
                        Button(l.t("restore.select.individual")) { showItems = true }
                            .accessibilityIdentifier("restore.individual")
                        Spacer()
                        Text(l.p("restore.select.summary", model.currentPlan()?.items.filter { $0.component != nil }.count ?? 0))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    TapSection()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(l.t("restore.select.conflictQuestion")).font(.headline)
                        Picker(l.t("restore.select.conflictQuestion"), selection: $model.selection.conflictResolution) {
                            Text(l.t("conflict.keep")).tag(ConflictResolution.keepExisting)
                            Text(l.t("conflict.replace")).tag(ConflictResolution.replace)
                            Text(l.t("conflict.skip")).tag(ConflictResolution.skip)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 420)
                        Text(l.t("restore.select.conflictHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            ConflictSheet(conflicts: model.pendingConflicts, defaultResolution: model.selection.conflictResolution)
        }
        .sheet(isPresented: Binding(get: { model.adminNotice != nil }, set: { if !$0 { model.adminNotice = nil } })) {
            AdminNoticeSheet()
        }
        .sheet(isPresented: $model.askForRestorePassphrase) { RestorePassphraseSheet() }
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
        let items = model.candidateItems.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) }
        let undecided = (model.manifest?.applications ?? []).filter { $0.needsMatchDecision }
        VStack(spacing: 0) {
            HStack {
                Text(l.t("items.title")).font(.title3.weight(.semibold))
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
                                ForEach(group) { item in
                                    Toggle(isOn: Binding(
                                        get: { !model.selection.excludedItemIDs.contains(item.id) },
                                        set: { on in
                                            if on { model.selection.excludedItemIDs.remove(item.id) } else { model.selection.excludedItemIDs.insert(item.id) }
                                        })) {
                                        HStack {
                                            Text(item.title)
                                            if item.title != item.identifier, !item.kind.isFile {
                                                Text(item.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if let version = item.originalVersion {
                                                Text(version).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                }
                            } header: {
                                SectionHeader(title: l.componentText(component), toggleAll: { on in
                                    for item in group {
                                        if on { model.selection.excludedItemIDs.remove(item.id) } else { model.selection.excludedItemIDs.insert(item.id) }
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
                Spacer()
                Button(l.t("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
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
    var conflicts: [RestoreItem]
    @ViewState private var choices: [String: ConflictResolution] = [:]
    var defaultResolution: ConflictResolution

    init(conflicts: [RestoreItem], defaultResolution: ConflictResolution) {
        self.conflicts = conflicts
        self.defaultResolution = defaultResolution
        _choices = ViewState(initialValue: Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, defaultResolution) }))
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
                    ForEach(conflicts) { item in
                        HStack {
                            Image(systemName: Symbols.kind(item.kind)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                Text(item.file.map { $0.domain == .user ? l.t("location.user") : l.t("location.system") } ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker(item.title, selection: Binding(get: { choices[item.id] ?? defaultResolution }, set: { choices[item.id] = $0 })) {
                                Text(l.t("conflict.keep")).tag(ConflictResolution.keepExisting)
                                Text(l.t("conflict.replace")).tag(ConflictResolution.replace)
                                Text(l.t("conflict.skip")).tag(ConflictResolution.skip)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 300)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 50, maxHeight: CGFloat(min(conflicts.count, 6)) * 52)
            Text(l.t("conflict.replaceHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Menu(l.t("conflict.applyToAll")) {
                    Button(l.t("conflict.keep")) { setAll(.keepExisting) }
                    Button(l.t("conflict.replace")) { setAll(.replace) }
                    Button(l.t("conflict.skip")) { setAll(.skip) }
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
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setAll(_ resolution: ConflictResolution) {
        for item in conflicts { choices[item.id] = resolution }
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
