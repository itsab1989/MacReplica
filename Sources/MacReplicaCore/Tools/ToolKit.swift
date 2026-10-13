import Foundation

/// The shared building blocks of the Tools section: what this Mac is, what a tool can do on it, what the user
/// asked for, what changed and how sure MacReplica is about it.
///
/// The tools never run as part of an inventory, backup or restore. Each change starts from a button the user
/// pressed, is described before it happens, is checked afterwards by reading the real state again and ends up
/// in the tool history.

/// The Mac a tool runs on.
public struct ToolEnvironment: Sendable, Equatable, Codable {
    /// e.g. `26.1` or `27.0.1`.
    public var macOSVersion: String
    public var architecture: CPUArchitecture

    public init(macOSVersion: String, architecture: CPUArchitecture) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    public static var current: ToolEnvironment {
        ToolEnvironment(macOSVersion: SystemInfo.macOSVersion, architecture: SystemInfo.currentArchitecture)
    }

    /// The major version (`26` for `26.1`); 0 if the text is not a version.
    public var majorVersion: Int { Int(macOSVersion.split(separator: ".").first ?? "") ?? 0 }

    /// At least this macOS version (`isAtLeast("15")`, `isAtLeast("26.1")`).
    public func isAtLeast(_ version: String) -> Bool {
        VersionComparison.compare(macOSVersion, version) != .orderedAscending
    }
}

/// What a tool or one of its options can do on this Mac. Shown as a badge and decides which buttons appear.
public enum ToolCapability: String, Sendable, Codable, CaseIterable {
    case supported
    case supportedWithRestrictions
    /// Works, but relies on something Apple does not document; a macOS update may stop it.
    case experimental
    /// Only the user can do it (for example in System Settings); MacReplica opens the right place.
    case requiresUserAction
    case requiresAdministrator
    /// An organisation manages this Mac's setting (device management); MacReplica does not touch it.
    case managedExternally
    case unsupportedOnThisVersion
    case unableToDetermine

    /// Whether MacReplica offers a button that changes something itself.
    public var allowsChange: Bool {
        switch self {
        case .supported, .supportedWithRestrictions, .experimental, .requiresAdministrator: return true
        case .requiresUserAction, .managedExternally, .unsupportedOnThisVersion, .unableToDetermine: return false
        }
    }
}

/// How sure MacReplica is that a change really took effect.
public enum ToolVerification: String, Sendable, Codable {
    /// The state read back afterwards is the one that was asked for.
    case verified
    /// The setting reads back as asked, but its effect could not be checked (e.g. it shows only after a relaunch).
    case partiallyVerified
    /// Nothing could be read back.
    case notVerified
    /// The state read back is not the one that was asked for.
    case failed
}

/// What the user has to do before a change shows.
public enum ToolRestart: String, Sendable, Codable {
    case none
    case relaunchApps
    case logOut
    case restart
}

/// The outcome of one change or revert.
public struct ToolOutcome: Sendable, Equatable {
    public var verification: ToolVerification
    /// Short, already localized explanation of what was found afterwards.
    public var stateAfter: String
    public var restart: ToolRestart
    /// For a change that failed half-way: what did happen and whether the user has to do something.
    public var partialNote: String?

    public init(verification: ToolVerification, stateAfter: String, restart: ToolRestart = .none, partialNote: String? = nil) {
        self.verification = verification
        self.stateAfter = stateAfter
        self.restart = restart
        self.partialNote = partialNote
    }
}

/// One entry of the tool history: no passwords, no file contents, no personal paths.
public struct ToolHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Result: String, Codable, Sendable { case succeeded, failed, cancelled, partial }

    public var id: UUID
    public var date: Date
    /// `gatekeeper`, `updates` or `windowCorners`.
    public var tool: String
    /// A stable identifier of the change, e.g. `windowCorners.apply.reduced` or `updates.revert`.
    public var change: String
    /// Machine-readable previous state (what a revert goes back to); nil if it could not be read.
    public var previousState: String?
    public var resultingState: String?
    public var macOSVersion: String
    public var result: Result
    public var verification: ToolVerification
    public var revertAvailable: Bool

    public init(id: UUID = UUID(), date: Date = Date(), tool: String, change: String, previousState: String?, resultingState: String?,
                macOSVersion: String, result: Result, verification: ToolVerification, revertAvailable: Bool) {
        self.id = id
        self.date = date
        self.tool = tool
        self.change = change
        self.previousState = previousState
        self.resultingState = resultingState
        self.macOSVersion = macOSVersion
        self.result = result
        self.verification = verification
        self.revertAvailable = revertAvailable
    }
}

/// The tool history as one JSON file in MacReplica's Application Support folder (newest last, at most 200 entries).
public struct ToolHistoryStore: Sendable {
    public var file: URL
    public var limit: Int

    public init(file: URL, limit: Int = 200) {
        self.file = file
        self.limit = limit
    }

    public init(layout: SystemLayout) {
        self.init(file: layout.applicationSupport.appendingPathComponent("tools-history.json"))
    }

    public func entries() -> [ToolHistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ToolHistoryEntry].self, from: data)) ?? []
    }

    public func append(_ entry: ToolHistoryEntry) throws {
        var all = entries()
        all.append(entry)
        if all.count > limit { all.removeFirst(all.count - limit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: file, options: .atomic)
    }

    /// The most recent successful change of a tool that has not been reverted since (what “Restore previous state” undoes).
    public func lastRevertibleChange(tool: String) -> ToolHistoryEntry? {
        for entry in entries().reversed() where entry.tool == tool {
            if entry.change.hasSuffix(".revert"), entry.result == .succeeded { return nil }
            if entry.revertAvailable, entry.result == .succeeded || entry.result == .partial { return entry }
        }
        return nil
    }
}
