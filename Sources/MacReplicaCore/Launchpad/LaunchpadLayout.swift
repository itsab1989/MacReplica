import Foundation
import SQLite3

/// The arrangement of Launchpad (macOS 13–15): pages with apps and folders, folders with their name and pages.
/// Apps are recorded by bundle identifier only. macOS 26 replaced Launchpad with the Apps view, which has no
/// user arrangement, so there the layout is only kept as a reference.
public struct LaunchpadLayout: Codable, Equatable, Hashable, Sendable {
    /// Written as `{"app": "com.apple.Safari"}` or `{"folder": {"name": "Work", "pages": [["com.apple.mail"]]}}`.
    public enum Entry: Codable, Equatable, Hashable, Sendable {
        case app(String)
        case folder(name: String, pages: [[String]])

        private enum CodingKeys: String, CodingKey { case app, folder }
        private struct Folder: Codable { var name: String, pages: [[String]] }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let app = try c.decodeIfPresent(String.self, forKey: .app) {
                self = .app(app)
            } else {
                let folder = try c.decode(Folder.self, forKey: .folder)
                self = .folder(name: folder.name, pages: folder.pages)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .app(let id): try c.encode(id, forKey: .app)
            case .folder(let name, let pages): try c.encode(Folder(name: name, pages: pages), forKey: .folder)
            }
        }
    }

    public var pages: [[Entry]]
    /// macOS version the layout was recorded on.
    public var macOSVersion: String
    /// The name Launchpad showed for each app (bundle identifier → title), recorded since 1.1.7. When an app's
    /// identifier differs on the new Mac (GIMP 2.10 `org.gimp.gimp-2.10` → GIMP 3 `org.gimp.gimp`, tester 2026-10-19),
    /// the app of the same name takes its place. Older backups get the names from their app list (`withNames`).
    public var names: [String: String]?

    // `macosVersion` survives the manifest's snake_case conversion (`macOSVersion` would come back as `macOsVersion`).
    private enum CodingKeys: String, CodingKey {
        case pages
        case macOSVersion = "macosVersion"
        case names
    }

    public init(pages: [[Entry]], macOSVersion: String, names: [String: String]? = nil) {
        self.pages = pages
        self.macOSVersion = macOSVersion
        self.names = names
    }

    /// Every bundle identifier in the layout.
    public var bundleIdentifiers: Set<String> {
        Set(pages.flatMap { $0 }.flatMap { entry -> [String] in
            switch entry {
            case .app(let bundle): return [bundle]
            case .folder(_, let pages): return pages.flatMap { $0 }
            }
        })
    }

    /// The layout as it applies to `actual`: each recorded identifier `actual` does not contain is replaced by the app of
    /// the same name in `actual` that the layout does not contain itself – the rule `apply` places apps by. Used to
    /// verify an arrangement in which an app with a changed identifier took its place.
    public func resolving(against actual: LaunchpadLayout) -> LaunchpadLayout {
        guard let names, !names.isEmpty else { return self }
        let present = actual.bundleIdentifiers, mine = bundleIdentifiers
        var byTitle: [String: [String]] = [:]
        for (bundle, title) in (actual.names ?? [:]).sorted(by: { $0.key < $1.key }) where !mine.contains(bundle) {
            byTitle[title.trimmingCharacters(in: .whitespaces).lowercased(), default: []].append(bundle)
        }
        var used = Set<String>(), map: [String: String] = [:]
        let ordered = pages.flatMap { $0 }.flatMap { entry -> [String] in
            if case .folder(_, let pages) = entry { return pages.flatMap { $0 } }
            if case .app(let bundle) = entry { return [bundle] }
            return []
        }
        for bundle in ordered where !present.contains(bundle) && map[bundle] == nil {
            guard let name = names[bundle]?.trimmingCharacters(in: .whitespaces).lowercased(),
                  let other = byTitle[name]?.first(where: { !used.contains($0) }) else { continue }
            map[bundle] = other
            used.insert(other)
        }
        guard !map.isEmpty else { return self }
        var copy = self
        copy.pages = pages.map { page in
            page.map { entry in
                switch entry {
                case .app(let bundle): return .app(map[bundle] ?? bundle)
                case .folder(let name, let pages): return .folder(name: name, pages: pages.map { $0.map { map[$0] ?? $0 } })
                }
            }
        }
        return copy
    }

    /// The layout with names added for apps it has none for (e.g. from the backup's app list).
    public func withNames(_ fallback: [String: String]) -> LaunchpadLayout {
        var copy = self
        var merged = names ?? [:]
        for bundle in bundleIdentifiers where merged[bundle] == nil {
            if let name = fallback[bundle], !name.isEmpty { merged[bundle] = name }
        }
        copy.names = merged.isEmpty ? nil : merged
        return copy
    }

    public var folderNames: [String] { pages.flatMap { $0 }.compactMap { if case .folder(let name, _) = $0 { return name }; return nil } }
    public var appCount: Int {
        pages.flatMap { $0 }.reduce(0) { count, entry in
            if case .folder(_, let pages) = entry { return count + pages.flatMap { $0 }.count }
            return count + 1
        }
    }

    /// The layout without these apps; folders and pages that become empty are left out.
    public func removing(_ bundleIDs: Set<String>) -> LaunchpadLayout {
        guard !bundleIDs.isEmpty else { return self }
        let kept = pages.map { page in
            page.compactMap { entry -> Entry? in
                switch entry {
                case .app(let id): return bundleIDs.contains(id) ? nil : entry
                case .folder(let name, let folderPages):
                    let remaining = folderPages.map { $0.filter { !bundleIDs.contains($0) } }.filter { !$0.isEmpty }
                    return remaining.isEmpty ? nil : .folder(name: name, pages: remaining)
                }
            }
        }.filter { !$0.isEmpty }
        return LaunchpadLayout(pages: kept, macOSVersion: macOSVersion)
    }

    /// Launchpad exists up to macOS 15.
    public static func isSupported(macOSVersion: String) -> Bool {
        (Int(macOSVersion.split(separator: ".").first ?? "") ?? 0) <= 15
    }

    /// How well `actual` (read back after restoring) matches this layout for the apps both contain: every folder
    /// with its apps, and the order of top-level entries.
    /// `installed` counts the entries per app on the restored Mac (an app can be there in several copies, or in
    /// fewer than recorded): the layout's entries beyond that count are left out of the comparison.
    public func matches(_ actual: LaunchpadLayout, installed: [String: Int]) -> Bool {
        func normalized(_ layout: LaunchpadLayout) -> [[Entry]] {
            var left = installed
            func keep(_ id: String) -> Bool {
                guard let count = left[id], count > 0 else { return false }
                left[id] = count - 1
                return true
            }
            return layout.pages.map { page in
                page.compactMap { entry -> Entry? in
                    switch entry {
                    case .app(let id): return keep(id) ? entry : nil
                    case .folder(let name, let pages):
                        let apps = pages.map { $0.filter(keep) }.filter { !$0.isEmpty }
                        return apps.isEmpty ? nil : .folder(name: name, pages: apps)
                    }
                }
            }.filter { !$0.isEmpty }
        }
        let expected = normalized(self)
        return expected == Array(normalized(actual).prefix(expected.count))
    }

    public func matches(_ actual: LaunchpadLayout, installed: Set<String>) -> Bool {
        matches(actual, installed: Dictionary(uniqueKeysWithValues: installed.map { ($0, 1) }))
    }

    /// Entries per app in this layout.
    public var appEntryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for page in pages {
            for entry in page {
                switch entry {
                case .app(let id): counts[id, default: 0] += 1
                case .folder(_, let folderPages): for id in folderPages.joined() { counts[id, default: 0] += 1 }
                }
            }
        }
        return counts
    }
}

