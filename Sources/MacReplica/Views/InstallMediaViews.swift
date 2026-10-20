import MacReplicaCore
import SwiftUI

/// The Tools card that opens the installer creator.
struct InstallMediaToolCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        ToolCard(id: "installMedia", symbol: "externaldrive.badge.plus", title: l.t("installMedia.title"), summary: l.t("installMedia.summary"),
                 help: l.t("installMedia.help"), capability: .requiresAdministrator) {
            HStack {
                Spacer()
                Button(l.t("installMedia.open")) { model.openInstallMedia() }
                    .accessibilityIdentifier("installMedia.open")
            }
        }
    }
}

struct InstallMediaView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        ScreenLayout(title: l.t("installMedia.title"), subtitle: l.t("installMedia.step.\(stepKey(state.step))")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InstallMediaSteps(step: state.step)
                    switch state.step {
                    case .choose: InstallMediaChooseView()
                    case .installer: InstallMediaInstallerView()
                    case .drive: InstallMediaDriveView()
                    case .confirm: InstallMediaConfirmView()
                    case .working: InstallMediaWorkingView()
                    case .finished: InstallMediaFinishedView()
                    case .failed: InstallMediaFailedView()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        } buttons: {
            // Back to the start screen from every step; while the drive is written it cannot be left safely.
            Button(l.t("installMedia.mainMenu")) { model.installMediaGoHome() }
                .disabled(state.step == .working)
                .help(state.step == .working ? l.t("installMedia.mainMenu.busy") : (state.downloading ? l.t("installMedia.mainMenu.download") : ""))
                .accessibilityIdentifier("installMedia.home")
            if state.step != .working {
                Button(state.step == .finished ? l.t("common.done") : (state.step == .choose ? l.t("installMedia.backToTools") : l.t("common.back"))) {
                    state.step == .finished ? model.closeInstallMedia() : model.installMediaBack()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(state.downloading)
                .accessibilityIdentifier("installMedia.back")
            }
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let l = model.l
        let state = model.installMedia
        switch state.step {
        case .installer:
            Button(l.t("installMedia.continue")) { model.continueToDrives() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.report == nil || state.inspecting || state.downloading || !model.installerProblems.isEmpty)
                .accessibilityIdentifier("installMedia.continue")
        case .drive:
            Button(l.t("installMedia.continue")) { model.continueToConfirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.confirmedDrive == nil || state.scanningDrives)
                .accessibilityIdentifier("installMedia.continue")
        case .confirm:
            Button(role: .destructive) { model.requestCreateInstallMedia() } label: {
                Text(l.t(state.confirmedCandidate?.isPartition == true ? "installMedia.create.partition" : "installMedia.create"))
            }
            .disabled(!state.readyToCreate)
            .accessibilityIdentifier("installMedia.create")
            .confirmationDialog(l.t("installMedia.final.title", state.confirmedCandidate?.partition?.name.ifEmpty(state.confirmedCandidate?.partition?.device ?? "") ?? ""),
                                isPresented: $model.installMedia.askingFinalConfirmation) {
                Button(l.t("installMedia.final.erase"), role: .destructive) { model.createInstallMedia() }
                    .accessibilityIdentifier("installMedia.final.erase")
                Button(l.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(l.t("installMedia.final.message"))
            }
        case .finished:
            Button(l.t("installMedia.another")) { model.openInstallMedia() }
                .accessibilityIdentifier("installMedia.another")
        case .failed:
            Button(l.t("installMedia.tryAgain")) { model.installMediaBack() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("installMedia.tryAgain")
        case .choose, .working:
            EmptyView()
        }
    }

    private func stepKey(_ step: InstallMediaState.Step) -> String {
        switch step {
        case .choose: return "choose"
        case .installer: return "installer"
        case .drive: return "drive"
        case .confirm: return "confirm"
        case .working: return "working"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }
}

/// 1 macOS · 2 Installer · 3 Drive · 4 Confirm · 5 Create
struct InstallMediaSteps: View {
    @EnvironmentObject var model: AppModel
    var step: InstallMediaState.Step

    private var index: Int {
        switch step {
        case .choose: return 0
        case .installer: return 1
        case .drive: return 2
        case .confirm: return 3
        case .working, .finished, .failed: return 4
        }
    }

    var body: some View {
        let names = ["choose", "installer", "drive", "confirm", "create"]
        HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { offset, name in
                if offset > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Text("\(offset + 1) " + model.l.t("installMedia.steps.\(name)"))
                    .font(.caption.weight(offset == index ? .semibold : .regular))
                    .foregroundStyle(offset == index ? Color.accentColor : (offset < index ? Color.primary : Color.secondary))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("installMedia.steps")
    }
}

// MARK: A. Choose a release

struct InstallMediaChooseView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let catalog = model.installMedia.catalog
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("installMedia.choose.intro")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            InstallMediaLocalCard()
            Card {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        sourceLine(l.t("installMedia.source.softwareUpdate"), checked: catalog.softwareUpdateCheckedAt, problem: catalog.softwareUpdateProblem,
                                   id: "installMedia.source.softwareUpdate")
                        sourceLine(l.t("installMedia.source.applePage"), checked: catalog.applePageCheckedAt, problem: catalog.applePageProblem,
                                   id: "installMedia.source.applePage")
                    }
                    Spacer()
                    if model.installMedia.refreshing { ProgressView().controlSize(.small) }
                    Button(l.t("installMedia.checkAgain")) { model.refreshInstallerCatalog() }
                        .disabled(model.installMedia.refreshing)
                        .accessibilityIdentifier("installMedia.refresh")
                }
            }
            if catalog.releases.isEmpty && !model.installMedia.refreshing {
                NoticeView(style: .warning, title: l.t("installMedia.choose.empty"), message: l.t("installMedia.choose.emptyHint"))
                    .accessibilityIdentifier("installMedia.empty")
            }
            ForEach(catalog.grouped) { group in
                InstallMediaMajorCard(group: group)
            }
        }
    }

    private func sourceLine(_ name: String, checked: Date?, problem: String?, id: String) -> some View {
        let l = model.l
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: problem == nil && checked != nil ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(problem == nil && checked != nil ? Color.green : Color.orange)
            Text(name).fontWeight(.medium)
            Text(checked.map { l.t("installMedia.source.checked", l.date($0)) } ?? l.t("installMedia.source.never")).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.orange).lineLimit(2) }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

