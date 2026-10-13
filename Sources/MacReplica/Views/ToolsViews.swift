import MacReplicaCore
import SwiftUI

/// The Tools section: independent tools for this Mac, each in the same card layout (what it is, what MacReplica
/// found, what it would change, whether a password is needed, the action, how to undo it, the limits and the
/// verified result). New tools are added as further cards.
struct ToolsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let env = model.tools.environment
        ScreenLayout(title: l.t("tools.title"),
                     subtitle: l.t("tools.subtitle", env.macOSVersion, l.t("tools.arch.\(env.architecture.rawValue)"))) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(l.t("tools.intro")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    GatekeeperToolCard()
                    UpdatesToolCard()
                    WindowCornersToolCard()
                    if !model.tools.history.isEmpty { ToolHistoryView() }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        } buttons: {
            Button(l.t("common.back")) { model.goHome() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("tools.back")
            Spacer()
        }
    }
}

/// The frame every tool uses: title with help, a capability badge, then the tool's own content.
struct ToolCard<Content: View>: View {
    @EnvironmentObject var model: AppModel
    var id: String
    var symbol: String
    var title: String
    var summary: String
    var help: String
    var capability: ToolCapability?
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.headline)
                        HelpButton(text: help, title: title, id: "help.tools.\(id)")
                        Spacer(minLength: 8)
                        if let capability { CapabilityBadge(capability: capability) }
                    }
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tools.\(id)")
    }
}

struct CapabilityBadge: View {
    @EnvironmentObject var model: AppModel
    var capability: ToolCapability

    private var color: Color {
        switch capability {
        case .supported: return .green
        case .supportedWithRestrictions, .requiresAdministrator, .requiresUserAction: return .blue
        case .experimental: return .orange
        case .managedExternally, .unsupportedOnThisVersion, .unableToDetermine: return .secondary
        }
    }

    var body: some View {
        Text(model.l.t("tools.capability.\(capability.rawValue)"))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityIdentifier("tools.capability.\(capability.rawValue)")
    }
}

/// One “label: value” line of a detected state.
struct ToolStateRow: View {
    var symbol: String
    var color: Color
    var label: String
    var value: String
    var id: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id ?? "")
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Limits of a tool, always visible as a disclosure (not a hover tooltip).
struct ToolLimitations: View {
    @EnvironmentObject var model: AppModel
    var id: String
    var lines: [String]
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(model.l.t("tools.limitations")).font(.callout)
        }
        .accessibilityIdentifier("tools.\(id).limitations")
    }
}

// MARK: Gatekeeper

struct GatekeeperToolCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let status = model.tools.gatekeeper
        ToolCard(id: "gatekeeper", symbol: "lock.shield", title: l.t("tools.gatekeeper.title"), summary: l.t("tools.gatekeeper.summary"),
                 help: l.t("tools.gatekeeper.help"), capability: status?.capability) {
            if model.tools.checkingGatekeeper && status == nil {
                ProgressView().controlSize(.small)
            } else if let status {
                GatekeeperStatusView(status: status)
            }
            if let status { GatekeeperSystemWideView(status: status) }
            Divider()
            AppInspectionView()
            ToolLimitations(id: "gatekeeper", lines: [l.t("tools.gatekeeper.limit.global"), l.t("tools.gatekeeper.limit.quarantine"),
                                                      l.t("tools.gatekeeper.limit.hour"), l.t("tools.gatekeeper.limit.managed")])
        }
    }
}

