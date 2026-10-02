import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Homebrew")
struct HomebrewTests {
    static func layout(_ sandbox: Sandbox) throws -> SystemLayout {
        var layout = SystemLayout.live(architecture: .arm64)
        layout.homebrewPrefixes = [try sandbox.folder("opt/homebrew"), try sandbox.folder("usr/local")]
        layout.homeDirectory = try sandbox.folder("home")
        return layout
    }

    static func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func parsesVersionLine() {
        #expect(HomebrewClient.parseVersion("Homebrew 4.4.0\nHomebrew/homebrew-core (git revision abc)") == "4.4.0")
        #expect(HomebrewClient.parseVersion("Warning: x\nHomebrew 4.3.1-12-gabc") == "4.3.1-12-gabc")
        #expect(HomebrewClient.parseVersion("Homebrew >=4") == nil)
        #expect(HomebrewClient.parseVersion("") == nil)
    }

    @Test func locateReportsNotInstalled() async throws {
        let sandbox = try Sandbox("brew-none")
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "Homebrew 4.4.0", stderr: "") }
        #expect(await HomebrewClient(layout: try Self.layout(sandbox), runner: runner).locate() == .notInstalled)
        #expect(runner.commands.isEmpty)
    }

    @Test func locateFindsWorkingBrewAndUsesAbsolutePath() async throws {
        let sandbox = try Sandbox("brew-ready")
        let layout = try Self.layout(sandbox)
        try Self.makeExecutable(URL(fileURLWithPath: layout.brewExecutable(in: layout.homebrewPrefixes[0])))
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "Homebrew 4.4.0\n", stderr: "") }
        let status = await HomebrewClient(layout: layout, runner: runner).locate()
        #expect(status.installation?.version == "4.4.0")
        #expect(status.installation?.prefix == layout.homebrewPrefixes[0])
        let command = try #require(runner.commands.first)
        #expect(command.executable == layout.brewExecutable(in: layout.homebrewPrefixes[0]))
        #expect(command.arguments == ["--version"])
        // PATH is set explicitly and starts with the Homebrew prefix, never inherited.
        #expect(command.environment["PATH"]?.hasPrefix(layout.homebrewPrefixes[0].path + "/bin:") == true)
        #expect(command.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func locateDetectsBrokenBrewAndFallsBackToSecondPrefix() async throws {
        let sandbox = try Sandbox("brew-broken")
        let layout = try Self.layout(sandbox)
        let first = layout.brewExecutable(in: layout.homebrewPrefixes[0])
        let second = layout.brewExecutable(in: layout.homebrewPrefixes[1])
        try Self.makeExecutable(URL(fileURLWithPath: first))
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "Error: broken") }
        #expect(await HomebrewClient(layout: layout, runner: runner).locate() == .broken(executable: first, reason: "brew --version exited with 1"))

        try Self.makeExecutable(URL(fileURLWithPath: second))
        let mixed = ScriptedRunner { command in
            command.executable == second ? CommandResult(exitCode: 0, stdout: "Homebrew 4.2.0", stderr: "") : CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        #expect(await HomebrewClient(layout: layout, runner: mixed).locate().installation?.executable == second)
    }

    @Test func locateTreatsNonExecutableAndTimeoutsAsBroken() async throws {
        let sandbox = try Sandbox("brew-noexec")
        let layout = try Self.layout(sandbox)
        let path = layout.brewExecutable(in: layout.homebrewPrefixes[0])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "Homebrew 1.0", stderr: "") }
        #expect(await HomebrewClient(layout: layout, runner: runner).locate() == .broken(executable: path, reason: "not executable"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let slow = ScriptedRunner { _ in CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true) }
        #expect(await HomebrewClient(layout: layout, runner: slow).locate() == .broken(executable: path, reason: "timed out"))
    }

    @Test func parsesInstalledPackages() throws {
        let json = #"""
        {"formulae": [
          {"name": "git", "full_name": "git", "tap": "homebrew/core",
           "installed": [{"version": "2.46.0", "installed_on_request": true}], "versions": {"stable": "2.47.0"}},
          {"name": "openssl@3", "full_name": "openssl@3", "tap": "homebrew/core",
           "installed": [{"version": "3.3.2", "installed_on_request": false}]},
          {"name": "tool", "full_name": "example/tools/tool", "tap": "example/tools",
           "installed": [{"version": "0.9", "installed_on_request": true}]},
          {"name": "not-installed", "installed": []}],
         "casks": [
          {"token": "example-editor", "full_token": "example-editor", "tap": "homebrew/cask", "installed": "1.2",
           "artifacts": [{"app": ["Example Editor.app"]}]},
          {"token": "font-x", "installed": null, "version": "2.0", "artifacts": []}]}
        """#
        let parsed = try HomebrewClient.parseInstalled(Data(json.utf8))
        #expect(parsed.formulae.map(\.name) == ["example/tools/tool", "git", "openssl@3"])
        #expect(parsed.formulae.first { $0.name == "git" }?.version == "2.46.0")
        #expect(parsed.formulae.first { $0.name == "openssl@3" }?.installedOnRequest == false)
        #expect(parsed.casks == [BrewCaskRecord(token: "example-editor", version: "1.2", tap: "homebrew/cask", appArtifacts: ["Example Editor.app"]),
                                 BrewCaskRecord(token: "font-x", version: "2.0", tap: nil, appArtifacts: [])])
        #expect(throws: HomebrewError.unexpectedOutput("brew info JSON")) { try HomebrewClient.parseInstalled(Data("[]".utf8)) }
    }

    @Test func parsesTapsAndDropsBuiltIns() throws {
        let json = #"[{"name": "homebrew/core"}, {"name": "example/tools", "remote": "https://github.com/example/homebrew-tools"}, {"remote": "x"}]"#
        #expect(try HomebrewClient.parseTaps(Data(json.utf8)) == [BrewTapRecord(name: "example/tools", remote: "https://github.com/example/homebrew-tools")])
        #expect(throws: (any Error).self) { try HomebrewClient.parseTaps(Data("{}".utf8)) }
    }

    @Test func parsesListVersions() {
        #expect(HomebrewClient.parseListVersions("git 2.46.0 2.47.0\n") == "2.47.0")
        #expect(HomebrewClient.parseListVersions("git") == nil)
        #expect(HomebrewClient.parseListVersions("") == nil)
    }

    @Test(arguments: ["git", "openssl@3", "example/tools/tool", "visual-studio-code", "font-fira-code", "c++", "python@3.12", "example/tools"])
    func acceptsValidPackageNames(_ name: String) throws {
        try HomebrewClient.validatePackageName(name)
    }

    @Test(arguments: ["", "--force", "-v", "; rm -rf ~", "a b", "../etc", "a/../b", "$(whoami)", "`id`", "a|b", "/abs/path", "a/b/c/d", "name\n--debug"])
    func rejectsDangerousPackageNames(_ name: String) {
        #expect(throws: HomebrewError.invalidPackageName(name)) { try HomebrewClient.validatePackageName(name) }
    }

    @Test func tapRemoteValidation() throws {
        try HomebrewClient.validateTapRemote("https://github.com/example/homebrew-tools")
        try HomebrewClient.validateTapRemote("git@github.com:example/homebrew-tools.git")
        for bad in ["http://insecure.example.com/x", "file:///tmp/tap", "--upload-pack=evil", "ssh://x", "git@host:x; rm"] {
            #expect(throws: HomebrewError.invalidPackageName(bad)) { try HomebrewClient.validateTapRemote(bad) }
        }
    }

    @Test func installPassesArgumentsWithoutShellAndOnlyAddsAskpassWhenGiven() async throws {
        let sandbox = try Sandbox("brew-install")
        let layout = try Self.layout(sandbox)
        let brew = HomebrewInstallation(executable: layout.brewExecutable(in: layout.homebrewPrefixes[0]), prefix: layout.homebrewPrefixes[0], version: "4")
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
        let client = HomebrewClient(layout: layout, runner: runner)
        _ = try await client.install(brew, package: .cask("example-editor"), askpass: "/Applications/MacReplica.app/Contents/Helpers/MacReplicaAskpass",
                                     extraEnvironment: ["MACREPLICA_ASKPASS_TITLE": "T"])
        _ = try await client.install(brew, package: .formula("git"), askpass: nil, extraEnvironment: ["MACREPLICA_ASKPASS_TITLE": "T"])
        _ = try await client.install(brew, package: .tap(name: "example/tools", remote: "https://github.com/example/homebrew-tools"), askpass: nil)
        let commands = runner.commands
        #expect(commands[0].arguments == ["install", "--cask", "example-editor"])
        #expect(commands[0].environment["SUDO_ASKPASS"]?.hasSuffix("MacReplicaAskpass") == true)
        #expect(commands[0].environment["MACREPLICA_ASKPASS_TITLE"] == "T")
        #expect(commands[1].arguments == ["install", "--formula", "git"])
        #expect(commands[1].environment["SUDO_ASKPASS"] == nil)
        #expect(commands[1].environment["MACREPLICA_ASKPASS_TITLE"] == nil)
        #expect(commands[2].arguments == ["tap", "example/tools", "https://github.com/example/homebrew-tools"])
        await #expect(throws: HomebrewError.invalidPackageName("--force")) {
            _ = try await client.install(brew, package: .cask("--force"), askpass: nil)
        }
        #expect(runner.commands.count == 3)
    }

    @Test func commandFailuresAreReportedWithRedactedOutput() async throws {
        let sandbox = try Sandbox("brew-fail")
        let layout = try Self.layout(sandbox)
        let brew = HomebrewInstallation(executable: "/opt/homebrew/bin/brew", prefix: layout.homebrewPrefixes[0], version: "4")
        let home = layout.homeDirectory.path
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "Error in \(home)/x") }
        await #expect(throws: HomebrewError.commandFailed(arguments: "info --json=v2 --installed", output: "\nError in ~/x")) {
            _ = try await HomebrewClient(layout: layout, runner: runner).installedPackages(brew)
        }
    }

    @Test func masListParsing() {
        let output = "497799835  Xcode  (15.4)\n  1234567890 Ledger Lite (5.1)\nnot a line\n42  Name (with parens) (1.0)\n"
        #expect(MASClient.parseList(output) == [
            MASAppRecord(appStoreID: 497_799_835, name: "Xcode", version: "15.4"),
            MASAppRecord(appStoreID: 1_234_567_890, name: "Ledger Lite", version: "5.1"),
            MASAppRecord(appStoreID: 42, name: "Name (with parens)", version: "1.0"),
        ])
    }

    @Test func masRejectsInvalidIdentifiers() async throws {
        let runner = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
        let client = MASClient(layout: .live(), runner: runner)
        await #expect(throws: MASError.invalidIdentifier) { _ = try await client.install(mas: "/opt/homebrew/bin/mas", appStoreID: 0) }
        _ = try await client.install(mas: "/opt/homebrew/bin/mas", appStoreID: 12)
        #expect(runner.commands.last?.arguments == ["install", "12"])
    }

    @Test func homebrewPackageSignatureCheck() {
        let trusted = """
        Package "Homebrew.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Some Maintainer (927JGANW46)
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        #expect(GitHubHomebrewPackageSource.isTrustedSignature(trusted))
        #expect(!GitHubHomebrewPackageSource.isTrustedSignature(trusted.replacingOccurrences(of: "927JGANW46", with: "ABCDE12345")))
        #expect(!GitHubHomebrewPackageSource.isTrustedSignature(trusted.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application")))
        #expect(!GitHubHomebrewPackageSource.isTrustedSignature(trusted.replacingOccurrences(of: "trusted by the Apple notary service", with: "not notarized")))
        #expect(!GitHubHomebrewPackageSource.isTrustedSignature("Status: no signature"))
        // The team ID must belong to the leaf certificate, not appear somewhere else.
        let spoofed = trusted.replacingOccurrences(of: "1. Developer ID Installer: Some Maintainer (927JGANW46)", with: "1. Developer ID Installer: Evil (ABCDE12345)\n 4. (927JGANW46)")
        #expect(!GitHubHomebrewPackageSource.isTrustedSignature(spoofed))
    }

    @Test func homebrewReleaseParsing() throws {
        let json = #"""
        {"tag_name": "4.4.0", "assets": [
          {"name": "Homebrew-4.4.0.pkg", "browser_download_url": "https://evil.example.com/Homebrew.pkg"},
          {"name": "notes.txt", "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.4.0/notes.txt"},
          {"name": "Homebrew.pkg", "digest": "sha256:ABCDEF", "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.4.0/Homebrew.pkg"}]}
        """#
        let asset = try GitHubHomebrewPackageSource.parseRelease(Data(json.utf8))
        #expect(asset.url.absoluteString == "https://github.com/Homebrew/brew/releases/download/4.4.0/Homebrew.pkg")
        #expect(asset.sha256 == "abcdef")
        #expect(throws: HomebrewInstallError.releaseInfoUnavailable("no Homebrew.pkg asset")) {
            try GitHubHomebrewPackageSource.parseRelease(Data(#"{"assets": [{"name": "Homebrew.pkg", "browser_download_url": "https://example.com/Homebrew.pkg"}]}"#.utf8))
        }
        #expect(throws: (any Error).self) { try GitHubHomebrewPackageSource.parseRelease(Data("[]".utf8)) }
    }

    @Test func homebrewInstallerVerifiesTheResultAndCleansUp() async throws {
        let sandbox = try Sandbox("brew-installer")
        let simulation = try TestEnvironment.freshMac(sandbox).1
        let installer = HomebrewInstaller(layout: simulation.layout, runner: simulation.makeRunner(),
                                          source: simulation.makeHomebrewSource(), privileged: simulation.makePrivilegedExecutor())
        let installation = try await installer.install(reason: "test", log: LogStore(fileURL: nil, homeDirectory: simulation.layout.homeDirectory))
        #expect(installation.version == "4.4.0")
        // An installer that "succeeds" without producing a working brew is reported, not trusted.
        let sandbox2 = try Sandbox("brew-installer-fake")
        let simulation2 = try TestEnvironment.freshMac(sandbox2).1
        let noop = HomebrewInstaller(layout: simulation2.layout, runner: simulation2.makeRunner(), source: simulation2.makeHomebrewSource(),
                                     privileged: DirectPrivilegedExecutor(packageInstaller: { _ in }))
        await #expect(throws: HomebrewInstallError.notWorkingAfterInstall("brew not found after installation")) {
            _ = try await noop.install(reason: "test", log: LogStore(fileURL: nil, homeDirectory: simulation2.layout.homeDirectory))
        }
    }
}
