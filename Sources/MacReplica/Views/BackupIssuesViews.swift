import MacReplicaCore
import SwiftUI

/// How complete a backup is, as one notice: complete, complete except files left out on purpose, or partial.
struct CompletenessNotice: View {
    @EnvironmentObject var model: AppModel
    var manifest: Manifest
    /// On the new Mac the advice is about the old Mac, if the user still has it.
    var onNewMac = false

    var body: some View {
        let l = model.l
        let style: NoticeView.Style = manifest.completeness == .complete ? .success : (manifest.completeness == .partial ? .warning : .info)
        let message = onNewMac && manifest.completeness != .complete ? l.t("completeness.restore.message") : l.completenessMessage(manifest)
        NoticeView(style: style, title: l.completenessTitle(manifest), message: message)
            .accessibilityIdentifier("completeness.\(manifest.completeness.rawValue)")
    }
}

/// Everything that is not in the backup – or is in it only because the user asked – with the reason and what to do.
/// `editable`: on the selection screen, files left out as sensitive can be included (after a confirmation).
/// `onThisMac`: the files are on this Mac, so they can be shown in Finder.
struct NotInBackupView: View {
    @EnvironmentObject var model: AppModel
    var manifest: Manifest
    var editable: Bool
    var onThisMac: Bool

    var body: some View {
        let l = model.l
        let sensitive = manifest.excludedSensitiveFiles
        let gaps = manifest.backupGaps
        let included = manifest.sensitiveFilesIncludedOnRequest
        VStack(alignment: .leading, spacing: 10) {
            if !gaps.isEmpty {
                LabelWithHelp(label: l.p("notInBackup.gaps", gaps.count), help: l.t("notInBackup.gaps.help"), id: "help.notInBackup.gaps",
                              font: .subheadline.weight(.semibold))
                ForEach(Array(gaps.enumerated()), id: \.offset) { _, issue in
                    IssueRow(symbol: "exclamationmark.triangle.fill", color: .orange, title: issue.fileName, path: issue.path,
                             lines: [l.backupIssueText(issue)], onThisMac: onThisMac)
                }
            }
            if !sensitive.isEmpty {
                LabelWithHelp(label: l.p("notInBackup.sensitive", sensitive.count), help: l.t("notInBackup.sensitive.help"),
                              id: "help.notInBackup.sensitive", font: .subheadline.weight(.semibold))
                ForEach(Array(sensitive.enumerated()), id: \.offset) { _, issue in
                    let header = onThisMac && issue.sensitive?.kind == .passwordDatabase
                        ? KeePassHeader.read(model.services.layout.resolve(displayPath: issue.path)) : nil
                    IssueRow(symbol: "lock.fill", color: .secondary, title: issue.fileName, path: issue.path,
                             lines: [l.sensitiveDescription(issue, header: header), l.sensitiveExplanation(issue)], onThisMac: onThisMac) {
                        if editable, issue.sensitive.map({ CredentialPolicy.isCopyable($0.kind) }) ?? true, issue.detail != .leftOutByUser {
                            Button(l.t("credential.addOne")) { model.includeSensitiveFile(issue) }
                                .controlSize(.small)
                                .accessibilityIdentifier("sensitive.include.\(issue.fileName)")
                        }
                    }
                }
            }
            if !included.isEmpty {
                LabelWithHelp(label: l.p("notInBackup.included", included.count), help: l.t("notInBackup.included.help"),
                              id: "help.notInBackup.included", font: .subheadline.weight(.semibold))
                ForEach(included, id: \.backupPath) { record in
                    let kind = record.metadata[AppDataScanner.includedOnRequestKey].flatMap(SensitiveKind.init(rawValue:))
                    IssueRow(symbol: "lock.open.fill", color: .orange, title: record.fileName, path: record.originalPath,
                             lines: [kind.map { l.t("sensitive.includedAs", l.sensitiveKindText($0)) } ?? ""], onThisMac: onThisMac) {
                        if editable {
                            Button(l.t("sensitive.exclude.button")) { model.excludeSensitiveFileAgain(record.originalPath) }
                                .controlSize(.small)
                                .accessibilityIdentifier("sensitive.exclude.\(record.fileName)")
                        }
                    }
                }
            }
        }
    }
}

/// One file: name, where it is, what it is and what to do; "Show in Finder" when it is on this Mac.
struct IssueRow<Actions: View>: View {
    @EnvironmentObject var model: AppModel
    var symbol: String
    var color: Color
    var title: String
    var path: String
    var lines: [String]
    var onThisMac: Bool
    @ViewBuilder var actions: Actions

    init(symbol: String, color: Color, title: String, path: String, lines: [String], onThisMac: Bool,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.path = path
        self.lines = lines
        self.onThisMac = onThisMac
        self.actions = actions()
    }

    var body: some View {
        let l = model.l
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if !path.isEmpty {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                actions
                if onThisMac, model.fileExists(path) {
                    Button(l.t("notInBackup.reveal")) { model.revealFile(path) }
                        .controlSize(.small)
                        .accessibilityIdentifier("notInBackup.reveal.\(title)")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}