struct GatekeeperStatusView: View {
    @EnvironmentObject var model: AppModel
    var status: GatekeeperStatus

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 6) {
            ToolStateRow(symbol: status.assessments == .enabled ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                         color: status.assessments == .enabled ? .green : (status.assessments == .disabled ? .orange : .secondary),
                         label: l.t("tools.gatekeeper.state"), value: l.t("tools.gatekeeper.assessments.\(status.assessments.rawValue)"),
                         id: "tools.gatekeeper.assessments")
            let ours = model.isInstalled(.gatekeeperOff)
            if status.profile != .none {
                ToolStateRow(symbol: "doc.badge.gearshape", color: .orange, label: l.t("tools.gatekeeper.profile"),
                             value: l.t(ours ? "tools.gatekeeper.profile.ours" : "tools.gatekeeper.profile.\(status.profile.rawValue)"),
                             id: "tools.gatekeeper.profile")
            }
            ToolStateRow(symbol: "building.2", color: .secondary, label: l.t("tools.gatekeeper.enrollment"),
                         value: l.t("tools.gatekeeper.enrollment.\(status.enrollment.rawValue)"))
            ToolStateRow(symbol: "lock", color: status.sip == .enabled ? .green : .secondary, label: l.t("tools.gatekeeper.sip"),
                         value: l.t("tools.gatekeeper.sip.\(status.sip.rawValue)"))
            switch status.summary {
            case .normal:
                NoticeView(style: .success, title: l.t("tools.gatekeeper.normal.title"), message: l.t("tools.gatekeeper.normal.message"))
            case .disabledByProfile where ours:
                // MacReplica's own profile: “Turn app checking back on” below removes it.
                NoticeView(style: .warning, title: l.t("tools.gatekeeper.byProfile.title"), message: l.t("tools.gatekeeper.byOwnProfile.message"))
            case .disabledByProfile:
                NoticeView(style: .warning, title: l.t("tools.gatekeeper.byProfile.title"), message: l.t("tools.gatekeeper.byProfile.message"))
                Button(l.t("tools.gatekeeper.openDeviceManagement")) { model.openDeviceManagementSettings() }
                    .accessibilityIdentifier("tools.gatekeeper.openDeviceManagement")
            case .disabledByUser:
                NoticeView(style: .warning, title: l.t("tools.gatekeeper.byUser.title"), message: l.t("tools.gatekeeper.byUser.message"))
                Button(l.t("tools.gatekeeper.openSecurity")) { model.openSecuritySettings() }
                    .accessibilityIdentifier("tools.gatekeeper.openSecurity")
            case .managed:
                NoticeView(style: .info, title: l.t("tools.gatekeeper.managed.title"), message: l.t("tools.gatekeeper.managed.message"))
            case .unknown:
                NoticeView(style: .info, title: l.t("tools.gatekeeper.unknown.title"), message: l.t("tools.gatekeeper.unknown.message"))
            }
            HStack {
                Spacer()
                Button(l.t("tools.recheck")) { model.refreshGatekeeper() }
                    .controlSize(.small)
                    .disabled(model.tools.checkingGatekeeper)
                    .accessibilityIdentifier("tools.gatekeeper.recheck")
            }
        }
    }
}

struct AppInspectionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 8) {
            LabelWithHelp(label: l.t("tools.gatekeeper.app.title"), help: l.t("tools.gatekeeper.app.help"), id: "help.tools.gatekeeper.app",
                          font: .subheadline.weight(.semibold))
            HStack {
                Button(l.t("tools.gatekeeper.choose")) { model.chooseAppToInspect() }
                    .disabled(model.tools.inspectingApp)
                    .accessibilityIdentifier("tools.gatekeeper.choose")
                if model.tools.inspectingApp { ProgressView().controlSize(.small) }
            }
            if let report = model.tools.appReport {
                AppSecurityReportView(report: report)
            }
        }
    }
}

