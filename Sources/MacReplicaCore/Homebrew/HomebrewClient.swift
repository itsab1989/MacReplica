import Foundation

public struct HomebrewInstallation: Sendable, Equatable {
    public var executable: String
    public var prefix: URL
    public var version: String
}

public enum HomebrewStatus: Sendable, Equatable {
    case notInstalled
    /// `brew` exists but does not work, e.g. after an interrupted installation.
    case broken(executable: String, reason: String)
    case ready(HomebrewInstallation)

    public var installation: HomebrewInstallation? {
        if case .ready(let installation) = self { return installation }
        return nil
    }
}

public struct InstalledHomebrewPackages: Sendable, Equatable {
    public var formulae: [BrewFormulaRecord]
    public var casks: [BrewCaskRecord]
}

/// Talks to Homebrew through its documented command line interface.
public struct HomebrewClient: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    /// Finds a working `brew`. Every candidate path is checked explicitly;
    /// MacReplica never relies on `PATH` to find Homebrew.
    public func locate() async -> HomebrewStatus {
        var firstBroken: HomebrewStatus?
        for prefix in layout.homebrewPrefixes {
            let executable = layout.brewExecutable(in: prefix)
            let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
            guard attributes != nil || FileManager.default.fileExists(atPath: executable) else { continue }
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                firstBroken = firstBroken ?? .broken(executable: executable, reason: "not executable")
                continue
            }
            do {
                let result = try await runner.run(Command(
                    executable: executable, arguments: ["--version"],
                    environment: layout.processEnvironment(homebrewPrefix: prefix, askpass: nil), timeout: 60))
                if result.succeeded, let version = Self.parseVersion(result.stdout) {
                    return .ready(HomebrewInstallation(executable: executable, prefix: prefix, version: version))
                }
                // The reason names what `brew` printed (redacted, short), so the log shows why it was not used.
                let output = (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3).joined(separator: " | ")
                let printed = output.isEmpty ? "" : ": " + layout.redact(String(output.prefix(300)))
                let reason = result.timedOut ? "timed out" : "brew --version exited with \(result.exitCode)\(printed)"
                firstBroken = firstBroken ?? .broken(executable: executable, reason: reason)
            } catch {
                firstBroken = firstBroken ?? .broken(executable: executable, reason: String(describing: error))
            }
        }
        return firstBroken ?? .notInstalled
    }

    /// Parses the first line of `brew --version`, e.g. "Homebrew 4.3.1-12-gabc" → "4.3.1-12-gabc".
    /// Without git (no Command Line Tools, or Homebrew from its installer package) Homebrew prints
    /// "Homebrew >=4.6.0 (shallow or no git repository)"; that is a working Homebrew too → "4.6.0".
    public static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Homebrew ") else { continue }
            var version = trimmed.dropFirst("Homebrew ".count).trimmingCharacters(in: .whitespaces)
            if version.hasPrefix(">=") {
                version = String(version.dropFirst(2).prefix { !$0.isWhitespace })
            }
            if let first = version.first, first.isNumber { return String(version) }
        }
        return nil
    }

    private func command(_ brew: HomebrewInstallation, _ arguments: [String], timeout: TimeInterval = 300, askpass: String? = nil) -> Command {
        Command(executable: brew.executable, arguments: arguments,
                environment: layout.processEnvironment(homebrewPrefix: brew.prefix, askpass: askpass), timeout: timeout)
    }

    public func installedPackages(_ brew: HomebrewInstallation) async throws -> InstalledHomebrewPackages {
        let result = try await runner.run(command(brew, ["info", "--json=v2", "--installed"], timeout: 600))
        guard result.succeeded else {
            throw HomebrewError.commandFailed(arguments: "info --json=v2 --installed", output: layout.redact(result.combinedOutput))
        }
        return try Self.parseInstalled(Data(result.stdout.utf8))
    }

    public static func parseInstalled(_ data: Data) throws -> InstalledHomebrewPackages {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomebrewError.unexpectedOutput("brew info JSON")
        }
        var formulae: [BrewFormulaRecord] = []
        for item in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = item["full_name"] as? String ?? item["name"] as? String else { continue }
            let installed = item["installed"] as? [[String: Any]] ?? []
            guard let latest = installed.last else { continue }
            let version = latest["version"] as? String ?? (item["versions"] as? [String: Any])?["stable"] as? String ?? ""
            let onRequest = installed.contains { ($0["installed_on_request"] as? Bool) == true }
            formulae.append(BrewFormulaRecord(name: name, version: version, tap: item["tap"] as? String, installedOnRequest: onRequest))
        }
        var casks: [BrewCaskRecord] = []
        for item in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = item["full_token"] as? String ?? item["token"] as? String else { continue }
            let version = item["installed"] as? String ?? item["version"] as? String ?? ""
            casks.append(BrewCaskRecord(
                token: token, version: version, tap: item["tap"] as? String,
                appArtifacts: CaskCatalog.appArtifacts(from: item["artifacts"])))
        }
        return InstalledHomebrewPackages(
            formulae: formulae.sorted { $0.name < $1.name },
            casks: casks.sorted { $0.token < $1.token })
    }

    public func taps(_ brew: HomebrewInstallation) async throws -> [BrewTapRecord] {
        let result = try await runner.run(command(brew, ["tap-info", "--json", "--installed"], timeout: 120))
        guard result.succeeded else {
            throw HomebrewError.commandFailed(arguments: "tap-info --json --installed", output: layout.redact(result.combinedOutput))
        }
        return try Self.parseTaps(Data(result.stdout.utf8))
    }

    public static func parseTaps(_ data: Data) throws -> [BrewTapRecord] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HomebrewError.unexpectedOutput("brew tap-info JSON")
        }
        return items.compactMap { item -> BrewTapRecord? in
            guard let name = item["name"] as? String else { return nil }
            return BrewTapRecord(name: name, remote: item["remote"] as? String)
        }
        .filter { !$0.isBuiltIn }
        .sorted { $0.name < $1.name }
    }

    /// The installed version of a formula, or nil if it is not installed.
    public func installedFormulaVersion(_ brew: HomebrewInstallation, name: String) async throws -> String? {
        let result = try await runner.run(command(brew, ["list", "--formula", "--versions", name], timeout: 120))
        guard result.succeeded else { return nil }
        return Self.parseListVersions(result.stdout)
    }

    public func installedCaskVersion(_ brew: HomebrewInstallation, token: String) async throws -> String? {
        let result = try await runner.run(command(brew, ["list", "--cask", "--versions", token], timeout: 120))
        guard result.succeeded else { return nil }
        return Self.parseListVersions(result.stdout)
    }

    /// `brew list --versions` prints "name 1.2.3 1.2.4"; the newest version is last.
    public static func parseListVersions(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let last = parts.last else { return nil }
        return String(last)
    }

    public func installedTaps(_ brew: HomebrewInstallation) async throws -> Set<String> {
        let result = try await runner.run(command(brew, ["tap"], timeout: 120))
        guard result.succeeded else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    public func install(_ brew: HomebrewInstallation, package: HomebrewPackage, askpass: String?,
                        extraEnvironment: [String: String] = [:],
                        onOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let arguments: [String]
        switch package {
        case .formula(let name):
            try Self.validatePackageName(name)
            arguments = ["install", "--formula", name]
        case .formulaHead(let name):
            try Self.validatePackageName(name)
            arguments = ["install", "--formula", name, "--HEAD"]
        case .cask(let token):
            try Self.validatePackageName(token)
            arguments = ["install", "--cask", token]
        case .tap(let name, let remote):
            try Self.validatePackageName(name)
            if let remote {
                try Self.validateTapRemote(remote)
                arguments = ["tap", name, remote]
            } else {
                arguments = ["tap", name]
            }
        }
        var installCommand = command(brew, arguments, timeout: 3600, askpass: askpass)
        if askpass != nil {
            installCommand.environment.merge(extraEnvironment) { current, _ in current }
        }
        return try await runner.run(installCommand, onOutputLine: onOutputLine)
    }

    /// Homebrew 6.0 and later only load formulae and casks from third-party taps the user trusts.
    public static func requiresTapTrust(_ version: String) -> Bool {
        (Int(version.split(separator: ".").first ?? "") ?? 0) >= 6
    }

    /// Marks a third-party tap as trusted (`brew trust --tap`). Only called for taps the user allowed in MacReplica.
    public func trustTap(_ brew: HomebrewInstallation, name: String) async throws -> CommandResult {
        try Self.validatePackageName(name)
        return try await runner.run(command(brew, ["trust", "--tap", name], timeout: 120))
    }

    /// Package names come from a backup file and must never be interpreted as options or paths.
    public static func validatePackageName(_ name: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9@+._-]*(/[A-Za-z0-9][A-Za-z0-9@+._-]*){0,2}$"#
        guard name.count <= 200, name.range(of: pattern, options: .regularExpression) != nil, !name.contains("..") else {
            throw HomebrewError.invalidPackageName(name)
        }
    }

    /// Only HTTPS and SSH Git remotes are accepted for third-party taps.
    public static func validateTapRemote(_ remote: String) throws {
        guard let url = URL(string: remote), url.scheme == "https", url.host != nil, !remote.hasPrefix("-") else {
            if remote.range(of: #"^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil { return }
            throw HomebrewError.invalidPackageName(remote)
        }
    }
}

public enum HomebrewPackage: Sendable, Equatable {
    case formula(String)
    /// The development version built from the formula's source repository (`--HEAD`).
    case formulaHead(String)
    case cask(String)
    case tap(name: String, remote: String?)
}

public enum HomebrewError: Error, Equatable, Sendable {
    case commandFailed(arguments: String, output: String)
    case unexpectedOutput(String)
    case invalidPackageName(String)
}
