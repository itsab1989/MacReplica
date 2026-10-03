import MacReplicaCore
import SwiftUI

/// Apps without automatic installation and App Store apps: official sources, downloads, guided installation.
struct GuidedInstallView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let apps = model.openApps
        let tools = model.openToolchainSteps
        ScreenLayout(title: l.t("guided.title"), subtitle: l.t("guided.subtitle")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if apps.isEmpty && tools.isEmpty {
                        NoticeView(style: .success, title: l.t("guided.allDone.title"), message: l.t("guided.allDone.message"))
                    }
                    if !apps.isEmpty {
                        Text(l.p("guided.apps.heading", apps.count)).font(.headline)
                        if !model.guided.searched {
                            NoticeView(style: .info, title: l.t("guided.find.title"), message: l.t("guided.find.message"))
                            HStack {
                                Spacer()
                                if model.guided.findingOffers { ProgressView().controlSize(.small) }
                                Button(l.t("guided.find.button")) { model.findOffers() }
                                    .disabled(model.guided.findingOffers)
                                    .accessibilityIdentifier("guided.find")
                            }
                        }
                        Card {
                            ForEach(apps) { item in
                                GuidedAppRow(item: item)
                                if item.id != apps.last?.id { Divider() }
                            }
                        }
                    }
                    if !tools.isEmpty {
                        Text(l.p("guided.tools.heading", tools.count)).font(.headline)
                        Text(l.t("guided.tools.message")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Card {
                            ForEach(tools) { item in
                                GuidedToolchainRow(item: item)
                                if item.id != tools.last?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        } buttons: {
            Button(l.t("guided.back")) { model.screen = .restoreSummary }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("guided.back")
            Spacer()
            Button(l.t("guided.checkAgain")) { model.checkOpenStepsAgain() }
                .help(l.t("guided.checkAgain.help"))
                .disabled(model.guided.running)
                .accessibilityIdentifier("guided.checkAgain")
            if !apps.isEmpty {
                Button(l.t("guided.downloadSelected")) { model.downloadSelected() }
                    .disabled(!model.guided.searched || model.guided.selected.isEmpty || model.guided.running)
                    .accessibilityIdentifier("guided.downloadSelected")
                Button(l.t("guided.installSequence")) { model.installSequentially(apps.map(\.id).filter { model.guided.selected.contains($0) }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.guided.selected.isEmpty || model.guided.running)
                    .accessibilityIdentifier("guided.installSequence")
            }
        }
        .sheet(isPresented: Binding(get: { model.guided.pending != nil }, set: { if !$0 { model.answerPending(.later) } })) {
            if let pending = model.guided.pending { PendingStepSheet(pending: pending) }
        }
    }
}

/// One app: tick for the sequence, chosen source, download progress and status.
struct GuidedAppRow: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem

    var body: some View {
        let l = model.l
        let offers = model.guided.offers[item.id] ?? []
        let chosen = model.chosenOffer(for: item.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(get: { model.guided.selected.contains(item.id) },
                                     set: { on in if on { model.guided.selected.insert(item.id) } else { model.guided.selected.remove(item.id) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title).fontWeight(.medium)
                            if let channel = item.app?.channel, channel.isPrerelease { ChannelBadge(channel: channel) }
                        }
                        Text([item.originalVersion.map { l.t("common.version", $0) }, item.kind == .appStoreApp ? l.t("method.appStore") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(model.guided.running)
                .accessibilityIdentifier("guided.select.\(item.id)")
                Spacer()
                GuidedStatusView(item: item)
            }
            if offers.count > 1 {
                HStack {
                    Text(l.t("guided.source")).font(.caption).foregroundStyle(.secondary)
                    Picker(l.t("guided.source"), selection: Binding(get: { chosen?.id ?? "" }, set: { model.chooseOffer($0, for: item.id) })) {
                        ForEach(offers) { offer in Text(l.offerText(offer)).tag(offer.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.guided.running)
                    .accessibilityIdentifier("guided.source.\(item.id)")
                }
                .padding(.leading, 22)
            } else if let chosen {
                Text(l.offerText(chosen)).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            } else if model.guided.searched {
                Text(l.t("guided.noSource")).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }
            if let chosen {
                Text(chosen.kind == .appStore ? l.t("offer.appStore.hint") : chosen.kind == .vendorWebsite ? l.t("offer.website.hint") : l.trustText(chosen.trust))
                    .font(.caption)
                    .foregroundStyle(chosen.isDownloadable || chosen.kind == .appStore || chosen.kind == .vendorWebsite ? Color.secondary : Color.orange)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if case .downloading? = model.guided.downloads[item.id] {
                    Button(l.t("guided.pause")) { model.pauseDownload(item.id) }.accessibilityIdentifier("guided.pause.\(item.id)")
                    Button(l.t("guided.cancelDownload")) { model.cancelDownload(item.id) }.accessibilityIdentifier("guided.cancel.\(item.id)")
                } else if model.guided.downloads[item.id] == .paused {
                    Button(l.t("guided.resume")) { model.resumeDownload(item.id) }.accessibilityIdentifier("guided.resume.\(item.id)")
                } else if case .failed? = model.guided.downloads[item.id] {
                    Button(l.t("guided.retry")) { model.retryDownload(item.id) }.accessibilityIdentifier("guided.retry.\(item.id)")
                }
                if !model.guided.running {
                    Button(l.t("guided.later")) { model.markGuided(item.id, .postponedByUser) }
                        .accessibilityIdentifier("guided.later.\(item.id)")
                    Button(l.t("guided.skip")) { model.markGuided(item.id, .userSkipped) }
                        .accessibilityIdentifier("guided.skip.\(item.id)")
                    Button(l.t("guided.installOne")) { model.installSequentially([item.id]) }
                        .accessibilityIdentifier("guided.install.\(item.id)")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// Download progress or the current state of an app in the guided installation.
struct GuidedStatusView: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem

    var body: some View {
        let l = model.l
        Group {
            switch model.guided.downloads[item.id] {
            case .downloading(let received, let expected)?:
                HStack(spacing: 6) {
                    if let expected, expected > 0 {
                        ProgressView(value: Double(received), total: Double(expected)).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)).font(.caption.monospacedDigit())
                }
            case .queued?: Text(l.t("guided.state.queued"))
            case .paused?: Text(l.t("guided.state.paused"))
            case .failed(let error)?: Text(l.downloadErrorText(error)).foregroundStyle(.red)
            default:
                switch model.guided.states[item.id] ?? .notStarted {
                case .verifying: Text(l.t("guided.state.verifying"))
                case .installing: Text(l.t("guided.state.installing"))
                case .waitingForUser: Text(l.t("guided.state.waiting")).foregroundStyle(.orange)
                case .finished(let outcome): Text(l.outcomeText(outcome)).foregroundStyle(outcome.isFailure ? .red : .green)
                case .downloading: Text(l.t("guided.state.queued"))
                case .notStarted:
                    if case .finished? = model.guided.downloads[item.id] { Text(l.t("guided.state.downloaded")) } else { EmptyView() }
                }
            }
        }
        .font(.caption)
        .accessibilityIdentifier("guided.status.\(item.id)")
    }
}

/// A developer-tool step the user performs: the exact command or page, copyable.
struct GuidedToolchainRow: View {
    @EnvironmentObject var model: AppModel
    var item: RestoreItem

    var body: some View {
        let l = model.l
        let instruction = model.instruction(for: item)
        let descriptor = item.toolchain.map { ToolchainCatalog.descriptor($0.provider) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l.itemTitle(item)).fontWeight(.medium)
                Spacer()
                if let result = model.session?.results[item.id] {
                    Text(l.outcomeText(result.outcome)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if item.kind == .displayProfile, let instruction {
                Text(instruction).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let instruction, instruction.hasPrefix("https://") {
                Button(instruction) { model.openWebPage(instruction) }.buttonStyle(.link).font(.caption)
            } else if let instruction {
                HStack(alignment: .top) {
                    Text(instruction).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Button(l.t("guided.copy")) { model.copyToPasteboard(instruction) }
                        .controlSize(.small)
                        .accessibilityIdentifier("guided.copy.\(item.id)")
                }
            } else if let descriptor {
                Text(l.t("guided.installManager", descriptor.name)).font(.caption).foregroundStyle(.secondary)
            }
            if let descriptor {
                Button(l.t("guided.website", descriptor.name)) { model.openWebPage(descriptor.website) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shown while MacReplica waits for the user to finish a step outside the app.
struct PendingStepSheet: View {
    @EnvironmentObject var model: AppModel
    var pending: PendingGuidedStep

    var body: some View {
        let l = model.l
        let title = model.openApps.first { $0.id == pending.itemID }?.title ?? model.plan?.item(id: pending.itemID)?.title ?? ""
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Text(l.guidedStepText(pending.step)).fixedSize(horizontal: false, vertical: true)
            Text(l.t("guided.pending.hint")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(l.t("guided.pending.cancel"), role: .destructive) { model.answerPending(.cancel) }
                    .accessibilityIdentifier("pending.cancel")
                Spacer()
                Button(l.t("guided.skip")) { model.answerPending(.skip) }.accessibilityIdentifier("pending.skip")
                Button(l.t("guided.later")) { model.answerPending(.later) }.accessibilityIdentifier("pending.later")
                Button(l.t("guided.pending.done")) { model.answerPending(.checkAgain) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pending.done")
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

/// A small label for pre-release channels ("Nightly", "Beta" …).
struct ChannelBadge: View {
    @EnvironmentObject var model: AppModel
    var channel: ReleaseChannel

    var body: some View {
        Text(model.l.channelText(channel))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
    }
}
