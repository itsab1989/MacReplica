import Foundation
import Testing
@testable import MacReplicaCore

/// The details of settings restore that the mutation run showed untested: which categories start selected, how a
/// changed value, an equal one and one of another kind are counted, the order of the report, and that the Dock,
/// Finder or menu bar is restarted only when something was really applied.
@Suite("macOS settings: edge cases")
struct SystemSettingsEdgeTests {
    /// `defaults export/import` and `killall` on in-memory domains; records every restart.
    final class FakeDefaults: CommandRunning, @unchecked Sendable {
        var domains: [String: [String: Any]]
        var restarted: [String] = []
        /// Values this “macOS” does not keep (read back as before).
        var refused: Set<String> = []
        private let lock = NSLock()

        init(_ domains: [String: [String: Any]]) { self.domains = domains }

        func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            try lock.withLock { try handle(command) }
        }

        private func handle(_ command: Command) throws -> CommandResult {
            let args = command.arguments
            if command.executable.hasSuffix("killall") { restarted.append(args.joined()); return CommandResult(exitCode: 0, stdout: "", stderr: "") }
            let domain = args[1] == "-g" ? SettingsCatalog.global : args[1]
            if args[0] == "export" {
                let data = try PropertyListSerialization.data(fromPropertyList: domains[domain] ?? [:], format: .xml, options: 0)
                return CommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            var values = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[2])), format: nil) as? [String: Any] ?? [:]
            for key in refused { values[key] = domains[domain]?[key] }
            domains[domain] = values
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    static func record(_ category: String, _ values: [String: [String: Any]], in root: URL) throws -> SettingsRecord {
        var files: [FileRecord] = []
        for (domain, domainValues) in values {
            let relative = "settings/\(category)/\(domain).plist"
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: domainValues, format: .xml, options: 0).write(to: url)
            files.append(FileRecord(fileName: "\(domain).plist", domain: .user, relativePath: relative, originalPath: "~/Library/Preferences/\(domain).plist",
                                    backupPath: relative, sha256: try Hashing.sha256Hex(ofFile: url), size: 1, metadata: ["domain": domain]))
        }
        return SettingsRecord(category: category, files: files, keyCount: values.values.map(\.count).reduce(0, +))
    }

    static func restorer(_ fake: FakeDefaults, root: URL) -> SettingsRestorer {
        var layout = SystemLayout.live()
        layout.defaults = "/usr/bin/defaults"
        layout.killall = "/usr/bin/killall"
        return SettingsRestorer(store: SettingsStore(layout: layout, runner: fake), backupRoot: root)
    }

    @Test func whichCategoriesStartSelectedAndHowTheyApply() {
        let expected: [String: (Bool, SettingsCategory.Apply, SettingsCategory.CrossVersion)] = [
            "dock": (true, .restartDock, .stable), "finder": (true, .restartFinder, .stable), "keyboard": (true, .logout, .stable),
            "trackpadMouse": (true, .logout, .stable), "languageRegion": (true, .logout, .stable), "appearance": (true, .logout, .stable),
            "screenshots": (true, .restartMenuBar, .stable), "keyboardShortcuts": (false, .logout, .sameMajorVersion),
            "inputSources": (false, .logout, .sameMajorVersion), "menuBarClock": (true, .restartMenuBar, .stable),
        ]
        #expect(SettingsCatalog.categories.map(\.id).sorted() == expected.keys.sorted())
        for category in SettingsCatalog.categories {
            let (selected, apply, cross) = expected[category.id]!
            #expect(category.selectedByDefault == selected, "\(category.id)")
            #expect(category.apply == apply, "\(category.id)")
            #expect(category.crossVersion == cross, "\(category.id)")
        }
        #expect(SettingsCatalog.category("nothing") == nil)
    }

    @Test func homeFolderAndFileURLsAreRewritten() {
        #expect(SettingsValues.replacingHome("/Users/anna", from: "/Users/anna", to: "/Users/bob") as? String == "/Users/bob")
        #expect(SettingsValues.replacingHome("file:///Users/anna", from: "/Users/anna", to: "/Users/bob") as? String == "file:///Users/bob/")
        #expect(SettingsValues.replacingHome("file:///Users/anna/", from: "/Users/anna", to: "/Users/bob") as? String == "file:///Users/bob/")
        #expect(SettingsValues.replacingHome(["a": ["/Users/anna/x"]], from: "/Users/anna", to: "/Users/bob") as? [String: [String]] == ["a": ["/Users/bob/x"]])
        #expect(SettingsValues.replacingHome(5, from: "/Users/anna", to: "/Users/bob") as? Int == 5)
        #expect(SettingsValues.equal(nil, nil))
        #expect(!SettingsValues.equal(nil, 1))
        #expect(!SettingsValues.equal(1, nil))
        #expect(SettingsValues.equal(1, 1) && !SettingsValues.equal(1, 2))
        #expect(SettingsValues.sameKind("a", "b") && SettingsValues.sameKind(1, true) && !SettingsValues.sameKind(1, "1"))
    }

    @Test func changesCountEqualValuesAndListTheRestInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try Self.record("dock", ["com.apple.dock": ["tilesize": 48, "autohide": true, "orientation": "left", "largesize": 80, "mineffect": "scale"]], in: root)
        let fake = FakeDefaults(["com.apple.dock": ["tilesize": 48, "autohide": false, "largesize": "big", "mineffect": "genie"]])
        let change = try await Self.restorer(fake, root: root).changes(record)
        #expect(change.unchanged == 1)
        #expect(change.differentType == ["com.apple.dock › largesize"])
        // Sorted by key, and an equal or different-kind key is never listed as “to change”.
        #expect(change.toChange == ["com.apple.dock › autohide", "com.apple.dock › mineffect", "com.apple.dock › orientation"])
    }

    @Test func restartOnlyWhenSomethingWasApplied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let record = try Self.record("dock", ["com.apple.dock": ["tilesize": 48, "autohide": true]], in: root)
        // Everything already as recorded: nothing written, no restart.
        let same = FakeDefaults(["com.apple.dock": ["tilesize": 48, "autohide": true]])
        let unchanged = try await Self.restorer(same, root: root).apply(record, work: work)
        #expect(unchanged.applied == 0)
        #expect(same.restarted.isEmpty)
        // This macOS refuses every key: written but not kept – reported in order, no restart.
        let refusing = FakeDefaults(["com.apple.dock": ["tilesize": 30, "autohide": false]])
        refusing.refused = ["tilesize", "autohide"]
        let refused = try await Self.restorer(refusing, root: root).apply(record, work: work)
        #expect(refused.applied == 0)
        #expect(refused.notKept == ["com.apple.dock › autohide", "com.apple.dock › tilesize"])
        #expect(refusing.restarted.isEmpty)
        // One key really applied: the Dock restarts once.
        let different = FakeDefaults(["com.apple.dock": ["tilesize": 30, "autohide": true]])
        let applied = try await Self.restorer(different, root: root).apply(record, work: work)
        #expect(applied.applied == 1)
        #expect(different.restarted == ["Dock"])
        #expect(different.domains["com.apple.dock"]?["tilesize"] as? Int == 48)
    }
}
