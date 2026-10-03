import MacReplicaCore
import SwiftUI

/// Backup selection for fonts and ICC profiles: "What do you want to take with you?"
struct FontsAndProfilesSection: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showFonts = false
    @ViewState private var showProfiles = false

    var body: some View {
        let l = model.l
        let fonts = model.inventory?.fonts.map(\.record) ?? []
        let profiles = model.inventory?.colorProfiles.map(\.record) ?? []
        if !fonts.isEmpty || !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t("files.section.title")).font(.headline)
                Text(l.t("files.section.message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    if !fonts.isEmpty {
                        FileGroupDisclosure(kind: .font, records: fonts, expanded: $showFonts)
                    }
                    if !fonts.isEmpty, !profiles.isEmpty { Divider() }
                    if !profiles.isEmpty {
                        FileGroupDisclosure(kind: .colorProfile, records: profiles, expanded: $showProfiles)
                    }
                    let assignments = model.inventory?.manifest.displayProfiles ?? []
                    if !assignments.isEmpty {
                        Divider()
                        Toggle(isOn: $model.includeDisplayAssignments) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.p("files.displayAssignments", assignments.count))
                                Text(assignments.map { "\($0.displayName ?? "–"): \($0.profileDescription ?? $0.macOSProfile ?? "")" }
                                    .joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(l.t("files.displayAssignments.hint")).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("files.displayAssignments")
                    }
                }
            }
        }
    }
}

private struct FileGroupDisclosure: View {
    @EnvironmentObject var model: AppModel
    var kind: BackupFileKind
    var records: [FileRecord]
    @Binding var expanded: Bool

    var body: some View {
        let l = model.l
        let ids = records.map { InventoryResult.selectionID($0, kind: kind) }
        let selected = ids.filter { !model.excludedBackupFiles.contains($0) }.count
        let groups = Dictionary(grouping: records) { $0.origin ?? ($0.domain == .user ? .userInstalled : .sharedInstalled) }
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(FileOrigin.allCases.filter { groups[$0] != nil }, id: \.self) { origin in
                    let members = groups[origin] ?? []
                    HStack {
                        Text(l.fileOriginText(origin)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(l.t("items.selectAll")) { set(members, on: true) }.buttonStyle(.link)
                        Button(l.t("items.selectNone")) { set(members, on: false) }.buttonStyle(.link)
                    }
                    .padding(.top, 4)
                    if origin == .displayGenerated {
                        Text(l.t("files.displayGenerated.hint")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(members.sorted { l.fileTitle($0).localizedStandardCompare(l.fileTitle($1)) == .orderedAscending }) { record in
                        BackupFileRow(record: record, kind: kind)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            // The whole row opens the list, not only the small triangle.
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: Symbols.component(kind == .font ? .fonts : .colorProfiles)).foregroundStyle(.secondary).frame(width: 20)
                    Text(l.t(kind == .font ? "component.fonts" : "component.colorProfiles"))
                    Spacer()
                    Text(l.t("files.selectedOf", selected, records.count))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("files.\(kind == .font ? "fonts" : "profiles")")
            .accessibilityValue(l.t("files.selectedOf", selected, records.count))
        }
    }

    private func set(_ members: [FileRecord], on: Bool) {
        for record in members {
            let id = InventoryResult.selectionID(record, kind: kind)
            if on { model.excludedBackupFiles.remove(id) } else { model.excludedBackupFiles.insert(id) }
        }
    }
}

private struct BackupFileRow: View {
    @EnvironmentObject var model: AppModel
    var record: FileRecord
    var kind: BackupFileKind

    var body: some View {
        let l = model.l
        let id = InventoryResult.selectionID(record, kind: kind)
        Toggle(isOn: Binding(
            get: { !model.excludedBackupFiles.contains(id) },
            set: { on in
                if on { model.excludedBackupFiles.remove(id) } else { model.excludedBackupFiles.insert(id) }
            })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l.fileTitle(record))
                Text(subtitle(l)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("file.\(id)")
    }

    private func subtitle(_ l: Localizer) -> String {
        var parts: [String] = []
        if let font = record.font {
            if font.styles.count > 1 { parts.append(l.p("files.styles", font.styles.count)) }
            if let version = font.shortVersion { parts.append(l.t("files.version", version)) }
            parts.append(font.format)
        } else if kind == .font {
            parts.append(l.t("files.legacyOrUnreadable"))
        }
        if let profile = record.profile {
            parts.append(l.profileClassText(profile.deviceClass))
            parts.append(profile.colorSpace)
            parts.append("ICC \(profile.version)")
        }
        parts.append(record.fileName)
        parts.append(l.fileSize(record.size))
        return parts.joined(separator: " · ")
    }
}