struct InstallMediaMajorCard: View {
    @EnvironmentObject var model: AppModel
    var group: MacOSMajorRelease

    var body: some View {
        Card {
            Text("\(group.name) (\(group.major))").font(.headline)
            ForEach(group.releases) { release in
                InstallMediaReleaseRow(release: release)
                if release.id != group.releases.last?.id { Divider() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("installMedia.major.\(group.major)")
    }
}

struct InstallMediaReleaseRow: View {
    @EnvironmentObject var model: AppModel
    var release: MacOSRelease

    var body: some View {
        let l = model.l
        let suitability = model.suitability(of: release)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // The group's title names the release; a row only needs its version.
                Text(release.version ?? "\(release.name) \(release.major)").fontWeight(.medium)
                Text(details(release)).font(.caption).foregroundStyle(.secondary)
                Text(l.t("installMedia.suitability.\(key(suitability))")).font(.caption)
                    .foregroundStyle(suitability == .intelMacsOnly ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(l.t("installMedia.choose.select")) { model.chooseRelease(release) }
                .disabled(suitability == .intelMacsOnly)
                .accessibilityIdentifier("installMedia.release.\(release.id)")
        }
    }

    private func details(_ release: MacOSRelease) -> String {
        let l = model.l
        var parts: [String] = []
        if let build = release.build { parts.append(l.t("installMedia.build", build)) }
        if let size = release.sizeBytes { parts.append(l.fileSize(size)) }
        switch release.source {
        case .softwareUpdate: parts.append(l.t("installMedia.from.softwareUpdate"))
        case .appStore: parts.append(l.t("installMedia.from.appStore"))
        case .appleDiskImage: parts.append(l.t("installMedia.from.appleDiskImage"))
        case .onThisMac: parts.append(l.t("installMedia.from.onThisMac"))
        }
        return parts.joined(separator: " · ")
    }

    private func key(_ suitability: InstallerSuitability) -> String {
        switch suitability {
        case .downloadHere: return "downloadHere"
        case .appStore: return "appStore"
        case .appleDiskImage: return "appleDiskImage"
        case .intelMacsOnly: return "intelMacsOnly"
        case .onThisMac: return "onThisMac"
        }
    }
}

// MARK: B/C. Get and check the installer

struct InstallMediaInstallerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        if let release = state.selected {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Text(release.version.map { "\(release.name) \($0)" } ?? "\(release.name) \(release.major)").font(.headline)
                    Text(l.t("installMedia.installer.expected", release.installerAppName)).font(.callout).foregroundStyle(.secondary)
                    if state.inspecting {
                        HStack { ProgressView().controlSize(.small); Text(l.t("installMedia.installer.inspecting")) }
                            .accessibilityIdentifier("installMedia.inspecting")
                    }
                }
                if let report = state.report {
                    InstallMediaReportCard(report: report, release: release)
                } else if !state.inspecting {
                    getInstaller(release)
                }
            }
        }
    }

    @ViewBuilder private func getInstaller(_ release: MacOSRelease) -> some View {
        let l = model.l
        let state = model.installMedia
        Card {
            switch release.source {
            case .softwareUpdate:
                Text(l.t("installMedia.download.intro", release.sizeBytes.map(l.fileSize) ?? "?")).fixedSize(horizontal: false, vertical: true)
                if state.downloading {
                    if let percent = state.downloadPercent {
                        ProgressView(value: percent, total: 100) { Text(l.t("installMedia.download.progress", l.percent(percent / 100))) }
                            .accessibilityIdentifier("installMedia.download.progress")
                    } else {
                        HStack { ProgressView().controlSize(.small); Text(l.t("installMedia.download.starting")) }
                            .accessibilityIdentifier("installMedia.download.progress")
                    }
                    Button(l.t("installMedia.download.cancel")) { model.cancelDownload() }
                        .accessibilityIdentifier("installMedia.download.cancel")
                } else {
                    Button(l.t("installMedia.download")) { model.downloadInstaller() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("installMedia.download")
                }
                if let problem = state.downloadProblem {
                    NoticeView(style: .error, title: l.t("installMedia.download.failed"), message: problem)
                        .accessibilityIdentifier("installMedia.download.problem")
                }
            case .onThisMac:
                // The installer that was chosen is no longer there.
                Text(l.t("installMedia.local.gone", release.installerAppName)).fixedSize(horizontal: false, vertical: true)
                Button(l.t("installMedia.checkAgain")) { model.checkForInstaller() }
                    .accessibilityIdentifier("installMedia.checkInstaller")
            case .appStore, .appleDiskImage:
                let isStore: Bool = { if case .appStore = release.source { return true }; return false }()
                Text(l.t(isStore ? "installMedia.external.appStore" : "installMedia.external.diskImage", release.installerAppName))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(l.t(isStore ? "installMedia.external.openStore" : "installMedia.external.openDownload")) { model.openExternalInstaller() }
                        .accessibilityIdentifier("installMedia.openExternal")
                    Button(l.t("installMedia.checkAgain")) { model.checkForInstaller() }
                        .accessibilityIdentifier("installMedia.checkInstaller")
                }
                if state.openedExternally {
                    Text(l.t("installMedia.external.opened")).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("installMedia.external.opened")
                }
            }
        }
    }
}

