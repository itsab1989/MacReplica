import Foundation

/// Maps tool output to a failure category so that the user gets a helpful explanation
/// instead of raw command output.
public enum ErrorClassifier {
    private static let rules: [(FailureCategory, [String])] = [
        (.diskFull, ["no space left on device", "not enough disk space", "disk is full"]),
        (.appStoreNotSignedIn, ["not signed in", "sign in to the app store", "notsignedin", "no apple account", "not logged in", "unauthenticated"]),
        (.adminRightsDenied, ["a password is required", "no askpass program", "incorrect password", "sorry, try again",
                              "user canceled", "user cancelled", "(-128)", "sudo: a terminal is required", "authorization failed"]),
        (.appAlreadyExists, ["it seems there is already an app at", "already an app at", "there is already a binary at"]),
        (.incompatible, ["depends on hardware architecture", "requires macos", "this software does not run on macos",
                         "is not supported on", "unsupported architecture", "requires rosetta", "bad cpu type"]),
        (.network, ["could not resolve host", "failed to connect", "connection timed out", "network is unreachable",
                    "curl: (6)", "curl: (7)", "curl: (28)", "curl: (35)", "curl: (56)", "ssl_error", "timed out while",
                    "the internet connection appears to be offline", "download failed", "operation timed out",
                    "failed to establish a new connection", "connection error", "temporary failure in name resolution"]),
        (.packageNotFound, ["no available formula", "no available cask", "no cask with this name", "cask '", "is unavailable",
                            "no formulae or casks found", "no app with", "no results found", "app not found", "has been disabled",
                            "invalid app identifier", "unknown app", "no matching distribution found"]),
    ]

    public static func classify(_ output: String, exitCode: Int32, timedOut: Bool = false) -> FailureCategory {
        if timedOut { return .timeout }
        let lower = output.lowercased()
        for (category, needles) in rules where needles.contains(where: { lower.contains($0) }) {
            // "cask '…' is unavailable" must contain both parts to count as not found.
            if category == .packageNotFound, lower.contains("cask '"), !lower.contains("unavailable"),
               !needles.filter({ $0 != "cask '" }).contains(where: { lower.contains($0) }) {
                continue
            }
            return category
        }
        return .unknown
    }

    /// The last meaningful lines of tool output, redacted, for the details view and log.
    public static func technicalDetail(_ output: String, layout: SystemLayout, maxLines: Int = 12) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return layout.redact(lines.suffix(maxLines).joined(separator: "\n"))
    }
}
