import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A temporary folder owned by the test that is always removed afterwards
/// through MacReplica's own `SafeCleaner`.
final class Sandbox {
    let url: URL

    init(_ name: String = "test") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MacReplicaTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try OwnershipMarker(kind: .temporary).write(into: url)
    }

    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func write(_ text: String, to path: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    deinit {
        try? SafeCleaner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser).removeOwnedFolder(url, kind: .temporary)
    }
}

enum TestEnvironment {
    static let english = Localizer(language: .english)

    static func sourceMac(_ sandbox: Sandbox) throws -> (SimulationRoot, SimulationEnvironment) {
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .sourceMac)
        return (root, try root.environment)
    }

    static func freshMac(_ sandbox: Sandbox, name: String = "fresh") throws -> (SimulationRoot, SimulationEnvironment) {
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent(name), scenario: .freshMac)
        return (root, try root.environment)
    }

    static func inventory(_ simulation: SimulationEnvironment) -> InventoryService {
        InventoryService(layout: simulation.layout, runner: simulation.makeRunner(), catalogProvider: simulation.makeCatalogProvider(),
                         macOSVersion: simulation.config.macosVersion, architecture: simulation.config.architecture)
    }

    static func restoreEnvironment(_ simulation: SimulationEnvironment, runner: CommandRunning? = nil,
                                   privileged: PrivilegedExecuting? = nil, architecture: CPUArchitecture = .arm64,
                                   askpass: String? = nil) -> RestoreEnvironment {
        RestoreEnvironment(layout: simulation.layout, runner: runner ?? simulation.makeRunner(),
                           privileged: privileged ?? simulation.makePrivilegedExecutor(),
                           homebrewSource: simulation.makeHomebrewSource(), localizer: english,
                           log: LogStore(fileURL: nil, homeDirectory: simulation.layout.homeDirectory),
                           targetArchitecture: architecture, rosettaInstalled: true, askpassPath: askpass,
                           commandLineToolsPollInterval: 0.2, commandLineToolsTimeout: 20)
    }

    /// Inventory of the synthetic source Mac, written as a backup.
    static func makeBackup(_ sandbox: Sandbox) async throws -> (URL, Manifest) {
        let (_, source) = try sourceMac(sandbox)
        let result = try await inventory(source).run()
        let parent = try sandbox.folder("backups")
        let outcome = try BackupWriter(layout: source.layout, localizer: english)
            .write(result, into: parent, log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        return (outcome.url, outcome.manifest)
    }
}

/// Collects restore events from the executor's callback.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RestoreEvent] = []

    func record(_ event: RestoreEvent) { lock.withLock { _events.append(event) } }

    var events: [RestoreEvent] { lock.withLock { _events } }

    var startedIDs: [String] {
        events.compactMap { if case .started(let item, _, _) = $0 { return item.id }; return nil }
    }

    var activities: [(String, RestoreActivity)] {
        events.compactMap { if case .activity(let id, let activity) = $0 { return (id, activity) }; return nil }
    }

    var summary: RestoreSummary? {
        events.compactMap { if case .completed(let summary) = $0 { return summary }; return nil }.last
    }
}

/// A command runner that records every command and answers from a script,
/// for unit tests that must not start any process.
final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (Command) -> CommandResult
    private let lock = NSLock()
    private var _commands: [Command] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var commands: [Command] { lock.withLock { _commands } }

    func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        lock.withLock { _commands.append(command) }
        return handler(command)
    }
}

extension ItemOutcome {
    var label: String {
        switch self {
        case .succeeded: return "succeeded"
        case .alreadyPresent: return "alreadyPresent"
        case .skipped(let reason): return "skipped(\(reason))"
        case .failed(let failure): return "failed(\(failure.category.rawValue))"
        }
    }
}
