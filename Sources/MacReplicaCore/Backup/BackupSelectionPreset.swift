import Foundation

/// The choices made on the backup selection screen, saved so the next backup does not need them again.
///
/// Written as `MacReplica Selection.json` next to the backups (and wherever the user saves it). Only choices
/// are stored, never data: which items are on or off, the backup location, the user's own folders and
/// installers by path. Items that did not exist when the selection was saved keep their default, so new apps
/// and new data are included as usual. Passphrases are never stored.
public struct BackupSelectionPreset: Codable, Equatable, Sendable {
    public static let fileName = "MacReplica Selection.json"
    public static let currentFormat = 1

    public struct OwnInstaller: Codable, Equatable, Sendable {
        public var path: String
        public var include: Bool
        public init(path: String, include: Bool) {
            self.path = path
            self.include = include
        }
    }

    public var format: Int
    public var savedAt: Date
    public var macreplicaVersion: String
    /// Item ID → included. Missing IDs keep their default.
    public var applications: [String: Bool]
    public var files: [String: Bool]
    public var applicationData: [String: Bool]
    public var toolchains: [String: Bool]
    public var pythonEnvironments: [String: Bool]
    public var preservedPythonEnvironments: [String]
    public var includePythonSettings: Bool
    public var includeGitSettings: Bool
    public var includeGitEmail: Bool
    public var includeDisplayAssignments: Bool
    /// Credential providers the user switched on (the passphrase is asked again).
    public var credentialProviders: [String]
    /// App ID → chosen Homebrew package token, or "" for "None of these".
    public var matchChoices: [String: String]
    /// The user's own folders, home folder written as `~`.
    public var personalFolders: [String]
    /// App ID → the user's installers, home folder written as `~`.
    public var ownInstallers: [String: [OwnInstaller]]
    /// Where the backup is saved (home folder written as `~`).
    public var destination: String?

    public init(savedAt: Date = Date(), macreplicaVersion: String = SystemInfo.appVersion, applications: [String: Bool] = [:],
                files: [String: Bool] = [:], applicationData: [String: Bool] = [:], toolchains: [String: Bool] = [:],
                pythonEnvironments: [String: Bool] = [:], preservedPythonEnvironments: [String] = [], includePythonSettings: Bool = true,
                includeGitSettings: Bool = true, includeGitEmail: Bool = false, includeDisplayAssignments: Bool = true,
                credentialProviders: [String] = [], matchChoices: [String: String] = [:], personalFolders: [String] = [],
                ownInstallers: [String: [OwnInstaller]] = [:], destination: String? = nil) {
        self.format = Self.currentFormat
        self.savedAt = savedAt
        self.macreplicaVersion = macreplicaVersion
        self.applications = applications
        self.files = files
        self.applicationData = applicationData
        self.toolchains = toolchains
        self.pythonEnvironments = pythonEnvironments
        self.preservedPythonEnvironments = preservedPythonEnvironments
        self.includePythonSettings = includePythonSettings
        self.includeGitSettings = includeGitSettings
        self.includeGitEmail = includeGitEmail
        self.includeDisplayAssignments = includeDisplayAssignments
        self.credentialProviders = credentialProviders
        self.matchChoices = matchChoices
        self.personalFolders = personalFolders
        self.ownInstallers = ownInstallers
        self.destination = destination
    }

    /// Turns a choice map into the set of excluded IDs for the items that exist now: a saved choice wins,
    /// otherwise the item keeps whether it is excluded by default.
    public static func excluded(ids: [String], saved: [String: Bool], excludedByDefault: Set<String>) -> Set<String> {
        Set(ids.filter { id in saved[id].map { !$0 } ?? excludedByDefault.contains(id) })
    }

    /// The choice map of the items that exist now.
    public static func choices(ids: [String], excluded: Set<String>) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, !excluded.contains($0)) })
    }

    // MARK: Files

    public enum PresetError: Error, Equatable, Sendable {
        case unreadable
        /// Written by a newer MacReplica that stores choices this version does not know.
        case newerFormat(Int)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> BackupSelectionPreset {
        guard let data = try? Data(contentsOf: url) else { throw PresetError.unreadable }
        struct Header: Decodable { var format: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw PresetError.unreadable }
        guard header.format <= currentFormat else { throw PresetError.newerFormat(header.format) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let preset = try? decoder.decode(BackupSelectionPreset.self, from: data) else { throw PresetError.unreadable }
        return preset
    }

    /// The selection saved in a folder (next to the backups), if any.
    public static func saved(in folder: URL) -> BackupSelectionPreset? {
        try? read(from: folder.appendingPathComponent(fileName))
    }
}
