import Foundation

extension ReportBuilder {
    /// Step-by-step restore instructions stored in every backup (`restore/RESTORE_INSTRUCTIONS.html`).
    public func restoreInstructions(_ manifest: Manifest, folderName: String) -> String {
        let l = localizer
        let counts = InventoryCounts(manifest)
        func list(_ keys: [String], ordered: Bool = true) -> String {
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + keys.map { "<li>\(HTML.escape(l.t($0)))</li>" }.joined() + "</\(tag)>"
        }
        func h2(_ key: String) -> String { "<h2>\(HTML.escape(l.t(key)))</h2>" }

        var body = "<p>\(HTML.escape(l.t("guide.intro")))</p>"

        body += h2("guide.contents")
        body += "<div class=\"cards\">"
        body += card(counts.applications, l.t("report.card.applications"))
        body += card(counts.homebrew + counts.appStore, l.t("guide.automatic"))
        body += card(counts.officialDownload + counts.manual, l.t("category.manual"))
        body += card(counts.formulae + counts.casks, "Homebrew")
        body += card(manifest.python.environments.count, l.t("component.python"))
        body += card(manifest.applicationData.count, l.t("component.applicationData"))
        body += card(counts.fonts, l.t("component.fonts"))
        body += card(counts.colorProfiles, l.t("component.colorProfiles"))
        body += "</div>"
        if manifest.backupGaps.isEmpty {
            body += "<p class=\"ok\">\(HTML.escape(l.t("guide.complete")))</p>"
        } else {
            body += "<p class=\"warn\">\(HTML.escape(l.p("guide.partial", manifest.backupGaps.count)))</p><ul>"
            for issue in manifest.backupGaps.prefix(50) {
                body += "<li><code>\(HTML.escape(issue.path))</code> — \(HTML.escape(l.t("backupIssue.\(issue.reason.rawValue)")))</li>"
            }
            body += "</ul>"
        }
        if !manifest.excludedSensitiveFiles.isEmpty {
            body += "<p class=\"muted\">\(HTML.escape(l.p("appData.refused", manifest.excludedSensitiveFiles.count)))</p>"
        }

        body += h2("guide.oldMac.title")
        body += list(["guide.oldMac.1", "guide.oldMac.2", "guide.oldMac.3", "guide.oldMac.4", "guide.oldMac.5", "guide.oldMac.6"])

        body += h2("guide.transfer.title")
        body += "<p>\(HTML.escape(l.t("guide.transfer.intro", folderName)))</p>"
        body += list(["guide.transfer.drive", "guide.transfer.network", "guide.transfer.cloud", "guide.transfer.airdrop"], ordered: false)
        body += "<p>\(HTML.escape(l.t("guide.transfer.check")))</p>"

        body += h2("guide.newMac.title")
        body += list(["guide.newMac.1", "guide.newMac.2", "guide.newMac.3", "guide.newMac.4", "guide.newMac.5", "guide.newMac.6",
                      "guide.newMac.7", "guide.newMac.8"])

        let manual = manifest.applications.filter { $0.restoreMethod.category == .manual || $0.restoreMethod.category == .officialDownload }
        if !manual.isEmpty {
            body += h2("report.manual.title")
            body += "<ul>" + manual.map { app in
                "<li><b>\(HTML.escape(app.name))</b> — \(HTML.escape(l.manualHint(for: app)))"
                    + (app.homepage.map { " " + HTML.link($0) } ?? "") + "</li>"
            }.joined() + "</ul>"
        }

        if !manifest.python.isEmpty {
            body += h2("guide.python.title")
            body += "<p>\(HTML.escape(l.t("guide.python.intro")))</p>"
            for environment in manifest.python.environments {
                body += "<h3>\(HTML.escape(environment.name)) <span class=\"muted\">· Python \(HTML.escape(environment.pythonVersion))</span></h3>"
                body += "<p>\(HTML.escape(l.t("guide.python.location", environment.path)))<br>"
                body += HTML.escape(l.p("guide.python.packages", environment.installablePackages.count)) + "</p>"
                let shellPath = environment.path.hasPrefix("~/") ? "\"$HOME/\(environment.path.dropFirst(2))\"" : "\"\(environment.path)\""
                let minor = environment.minorVersion
                let commands = [
                    "brew install python@\(minor)",
                    "\"$(brew --prefix)/opt/python@\(minor)/bin/python\(minor)\" -m venv \(shellPath)",
                    "\(shellPath.dropLast())/bin/python\" -m pip install -r \"<\(l.t("guide.python.backupFolder"))>/\(environment.requirementsPath)\"",
                ]
                body += "<p class=\"muted\">\(HTML.escape(l.t("guide.python.manualCommands")))</p>"
                body += "<pre><code>\(HTML.escape(commands.joined(separator: "\n")))</code></pre>"
                if !environment.manualPackages.isEmpty {
                    body += "<p class=\"warn\">\(HTML.escape(l.t("guide.python.manualPackages", environment.manualPackages.map(\.name).joined(separator: ", "))))</p>"
                }
            }
            if !manifest.python.settings.isEmpty {
                body += "<h3>\(HTML.escape(l.t("guide.python.settings")))</h3><p>\(HTML.escape(l.t("guide.python.settingsIntro")))</p><pre><code>"
                body += manifest.python.settings.map { setting in
                    HTML.escape(setting.key.contains(" ") ? "# \(setting.key): \(setting.value)  (\(setting.source))"
                                                           : "export \(setting.key)=\"\(setting.value)\"  # \(setting.source)")
                }.joined(separator: "\n")
                body += "</code></pre>"
            }
        }

        if !manifest.applicationData.isEmpty {
            body += h2("component.applicationData")
            body += "<p>\(HTML.escape(l.t("guide.appData.intro")))</p><ul>"
            for folder in manifest.applicationData {
                body += "<li><code>\(HTML.escape(folder.displayPath))</code> — \(HTML.escape(l.p("guide.appData.files", folder.files.count)))"
                body += " (\(HTML.escape(l.fileSize(folder.totalSize))))</li>"
            }
            body += "</ul>"
        }

        if !manifest.developer.isEmpty {
            body += h2("component.developerSettings")
            body += "<p>\(HTML.escape(l.t("guide.developer.intro")))</p>"
            if !manifest.developer.removedGitSections.isEmpty {
                body += "<p class=\"muted\">\(HTML.escape(l.t("guide.developer.removed", manifest.developer.removedGitSections.joined(separator: ", "))))</p>"
            }
        }

        // Sign-ins and credentials: what moves and what does not.
        body += h2("guide.accounts.title")
        body += "<p>\(HTML.escape(l.t("guide.accounts.intro")))</p>"
        body += list(["guide.accounts.configuration", "guide.accounts.reauthentication", "guide.accounts.keychain"], ordered: false)
        if manifest.credentials.isEmpty {
            body += "<p class=\"muted\">\(HTML.escape(l.t("guide.accounts.noCredentials")))</p>"
        } else {
            for record in manifest.credentials {
                body += "<p class=\"warn\">\(HTML.escape(l.t("guide.accounts.vault", record.provider.uppercased(), record.items.joined(separator: ", "), record.vaultPath)))</p>"
            }
        }

        let blocked = manifest.locations.filter { $0.status == .noPermission }
        if !blocked.isEmpty {
            body += h2("guide.access.title")
            body += "<p>\(HTML.escape(l.t("guide.access.intro")))</p><ul>"
            body += blocked.map { "<li><code>\(HTML.escape($0.location))</code></li>" }.joined() + "</ul>"
        }

        body += h2("guide.trouble.title")
        body += list(["guide.trouble.1", "guide.trouble.2", "guide.trouble.3"], ordered: false)

        return page(title: l.t("guide.title"), subtitle: l.t("report.subtitle", l.date(manifest.createdAt), manifest.macosVersion,
                                                              l.architectureText(manifest.architecture)), body: body)
    }
}
