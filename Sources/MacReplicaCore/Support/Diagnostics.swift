import Foundation

/// The stages of an app launch, in order.
public enum StartupStage: String, Codable, Sendable, CaseIterable {
    case launch, configuration, localization, storage, environment, userInterface
}

/// One app launch, as recorded in `startup.json`.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var version: String
    public var startedAt: Date
    public var stages: [StartupStage]
    public var completed: Bool
    public var failure: String?
    public var safeMode: Bool

    public var lastStage: StartupStage? { stages.last }
}

/// A tiny, crash-safe record of how far each launch got.
///
/// Every stage is written to disk immediately, so if MacReplica crashes during
/// startup the next launch knows which stage was reached. It complements, and
/// does not replace, macOS's own crash reports.
public final class StartupRecorder: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var records: [LaunchRecord]
    public let previousLaunch: LaunchRecord?

    public init(fileURL: URL, version: String = SystemInfo.appVersion, safeMode: Bool = false) {
        self.fileURL = fileURL
        let existing = (try? Data(contentsOf: fileURL)).map(Self.decode) ?? []
        previousLaunch = existing.last
        records = Array(existing.suffix(9))
        records.append(LaunchRecord(version: version, startedAt: Date(), stages: [.launch], completed: false, failure: nil, safeMode: safeMode))
        save()
    }

    /// True when the previous launch never reached the user interface.
    public var previousLaunchFailed: Bool {
        guard let previousLaunch else { return false }
        return !previousLaunch.completed
    }

    public var current: LaunchRecord { lock.withLock { records[records.count - 1] } }
    public var history: [LaunchRecord] { lock.withLock { records } }

    public func reached(_ stage: StartupStage) {
        lock.withLock {
            if !records[records.count - 1].stages.contains(stage) { records[records.count - 1].stages.append(stage) }
        }
        save()
    }

    public func failed(_ stage: StartupStage, error: String) {
        lock.withLock { records[records.count - 1].failure = "\(stage.rawValue): \(error)" }
        save()
    }

    public func completed() {
        lock.withLock {
            if !records[records.count - 1].stages.contains(.userInterface) { records[records.count - 1].stages.append(.userInterface) }
            records[records.count - 1].completed = true
        }
        save()
    }

    private func save() {
        let data = lock.withLock { () -> Data? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(records)
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension StartupRecorder {
    /// Records are written with ISO 8601 dates.
    static func decode(_ data: Data) -> [LaunchRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LaunchRecord].self, from: data)) ?? []
    }
}

/// Builds a plain-text diagnostic report a user can attach to a bug report.
/// Everything in it is already redacted; it contains no backup contents.
public enum DiagnosticReport {
    public static func make(layout: SystemLayout, startupFile: URL, maxLinesPerLog: Int = 300, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("MacReplica diagnostic report")
        lines.append("Created: \(ISO8601DateFormatter().string(from: now))")
        lines.append("MacReplica: \(SystemInfo.appVersion) (build \(SystemInfo.buildNumber))")
        lines.append("macOS: \(SystemInfo.macOSVersion)")
        lines.append("Architecture: \(SystemInfo.currentArchitecture.rawValue)")
        lines.append("Simulation: \(layout.isSimulation ? "yes" : "no")")
        lines.append("")
        lines.append("== Recent launches")
        if let data = try? Data(contentsOf: startupFile) {
            for record in StartupRecorder.decode(data) {
                let stages = record.stages.map(\.rawValue).joined(separator: " → ")
                lines.append("\(ISO8601DateFormatter().string(from: record.startedAt)) v\(record.version) completed=\(record.completed) "
                             + "safeMode=\(record.safeMode) stages: \(stages)" + (record.failure.map { " failure: \($0)" } ?? ""))
            }
        } else {
            lines.append("(no startup record)")
        }

        let logs = ((try? FileManager.default.contentsOfDirectory(at: layout.logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
            .prefix(5)
        for log in logs {
            lines.append("")
            lines.append("== \(log.lastPathComponent)")
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            lines += text.split(whereSeparator: \.isNewline).suffix(maxLinesPerLog).map { layout.redact(String($0)) }
        }

        // macOS writes crash reports itself; only their names are listed here.
        let reports = layout.homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports")
        let crashes = ((try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []).filter { $0.hasPrefix("MacReplica") }.sorted()
        lines.append("")
        lines.append("== macOS crash reports for MacReplica")
        lines += crashes.isEmpty ? ["(none)"] : crashes.suffix(10).map { "~/Library/Logs/DiagnosticReports/\($0)" }
        return layout.redact(lines.joined(separator: "\n")) + "\n"
    }
}

extension URL {
    var modificationDate: Date? { try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}