struct AppSecurityReportView: View {
    @EnvironmentObject var model: AppModel
    var report: AppSecurityReport

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 5) {
            Text(report.appName).font(.callout.weight(.semibold)).accessibilityIdentifier("tools.gatekeeper.app.name")
            ToolStateRow(symbol: "signature", color: report.signature == .valid ? .green : .orange, label: l.t("tools.gatekeeper.app.signature"),
                         value: l.t("tools.gatekeeper.signature.\(report.signature.rawValue)") + (report.signer.map { " – \($0)" } ?? ""))
            ToolStateRow(symbol: "checkmark.seal", color: report.notarized == true ? .green : .secondary, label: l.t("tools.gatekeeper.app.notarized"),
                         value: report.notarized.map { l.t($0 ? "common.yes" : "common.no") } ?? l.t("tools.unknown"))
            ToolStateRow(symbol: "arrow.down.circle", color: .secondary, label: l.t("tools.gatekeeper.app.quarantine"),
                         value: report.quarantined ? l.t("tools.gatekeeper.quarantine.yes", report.quarantineAgent ?? "–") : l.t("tools.gatekeeper.quarantine.no"))
            ToolStateRow(symbol: "shield.lefthalf.filled", color: .secondary, label: l.t("tools.gatekeeper.app.verdict"),
                         value: l.t("tools.gatekeeper.verdict.\(report.verdict.rawValue)") + (report.assessmentSource.map { " (\($0))" } ?? ""),
                         id: "tools.gatekeeper.app.verdict")
            ForEach(report.policyFindings, id: \.self) { finding in
                Label(finding, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            let advice = report.advice
            NoticeView(style: advice == .opensNormally ? .success : (advice == .damaged ? .error : (advice == .notChecked ? .info : .warning)),
                       title: l.t("tools.gatekeeper.advice.\(advice.rawValue).title"), message: l.t("tools.gatekeeper.advice.\(advice.rawValue).message"))
                .accessibilityIdentifier("tools.gatekeeper.advice.\(advice.rawValue)")
            QuarantineActionsView(report: report)
            if advice == .needsOpenAnyway || advice == .firstOpenAsks {
                if model.tools.awaitingApproval == nil {
                    Button(l.t("tools.gatekeeper.openAnyway.start")) { model.startOpenAnyway() }
                        .accessibilityIdentifier("tools.gatekeeper.openAnyway.start")
                } else {
                    Text(l.t("tools.gatekeeper.openAnyway.steps")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(l.t("tools.gatekeeper.openSecurity")) { model.openSecuritySettings() }
                        Button(l.t("tools.gatekeeper.openAnyway.done")) { model.finishOpenAnyway() }
                            .accessibilityIdentifier("tools.gatekeeper.openAnyway.done")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: Update preferences

struct UpdatesToolCard: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var confirm: PendingUpdateChange?

    var body: some View {
        let l = model.l
        let status = model.tools.updates
        ToolCard(id: "updates", symbol: "arrow.triangle.2.circlepath", title: l.t("tools.updates.title"), summary: l.t("tools.updates.summary"),
                 help: l.t("tools.updates.help"), capability: status?.capability) {
            if let settings = status?.settings {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(UpdateSettings.Item.allCases, id: \.self) { item in
                        let on = settings.value(item)
                        ToolStateRow(symbol: on ? "checkmark.circle.fill" : "circle", color: on ? .green : .secondary,
                                     label: l.t("tools.updates.item.\(item.rawValue)"), value: l.t(on ? "tools.on" : "tools.off"),
                                     id: "tools.updates.state.\(item.rawValue)")
                    }
                    if let store = settings.appStoreAutoUpdate {
                        ToolStateRow(symbol: "bag", color: .secondary, label: l.t("tools.updates.appStore"), value: l.t(store ? "tools.on" : "tools.off"))
                    }
                }
                if settings.securityUpdatesOff {
                    NoticeView(style: .warning, title: l.t("tools.updates.securityOff.title"), message: l.t("tools.updates.securityOff.message"))
                        .accessibilityIdentifier("tools.updates.securityOff")
                }
            } else if status != nil {
                NoticeView(style: .info, title: l.t("tools.updates.unreadable"))
            }
            if status?.managed == true {
                NoticeView(style: .info, title: l.t("tools.updates.managed.title"), message: l.t("tools.updates.managed.message"))
            }
            SupportStatusView()
            Divider()
            LabelWithHelp(label: l.t("tools.updates.stay.title"), help: l.t("tools.updates.stay.help"), id: "help.tools.updates.stay",
                          font: .subheadline.weight(.semibold))
            Text(l.t("tools.updates.stay.message")).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let settings = status?.settings, status?.managed == false {
                if let pending = model.tools.pendingUpdateChange {
                    PendingUpdateView(pending: pending, current: settings)
                } else {
                    HStack {
                        if !settings.differences(to: .recommended).isEmpty {
                            Button(l.t("tools.updates.applyRecommended")) {
                                confirm = PendingUpdateChange(change: "updates.apply.recommended", before: settings, target: .recommended)
                            }
                            .accessibilityIdentifier("tools.updates.applyRecommended")
                        } else {
                            Label(l.t("tools.updates.isRecommended"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                .accessibilityIdentifier("tools.updates.isRecommended")
                        }
                        if let revert = model.revertibleUpdateChange, revert.previous != settings {
                            Button(l.t("tools.updates.revert")) {
                                confirm = PendingUpdateChange(change: "updates.revert", before: settings, target: revert.previous)
                            }
                            .accessibilityIdentifier("tools.updates.revert")
                        }
                        Spacer()
                        Button(l.t("tools.updates.openSettings")) { model.openSoftwareUpdateSettings() }
                            .accessibilityIdentifier("tools.updates.openSettings")
                    }
                }
            }
            if let outcome = model.tools.updateOutcome {
                NoticeView(style: outcome.verification == .verified ? .success : .warning,
                           title: l.t("tools.verification.title.\(outcome.verification.rawValue)"), message: outcome.stateAfter)
                    .accessibilityIdentifier("tools.updates.outcome.\(outcome.verification.rawValue)")
            }
            Divider()
            MajorUpgradeDeferralView()
            ToolLimitations(id: "updates", lines: [l.t("tools.updates.limit.noWrite"), l.t("tools.updates.limit.badge"),
                                                   l.t("tools.updates.limit.updateAll"), l.t("tools.updates.limit.bsi"),
                                                   l.t("tools.updates.limit.endOfSupport")])
        }
        .alert(l.t("tools.updates.confirm.title"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { change in
            Button(l.t("tools.updates.confirm.go")) { model.beginUpdateChange(change.change, target: change.target) }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: { change in
            // Going back to a state without security updates is allowed, but never without saying so.
            Text(UpdateChangeText.steps(change, l: l) + "\n\n" + l.t("tools.updates.confirm.message")
                 + (change.target.securityUpdatesOff ? "\n\n" + l.t("tools.updates.confirm.securityOff") : ""))
        }
    }
}

enum UpdateChangeText {
    /// “Turn on: …”, “Turn off: …” for the switches that differ.
    static func steps(_ change: PendingUpdateChange, l: Localizer) -> String {
        let diff = change.before.differences(to: change.target)
        let on = diff.filter { change.target.value($0) }.map { l.t("tools.updates.item.\($0.rawValue)") }
        let off = diff.filter { !change.target.value($0) }.map { l.t("tools.updates.item.\($0.rawValue)") }
        var lines: [String] = []
        if !on.isEmpty { lines.append(l.t("tools.updates.turnOn", on.joined(separator: ", "))) }
        if !off.isEmpty { lines.append(l.t("tools.updates.turnOff", off.joined(separator: ", "))) }
        return lines.joined(separator: "\n")
    }
}

struct PendingUpdateView: View {
    @EnvironmentObject var model: AppModel
    var pending: PendingUpdateChange
    var current: UpdateSettings

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("tools.updates.pending.steps")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(UpdateChangeText.steps(PendingUpdateChange(change: pending.change, before: current, target: pending.target), l: l))
                .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tools.updates.pending.list")
            HStack {
                Button(l.t("tools.updates.openSettings")) { model.openSoftwareUpdateSettings() }
                Button(l.t("tools.updates.pending.check")) { model.finishUpdateChange() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tools.updates.pending.check")
                Spacer()
                Button(l.t("common.cancel")) { model.cancelUpdateChange() }
                    .accessibilityIdentifier("tools.updates.pending.cancel")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

struct SupportStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 5) {
            if let support = model.tools.support {
                let style: NoticeView.Style = support.support == .likelyEnded ? .warning : (support.support == .unknown ? .info : .success)
                NoticeView(style: style, title: l.t("tools.updates.support.\(support.support.rawValue).title", support.installedVersion),
                           message: l.t("tools.updates.support.\(support.support.rawValue).message"))
                    .accessibilityIdentifier("tools.updates.support.\(support.support.rawValue)")
                if support.updateAvailable, let latest = support.latestForThisMajor {
                    Label(l.t("tools.updates.support.updateAvailable", latest), systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.orange)
                        .accessibilityIdentifier("tools.updates.support.updateAvailable")
                }
            }
            HStack {
                Button(l.t("tools.updates.support.check")) { model.checkMacOSSupport() }
                    .controlSize(.small)
                    .disabled(model.tools.checkingSupport)
                    .accessibilityIdentifier("tools.updates.support.check")
                if model.tools.checkingSupport { ProgressView().controlSize(.small) }
                HelpButton(text: l.t("tools.updates.support.help"), title: l.t("tools.updates.support.check"), id: "help.tools.updates.support")
            }
        }
    }
}

// MARK: Profiles

/// Turning Gatekeeper off for the whole Mac with MacReplica's own profile, and back on – always through
/// Device Management, where only the user can install or remove profiles.
struct GatekeeperSystemWideView: View {
    @EnvironmentObject var model: AppModel
    var status: GatekeeperStatus
    @ViewState private var confirmOff = false
    @ViewState private var confirmOn = false

    var body: some View {
        let l = model.l
        let ours = model.isInstalled(.gatekeeperOff)
        VStack(alignment: .leading, spacing: 6) {
            if let pending = model.tools.pendingProfile, pending.profile == .gatekeeperOff {
                PendingProfileView(pending: pending)
            } else if ours {
                Button(l.t("tools.gatekeeper.profileOff.button")) { confirmOn = true }
                    .accessibilityIdentifier("tools.gatekeeper.profileOff")
            } else if status.summary == .normal, model.tools.installedProfiles != nil {
                HStack(spacing: 6) {
                    Button(l.t("tools.gatekeeper.profileOn.button")) { confirmOff = true }
                        .accessibilityIdentifier("tools.gatekeeper.profileOn")
                    HelpButton(text: l.t("tools.gatekeeper.profileOn.help"), title: l.t("tools.gatekeeper.profileOn.button"), id: "help.tools.gatekeeper.profileOn")
                }
            }
            if let outcome = model.tools.gatekeeperOutcome { ToolOutcomeView(outcome: outcome, id: "tools.gatekeeper.outcome") }
        }
        .alert(l.t("tools.gatekeeper.profileOn.confirm.title"), isPresented: $confirmOff) {
            Button(l.t("tools.gatekeeper.profileOn.confirm.go"), role: .destructive) { model.prepareProfile(.gatekeeperOff) }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.gatekeeper.profileOn.confirm.message"))
        }
        .alert(l.t("tools.gatekeeper.profileOff.confirm.title"), isPresented: $confirmOn) {
            Button(l.t("tools.gatekeeper.openDeviceManagement")) { model.beginProfileRemoval(.gatekeeperOff) }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.gatekeeper.profileOff.confirm.message"))
        }
    }
}

/// The user's steps in Device Management, then “check again”.
struct PendingProfileView: View {
    @EnvironmentObject var model: AppModel
    var pending: PendingProfile

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("tools.profile.steps.\(pending.action.rawValue)")).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tools.profile.steps.\(pending.action.rawValue)")
            HStack {
                Button(l.t("tools.gatekeeper.openDeviceManagement")) { model.openDeviceManagementSettings() }
                Button(l.t("tools.profile.check")) { model.finishPendingProfile() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tools.profile.check")
                Spacer()
                Button(l.t("common.cancel")) { model.cancelPendingProfile() }
                    .accessibilityIdentifier("tools.profile.cancel")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

struct ToolOutcomeView: View {
    @EnvironmentObject var model: AppModel
    var outcome: ToolOutcome
    var id: String

    var body: some View {
        let l = model.l
        let style: NoticeView.Style = outcome.verification == .verified ? .success : (outcome.verification == .failed ? .warning : .info)
        NoticeView(style: style, title: l.t("tools.verification.title.\(outcome.verification.rawValue)"),
                   message: outcome.stateAfter + (outcome.restart == .none ? "" : "\n" + l.t("tools.restart.\(outcome.restart.rawValue)")))
            .accessibilityIdentifier("\(id).\(outcome.verification.rawValue)")
    }
}

/// Deferring the next major macOS version with MacReplica's own profile, where that keeps security updates flowing.
struct MajorUpgradeDeferralView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var days = 90
    @ViewState private var confirm = false
    @ViewState private var confirmRemove = false

    var body: some View {
        let l = model.l
        let support = MajorUpgradeDeferralSupport.forVersion(model.tools.environment)
        let ours = model.isInstalled(.deferMajorUpgrades(days: 1))
        let active = ManagedProfileEffect.majorUpgradeDeferralDays(managedPreferences: model.services.layout.managedPreferences)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(l.t("tools.updates.deferral.title")).font(.subheadline.weight(.semibold))
                HelpButton(text: l.t("tools.updates.deferral.help"), title: l.t("tools.updates.deferral.title"), id: "help.tools.updates.deferral")
                Spacer()
                CapabilityBadge(capability: support.capability)
            }
            Text(l.t("tools.updates.deferral.\(support.rawValue)"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tools.updates.deferral")
            if let active {
                ToolStateRow(symbol: "calendar.badge.clock", color: .orange, label: l.t("tools.updates.deferral.active"),
                             value: l.p("tools.updates.deferral.days", active), id: "tools.updates.deferral.active")
            }
            if let pending = model.tools.pendingProfile, pending.profile != .gatekeeperOff {
                PendingProfileView(pending: pending)
            } else if ours {
                Button(l.t("tools.updates.deferral.remove")) { confirmRemove = true }
                    .accessibilityIdentifier("tools.updates.deferral.remove")
            } else if support.canInstall, model.tools.updates?.managed == false, active == nil {
                HStack {
                    Picker(l.t("tools.updates.deferral.period"), selection: $days) {
                        ForEach([30, 60, 90], id: \.self) { Text(l.p("tools.updates.deferral.days", $0)).tag($0) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("tools.updates.deferral.period")
                    Button(l.t("tools.updates.deferral.install")) { confirm = true }
                        .accessibilityIdentifier("tools.updates.deferral.install")
                }
            }
            if let outcome = model.tools.deferralOutcome { ToolOutcomeView(outcome: outcome, id: "tools.updates.deferral.outcome") }
        }
        .alert(l.t("tools.updates.deferral.confirm.title"), isPresented: $confirm) {
            Button(l.t("tools.updates.deferral.confirm.go")) { model.prepareProfile(.deferMajorUpgrades(days: days)) }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.updates.deferral.confirm.message", days))
        }
        .alert(l.t("tools.updates.deferral.remove"), isPresented: $confirmRemove) {
            Button(l.t("tools.gatekeeper.openDeviceManagement")) { model.beginProfileRemoval(.deferMajorUpgrades(days: 1)) }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.updates.deferral.remove.message"))
        }
    }
}

// MARK: Window corners

/// Corner radius for app windows and – with the corner plugin – menus, popovers and Quick Look. One radius for all
/// chosen surfaces by default (so everything looks alike), or a separate radius per surface; every surface can be
/// left out entirely.
struct WindowCornersToolCard: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var sameRadius = true
    @ViewState private var shared = 10
    @ViewState private var separate: [CornerSurface: Int] = [:]
    @ViewState private var included: Set<CornerSurface> = [.windows, .utilityPanels]
    @ViewState private var classicMenus = false
    @ViewState private var advancedUnlocked = false
    @ViewState private var confirmAdvanced = false
    @ViewState private var confirm: CornerConfiguration?
    @ViewState private var loaded = false

    static let presets = [10, 7, 4]

    private func radius(for surface: CornerSurface) -> Int { sameRadius ? shared : (separate[surface] ?? shared) }

    private var configuration: CornerConfiguration {
        var radii: [CornerSurface: CornerSetting] = [:]
        for surface in CornerSurface.radiusSurfaces where included.contains(surface) { radii[surface] = .radius(radius(for: surface)) }
        // Menus come either from the plugin (any radius) or as AppKit's classic style – not both.
        return CornerConfiguration(radii: radii, roundedButtons: included.contains(.buttons),
                                   classicMenus: classicMenus && !included.contains(.menus))
    }

    private func load(_ state: CornerConfiguration) {
        guard !loaded else { return }
        loaded = true
        var chosen = Set<CornerSurface>()
        var values: [CornerSurface: Int] = [:]
        for surface in CornerSurface.radiusSurfaces {
            if case .radius(let points) = state.radius(surface) { chosen.insert(surface); values[surface] = points }
        }
        if state.roundedButtons { chosen.insert(.buttons) }
        if !chosen.isEmpty {
            included = chosen
            separate = values
            let distinct = Set(values.values)
            sameRadius = distinct.count <= 1
            shared = distinct.first ?? 10
        }
        classicMenus = state.classicMenus
        advancedUnlocked = chosen.contains { $0.needsPlugin } || model.tools.plugin?.installed == true
    }

    var body: some View {
        let l = model.l
        let tool = model.cornerTool
        ToolCard(id: "corners", symbol: "square.on.square.dashed", title: l.t("tools.corners.title"), summary: l.t("tools.corners.summary"),
                 help: l.t("tools.corners.help"), capability: tool.capability) {
            if !tool.capability.allowsChange {
                NoticeView(style: .info, title: l.t("tools.corners.unsupported.title", model.tools.environment.macOSVersion),
                           message: l.t("tools.corners.unsupported.message"))
                    .accessibilityIdentifier("tools.corners.unsupported")
            } else if let state = model.tools.corners {
                Toggle(l.t("tools.corners.same"), isOn: $sameRadius)
                    .accessibilityIdentifier("tools.corners.same")
                if sameRadius {
                    RadiusPicker(label: l.t("tools.corners.choose"), value: $shared, id: "tools.corners.choose")
                }
                Text(l.t("tools.corners.surfaces")).font(.subheadline.weight(.semibold))
                surfaceRow(.windows, state: state)
                surfaceRow(.utilityPanels, state: state)
                HStack(spacing: 6) {
                    Toggle(l.t("tools.menus.classic"), isOn: $classicMenus)
                        .disabled(included.contains(.menus))
                        .accessibilityIdentifier("tools.menus.classic")
                    HelpButton(text: l.t("tools.menus.help"), title: l.t("tools.menus.title"), id: "help.tools.menus")
                    Spacer()
                    Text(l.t(state.classicMenus ? "tools.corners.now.classic" : "tools.corners.now.glass")).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if advancedUnlocked {
                    Text(l.t("tools.plugin.surfaces")).font(.subheadline.weight(.semibold))
                    surfaceRow(.menus, state: state)
                    surfaceRow(.popovers, state: state)
                    surfaceRow(.quickLook, state: state)
                    surfaceRow(.toolbars, state: state)
                    surfaceRow(.buttons, state: state)
                    CornerPluginView()
                } else {
                    HStack(spacing: 6) {
                        Button(l.t("tools.plugin.show")) { confirmAdvanced = true }
                            .accessibilityIdentifier("tools.plugin.show")
                        HelpButton(text: l.t("tools.plugin.help"), title: l.t("tools.quicklook.title"), id: "help.tools.plugin")
                    }
                }
                Divider()
                HStack {
                    Button(l.t("tools.corners.apply")) { confirm = configuration }
                        .disabled(configuration == tool.normalized(state) )
                        .accessibilityIdentifier("tools.corners.apply")
                    if model.revertibleCornerChange != nil {
                        Button(l.t("tools.corners.revert")) { model.revertCorners() }
                            .accessibilityIdentifier("tools.corners.revert")
                    }
                    Spacer()
                    if !state.isSystemDefault {
                        Button(l.t("tools.corners.default")) { confirm = CornerConfiguration() }
                            .accessibilityIdentifier("tools.corners.default")
                    }
                }
                if let outcome = model.tools.cornerOutcome { ToolOutcomeView(outcome: outcome, id: "tools.corners.outcome") }
                CornerScopeView()
            }
            ToolLimitations(id: "corners", lines: [l.t("tools.corners.limit.undocumented"), l.t("tools.corners.limit.relaunch"),
                                                   l.t("tools.corners.limit.overlays"), l.t("tools.corners.limit.versions"),
                                                   l.t("tools.corners.limit.revert")])
        }
        .onAppear { if let state = model.tools.corners { load(state) } }
        .onChange(of: model.tools.corners) { state in if let state { load(state) } }
        .alert(l.t("tools.quicklook.warning.title"), isPresented: $confirmAdvanced) {
            Button(l.t("tools.quicklook.warning.go"), role: .destructive) { advancedUnlocked = true }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.quicklook.warning.message"))
        }
        .alert(l.t("tools.corners.confirm.title"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { chosen in
            Button(l.t("tools.corners.confirm.go")) {
                model.applyCorners(chosen, change: chosen.isSystemDefault ? "windowCorners.default" : "windowCorners.apply")
            }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: { chosen in
            Text(summary(chosen, l: l))
        }
    }

    @ViewBuilder
    private func surfaceRow(_ surface: CornerSurface, state: CornerConfiguration) -> some View {
        let l = model.l
        HStack(spacing: 8) {
            Toggle(l.t("tools.corners.surface.\(surface.rawValue)"), isOn: Binding(
                get: { included.contains(surface) },
                set: { on in
                    if on { included.insert(surface) } else { included.remove(surface) }
                    if surface == .menus, on { classicMenus = false }
                }))
                .accessibilityIdentifier("tools.corners.include.\(surface.rawValue)")
            Spacer(minLength: 8)
            if surface.isRadius, !sameRadius, included.contains(surface) {
                RadiusPicker(label: "", value: Binding(get: { separate[surface] ?? shared }, set: { separate[surface] = $0 }),
                             id: "tools.corners.radius.\(surface.rawValue)")
            }
            Text(currentText(surface, state: state, l: l)).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("tools.corners.now.\(surface.rawValue)")
        }
    }

    private func currentText(_ surface: CornerSurface, state: CornerConfiguration, l: Localizer) -> String {
        if surface == .buttons { return l.t(state.roundedButtons ? "tools.corners.now.rounded" : "tools.corners.now.capsule") }
        switch state.radius(surface) {
        case .radius(let points): return l.t("tools.corners.now.points", points)
        case .system:
            if surface == .windows || surface == .utilityPanels, let system = model.cornerTool.systemRadius { return l.t("tools.corners.now.systemPoints", system) }
            return l.t("tools.corners.now.system")
        }
    }

    private func summary(_ chosen: CornerConfiguration, l: Localizer) -> String {
        if chosen.isSystemDefault { return l.t("tools.corners.confirm.default") + "\n\n" + l.t("tools.corners.confirm.common") }
        var lines: [String] = []
        for surface in CornerSurface.radiusSurfaces {
            if case .radius(let points) = chosen.radius(surface) {
                lines.append(l.t("tools.corners.surface.\(surface.rawValue)") + ": " + l.t("tools.corners.points", points))
            }
        }
        if chosen.roundedButtons { lines.append(l.t("tools.corners.surface.buttons")) }
        if chosen.classicMenus { lines.append(l.t("tools.menus.classic")) }
        var text = lines.joined(separator: "\n") + "\n\n" + l.t("tools.corners.confirm.common")
        if chosen.needsPlugin, model.tools.plugin?.installed != true { text += "\n\n" + l.t("tools.plugin.needsPluginNote") }
        return text
    }
}

struct RadiusPicker: View {
    @EnvironmentObject var model: AppModel
    var label: String
    @Binding var value: Int
    var id: String

    var body: some View {
        let l = model.l
        Picker(label, selection: $value) {
            Text(l.t("tools.corners.preset.10")).tag(10)
            Text(l.t("tools.corners.preset.7")).tag(7)
            Text(l.t("tools.corners.preset.4")).tag(4)
            ForEach(Array(CornerSetting.range).filter { !WindowCornersToolCard.presets.contains($0) }, id: \.self) {
                Text(l.t("tools.corners.points", $0)).tag($0)
            }
        }
        .fixedSize()
        .accessibilityIdentifier(id)
    }
}

/// Requirements, steps and install/remove of the corner plugin – all of it behind the warning the user confirmed.
struct CornerPluginView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var confirmInstall = false
    @ViewState private var confirmRemove = false

    var body: some View {
        let l = model.l
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(l.t("tools.plugin.title")).font(.subheadline.weight(.semibold))
                HelpButton(text: l.t("tools.plugin.help"), title: l.t("tools.plugin.title"), id: "help.tools.plugin.panel")
                Spacer()
                if let status = model.tools.plugin { CapabilityBadge(capability: status.capability) }
            }
            if let status = model.tools.plugin {
                requirement(status.readiness != .untestedBuild, l.t("tools.plugin.req.build", status.build ?? "?"), id: "build")
                requirement(status.sip == .disabled, l.t("tools.plugin.req.sip"), id: "sip")
                requirement(status.bootArgumentSet == true, l.t("tools.plugin.req.bootArg"), id: "bootArg")
                requirement(status.ammoniaInstalled, l.t("tools.plugin.req.ammonia"), id: "ammonia")
                requirement(status.installed && status.current, l.t(status.installed && !status.current ? "tools.plugin.req.outdated" : "tools.plugin.req.installed"),
                            id: "installed")
                if status.readiness != .ready, status.readiness != .untestedBuild {
                    Text(l.t("tools.plugin.steps")).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("tools.plugin.steps")
                }
                if status.readiness == .untestedBuild {
                    Text(l.t("tools.plugin.untested")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if status.readiness == .ready, !(status.installed && status.current) {
                        Button(l.t(status.installed ? "tools.plugin.update" : "tools.plugin.install")) { confirmInstall = true }
                            .disabled(model.tools.pluginBusy)
                            .accessibilityIdentifier("tools.plugin.install")
                    }
                    if status.installed {
                        Button(l.t("tools.plugin.remove")) { confirmRemove = true }
                            .disabled(model.tools.pluginBusy)
                            .accessibilityIdentifier("tools.plugin.remove")
                    }
                    if model.tools.pluginBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(l.t("tools.recheck")) { model.refreshPlugin() }.controlSize(.small)
                        .accessibilityIdentifier("tools.plugin.recheck")
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let outcome = model.tools.pluginOutcome { ToolOutcomeView(outcome: outcome, id: "tools.plugin.outcome") }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.07)))
        .alert(l.t("tools.plugin.confirm.title"), isPresented: $confirmInstall) {
            Button(l.t("tools.plugin.confirm.go"), role: .destructive) { model.installPlugin() }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.plugin.confirm.message"))
        }
        .alert(l.t("tools.plugin.remove"), isPresented: $confirmRemove) {
            Button(l.t("tools.plugin.remove.go")) { model.removePlugin() }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.plugin.remove.message"))
        }
    }

    private func requirement(_ met: Bool, _ text: String, id: String) -> some View {
        Label(text, systemImage: met ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(met ? Color.green : Color.secondary)
            .accessibilityIdentifier("tools.plugin.req.\(id).\(met ? "met" : "open")")
    }
}

/// What the setting changes and what it does not – shown, not hidden in a tooltip.
struct CornerScopeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l.t("tools.corners.changes")).font(.caption.weight(.semibold))
                ForEach(["windows", "documents", "sheets", "panels", "classicMenus"], id: \.self) { key in
                    Label(l.t("tools.corners.scope.\(key)"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(l.t("tools.corners.pluginOnly")).font(.caption.weight(.semibold))
                ForEach(["menus", "popovers", "quickLook", "toolbars", "buttons"], id: \.self) { key in
                    Label(l.t("tools.corners.scope.plugin.\(key)"), systemImage: "puzzlepiece.extension").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(l.t("tools.corners.unchanged")).font(.caption.weight(.semibold))
                ForEach(["quickLookInner", "overlays", "ownFrames"], id: \.self) { key in
                    Label(l.t("tools.corners.scope.\(key)"), systemImage: "xmark").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("tools.corners.scope")
    }
}

/// Open the chosen app now, or – at the user's own risk, after a warning – remove its quarantine mark (and put it back).
struct QuarantineActionsView: View {
    @EnvironmentObject var model: AppModel
    var report: AppSecurityReport
    @ViewState private var confirmRemove = false

    var body: some View {
        let l = model.l
        let restorable = model.tools.removedQuarantine?.app.path == report.path
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if report.advice != .damaged {
                    Button(l.t("tools.gatekeeper.openNow")) { model.openInspectedApp() }
                        .accessibilityIdentifier("tools.gatekeeper.openNow")
                    if report.quarantined {
                        Button(l.t("tools.gatekeeper.quarantine.remove")) { confirmRemove = true }
                            .accessibilityIdentifier("tools.gatekeeper.quarantine.remove")
                    }
                }
                if restorable, !report.quarantined {
                    Button(l.t("tools.gatekeeper.quarantine.restore")) { model.restoreQuarantineOfInspectedApp() }
                        .accessibilityIdentifier("tools.gatekeeper.quarantine.restore")
                }
                if report.quarantined || restorable {
                    HelpButton(text: l.t("tools.gatekeeper.quarantine.help"), title: l.t("tools.gatekeeper.quarantine.remove"),
                               id: "help.tools.gatekeeper.quarantine")
                }
            }
            if let outcome = model.tools.quarantineOutcome { ToolOutcomeView(outcome: outcome, id: "tools.gatekeeper.quarantine.outcome") }
        }
        .alert(l.t("tools.gatekeeper.quarantine.confirm.title", report.appName), isPresented: $confirmRemove) {
            Button(l.t("tools.gatekeeper.quarantine.confirm.go"), role: .destructive) { model.removeQuarantineFromInspectedApp() }
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("tools.gatekeeper.quarantine.confirm.message", report.appName))
        }
    }
}

/// The last changes made with the tools (newest first).
struct ToolHistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        Card {
            LabelWithHelp(label: l.t("tools.history.title"), help: l.t("tools.history.help"), id: "help.tools.history", font: .headline)
            ForEach(model.tools.history.reversed().prefix(10)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.result == .succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(entry.result == .succeeded ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.t("tools.change.\(entry.change)")).font(.callout)
                        Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.language.locale)) + " · macOS " + entry.macOSVersion + " · "
                             + l.t("tools.verification.\(entry.verification.rawValue)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("tools.history")
    }
}
