import Foundation

/// Escapes text for safe inclusion in HTML. App names and paths come from the
/// system or from a backup and must never be able to inject markup.
public enum HTML {
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A link only for http(s) URLs; anything else (javascript:, file:) is shown as plain text.
    public static func link(_ urlString: String?, label: String? = nil) -> String {
        guard let urlString, let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return escape(label ?? urlString ?? "—")
        }
        return "<a href=\"\(escape(urlString))\" rel=\"noopener noreferrer\">\(escape(label ?? urlString))</a>"
    }
}

/// Builds the human-readable HTML reports in the selected language.
public struct ReportBuilder: Sendable {
    public var localizer: Localizer

    public init(localizer: Localizer) {
        self.localizer = localizer
    }

    private var l: Localizer { localizer }

    func page(title: String, subtitle: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(l.language.rawValue)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTML.escape(title))</title>
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --bg: #ffffff; --card: #f5f5f7; --ok: #1b7f3b; --bad: #c4291c; --warn: #a15c00; }
        @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --line: #424245; --bg: #1d1d1f; --card: #2c2c2e; --ok: #4cd964; --bad: #ff6b5e; --warn: #ffb340; } }
        body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg); margin: 0; padding: 32px; }
        main { max-width: 1100px; margin: 0 auto; }
        h1 { font-size: 26px; margin: 0 0 4px; } h2 { font-size: 18px; margin: 32px 0 8px; }
        .subtitle { color: var(--muted); margin-bottom: 24px; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
        .card { background: var(--card); border-radius: 10px; padding: 12px 16px; }
        .card b { display: block; font-size: 24px; }
        table { width: 100%; border-collapse: collapse; margin-top: 8px; }
        th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
        th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .03em; }
        code { font: 12px ui-monospace, Menlo, monospace; }
        .ok { color: var(--ok); } .bad { color: var(--bad); } .warn { color: var(--warn); } .muted { color: var(--muted); }
        footer { margin-top: 40px; color: var(--muted); font-size: 12px; }
        h3 { font-size: 15px; margin: 20px 0 4px; }
        pre { background: var(--card); border-radius: 8px; padding: 10px 12px; overflow-x: auto; }
        li { margin: 3px 0; }
        </style>
        </head>
        <body><main>
        <h1>\(HTML.escape(title))</h1>
        <div class="subtitle">\(HTML.escape(subtitle))</div>
        \(body)
        <footer>\(HTML.escape(l.t("report.footer", "\(SystemInfo.appVersion) (\(SystemInfo.buildNumber))")))</footer>
        </main></body></html>
        """
    }

    private func table(_ headers: [String], _ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "<p class=\"muted\">\(HTML.escape(l.t("report.none")))</p>" }
        let head = headers.map { "<th>\(HTML.escape($0))</th>" }.joined()
        let body = rows.map { "<tr>" + $0.map { "<td>\($0)</td>" }.joined() + "</tr>" }.joined(separator: "\n")
        return "<table><thead><tr>\(head)</tr></thead><tbody>\n\(body)\n</tbody></table>"
    }

    func card(_ value: Int, _ label: String) -> String {
        "<div class=\"card\"><b>\(HTML.escape(l.number(value)))</b>\(HTML.escape(label))</div>"
    }

    private func code(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "—" }
        return "<code>\(HTML.escape(text))</code>"
    }

    private func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return HTML.escape(value)
    }

    private func methodDetail(_ method: RestoreMethod) -> String {
        switch method {
        case .homebrewCask(let token): return HTML.escape(l.methodText(method)) + " " + code(token)
        case .homebrewFormula(let name): return HTML.escape(l.methodText(method)) + " " + code(name)
        case .appStore(let id): return HTML.escape(l.methodText(method)) + " " + code(String(id))
        case .officialDownload, .manual: return HTML.escape(l.methodText(method))
        }
    }

    private func subtitle(_ manifest: Manifest) -> String {
        l.t("report.subtitle", l.date(manifest.createdAt), manifest.macosVersion, l.architectureText(manifest.architecture))
    }

    public func inventoryReport(_ manifest: Manifest) -> String {
        let counts = InventoryCounts(manifest)
        var body = "<div class=\"cards\">"
        body += card(counts.applications, l.t("report.card.applications"))
        body += card(counts.homebrew, l.t("category.homebrew"))
        body += card(counts.appStore, l.t("category.appStore"))
        body += card(counts.officialDownload, l.t("category.officialDownload"))
        body += card(counts.manual, l.t("category.manual"))
        body += card(counts.fonts, l.t("component.fonts"))
        body += card(counts.colorProfiles, l.t("component.colorProfiles"))
        body += "</div>"

        body += "<h2>\(HTML.escape(l.t("component.applications")))</h2>"
        body += table(
            [l.t("report.column.name"), l.t("report.column.version"), l.t("report.column.vendor"), l.t("report.column.source"),
             l.t("report.column.restoreMethod"), l.t("report.column.architecture")],
            manifest.applications.map { app in
                [text(app.name) + "<br>" + code(app.bundleIdentifier), text(app.version), text(app.vendor),
                 HTML.escape(l.sourceText(app.source)), methodDetail(app.restoreMethod),
                 HTML.escape(app.architectures.map(l.architectureText).joined(separator: ", ").ifEmpty("—"))]
            })

        body += "<h2>\(HTML.escape(l.t("component.brewFormulae")))</h2>"
        body += table([l.t("report.column.name"), l.t("report.column.version"), l.t("report.column.tap")],
                      manifest.brewFormulae.filter(\.installedOnRequest).map { [code($0.name), text($0.version), code($0.tap)] })

        body += "<h2>\(HTML.escape(l.t("component.brewCasks")))</h2>"
        body += table([l.t("report.column.name"), l.t("report.column.version"), l.t("report.column.tap")],
                      manifest.brewCasks.map { [code($0.token), text($0.version), code($0.tap)] })

        if !manifest.brewTaps.isEmpty {
            body += "<h2>\(HTML.escape(l.t("report.taps")))</h2>"
            body += table([l.t("report.column.name"), l.t("report.column.source")],
                          manifest.brewTaps.map { [code($0.name), HTML.link($0.remote)] })
        }

        body += "<h2>\(HTML.escape(l.t("component.appStore")))</h2>"
        body += table([l.t("report.column.name"), l.t("report.column.version"), l.t("report.column.appStoreID")],
                      manifest.masApps.map { [text($0.name), text($0.version), code(String($0.appStoreID))] })

        body += "<h2>\(HTML.escape(l.t("component.fonts")))</h2>"
        body += table([l.t("report.column.file"), l.t("report.column.family"), l.t("report.column.location"), l.t("report.column.size")],
                      manifest.fonts.map { [text($0.fileName), text($0.metadata["family"]), HTML.escape(locationText($0.domain)),
                                            HTML.escape(l.fileSize($0.size))] })

        body += "<h2>\(HTML.escape(l.t("component.colorProfiles")))</h2>"
        body += table([l.t("report.column.file"), l.t("report.column.description"), l.t("report.column.location"), l.t("report.column.size")],
                      manifest.iccProfiles.map { [text($0.fileName), text($0.metadata["description"]), HTML.escape(locationText($0.domain)),
                                                  HTML.escape(l.fileSize($0.size))] })

        if !manifest.locations.isEmpty {
            body += "<h2>\(HTML.escape(l.t("report.locations")))</h2>"
            body += table([l.t("report.column.area"), l.t("report.column.location"), l.t("report.column.result")],
                          manifest.locations.map { location in
                              let css = location.status == .noPermission ? "warn" : (location.status == .scanned ? "ok" : "muted")
                              return [HTML.escape(l.accessAreaText(location.area)), code(location.location),
                                      "<span class=\"\(css)\">\(HTML.escape(l.accessStatusText(location.status)))</span>"]
                          })
        }
        return page(title: l.t("report.inventory.title"), subtitle: subtitle(manifest), body: body)
    }

    func locationText(_ domain: FileDomain) -> String {
        domain == .user ? l.t("location.user") : l.t("location.system")
    }

    /// Apps that need a manual step, with vendor links and hints.
    public func manualInstallationsReport(_ manifest: Manifest) -> String {
        let apps = manifest.applications.filter {
            $0.restoreMethod.category == .manual || $0.restoreMethod.category == .officialDownload
        }
        var body = "<p>\(HTML.escape(l.p("report.manual.intro", apps.count)))</p>"
        body += table(
            [l.t("report.column.name"), l.t("report.column.version"), l.t("report.column.vendor"), l.t("report.column.bundleID"),
             l.t("report.column.source"), l.t("report.column.recommended"), l.t("report.column.vendorPage"),
             l.t("report.column.downloadPage"), l.t("report.column.notes")],
            apps.map { app in
                [text(app.name), text(app.version), text(app.vendor), code(app.bundleIdentifier), HTML.escape(l.sourceText(app.source)),
                 HTML.escape(l.methodText(app.restoreMethod)), HTML.link(app.homepage, label: app.homepage.flatMap { URL(string: $0)?.host }),
                 downloadLink(app), HTML.escape(l.manualHint(for: app))]
            })
        return page(title: l.t("report.manual.title"), subtitle: subtitle(manifest), body: body)
    }

    private func downloadLink(_ app: AppRecord) -> String {
        if case .officialDownload(let url) = app.restoreMethod { return HTML.link(url, label: l.t("report.openDownloadPage")) }
        return "—"
    }

    public func dryRunReport(_ entries: [DryRunEntry], manualApps: [AppRecord], manifest: Manifest) -> String {
        let install = entries.filter { $0.prediction == .willInstall || $0.prediction == .willCopy }.count
        let present = entries.filter {
            if case .alreadyPresent = $0.prediction { return true }
            return $0.prediction == .identicalFileExists
        }.count
        let conflicts = entries.filter { if case .conflict = $0.prediction { return true }; return false }.count
        var body = "<p>\(HTML.escape(l.t("report.dryRun.intro")))</p><div class=\"cards\">"
        body += card(entries.count, l.t("report.dryRun.steps"))
        body += card(install, l.t("report.dryRun.willChange"))
        body += card(present, l.t("report.dryRun.alreadyPresent"))
        body += card(conflicts, l.t("report.dryRun.conflicts"))
        body += card(manualApps.count, l.t("category.manual"))
        body += "</div><h2>\(HTML.escape(l.t("report.dryRun.planned")))</h2>"
        body += table([l.t("report.column.name"), l.t("report.column.method"), l.t("report.column.plannedAction")],
                      entries.map { entry in
                          var action = HTML.escape(l.predictionText(entry.prediction, kind: entry.item.kind))
                          if entry.requiresAdmin { action += "<br><span class=\"warn\">\(HTML.escape(l.t("report.dryRun.needsAdmin")))</span>" }
                          for note in entry.notes { action += "<br><span class=\"muted\">\(HTML.escape(l.noteText(note)))</span>" }
                          return [text(entry.item.title), HTML.escape(l.itemMethodText(entry.item.kind)), action]
                      })
        if !manualApps.isEmpty {
            body += "<h2>\(HTML.escape(l.t("report.manual.title")))</h2>"
            body += table([l.t("report.column.name"), l.t("report.column.recommended"), l.t("report.column.notes")],
                          manualApps.map { [text($0.name), HTML.escape(l.methodText($0.restoreMethod)), HTML.escape(l.manualHint(for: $0))] })
        }
        return page(title: l.t("report.dryRun.title"), subtitle: subtitle(manifest), body: body)
    }

    public func restoreSummaryReport(plan: RestorePlan, session: RestoreSession, manifest: Manifest) -> String {
        let summary = RestoreSummary(results: Array(session.results.values), total: plan.items.count)
        var body = "<div class=\"cards\">"
        body += card(summary.succeeded, l.t("summary.succeeded"))
        body += card(summary.failed, l.t("summary.failed"))
        body += card(summary.skipped, l.t("summary.skipped"))
        body += "</div><h2>\(HTML.escape(l.t("report.restore.steps")))</h2>"
        body += table([l.t("report.column.name"), l.t("report.column.method"), l.t("report.column.result"), l.t("report.column.notes")],
                      plan.items.map { item in
                          guard let result = session.results[item.id] else {
                              return [text(item.title), HTML.escape(l.itemMethodText(item.kind)),
                                      "<span class=\"muted\">\(HTML.escape(l.t("report.restore.notRun")))</span>", "—"]
                          }
                          let css = result.outcome.isFailure ? "bad" : (result.outcome.isSkip ? "warn" : "ok")
                          var notes = result.notes.map { HTML.escape(l.noteText($0)) }
                          if case .failed(let failure) = result.outcome {
                              notes.insert(HTML.escape(l.failureExplanation(failure.category)), at: 0)
                          }
                          return [text(item.title), HTML.escape(l.itemMethodText(item.kind)),
                                  "<span class=\"\(css)\">\(HTML.escape(l.outcomeText(result.outcome)))</span>",
                                  notes.isEmpty ? "—" : notes.joined(separator: "<br>")]
                      })
        if !plan.manualApps.isEmpty {
            body += "<h2>\(HTML.escape(l.t("report.manual.title")))</h2>"
            body += table([l.t("report.column.name"), l.t("report.column.vendorPage"), l.t("report.column.notes")],
                          plan.manualApps.map { [text($0.name), HTML.link($0.homepage), HTML.escape(l.manualHint(for: $0))] })
        }
        return page(title: l.t("report.restore.title"), subtitle: subtitle(manifest), body: body)
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
