import Foundation

/// Developer configuration that is safe to keep: settings, not secrets.
public struct DeveloperSettings: Codable, Equatable, Sendable {
    /// `~/.gitconfig` with everything that could hold secrets removed.
    public var gitConfig: String?
    /// True if the saved Git configuration contains `user.email` (only when the user chose so).
    public var gitConfigIncludesEmail: Bool
    /// Sections that were left out, e.g. `url`, `http` — listed so the user knows what to set up again.
    public var removedGitSections: [String]

    public init(gitConfig: String? = nil, gitConfigIncludesEmail: Bool = false, removedGitSections: [String] = []) {
        self.gitConfig = gitConfig
        self.gitConfigIncludesEmail = gitConfigIncludesEmail
        self.removedGitSections = removedGitSections
    }

    public var isEmpty: Bool { gitConfig == nil }
}

public struct DeveloperSettingsScanner: Sendable {
    public var layout: SystemLayout

    public init(layout: SystemLayout) { self.layout = layout }

    /// Sections that only hold preferences. Everything else (url, http, include, sendemail …)
    /// is dropped because it can contain tokens, private hosts or machine-specific paths.
    static let allowedSections: Set<String> = ["user", "core", "init", "pull", "push", "fetch", "merge", "diff", "color", "alias", "rebase",
                                               "status", "log", "branch", "commit", "tag", "help", "advice", "column", "format", "grep",
                                               "rerere", "credential", "difftool", "mergetool", "filter"]
    static let refusedKeyFragments = ["token", "password", "secret", "signingkey", "oauth", "apikey"]

    public func scan(includeEmail: Bool = true) -> DeveloperSettings {
        guard let text = try? String(contentsOf: layout.homeDirectory.appendingPathComponent(".gitconfig"), encoding: .utf8) else {
            return DeveloperSettings()
        }
        let result = Self.sanitize(text, includeEmail: includeEmail, layout: layout)
        return DeveloperSettings(gitConfig: result.text.isEmpty ? nil : result.text, gitConfigIncludesEmail: result.hasEmail,
                                 removedGitSections: result.removed)
    }

    /// Keeps allowed sections and harmless values; the email only when `includeEmail` is true.
    public static func sanitize(_ text: String, includeEmail: Bool, layout: SystemLayout) -> (text: String, hasEmail: Bool, removed: [String]) {
        var output: [String] = []
        var removed = Set<String>()
        var currentAllowed = false
        var currentSection = ""
        var hasEmail = false
        let header = try! NSRegularExpression(pattern: #"^\s*\[\s*([A-Za-z0-9.-]+)(\s+"[^"]*")?\s*\]\s*$"#)
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                currentSection = line[range].lowercased()
                let hasSubsection = match.range(at: 2).location != NSNotFound
                // Subsections like [credential "https://host"] or [remote "x"] name hosts; keep only plain ones.
                currentAllowed = allowedSections.contains(currentSection) && !(hasSubsection && ["credential", "url"].contains(currentSection))
                if currentAllowed { output.append(line) } else { removed.insert(currentSection) }
                continue
            }
            guard currentAllowed else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let key = parts[0].lowercased()
            let value = parts.count > 1 ? parts[1] : ""
            if refusedKeyFragments.contains(where: { key.contains($0) }) { continue }
            if value.contains("://"), value.contains("@") { continue }
            if currentSection == "credential", key != "helper" { continue }
            if currentSection == "user", key == "email" {
                guard includeEmail else { continue }
                hasEmail = true
            }
            output.append("\t" + (parts.count > 1 ? "\(parts[0]) = \(layout.redact(value))" : parts[0]))
        }
        // Drop headers of sections that ended up empty.
        var compact: [String] = []
        for (index, line) in output.enumerated() {
            if line.hasPrefix("["), index + 1 >= output.count || output[index + 1].hasPrefix("[") { continue }
            compact.append(line)
        }
        return (compact.isEmpty ? "" : compact.joined(separator: "\n") + "\n", hasEmail, removed.sorted())
    }
}
