import Foundation
import os

/// A plain-text log file. Every line is redacted so that the home folder (and
/// with it the account name) never appears; secrets are never passed in.
public final class LogStore: @unchecked Sendable {
    public enum Level: String, Sendable { case info = "INFO", warning = "WARN", error = "ERROR" }

    /// The part of MacReplica a line belongs to, so problems can be found quickly.
    public enum Component: String, Sendable {
        case general, startup, inventory, homebrew, appStore, python, applicationData, backup, restore, verification, cleanup, permissions
    }

    public let fileURL: URL?
    private let homePath: String
    private let lock = NSLock()
    private var lines: [String] = []
    private let osLog = Logger(subsystem: "io.github.itsab1989.MacReplica", category: "general")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// - Parameter fileURL: Where to append lines; nil keeps the log in memory only.
    public init(fileURL: URL?, homeDirectory: URL) {
        self.fileURL = fileURL
        self.homePath = homeDirectory.standardizedFileURL.path
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    public func info(_ message: String, component: Component = .general) { write(.info, message, component: component) }
    public func warning(_ message: String, component: Component = .general) { write(.warning, message, component: component) }
    public func error(_ message: String, component: Component = .general) { write(.error, message, component: component) }

    public func write(_ level: Level, _ message: String, component: Component = .general) {
        let redacted = SystemLayout.redactHome(message, home: homePath).replacingOccurrences(of: homePath, with: "~")
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] [\(component.rawValue)] \(redacted)"
        lock.withLock {
            lines.append(line)
            if let fileURL {
                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
        switch level {
        case .info: osLog.info("\(redacted, privacy: .public)")
        case .warning: osLog.warning("\(redacted, privacy: .public)")
        case .error: osLog.error("\(redacted, privacy: .public)")
        }
    }

    public var allLines: [String] { lock.withLock { lines } }

    /// Creates a log file named after the current time in `folder` and keeps only the newest `keep` logs.
    public static func session(in folder: URL, name: String, homeDirectory: URL, keep: Int = 20) -> LogStore {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter.fileStamp.string(from: Date())
        let store = LogStore(fileURL: folder.appendingPathComponent("\(name)-\(stamp).log"), homeDirectory: homeDirectory)
        store.info("MacReplica \(SystemInfo.appVersion) (\(SystemInfo.buildNumber)) · macOS \(SystemInfo.macOSVersion) · \(SystemInfo.currentArchitecture.rawValue) · \(name)")
        pruneLogs(in: folder, keep: keep)
        return store
    }

    /// Removes old `.log` files in MacReplica's own log folder. Only files that
    /// match MacReplica's naming scheme are considered.
    static func pruneLogs(in folder: URL, keep: Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        let logs = items.filter {
            $0.pathExtension == "log"
                && $0.lastPathComponent.range(of: #"^(inventory|restore|verify|dryrun|app)-\d{8}-\d{6}\.log$"#, options: .regularExpression) != nil
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in logs.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
