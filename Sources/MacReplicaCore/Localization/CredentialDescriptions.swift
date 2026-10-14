import Foundation

/// Texts for the credential section, its readiness report and restore results.
extension Localizer {
    public func credentialCategoryText(_ category: CredentialCategory) -> String { t("credential.category.\(category.rawValue)") }
    public func credentialProblemText(_ problem: CredentialProblem) -> String { t("credential.problem.\(problem.rawValue)") }
    public func credentialNeedsText(_ needs: [CredentialPrerequisite]) -> String { needs.map { t("credential.needs.\($0.rawValue)") }.joined(separator: " ") }

    /// "KeePass password database · KDBX 4.1"
    public func credentialSummary(category: CredentialCategory, format: String?) -> String {
        [credentialCategoryText(category), format].compactMap { $0 }.joined(separator: " · ")
    }

    public func credentialStatusText(_ record: CredentialItemRecord) -> String {
        record.isPreserved ? t("credential.status.encryptedBackupVerified")
            : t("credential.status.failed", credentialProblemText(record.problem ?? .encryptionFailed))
    }
}

extension ReportBuilder {
    /// Every credential the backup knows about, by what happened to it: preserved (encrypted and verified), not
    /// preserved (with the reason), not decided, left out by the user, not copyable, and what needs a manual step.
    /// Paths and names only – never contents.
    func credentialReadinessSection(_ manifest: Manifest) -> String {
        let l = localizer
        var body = "<p>\(HTML.escape(l.t("credential.report.intro")))</p>"
        func list(_ title: String, _ style: String, _ rows: [String]) {
            guard !rows.isEmpty else { return }
            body += "<p class=\"\(style)\"><b>\(HTML.escape(title))</b></p><ul>" + rows.map { "<li>\($0)</li>" }.joined() + "</ul>"
        }
        func row(_ path: String, _ text: String) -> String { "<code>\(HTML.escape(path))</code> — \(HTML.escape(text))" }
        let preserved = manifest.preservedCredentials
        if !preserved.isEmpty {
            body += "<p class=\"ok\">\(HTML.escape(l.t("credential.report.unlock")))</p>"
        }
        list(l.p("credential.report.preserved", preserved.count), "ok", preserved.map { record in
            row(record.originalPath, [l.credentialSummary(category: record.category, format: record.format), l.credentialStatusText(record),
                                      l.credentialNeedsText(record.prerequisites)].filter { !$0.isEmpty }.joined(separator: ". "))
        })
        list(l.p("credential.report.failed", manifest.failedCredentials.count), "warn", manifest.failedCredentials.map {
            row($0.originalPath, l.credentialStatusText($0))
        })
        list(l.p("credential.report.undecided", manifest.undecidedCredentials.count), "warn", manifest.undecidedCredentials.map {
            row($0.path, l.sensitiveDescription($0) + ". " + l.t("credential.report.undecided.advice"))
        })
        list(l.p("credential.report.leftOut", manifest.credentialsLeftOutByUser.count), "muted", manifest.credentialsLeftOutByUser.map {
            row($0.path, l.sensitiveDescription($0) + ". " + l.t("credential.report.leftOut.reason"))
        })
        list(l.p("credential.report.notCopyable", manifest.uncopyableCredentials.count), "warn", manifest.uncopyableCredentials.map {
            row($0.path, l.sensitiveDescription($0) + ". " + l.sensitiveExplanation($0))
        })
        let manual = manifest.guidance.filter { GuidanceCatalog.credentialIDs.contains($0.id) }
        list(l.t("credential.report.manual"), "warn", manual.map {
            "<b>\(HTML.escape(l.guidanceName($0)))</b>: \(HTML.escape(l.t("guidance.credential.\($0.id)")))"
        })
        if manifest.credentialItems.isEmpty && manifest.credentials.isEmpty && manifest.excludedSensitiveFiles.isEmpty && manual.isEmpty {
            body += "<p class=\"muted\">\(HTML.escape(l.t("credential.report.none")))</p>"
        }
        return body
    }
}
