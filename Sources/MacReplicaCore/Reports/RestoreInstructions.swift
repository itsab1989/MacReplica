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
        body += homebrewSupportNote(manifest)
        body += notInBackupSection(manifest)

        body += h2("guide.oldMac.title")
        body += list(["guide.oldMac.1", "guide.oldMac.2", "guide.oldMac.3", "guide.oldMac.4", "guide.oldMac.5", "guide.oldMac.6"])

        body += h2("guide.transfer.title")
        body += "<p>\(HTML.escape(l.t("guide.transfer.intro", folderName)))</p>"
        body += list(["guide.transfer.drive", "guide.transfer.network", "guide.transfer.cloud", "guide.transfer.airdrop"], ordered: false)
        body += "<p>\(HTML.escape(l.t("guide.transfer.check")))</p>"

        body += h2("guide.newMac.title")
        if let app = manifest.bootstrapApp {
            body += "<p class=\"ok\">\(HTML.escape(l.bootstrapSummary(app)))</p>"
        }
        body += list([manifest.bootstrapApp == nil ? "guide.newMac.1" : "guide.newMac.1.fromBackup", "guide.newMac.2", "guide.newMac.3",
                      "guide.newMac.4", "guide.newMac.5", "guide.newMac.6", "guide.newMac.7", "guide.newMac.8"])

        let manual = manifest.applications.filter { $0.restoreMethod.category == .manual || $0.restoreMethod.category == .officialDownload }
        if !manual.isEmpty {
            body += h2("report.manual.title")
            // Built step by step: long string expressions with closures are slow to type-check on older compilers.
            body += "<ul>"
            for app in manual {
                var item = "<li><b>\(HTML.escape(app.name))</b> — \(HTML.escape(l.manualHint(for: app)))"
                if let homepage = app.homepage { item += " " + HTML.link(homepage) }
                body += item + "</li>"
            }
            body += "</ul>"
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
                var settingLines: [String] = []
                for setting in manifest.python.settings {
                    let line: String
                    if setting.key.contains(" ") {
                        line = "# \(setting.key): \(setting.value)  (\(setting.source))"
                    } else {
                        line = "export \(setting.key)=\"\(setting.value)\"  # \(setting.source)"
                    }
                    settingLines.append(HTML.escape(line))
                }
                body += settingLines.joined(separator: "\n")
                body += "</code></pre>"
            }
        }
        if !manifest.toolchains.isEmpty {
            body += h2("guide.toolchains.title")
            body += "<p>\(HTML.escape(l.t("guide.toolchains.intro")))</p>"
            for record in manifest.toolchains {
                let provider = ToolchainCatalog.provider(record.provider)
                let descriptor = provider.descriptor
                body += "<h3>\(HTML.escape(descriptor.name)) <span class=\"muted\">· \(HTML.escape(l.ecosystemText(descriptor.ecosystem)))</span></h3>"
                var items = record.runtimes.map { $0.version + ($0.isDefault ? " *" : "") }
                items += record.packages.map { [$0.name, $0.version].compactMap { $0 }.joined(separator: " ") }
                items += record.environments.map { "\($0.name): \($0.requestedPackages.filter { !$0.hasPrefix("expose=") }.joined(separator: ", "))" }
                if !items.isEmpty { body += "<p>\(HTML.escape(items.joined(separator: " · ")))</p>" }
                let instructions = provider.restoreActions(for: record).compactMap { provider.manualInstruction(for: $0) }
                if !instructions.isEmpty { body += "<pre><code>\(HTML.escape(instructions.joined(separator: "\n")))</code></pre>" }
                body += "<p class=\"muted\">\(HTML.link(descriptor.website))</p>"
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
            if manifest.developer.gitConfig != nil {
                body += "<p>\(HTML.escape(l.t("guide.developer.intro")))</p>"
            }
            for (editor, ids) in manifest.developer.editorExtensions.sorted(by: { $0.key < $1.key }) {
                let cli = editor == "Cursor" ? "cursor" : "code"
                body += "<h3>\(HTML.escape(l.t("guide.extensions.title", editor)))</h3><p>\(HTML.escape(l.t("guide.extensions.intro")))</p>"
                body += "<pre><code>\(HTML.escape(ids.map { "\(cli) --install-extension \($0)" }.joined(separator: "\n")))</code></pre>"
            }
            if !manifest.developer.removedGitSections.isEmpty {
                body += "<p class=\"muted\">\(HTML.escape(l.t("guide.developer.removed", manifest.developer.removedGitSections.joined(separator: ", "))))</p>"
            }
        }

        // Sign-ins and credentials: what moves and what does not.
        body += h2("guide.accounts.title")
        body += "<p>\(HTML.escape(l.t("guide.accounts.intro")))</p>"
        body += list(["guide.accounts.configuration", "guide.accounts.reauthentication", "guide.accounts.keychain"], ordered: false)
        let reauth = manifest.guidance.filter { $0.kind == .reauthenticationRequired }
        if !reauth.isEmpty {
            body += "<p><b>\(HTML.escape(l.t("guidance.reauth.title")))</b> \(HTML.escape(reauth.map(\.currentName).joined(separator: ", ")))</p>"
        }
        let manualServices = manifest.guidance.filter { $0.kind == .manualMigration }
        if !manualServices.isEmpty {
            body += "<p><b>\(HTML.escape(l.t("guidance.manual.title")))</b></p><ul>"
            body += manualServices.map { "<li><b>\(HTML.escape($0.currentName))</b>: \(HTML.escape(l.t("guidance.manual.\($0.id)")))</li>" }.joined() + "</ul>"
        }
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

    /// How complete the backup is and every file that is not in it (or only at the user's request), with the reason and
    /// what to do. Paths and file names only – never contents.
    func notInBackupSection(_ manifest: Manifest) -> String {
        let l = localizer
        var body = "<p class=\"\(manifest.completeness == .partial ? "warn" : "ok")\"><b>\(HTML.escape(l.completenessTitle(manifest)))</b> "
            + HTML.escape(l.completenessMessage(manifest)) + "</p>"
        if !manifest.backupGaps.isEmpty {
            body += "<p><b>\(HTML.escape(l.p("notInBackup.gaps", manifest.backupGaps.count)))</b></p><ul>"
            for issue in manifest.backupGaps.prefix(200) {
                body += "<li><code>\(HTML.escape(issue.path))</code> — \(HTML.escape(l.backupIssueText(issue)))</li>"
            }
            body += "</ul>"
        }
        if !manifest.excludedSensitiveFiles.isEmpty {
            body += "<p><b>\(HTML.escape(l.p("notInBackup.sensitive", manifest.excludedSensitiveFiles.count)))</b></p><ul>"
            for issue in manifest.excludedSensitiveFiles.prefix(200) {
                body += "<li><code>\(HTML.escape(issue.path))</code> — \(HTML.escape(l.sensitiveDescription(issue))). "
                    + "\(HTML.escape(l.sensitiveExplanation(issue)))</li>"
            }
            body += "</ul>"
        }
        let included = manifest.sensitiveFilesIncludedOnRequest
        if !included.isEmpty {
            body += "<p><b>\(HTML.escape(l.p("notInBackup.included", included.count)))</b></p><ul>"
            for record in included {
                let kind = record.metadata[AppDataScanner.includedOnRequestKey].flatMap(SensitiveKind.init(rawValue:))
                body += "<li><code>\(HTML.escape(record.originalPath))</code>" + (kind.map { " — " + HTML.escape(l.t("sensitive.includedAs", l.sensitiveKindText($0))) } ?? "") + "</li>"
            }
            body += "</ul>"
        }
        return body
    }
}
