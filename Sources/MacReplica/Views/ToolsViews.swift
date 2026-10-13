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
            if status.profile != .none {
                ToolStateRow(symbol: "doc.badge.gearshape", color: .orange, label: l.t("tools.gatekeeper.profile"),
                             value: l.t("tools.gatekeeper.profile.\(status.profile.rawValue)"), id: "tools.gatekeeper.profile")
            }
            ToolStateRow(symbol: "building.2", color: .secondary, label: l.t("tools.gatekeeper.enrollment"),
                         value: l.t("tools.gatekeeper.enrollment.\(status.enrollment.rawValue)"))
            ToolStateRow(symbol: "lock", color: status.sip == .enabled ? .green : .secondary, label: l.t("tools.gatekeeper.sip"),
                         value: l.t("tools.gatekeeper.sip.\(status.sip.rawValue)"))
            switch status.summary {
            case .normal:
                NoticeView(style: .success, title: l.t("tools.gatekeeper.normal.title"), message: l.t("tools.gatekeeper.normal.message"))
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
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened) + " · macOS " + entry.macOSVersion + " · "
                             + l.t("tools.verification.\(entry.verification.rawValue)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("tools.history")
    }
}