struct InstallMediaReportCard: View {
    @EnvironmentObject var model: AppModel
    var report: InstallerAppReport
    var release: MacOSRelease

    var body: some View {
        let l = model.l
        let problems = model.installerProblems
        Card {
            Text(l.t("installMedia.installer.found")).font(.headline)
            ToolStateRow(symbol: "app", color: .secondary, label: l.t("installMedia.installer.app"), value: report.app.lastPathComponent, id: "installMedia.installer.app")
            ToolStateRow(symbol: "number", color: .secondary, label: l.t("installMedia.installer.macOS"),
                         value: [report.macOSVersion, report.build].compactMap { $0 }.joined(separator: " · ").ifEmpty(l.t("installMedia.installer.versionUnknown")),
                         id: "installMedia.installer.version")
            ToolStateRow(symbol: "internaldrive", color: .secondary, label: l.t("installMedia.installer.size"), value: l.fileSize(report.sizeBytes))
            ToolStateRow(symbol: report.signedByApple ? "checkmark.seal.fill" : "xmark.seal.fill", color: report.signedByApple ? .green : .red,
                         label: l.t("installMedia.installer.signature"),
                         value: l.t(report.signedByApple ? "installMedia.installer.signedByApple" : "installMedia.installer.notSigned"),
                         id: "installMedia.installer.signature")
            ToolStateRow(symbol: report.createInstallMedia != nil ? "checkmark.circle.fill" : "xmark.circle.fill",
                         color: report.createInstallMedia != nil ? .green : .red, label: "createinstallmedia",
                         value: l.t(report.createInstallMedia != nil ? "installMedia.installer.toolPresent" : "installMedia.installer.toolMissing"),
                         id: "installMedia.installer.tool")
            if let found = report.macOSVersion, let wanted = release.version, found != wanted {
                NoticeView(style: .warning, title: l.t("installMedia.installer.otherVersion", found, wanted), message: l.t("installMedia.installer.otherVersionHint"))
                    .accessibilityIdentifier("installMedia.installer.otherVersion")
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                NoticeView(style: .error, title: problemText(problem), message: nil)
            }
            .accessibilityIdentifier("installMedia.installer.problems")
            if !problems.isEmpty {
                Button(l.t("installMedia.checkAgain")) { model.checkForInstaller() }
                    .accessibilityIdentifier("installMedia.installer.recheck")
            }
            if problems.isEmpty {
                Label(l.t("installMedia.installer.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityIdentifier("installMedia.installer.ready")
            }
        }
    }

    private func problemText(_ problem: InstallerAppProblem) -> String { Self.problemText(problem, model.l) }

    static func problemText(_ problem: InstallerAppProblem, _ l: Localizer) -> String {
        switch problem {
        case .notFound: return l.t("installMedia.problem.notFound")
        case .notSignedByApple(let detail): return l.t("installMedia.problem.notSigned", detail)
        case .noCreateInstallMedia: return l.t("installMedia.problem.noTool")
        case .toolNeedsInteraction: return l.t("installMedia.problem.interaction")
        case .toolDidNotAnswer(let detail): return l.t("installMedia.problem.noAnswer", detail)
        case .needsRosetta: return l.t("installMedia.problem.rosetta")
        case .payloadMissing: return l.t("installMedia.problem.payload")
        case .incomplete(let detail): return l.t("installMedia.problem.incomplete", detail)
        }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}

// MARK: D. Choose the drive

struct InstallMediaDriveView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("installMedia.drive.intro", l.fileSize(state.report?.requiredBytes ?? 0))).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if state.scanningDrives { ProgressView().controlSize(.small) }
                Button(l.t("installMedia.checkAgain")) { model.scanDrives() }
                    .disabled(state.scanningDrives)
                    .accessibilityIdentifier("installMedia.drives.refresh")
            }
            if state.confirmedDriveChanged {
                NoticeView(style: .warning, title: l.t("installMedia.drive.changedTitle"), message: l.t("installMedia.drive.changedMessage"))
                    .accessibilityIdentifier("installMedia.drive.changed")
            }
            if let problem = state.driveProblem {
                NoticeView(style: .error, title: l.t("installMedia.drive.listFailed"), message: problem)
            }
            if state.drives.isEmpty && !state.scanningDrives && state.driveProblem == nil {
                NoticeView(style: .info, title: l.t("installMedia.drive.none"), message: l.t("installMedia.drive.noneHint"))
                    .accessibilityIdentifier("installMedia.drive.none")
            }
            ForEach(state.drives) { candidate in
                InstallMediaDriveRow(candidate: candidate, selected: state.selectedDrive == candidate.id)
            }
            Card {
                Toggle(isOn: Binding(get: { model.installMedia.showInternalPartitions }, set: { model.setShowInternalPartitions($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.t("installMedia.expert.toggle")).fontWeight(.medium)
                        Text(l.t("installMedia.expert.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("installMedia.expert")
                if state.showInternalPartitions {
                    NoticeView(style: .warning, title: l.t("installMedia.expert.warningTitle"), message: l.t("installMedia.expert.warning"))
                        .accessibilityIdentifier("installMedia.expert.warning")
                    if !state.scanningDrives && !state.drives.contains(where: { $0.isPartition && $0.isEligible }) {
                        Text(l.t("installMedia.expert.none")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("installMedia.expert.none")
                    }
                }
            }
        }
    }
}

struct InstallMediaDriveRow: View {
    @EnvironmentObject var model: AppModel
    var candidate: DriveCandidate
    var selected: Bool

    var body: some View {
        let l = model.l
        let drive = candidate.drive
        Button {
            if candidate.isEligible { model.installMedia.selectedDrive = candidate.id }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: candidate.isEligible ? (selected ? "largecircle.fill.circle" : "circle") : "lock.fill")
                    .foregroundStyle(candidate.isEligible ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let partition = candidate.partition {
                        Text(l.t("installMedia.partition.title", partition.name.ifEmpty(partition.device))).fontWeight(.medium)
                        Text([l.fileSize(partition.sizeBytes), partition.content, partition.device, l.t("installMedia.partition.on", drive.mediaName.ifEmpty(drive.device))]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(drive.mediaName.ifEmpty(drive.device)).fontWeight(.medium)
                        Text([l.fileSize(drive.sizeBytes), drive.busProtocol, drive.device].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        let names = drive.volumes.map(\.name).filter { !$0.isEmpty && $0 != "EFI" }
                        if !names.isEmpty {
                            Text(l.t("installMedia.drive.volumes", names.joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(candidate.protections.enumerated()), id: \.offset) { _, protection in
                        Text(protectionText(protection)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .disabled(!candidate.isEligible)
        .accessibilityIdentifier("installMedia.drive.\(candidate.id)")
        .accessibilityValue(candidate.isEligible ? (selected ? "selected" : "eligible") : "protected")
    }

    private func protectionText(_ protection: DriveProtection) -> String {
        let l = model.l
        switch protection {
        case .startupDisk: return l.t("installMedia.protect.startup")
        case .internalDisk: return l.t("installMedia.protect.internal")
        case .diskImage: return l.t("installMedia.protect.diskImage")
        case .readOnly: return l.t("installMedia.protect.readOnly")
        case .holdsProtectedVolume(let name): return l.t("installMedia.protect.protectedVolume", name)
        case .timeMachine(let name): return l.t("installMedia.protect.timeMachine", name)
        case .tooSmall(let required): return l.t("installMedia.protect.tooSmall", l.fileSize(required))
        case .apfsVolume: return l.t("installMedia.protect.apfs")
        case .systemPartition: return l.t("installMedia.protect.system")
        case .unsupportedFormat(let format): return l.t("installMedia.protect.format", format)
        case .notMounted: return l.t("installMedia.protect.notMounted")
        case .notEmpty(let count): return l.p("installMedia.protect.notEmpty", count)
        case .notReadable(let name): return l.t("installMedia.protect.notReadable", name)
        }
    }
}

// MARK: E. Confirm

struct InstallMediaConfirmView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        if let candidate = state.confirmedCandidate, let report = state.report {
            let drive = candidate.drive
            let target = candidate.partition.map { $0.name.ifEmpty($0.device) } ?? drive.mediaName.ifEmpty(drive.device)
            VStack(alignment: .leading, spacing: 12) {
                NoticeView(style: .warning, title: l.t("installMedia.confirm.title", target),
                           message: l.t(candidate.isPartition ? "installMedia.confirm.partitionMessage" : "installMedia.confirm.message"))
                    .accessibilityIdentifier("installMedia.confirm.warning")
                if candidate.isPartition {
                    NoticeView(style: .error, title: l.t("installMedia.confirm.internalTitle"),
                               message: l.t(model.tools.environment.architecture == .arm64 ? "installMedia.confirm.internalAppleSilicon" : "installMedia.confirm.internalIntel"))
                        .accessibilityIdentifier("installMedia.confirm.internal")
                }
                Card {
                    ToolStateRow(symbol: "externaldrive", color: .secondary, label: l.t("installMedia.confirm.drive"),
                                 value: "\(drive.mediaName.ifEmpty(drive.device)) · \(l.fileSize(drive.sizeBytes)) · \(drive.busProtocol) · \(drive.device)",
                                 id: "installMedia.confirm.drive")
                    if let partition = candidate.partition {
                        ToolStateRow(symbol: "trash", color: .red, label: l.t("installMedia.confirm.erased"),
                                     value: "\(partition.name.ifEmpty(partition.device)) · \(l.fileSize(partition.sizeBytes)) · \(partition.device)",
                                     id: "installMedia.confirm.volumes")
                        let kept = drive.volumes.filter { $0.device.hasPrefix(drive.device + "s") && $0.device != partition.device }
                            .map { $0.name.ifEmpty($0.content) }
                        ToolStateRow(symbol: "lock", color: .green, label: l.t("installMedia.confirm.kept"),
                                     value: kept.isEmpty ? "–" : kept.joined(separator: ", "), id: "installMedia.confirm.kept")
                    } else {
                        let names = drive.volumes.map(\.name).filter { !$0.isEmpty && $0 != "EFI" }
                        ToolStateRow(symbol: "trash", color: .red, label: l.t("installMedia.confirm.erased"),
                                     value: names.isEmpty ? l.t("installMedia.confirm.noVolumes") : names.joined(separator: ", "),
                                     id: "installMedia.confirm.volumes")
                    }
                    ToolStateRow(symbol: "app", color: .secondary, label: l.t("installMedia.confirm.installer"),
                                 value: [report.app.lastPathComponent, report.macOSVersion].compactMap { $0 }.joined(separator: " · "))
                }
                if !InstallerFiles.isLockedForRoot(report.app) {
                    Label(l.t("installMedia.confirm.lockNote"), systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("installMedia.confirm.lockNote")
                }
                Card {
                    Text(l.t("installMedia.confirm.what")).font(.headline)
                    let prefix = candidate.isPartition ? "installMedia.confirm.partitionStep" : "installMedia.confirm.step"
                    ForEach(1...4, id: \.self) { index in
                        Label(l.t("\(prefix)\(index)"), systemImage: "\(index).circle").font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $model.installMedia.understood) {
                    Text(l.t("installMedia.confirm.understood", target)).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("installMedia.understood")
                if candidate.isPartition {
                    Toggle(isOn: $model.installMedia.understoodInternal) {
                        Text(l.t("installMedia.confirm.understoodInternal", target)).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("installMedia.understoodInternal")
                }
            }
        }
    }
}

// MARK: F. Working

struct InstallMediaWorkingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        VStack(alignment: .leading, spacing: 12) {
            NoticeView(style: .info, title: l.t("installMedia.working.title"), message: l.t("installMedia.working.message"))
            Card {
                let middle: [(InstallMediaStage, String)] = state.confirmedCandidate?.isPartition == true
                    ? [(.erasingAndCreating, "erasingAndCreating")] : [(.erasing, "erasing"), (.creating, "creating")]
                let stages: [(InstallMediaStage, String)] = [(.checkingInstaller, "checkingInstaller"), (.checkingDrive, "checkingDrive")]
                    + middle + [(.verifying, "verifying")]
                let current = stages.firstIndex { $0.0 == state.stage } ?? -1
                ForEach(Array(stages.enumerated()), id: \.offset) { offset, item in
                    HStack(spacing: 8) {
                        if offset < current { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else if offset == current { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        Text(l.t("installMedia.stage.\(item.1)")).fontWeight(offset == current ? .semibold : .regular)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("installMedia.stage.\(item.1)")
                    .accessibilityValue(offset < current ? "done" : (offset == current ? "running" : "waiting"))
                }
                if let started = state.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(l.t("installMedia.working.elapsed", Self.duration(context.date.timeIntervalSince(started))))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if state.stage == .creating || state.stage == .erasingAndCreating {
                    if let written = state.writtenBytes, let total = state.report?.sizeBytes, total > 0 {
                        // Measured on the drive: what is there so far, against the installer's size (never 100 % before
                        // Apple's tool has finished).
                        ProgressView(value: min(Double(written) / Double(total), 0.99)) {
                            Text(l.t("installMedia.working.written", l.fileSize(min(written, total)), l.fileSize(total)))
                                .font(.callout.monospacedDigit())
                        }
                        .accessibilityIdentifier("installMedia.working.progress")
                        .accessibilityValue("\(Int(min(Double(written) / Double(total), 0.99) * 100))")
                    }
                    Text(l.t("installMedia.working.creatingHint")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: G. Done

struct InstallMediaFinishedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        if let result = model.installMedia.result {
            VStack(alignment: .leading, spacing: 12) {
                switch result.verification {
                case .verified:
                    NoticeView(style: .success, title: l.t("installMedia.done.verified"), message: l.t("installMedia.done.verifiedMessage"))
                        .accessibilityIdentifier("installMedia.result")
                case .partiallyVerified:
                    NoticeView(style: .success, title: l.t("installMedia.done.partial"), message: l.t("installMedia.done.partialMessage"))
                        .accessibilityIdentifier("installMedia.result")
                case .notVerified, .failed:
                    NoticeView(style: .error, title: l.t("installMedia.done.failed"), message: l.t("installMedia.done.failedMessage"))
                        .accessibilityIdentifier("installMedia.result")
                }
                Card {
                    Text(l.t("installMedia.done.checks")).font(.headline)
                    ForEach(result.checks, id: \.item) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(check.passed ? .green : .red)
                            Text(l.t("installMedia.check.\(check.item.rawValue)"))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("installMedia.check.\(check.item.rawValue)")
                        .accessibilityValue(check.passed ? "passed" : "failed")
                    }
                }
                if result.verification != .failed { InstallMediaInstructions() }
                if let report = model.installMedia.report {
                    InstallMediaTrashRow(app: report.app, size: report.sizeBytes)
                }
            }
        }
    }
}

/// How to start up from the drive: this Mac's kind first, the other one after (the drive may be for another Mac).
struct InstallMediaInstructions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let kinds = model.tools.environment.architecture == .x86_64 ? ["intel", "appleSilicon"] : ["appleSilicon", "intel"]
        ForEach(kinds, id: \.self) { kind in
            Card {
                Text(l.t("installMedia.start.\(kind).title")).font(.headline)
                ForEach(1...3, id: \.self) { index in
                    Label(l.t("installMedia.start.\(kind).\(index)"), systemImage: "\(index).circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text(l.t("installMedia.start.\(kind).note")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("installMedia.instructions.\(kind)")
        }
        Label(l.t("installMedia.start.eject"), systemImage: "eject").font(.callout).foregroundStyle(.secondary)
    }
}

struct InstallMediaFailedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        VStack(alignment: .leading, spacing: 12) {
            NoticeView(style: .error, title: l.t("installMedia.failed.title"), message: state.failure.map { model.installMediaMessage($0) })
                .accessibilityIdentifier("installMedia.failure")
            NoticeView(style: state.driveErased ? .warning : .info,
                       title: l.t(state.driveErased ? "installMedia.failed.erased" : "installMedia.failed.untouched"),
                       message: l.t(state.driveErased ? "installMedia.failed.erasedHint" : "installMedia.failed.untouchedHint"))
                .accessibilityIdentifier("installMedia.failure.drive")
        }
    }
}

// MARK: Installers on this Mac

/// The Apple installers in Applications: use one, move it to the Trash, or choose one from elsewhere.
struct InstallMediaLocalCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let l = model.l
        let state = model.installMedia
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("installMedia.local.title")).font(.headline)
                Spacer()
                if state.checkingLocal || state.inspecting { ProgressView().controlSize(.small) }
                Button(l.t("installMedia.checkAgain")) { model.refreshLocalInstallers() }
                    .disabled(state.checkingLocal)
                    .accessibilityIdentifier("installMedia.local.refresh")
                Button(l.t("installMedia.local.choose")) { model.chooseInstallerFile() }
                    .disabled(state.copying)
                    .accessibilityIdentifier("installMedia.local.choose")
            }
            if state.localInstallers.isEmpty && !state.checkingLocal {
                Text(l.t("installMedia.local.none")).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("installMedia.local.none")
            }
            ForEach(state.localInstallers, id: \.app) { report in
                let problems = model.installMediaInspector.problems(of: report)
                let blocked = model.suitability(of: InstallerFiles.release(from: report)) == .intelMacsOnly
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.displayName.replacingOccurrences(of: "Install ", with: "", options: .anchored)
                             + (report.macOSVersion.map { " \($0)" } ?? "")).fontWeight(.medium)
                        Text([report.build.map { l.t("installMedia.build", $0) }, l.fileSize(report.sizeBytes), report.app.lastPathComponent]
                            .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if let problem = problems.first {
                            Text(l.t("installMedia.local.unusable", InstallMediaReportCard.problemText(problem, l))).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if blocked {
                            Text(l.t("installMedia.suitability.intelMacsOnly")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(l.t("installMedia.local.trash")) { model.askToTrash(report.app, size: report.sizeBytes) }
                        .disabled(state.trashing)
                        .accessibilityIdentifier("installMedia.local.trash.\(report.app.lastPathComponent)")
                    Button(l.t("installMedia.local.use")) { model.useLocalInstaller(report) }
                        .disabled(!problems.isEmpty || blocked)
                        .accessibilityIdentifier("installMedia.local.use.\(report.app.lastPathComponent)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("installMedia.local.\(report.app.lastPathComponent)")
            }
            Text(l.t("installMedia.local.chooseHint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let existing = state.copyNameTaken {
                NoticeView(style: .warning, title: l.t("installMedia.copy.nameTaken", existing.lastPathComponent), message: l.t("installMedia.copy.nameTakenHint"))
                    .accessibilityIdentifier("installMedia.copy.nameTaken")
                HStack {
                    Button(l.t("common.cancel")) { model.cancelCopy() }
                    Button(l.t("installMedia.copy.replace")) { model.replaceExistingAndCopy() }
                        .accessibilityIdentifier("installMedia.copy.replace")
                    Button(l.t("installMedia.copy.useExisting")) { model.useExistingInsteadOfCopy() }
                        .accessibilityIdentifier("installMedia.copy.useExisting")
                }
            } else if let source = state.pendingCopy {
                InstallMediaCopyQuestion(source: source)
            }
            if state.copying {
                HStack { ProgressView().controlSize(.small); Text(l.t("installMedia.copy.copying")) }
                    .accessibilityIdentifier("installMedia.copy.copying")
            }
            if let problem = state.copyProblem {
                NoticeView(style: .error, title: l.t("installMedia.copy.failed"), message: problem)
                    .accessibilityIdentifier("installMedia.copy.problem")
            }
            InstallMediaTrashStatus()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("installMedia.local")
        .modifier(InstallMediaTrashDialog())
    }
}

struct InstallMediaCopyQuestion: View {
    @EnvironmentObject var model: AppModel
    var source: URL

    var body: some View {
        let l = model.l
        let needed = model.installMedia.pendingCopyNeeded
        let free = InstallerFiles.availableSpace(model.installerFiles.applications)
        NoticeView(style: .info, title: l.t("installMedia.copy.title", source.lastPathComponent),
                   message: needed == 0 ? l.t("installMedia.copy.clone")
                       : l.t("installMedia.copy.message", needed.map { l.fileSize($0) } ?? "…", free.map { l.fileSize($0) } ?? "?"))
            .accessibilityIdentifier("installMedia.copy.question")
        HStack {
            Button(l.t("common.cancel")) { model.cancelCopy() }
                .accessibilityIdentifier("installMedia.copy.cancel")
            Button(l.t("installMedia.copy.confirm")) { model.confirmCopy() }
                .disabled(model.installMedia.copying || needed == nil)
                .accessibilityIdentifier("installMedia.copy.confirm")
        }
    }
}

/// “Move Installer to Trash…” on the finished screen.
struct InstallMediaTrashRow: View {
    @EnvironmentObject var model: AppModel
    var app: URL
    var size: Int64

    var body: some View {
        let l = model.l
        Card {
            HStack {
                Text(l.t("installMedia.done.trashHint", l.fileSize(size))).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(l.t("installMedia.done.trash")) { model.askToTrash(app, size: size) }
                    .disabled(model.installMedia.trashing || !FileManager.default.fileExists(atPath: app.path))
                    .accessibilityIdentifier("installMedia.done.trash")
            }
            InstallMediaTrashStatus()
        }
        .modifier(InstallMediaTrashDialog())
    }
}

struct InstallMediaTrashStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let state = model.installMedia
        if state.trashing {
            HStack { ProgressView().controlSize(.small); Text(model.l.t("installMedia.trash.moving")) }
        } else if let message = state.trashMessage {
            NoticeView(style: state.trashFailed ? .error : .success, title: message, message: nil)
                .accessibilityIdentifier("installMedia.trash.result")
        }
    }
}

struct InstallMediaTrashDialog: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        let l = model.l
        let candidate = model.installMedia.trashCandidate
        content.confirmationDialog(l.t("installMedia.trash.title", candidate?.lastPathComponent ?? ""),
                                   isPresented: Binding(get: { model.installMedia.trashCandidate != nil },
                                                        set: { if !$0 { model.installMedia.trashCandidate = nil } })) {
            Button(l.t("installMedia.trash.confirm"), role: .destructive) { model.confirmTrash() }
                .accessibilityIdentifier("installMedia.trash.confirm")
            Button(l.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l.t("installMedia.trash.message", model.installMedia.trashCandidateSize.map { l.fileSize($0) } ?? "?"))
        }
    }
}
