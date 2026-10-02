import MacReplicaCore
import SwiftUI

/// "Developer tools": version managers, runtimes, global tools and other package managers found on this Mac.
struct DeveloperToolsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let records = model.inventory?.manifest.toolchains ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text(l.t("developerTools.section.title")).font(.headline)
            Text(l.t("developerTools.section.message"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if records.isEmpty {
                Text(l.t("developerTools.none")).foregroundStyle(.secondary)
            } else {
                Card {
                    ForEach(Ecosystem.allCases) { ecosystem in
                        let group = records.filter { $0.ecosystem == ecosystem }
                        if !group.isEmpty {
                            Label(l.ecosystemText(ecosystem), systemImage: Symbols.ecosystem(ecosystem))
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, ecosystem == records.first?.ecosystem ? 0 : 6)
                            ForEach(group) { record in ToolchainToggle(record: record) }
                        }
                    }
                }
            }
        }
    }
}

struct ToolchainToggle: View {
    @EnvironmentObject var model: AppModel
    var record: ToolchainRecord

    var body: some View {
        let l = model.l
        let descriptor = ToolchainCatalog.descriptor(record.provider)
        Toggle(isOn: Binding(get: { !model.excludedToolchains.contains(record.provider) },
                             set: { on in if on { model.excludedToolchains.remove(record.provider) } else { model.excludedToolchains.insert(record.provider) } })) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(descriptor.name)
                    if let location = record.location { Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(l.supportLevelText(descriptor.overallSupport)).font(.caption)
                    .foregroundStyle(descriptor.overallSupport == .automatic ? .green : (descriptor.overallSupport == .guided ? .orange : .secondary))
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("toolchain.\(record.provider.rawValue)")
    }

    private var summary: String {
        let l = model.l
        var parts: [String] = []
        if !record.runtimes.isEmpty {
            let names = record.runtimes.prefix(4).map { $0.version + ($0.isDefault ? "*" : "") }.joined(separator: ", ")
            parts.append(l.p("developerTools.runtimes", record.runtimes.count) + ": " + names + (record.runtimes.count > 4 ? " …" : ""))
        }
        if !record.packages.isEmpty {
            let names = record.packages.prefix(4).map(\.name).joined(separator: ", ")
            parts.append(l.p("developerTools.packages", record.packages.count) + ": " + names + (record.packages.count > 4 ? " …" : ""))
        }
        if !record.environments.isEmpty {
            parts.append(l.p("developerTools.environments", record.environments.count) + ": " + record.environments.map(\.name).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// The open steps on the summary screen: apps to install and developer-tool steps for the user.
struct GuidedStepsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let apps = model.openApps
        let tools = model.openToolchainSteps
        if !apps.isEmpty || !tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t("summary.guidedHeading")).font(.headline)
                Text(l.t("summary.guidedMessage")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(apps.prefix(6)) { item in
                    HStack {
                        Image(systemName: Symbols.kind(item.kind)).foregroundStyle(.secondary).frame(width: 18)
                        Text(item.title)
                        if let channel = item.app?.channel, channel.isPrerelease { ChannelBadge(channel: channel) }
                        Spacer()
                        Text(l.outcomeText(model.session?.results[item.id]?.outcome ?? .skipped(.manualStepRequired)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if apps.count > 6 { Text(l.p("summary.guidedMore", apps.count - 6)).font(.caption).foregroundStyle(.secondary) }
                if !tools.isEmpty { Text(l.p("summary.guidedTools", tools.count)).font(.callout) }
                HStack {
                    Spacer()
                    Button(l.t("summary.guidedOpen")) { model.showGuidedInstall() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("summary.guided")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}
