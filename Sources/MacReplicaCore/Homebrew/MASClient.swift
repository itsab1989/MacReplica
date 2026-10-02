import Foundation

/// Mac App Store support through `mas`, the community command line client.
public struct MASClient: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    public func locate() -> String? {
        layout.masCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func command(_ mas: String, _ arguments: [String], timeout: TimeInterval) -> Command {
        let prefix = URL(fileURLWithPath: mas).deletingLastPathComponent().deletingLastPathComponent()
        return Command(executable: mas, arguments: arguments,
                       environment: layout.processEnvironment(homebrewPrefix: prefix, askpass: nil), timeout: timeout)
    }

    public func installedApps(mas: String) async throws -> [MASAppRecord] {
        let result = try await runner.run(command(mas, ["list"], timeout: 120))
        guard result.succeeded else {
            throw MASError.commandFailed(layout.redact(result.combinedOutput))
        }
        return Self.parseList(result.stdout)
    }

    /// Parses `mas list` lines such as `497799835  Xcode  (15.4)`.
    public static func parseList(_ output: String) -> [MASAppRecord] {
        let pattern = #"^\s*(\d+)\s+(.+?)\s+\(([^()]*)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [MASAppRecord] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let idRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let versionRange = Range(match.range(at: 3), in: line),
                  let id = Int(line[idRange])
            else { continue }
            result.append(MASAppRecord(appStoreID: id, name: String(line[nameRange]), version: String(line[versionRange])))
        }
        return result
    }

    public func install(mas: String, appStoreID: Int, onOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        guard appStoreID > 0 else { throw MASError.invalidIdentifier }
        return try await runner.run(command(mas, ["install", String(appStoreID)], timeout: 3600), onOutputLine: onOutputLine)
    }

    /// The App Store ID stored by Spotlight for an installed app, if available.
    public func appStoreID(ofBundle bundle: URL) async -> Int? {
        let result = try? await runner.run(Command(
            executable: layout.mdls, arguments: ["-raw", "-name", "kMDItemAppStoreAdamID", bundle.path],
            environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 30))
        guard let result, result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum MASError: Error, Equatable, Sendable {
    case commandFailed(String)
    case invalidIdentifier
}
