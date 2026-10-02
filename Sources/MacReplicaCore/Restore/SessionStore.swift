import Foundation

/// The persisted state of a restore, saved after every step so that an
/// interrupted restore (crash, quit, restart) can continue where it stopped.
public struct RestoreSession: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case inProgress, completed }

    public var id: String
    /// Backup location with the home folder written as `~`.
    public var backupPath: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selection: RestoreSelection
    public var itemIDs: [String]
    public var results: [String: ItemResult]
    /// The step that was running when the session was last saved.
    public var currentItemID: String?
    public var status: Status

    public init(id: String = UUID().uuidString, backupPath: String, selection: RestoreSelection, itemIDs: [String],
                createdAt: Date = Date()) {
        self.id = id
        self.backupPath = backupPath
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.selection = selection
        self.itemIDs = itemIDs
        self.results = [:]
        self.currentItemID = nil
        self.status = .inProgress
    }

    /// Steps that finished, either way, and do not need to run again on resume.
    public var finishedItemIDs: Set<String> { Set(results.keys) }

    public var remainingItemIDs: [String] { itemIDs.filter { results[$0] == nil } }
}

public struct SessionStore: Sendable {
    public var folder: URL
    private let cleaner: SafeCleaner

    public init(folder: URL, homeDirectory: URL) {
        self.folder = folder
        self.cleaner = SafeCleaner(homeDirectory: homeDirectory)
    }

    private func sessionFolder(_ id: String) -> URL { folder.appendingPathComponent(id) }

    // Session files are internal; dates use Foundation's lossless default encoding.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    public func save(_ session: RestoreSession) throws {
        guard session.id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
            throw CleanupError.protectedLocation(session.id)
        }
        let target = sessionFolder(session.id)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try OwnershipMarker(kind: .session, id: session.id, createdAt: session.createdAt).write(into: target)
        }
        try Self.encoder().encode(session).write(to: target.appendingPathComponent("session.json"), options: .atomic)
    }

    public func load(id: String) -> RestoreSession? {
        guard let data = try? Data(contentsOf: sessionFolder(id).appendingPathComponent("session.json")) else { return nil }
        return try? Self.decoder().decode(RestoreSession.self, from: data)
    }

    public func allSessions() -> [RestoreSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            guard OwnershipMarker.read(from: url)?.kind == .session else { return nil }
            return load(id: url.lastPathComponent)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The most recent restore that did not finish, if any.
    public func unfinishedSession() -> RestoreSession? {
        allSessions().first { $0.status == .inProgress }
    }

    public func remove(id: String) throws {
        try cleaner.removeOwnedFolder(sessionFolder(id), kind: .session)
    }

    /// Keeps the newest completed sessions for reference and removes older ones.
    public func pruneCompleted(keep: Int = 5) {
        let completed = allSessions().filter { $0.status == .completed }
        for session in completed.dropFirst(keep) { try? remove(id: session.id) }
    }
}