public enum LaunchpadError: Error, Equatable, Sendable {
    case databaseMissing
    case unreadable(String)
    case notSupported
}

/// Reads and rebuilds the Launchpad arrangement in the Dock's database
/// (`$(getconf DARWIN_USER_DIR)/com.apple.dock.launchpad/db/db`, schema confirmed on macOS 14 and 15).
///
/// Item types: 1 root, 2 folder (its name in `groups`), 3 page, 4 app (bundle identifier in `apps`). Rebuilding
/// never deletes apps: the Dock's own app entries are moved into the recorded pages and folders; apps that are
/// not in the layout follow on the last pages. The Dock is restarted afterwards so it loads the arrangement.
public struct LaunchpadStore: Sendable {
    public var database: URL
    /// Where the user's folder says the database is (`DARWIN_USER_DIR`), when the database in use was found otherwise.
    public var computedDatabase: URL?

    public init(database: URL, computedDatabase: URL? = nil) {
        self.database = database
        self.computedDatabase = computedDatabase
    }

    /// The live database of the current user: in the user's folder (`DARWIN_USER_DIR`), or – when there is none –
    /// the database the user's running Dock has open. On a tester's macOS 14 Mac the computed folder had no
    /// `com.apple.dock.launchpad` at all while Launchpad worked (1.1.4 log, 2026-10-18); the Dock keeps its database
    /// open all the time (shown with `lsof` on macOS 14.8.9), so that is the file the Dock really uses.
    public static func live() -> LaunchpadStore? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let computed = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0
            ? URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.dock.launchpad/db/db") : nil
        if let computed, FileManager.default.fileExists(atPath: computed.path) { return LaunchpadStore(database: computed) }
        if let open = openDockDatabase(), FileManager.default.fileExists(atPath: open.path) {
            return LaunchpadStore(database: open, computedDatabase: computed)
        }
        return computed.map { LaunchpadStore(database: $0) }
    }

    /// The Launchpad database the current user's Dock has open (`lsof`, read-only, only this user's own Dock).
    public static func openDockDatabase() -> URL? {
        openDatabase(inLsofOutput: lsofDock().output)
    }

    /// `lsof -a -c Dock -u <this user> -Fn`: its output, exit status and first error line.
    static func lsofDock() -> (output: String, status: Int32, error: String) {
        run("/usr/sbin/lsof", ["-a", "-c", "Dock", "-u", String(getuid()), "-Fn"])
    }

    static func run(_ executable: String, _ arguments: [String]) -> (output: String, status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return ("", -1, "could not start \(executable)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let firstError = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return (String(decoding: data, as: UTF8.self), process.terminationStatus, firstError)
    }

    /// The user MacReplica runs as, compared with the user logged in at the screen (owner of /dev/console).
    public static var runsAsLoggedInUser: Bool {
        guard let console = consoleUserID else { return true }
        return geteuid() == console
    }

    static var consoleUserID: uid_t? {
        var info = stat()
        return stat("/dev/console", &info) == 0 ? info.st_uid : nil
    }

    /// The running Docks as “pid/uid” from `ps -A -o pid=,uid=,comm=`.
    static func dockProcesses(inPsOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[2].hasSuffix("/Dock") || parts[2] == "Dock" else { return nil }
            return "\(parts[0])/uid \(parts[1])"
        }
    }

    /// For the log when Launchpad's database cannot be used: who MacReplica runs as, who is logged in, which Docks run
    /// and what `lsof` returned. User IDs and counts only – no names, no home folder.
    public static func userReport() -> String {
        let console = consoleUserID.map(String.init) ?? "unknown"
        let docks = dockProcesses(inPsOutput: run("/bin/ps", ["-A", "-o", "pid=,uid=,comm="]).output)
        let lsof = lsofDock()
        let lines = lsof.output.split(whereSeparator: \.isNewline)
        let files = lines.filter { $0.hasPrefix("n") }.count
        let launchpadFiles = lines.filter { $0.hasPrefix("n") && $0.lowercased().contains("launchpad") }.count
        // Any process of this user with a Launchpad file open, by command name (the Dock is not the only candidate).
        let all = run("/usr/sbin/lsof", ["-u", String(getuid()), "-Fcn"]).output
        var command = "", holders = Set<String>()
        for line in all.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            if line.hasPrefix("n"), line.lowercased().contains("launchpad") { holders.insert(command) }
        }
        // The user folder as a separate process sees it, against MacReplica's own lookup.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let own = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) : "?"
        let child = run("/usr/bin/getconf", ["DARWIN_USER_DIR"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "MacReplica uid \(getuid()) euid \(geteuid()); logged-in user uid \(console); Docks: \(docks.isEmpty ? "none" : docks.joined(separator: ", ")); "
            + "lsof exit \(lsof.status), \(files) open files of this user's Dock, \(launchpadFiles) with launchpad"
            + (lsof.error.isEmpty ? "" : ", error: \(lsof.error.prefix(120))")
            + "; processes of this user with a Launchpad file open: \(holders.isEmpty ? "none" : holders.sorted().joined(separator: ", "))"
            + "; user folder from getconf \(child == own ? "is the same" : "differs: \(child)")"
    }

    /// From `lsof -Fn` output (one `n<path>` line per open file): the Launchpad database itself (`…/db/db` in a folder
    /// whose name contains “launchpad”, wherever it is), not its `-wal`/`-shm`. Whether it really is Launchpad's
    /// database is checked when it is read (its tables).
    static func openDatabase(inLsofOutput output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("n/") {
            let url = URL(fileURLWithPath: String(line.dropFirst()))
            let folder = url.deletingLastPathComponent(), owner = folder.deletingLastPathComponent()
            if url.lastPathComponent == "db", folder.lastPathComponent == "db",
               owner.lastPathComponent.lowercased().contains("launchpad") { return url }
        }
        return nil
    }

    static let pageCapacity = 35

    /// What `stat` says along the database path, for the log when the database cannot be used: each level from the user's
    /// temporary folder down ("ok" or the error, e.g. "Operation not permitted"), and the file names in the `db` folder.
    /// No absolute path is written.
    public func locationReport() -> String {
        let db = database.deletingLastPathComponent(), launchpad = db.deletingLastPathComponent(), user = launchpad.deletingLastPathComponent()
        func state(_ url: URL) -> String { Self.statError(url).map { String(cString: strerror($0)) } ?? "ok" }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: db.path))?.sorted().joined(separator: ", ") ?? "-"
        return "user folder: \(state(user)); \(launchpad.lastPathComponent): \(state(launchpad)); db folder: \(state(db)) [\(files)]; "
            + "database file: \(state(database))"
    }

    /// For the log: which database is used and why, with both locations when the Dock's differs from the computed one.
    /// Only system folders under /var/folders appear, never a home folder or user name.
    public var sourceReport: String {
        guard let computedDatabase else { return "database in the user's folder" }
        return "database the Dock has open: \(database.path); the user's folder points to \(computedDatabase.path), which has none"
    }

    /// The `errno` of `stat` for the path, or nil if it succeeds.
    static func statError(_ url: URL) -> Int32? {
        var info = stat()
        return stat(url.path, &info) == 0 ? nil : errno
    }

    /// True when the database exists but macOS refuses access to it or a folder above it (privacy protection).
    public var accessDenied: Bool {
        [database, database.deletingLastPathComponent(), database.deletingLastPathComponent().deletingLastPathComponent()]
            .contains { [EPERM, EACCES].contains(Self.statError($0) ?? 0) }
    }

    /// Makes the Dock load a rebuilt database (`applyAndReloadDock`); the simulation records the signals instead.
    public var signalDock: @Sendable (Int32) -> Void = LaunchpadStore.signalDock

    // MARK: Reading

    /// Reads a copy of the database (with its write-ahead log), so the Dock's file is never opened for writing.
    public func read(macOSVersion: String, work: URL) throws -> LaunchpadLayout {
        guard FileManager.default.fileExists(atPath: database.path) else { throw LaunchpadError.databaseMissing }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent("launchpad.db")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: database.path + suffix), target = URL(fileURLWithPath: copy.path + suffix)
            try? FileManager.default.removeItem(at: target)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: target) }
        }
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + suffix) } }
        let db = try open(copy, readOnly: false)
        defer { sqlite3_close(db) }
        return try Self.read(db, macOSVersion: macOSVersion)
    }

    static func read(_ db: OpaquePointer, macOSVersion: String) throws -> LaunchpadLayout {
        let root = try Int(scalar(db, "SELECT value FROM dbinfo WHERE key='launchpad_root'") ?? "1") ?? 1
        let items = try rows(db, "SELECT i.rowid, i.type, i.parent_id, i.ordering, IFNULL(i.uuid,''), IFNULL(a.bundleid,''), IFNULL(g.title,'') "
                             + "FROM items i LEFT JOIN apps a ON a.item_id=i.rowid LEFT JOIN groups g ON g.item_id=i.rowid ORDER BY i.parent_id, i.ordering")
        struct Item { var id: Int, type: Int, parent: Int, uuid: String, bundle: String, title: String }
        let all = items.map { Item(id: Int($0[0]) ?? 0, type: Int($0[1]) ?? 0, parent: Int($0[2]) ?? 0, uuid: $0[4], bundle: $0[5], title: $0[6]) }
        func children(_ id: Int) -> [Item] { all.filter { $0.parent == id } }
        var pages: [[LaunchpadLayout.Entry]] = []
        for page in children(root) where page.type == 3 && page.uuid != "HOLDINGPAGE" {
            var entries: [LaunchpadLayout.Entry] = []
            for child in children(page.id) {
                switch child.type {
                case 4 where !child.bundle.isEmpty:
                    entries.append(.app(child.bundle))
                case 2:
                    let folderPages = children(child.id).filter { $0.type == 3 }.map { children($0.id).filter { $0.type == 4 && !$0.bundle.isEmpty }.map(\.bundle) }
                    entries.append(.folder(name: child.title, pages: folderPages.filter { !$0.isEmpty }))
                default:
                    break
                }
            }
            if !entries.isEmpty { pages.append(entries) }
        }
        var layout = LaunchpadLayout(pages: pages, macOSVersion: macOSVersion)
        let wanted = layout.bundleIdentifiers
        var names: [String: String] = [:]
        for row in try rows(db, "SELECT IFNULL(bundleid,''), IFNULL(title,'') FROM apps") where wanted.contains(row[0]) && !row[1].isEmpty {
            names[row[0]] = row[1]
        }
        layout.names = names.isEmpty ? nil : names
        return layout
    }

    // MARK: Rebuilding

    /// Rebuilds the layout and makes the Dock load it. The Dock keeps the arrangement in memory and writes it
    /// back when it quits normally, which would undo the change: it is paused while the database is written
    /// and then ended without saving (launchd starts it again at once, and it reads the new arrangement).
    @discardableResult
    public func applyAndReloadDock(_ layout: LaunchpadLayout, signal: ((Int32) -> Void)? = nil) throws -> Int {
        let signal = signal ?? signalDock
        signal(SIGSTOP)
        let placed: Int
        do {
            placed = try apply(layout)
        } catch {
            signal(SIGCONT)
            throw error
        }
        signal(SIGKILL)
        return placed
    }

    /// Sends a signal to the current user's Dock process.
    public static func signalDock(_ signal: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-\(signal)", "-u", NSUserName(), "Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Arranges the Dock's apps as in `layout`. Returns how many recorded apps were placed (apps that are not
    /// installed here are left out; their folders keep the others).
    @discardableResult
    public func apply(_ layout: LaunchpadLayout) throws -> Int {
        guard FileManager.default.fileExists(atPath: database.path) else { throw LaunchpadError.databaseMissing }
        let db = try open(database, readOnly: false)
        defer { sqlite3_close(db) }
        return try Self.apply(layout, to: db)
    }

    static func apply(_ layout: LaunchpadLayout, to db: OpaquePointer) throws -> Int {
        let root = try Int(scalar(db, "SELECT value FROM dbinfo WHERE key='launchpad_root'") ?? "1") ?? 1
        // An app can have several entries: copies with the same bundle identifier (e.g. two Xcode versions) each
        // have their own. The visible entries are those on a page of the Launchpad root (not on the version page).
        var entries: [String: [Int]] = [:]
        for row in try rows(db, "SELECT i.rowid, a.bundleid FROM items i JOIN apps a ON a.item_id=i.rowid WHERE i.type=4 ORDER BY i.rowid") {
            entries[row[1], default: []].append(Int(row[0]) ?? 0)
        }
        for (bundle, ids) in entries {
            let visible = ids.filter { isVisible(db, item: $0, root: root) }
            entries[bundle] = visible.isEmpty ? Array(ids.prefix(1)) : visible
        }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
            let oldPages = try rows(db, "SELECT rowid FROM items WHERE type=3 AND parent_id=\(root) AND IFNULL(uuid,'')<>'HOLDINGPAGE'").compactMap { Int($0[0]) }
            let oldFolders = try rows(db, "SELECT rowid FROM items WHERE type=2").compactMap { Int($0[0]) }
            var placed = Set<Int>()
            // New pages start after every existing one: deleting the old pages afterwards (the database's trigger
            // closes the gaps) leaves them in order right after the holding page.
            var pageIndex = (try Int(scalar(db, "SELECT IFNULL(MAX(ordering),0) FROM items WHERE parent_id=\(root)") ?? "0") ?? 0)
            // Every container (page or folder) has a row in `groups` as well – the name for folders, none for pages.
            // The Dock rebuilds a first page of its own if a page lacks it.
            func newItem(type: Int, parent: Int, ordering: Int, title: String? = nil) throws -> Int {
                try exec(db, "INSERT INTO items (uuid, flags, type, parent_id, ordering) VALUES ('\(UUID().uuidString)', 0, \(type), \(parent), \(ordering))")
                let id = Int(sqlite3_last_insert_rowid(db))
                try exec(db, "INSERT INTO groups (item_id, category_id, title) VALUES (\(id), NULL, \(title.map(quoted) ?? "NULL"))")
                return id
            }
            /// The next entry of the app that is not placed yet – or, when this Mac has no app with the recorded identifier,
            /// of the app with the same name that is not itself part of the layout (an identifier that changed).
            let recordedBundles = layout.bundleIdentifiers
            var byTitle: [String: [String]] = [:]
            // Sorted by identifier – the same choice `resolving(against:)` makes when two apps share a name.
            for row in try rows(db, "SELECT IFNULL(bundleid,''), IFNULL(title,'') FROM apps ORDER BY bundleid") where !row[1].isEmpty && !row[0].isEmpty {
                let key = row[1].trimmingCharacters(in: .whitespaces).lowercased()
                if !(byTitle[key]?.contains(row[0]) ?? false) { byTitle[key, default: []].append(row[0]) }
            }
            func appItem(_ bundle: String) -> Int? {
                if let item = entries[bundle]?.first(where: { !placed.contains($0) }) { return item }
                guard entries[bundle] == nil, let name = layout.names?[bundle]?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
                for other in byTitle[name] ?? [] where !recordedBundles.contains(other) {
                    if let item = entries[other]?.first(where: { !placed.contains($0) }) { return item }
                }
                return nil
            }
            func move(_ item: Int, to parent: Int, ordering: Int) throws {
                try exec(db, "UPDATE items SET parent_id=\(parent), ordering=\(ordering) WHERE rowid=\(item)")
                placed.insert(item)
            }
            for page in layout.pages {
                let pageID = try newItem(type: 3, parent: root, ordering: 1 + pageIndex)
                pageIndex += 1
                var slot = 0
                for entry in page {
                    switch entry {
                    case .app(let bundle):
                        guard let item = appItem(bundle) else { continue }
                        try move(item, to: pageID, ordering: slot)
                        slot += 1
                    case .folder(let name, let folderPages):
                        guard folderPages.joined().contains(where: { appItem($0) != nil }) else { continue }
                        let folder = try newItem(type: 2, parent: pageID, ordering: slot, title: name)
                        slot += 1
                        var index = 0
                        for apps in folderPages {
                            var inner: Int?, order = 0
                            for bundle in apps {
                                guard let item = appItem(bundle) else { continue }
                                if inner == nil { inner = try newItem(type: 3, parent: folder, ordering: index); index += 1 }
                                try move(item, to: inner!, ordering: order)
                                order += 1
                            }
                        }
                    }
                }
            }
            // Apps of this Mac that are not in the layout follow on further pages.
            let rest = try rows(db, "SELECT i.rowid FROM items i WHERE i.type=4 ORDER BY i.parent_id, i.ordering").compactMap { Int($0[0]) }
                .filter { !placed.contains($0) && (oldPages.contains(parent(db, $0) ?? -1) || isInFolder(db, item: $0, folders: oldFolders)) }
            var restPage = -1, restSlot = Self.pageCapacity
            for item in rest {
                if restSlot >= Self.pageCapacity {
                    restPage = try newItem(type: 3, parent: root, ordering: 1 + pageIndex)
                    pageIndex += 1
                    restSlot = 0
                }
                try move(item, to: restPage, ordering: restSlot)
                restSlot += 1
            }
            // The old pages and folders are empty now.
            for folder in oldFolders {
                try exec(db, "DELETE FROM items WHERE type=3 AND parent_id=\(folder)")
                try exec(db, "DELETE FROM items WHERE rowid=\(folder)")
            }
            for page in oldPages { try exec(db, "DELETE FROM items WHERE rowid=\(page)") }
            try exec(db, "UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
            try exec(db, "COMMIT")
            return placed.count - rest.count
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: SQLite helpers

    private static func parent(_ db: OpaquePointer, _ item: Int) -> Int? {
        (try? scalar(db, "SELECT parent_id FROM items WHERE rowid=\(item)")).flatMap { $0 }.flatMap { Int($0) }
    }

    private static func isOnRootPage(_ db: OpaquePointer, item: Int, root: Int) -> Bool {
        guard let page = parent(db, item) else { return false }
        if parent(db, page) == root { return true }
        // Inside a folder: page → folder → page → root.
        guard let folder = parent(db, page), let outer = parent(db, folder) else { return false }
        return parent(db, outer) == root
    }

    /// On a page of the root, or in a folder on such a page.
    private static func isVisible(_ db: OpaquePointer, item: Int, root: Int) -> Bool {
        if isOnRootPage(db, item: item, root: root) { return true }
        guard let page = parent(db, item), let folder = parent(db, page), let folderPage = parent(db, folder) else { return false }
        return parent(db, folderPage) == root
    }

    private static func isInFolder(_ db: OpaquePointer, item: Int, folders: [Int]) -> Bool {
        guard let page = parent(db, item), let folder = parent(db, page) else { return false }
        return folders.contains(folder)
    }

    private func open(_ url: URL, readOnly: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LaunchpadError.unreadable("cannot open the Launchpad database")
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LaunchpadError.unreadable(String(cString: sqlite3_errmsg(db))) }
    }

    static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String? { try rows(db, sql).first?.first }

    static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LaunchpadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
}

extension SystemLayout {
    /// The Dock's Launchpad database: in a simulation or test sandbox a file inside it (the Dock is never
    /// signalled there), otherwise the current user's.
    public var launchpadStore: LaunchpadStore? {
        if let root = simulationRoot {
            var store = LaunchpadStore(database: root.appendingPathComponent("state/launchpad/db/db"))
            let log = root.appendingPathComponent("state/dock-signals")
            store.signalDock = { signal in
                let line = Data("\(signal)\n".utf8)
                if let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    try? handle.close()
                } else {
                    try? line.write(to: log)
                }
            }
            return store
        }
        return LaunchpadStore.live()
    }
}
