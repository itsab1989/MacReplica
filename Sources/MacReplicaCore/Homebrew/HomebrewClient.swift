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
                appArtifacts: CaskCatalog.appArtifacts(from: item["artifacts"]), availability: Self.availability(item)))
        }
        return InstalledHomebrewPackages(
            formulae: formulae.sorted { $0.name < $1.name },
            casks: casks.sorted { $0.token < $1.token })
    }

    static func shortToken(_ token: String) -> String { String(token.split(separator: "/").last ?? Substring(token)) }

    /// From `brew info --json=v2`: a cask whose definition is gone (removed from Homebrew) is still listed for an
    /// installed copy, with an empty `url` and no tap (checked with Homebrew 5 on 2026-10-13).
    static func availability(_ item: [String: Any]) -> CaskAvailability {
        if item["disabled"] as? Bool == true {
            return CaskAvailability(state: .disabled, reason: item["disable_reason"] as? String, date: item["disable_date"] as? String)
        }
        if let url = item["url"] as? String, url.isEmpty, item["tap"] == nil || item["tap"] is NSNull {
            return CaskAvailability(state: .removed)
        }
        if item["deprecated"] as? Bool == true {
            return CaskAvailability(state: .deprecated, reason: item["deprecation_reason"] as? String, date: item["deprecation_date"] as? String)
        }
        return CaskAvailability(state: .available)
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
            let tokens = (item["cask_tokens"] as? [String] ?? []).map { $0.contains("/") ? $0 : "\(name)/\($0)" }
            return BrewTapRecord(name: name, remote: item["remote"] as? String, caskTokens: tokens.isEmpty ? nil : tokens)
        }
        .filter { !$0.isBuiltIn }
        .sorted { $0.name < $1.name }
    }

    /// The definitions of casks from third-party taps (full tokens), read from the tap on this Mac. Only parsed, never run.
    public func tapCasks(_ brew: HomebrewInstallation, tokens: [String]) async -> [CaskInfo] {
        let valid = tokens.filter { $0.range(of: #"^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9@_.+-]*$"#, options: .regularExpression) != nil }
        guard !valid.isEmpty, let result = try? await runner.run(command(brew, ["info", "--json=v2", "--cask"] + valid.prefix(200), timeout: 300)),
              result.succeeded, let root = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let casks = root["casks"], let data = try? JSONSerialization.data(withJSONObject: casks) else { return [] }
        return (try? CaskCatalog.parseCasks(data)) ?? []
    }

    /// The installed version of a formula, or nil if it is not installed.
    public func installedFormulaVersion(_ brew: HomebrewInstallation, name: String) async throws -> String? {
        let result = try await runner.run(command(brew, ["list", "--formula", "--versions", name], timeout: 120))
        guard result.succeeded else { return nil }
        return Self.parseListVersions(result.stdout)
    }

    /// `brew list --cask --versions` accepts only the short token: for `user/tap/token` it prints nothing and fails
    /// (checked with Homebrew 5, 2026-10-13), so a cask from a third-party tap is asked for by its last part.
    public func installedCaskVersion(_ brew: HomebrewInstallation, token: String) async throws -> String? {
        let result = try await runner.run(command(brew, ["list", "--cask", "--versions", Self.shortToken(token)], timeout: 120))
        guard result.succeeded else { return nil }
        return Self.parseListVersions(result.stdout)
    }

    /// What a cask puts on the Mac according to its definition (`brew info --json=v2 --cask`, only parsed, never run):
    /// its apps and its installer packages. nil when Homebrew does not answer.
    public func caskContents(_ brew: HomebrewInstallation, token: String) async -> CaskContents? {
        guard (try? Self.validatePackageName(token)) != nil,
              let result = try? await runner.run(command(brew, ["info", "--json=v2", "--cask", token], timeout: 120)),
              result.succeeded else { return nil }
        return Self.parseCaskContents(Data(result.stdout.utf8))
    }

    /// Reads the first cask of `brew info --json=v2 --cask` output. Homebrew 7 gives each app's full destination as
    /// `target` (e.g. `{"app": ["KeyCastr.app"], "target": "/Applications/KeyCastr.app"}`, seen 2026-11-03); a cask
    /// that renames its app gives `{"app": ["Foo.app", {"target": "Bar.app"}]}`. Packages are `{"pkg": ["X.pkg", …]}`;
    /// the receipts they leave are named in `uninstall` as `pkgutil` (one ID or a list, regular expressions allowed).
    public static func parseCaskContents(_ data: Data) -> CaskContents? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cask = (root["casks"] as? [[String: Any]])?.first else { return nil }
        let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
        var contents = CaskContents()
        for artifact in artifacts {
            if let apps = artifact["app"] as? [Any] {
                var names: [String] = []
                for entry in apps {
                    if let name = entry as? String { names.append((name as NSString).lastPathComponent) }
                    if let options = entry as? [String: Any], let target = options["target"] as? String {
                        names = [(target as NSString).lastPathComponent]
                        if target.hasPrefix("/") { contents.appTargets.append(target) }
                    }
                }
                if let target = artifact["target"] as? String {
                    if target.hasPrefix("/") { contents.appTargets.append(target) }
                    names = [(target as NSString).lastPathComponent]
                }
                contents.appNames += names.filter { $0.hasSuffix(".app") && !contents.appNames.contains($0) }
            }
            if let packages = artifact["pkg"] as? [Any], let name = packages.first as? String {
                contents.packages.append((name as NSString).lastPathComponent)
            }
            for stanza in artifact["uninstall"] as? [[String: Any]] ?? [] {
                if let id = stanza["pkgutil"] as? String { contents.receipts.append(id) }
                if let ids = stanza["pkgutil"] as? [String] { contents.receipts += ids }
            }
        }
        return contents
    }

    /// Whether one of a cask's receipts is installed, asked the way Homebrew asks: `pkgutil --pkgs=<pattern>`
    /// (read-only) for each `pkgutil` pattern of the cask. The patterns then mean what they mean to Homebrew: the whole
    /// ID, `*` and `?` as wildcards (`com.microsoft.dotnet.*10.0*arm64`), case-sensitive; pkgutil exits with 1 when
    /// nothing matches (checked 2026-11-03). nil if pkgutil cannot be run.
    public func hasReceipt(matching patterns: [String]) async -> Bool? {
        var answered = false
        for pattern in patterns where !pattern.isEmpty && pattern.count <= 300 {
            guard let result = try? await runner.run(Command(executable: layout.pkgutil, arguments: ["--pkgs=\(pattern)"],
                                                             environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 60))
            else { continue }
            answered = true
            if result.succeeded, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return answered ? false : nil
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

    /// - Parameter appdir: for casks, the folder their apps go to (`--appdir`); nil keeps Homebrew's default.
    public func install(_ brew: HomebrewInstallation, package: HomebrewPackage, askpass: String?,
                        extraEnvironment: [String: String] = [:], appdir: String? = nil,
                        onOutputLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        var arguments: [String]
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
        case .caskReinstall(let token):
            try Self.validatePackageName(token)
            arguments = ["reinstall", "--cask", token]
        case .tap(let name, let remote):
            try Self.validatePackageName(name)
            if let remote {
                try Self.validateTapRemote(remote)
                arguments = ["tap", name, remote]
            } else {
                arguments = ["tap", name]
            }
        }
        switch package {
        case .cask, .caskReinstall:
            if let appdir {
                try Self.validateAppFolder(appdir)
                arguments.append("--appdir=\(appdir)")
            }
        default: break
        }
        var installCommand = command(brew, arguments, timeout: 3600, askpass: askpass)
        if askpass != nil {
            installCommand.environment.merge(extraEnvironment) { current, _ in current }
        }
        return try await runner.run(installCommand, onOutputLine: onOutputLine)
    }

    /// True when Homebrew says it is too old for the package definitions it just loaded. Homebrew reads current casks
    /// from its online API, so an old copy (e.g. one brought back by Time Machine, with automatic updates off) fails
    /// with "Unexpected method 'postflight_steps' called on Cask zoom" or prints "Do not report this issue until
    /// you've run `brew update` and tried again" (both seen by a tester on 2026-10-17).
    public static func isOutdatedHomebrewOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("unexpected method '") || lower.contains("until you've run `brew update`")
    }

    /// Updates Homebrew itself and its package definitions (`brew update`); installed packages are not upgraded.
    public func update(_ brew: HomebrewInstallation) async throws -> CommandResult {
        try await runner.run(command(brew, ["update"], timeout: 1200))
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

    /// The app folder for `--appdir` is an absolute path without control characters.
    public static func validateAppFolder(_ path: String) throws {
        guard path.hasPrefix("/"), path.count <= 1024, !path.contains(".."),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw HomebrewError.invalidPackageName(path)
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

/// What a cask installs, from its definition.
public struct CaskContents: Sendable, Equatable {
    /// App bundle names (as installed, after a rename).
    public var appNames: [String] = []
    /// Full destination paths of the apps, when Homebrew gives them.
    public var appTargets: [String] = []
    /// Installer package file names.
    public var packages: [String] = []
    /// Receipt IDs (patterns) the packages leave, from `uninstall pkgutil:`.
    public var receipts: [String] = []

    public init(appNames: [String] = [], appTargets: [String] = [], packages: [String] = [], receipts: [String] = []) {
        self.appNames = appNames
        self.appTargets = appTargets
        self.packages = packages
        self.receipts = receipts
    }
}

public enum HomebrewPackage: Sendable, Equatable {
    case formula(String)
    /// The development version built from the formula's source repository (`--HEAD`).
    case formulaHead(String)
    case cask(String)
    /// Installs a cask again over Homebrew's own copy (`brew reinstall --cask`).
    case caskReinstall(String)
    case tap(name: String, remote: String?)
}

public enum HomebrewError: Error, Equatable, Sendable {
    case commandFailed(arguments: String, output: String)
    case unexpectedOutput(String)
    case invalidPackageName(String)
}
