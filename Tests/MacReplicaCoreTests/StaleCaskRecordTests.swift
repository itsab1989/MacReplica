import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A tester restored everything except the apps from Time Machine, then restored with MacReplica (2026-11-03,
/// docs/TESTER_FEEDBACK_1.1.0.md): Time Machine had brought back Homebrew's records (`/opt/homebrew/Caskroom`), so
/// Homebrew listed the casks as installed although their apps (dangling links in the Caskroom) and packages (no
/// receipts) were missing; `brew install` answered "already installed" and MacReplica reported success.
/// Reproduced with Homebrew 7.0.12: `brew install --cask` and `--force` install nothing, `brew reinstall --cask` does.
@Suite("Casks Homebrew lists without their apps or packages", .serialized)
struct StaleCaskRecordTests {
    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
        let fresh: SimulationRoot
        let target: SimulationEnvironment
    }

    static let packageCask = BrewCaskRecord(token: "sound-bridge", version: "0.5.0")

    func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox("stale-cask-\(name)")
        var (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        manifest.brewCasks.append(Self.packageCask)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let bin = fresh.url.appendingPathComponent("opt/homebrew/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.url.appendingPathComponent("tools/brew"), to: bin.appendingPathComponent("brew"))
        // A cask that installs only a package, like background-music or microsoft-teams.
        try #"{"version": "0.5.0", "app": "", "bundle_id": "", "pkg": "SoundBridge-0.5.0.pkg", "pkgutil": "com.example.soundbridge"}"#
            .write(to: fresh.state.appendingPathComponent("brew/available/casks/sound-bridge.json"), atomically: true, encoding: .utf8)
        return Context(sandbox: sandbox, backup: backup, manifest: manifest, fresh: fresh, target: target)
    }

    /// What Time Machine brings back: Homebrew's record of the cask, nothing else.
    func recordOnly(_ c: Context, _ token: String, version: String) throws {
        try c.fresh.setFlag("brew/casks/\(token)", true, content: version)
    }

    func app(_ c: Context, _ name: String) -> URL { c.target.layout.applicationFolders[0].appendingPathComponent(name) }

    func restore(_ c: Context) async -> RestoreSession {
        let selection = RestoreSelection(components: [.brewCasks, .applications])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        return await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    @Test("A cask Homebrew lists but whose app is missing is reinstalled, not reported as already installed")
    func missingAppIsReinstalled() async throws {
        let c = try await context("app")
        try recordOnly(c, "pixel-forge", version: "2.4.1")
        #expect(!FileManager.default.fileExists(atPath: app(c, "Pixel Forge.app").path))
        let result = await restore(c).results["cask:pixel-forge"]
        #expect(result?.outcome == .succeeded, "\(result?.outcome.label ?? "-")")
        #expect(result?.notes.contains(.reinstalledMissingParts(parts: "Pixel Forge.app")) == true)
        #expect(c.fresh.calls().contains("brew reinstall --cask pixel-forge"))
        #expect(FileManager.default.fileExists(atPath: app(c, "Pixel Forge.app/Contents/Info.plist").path))
    }

    @Test("A cask whose app is there stays 'already installed' and is not reinstalled")
    func presentAppIsLeftAlone() async throws {
        let c = try await context("present")
        try recordOnly(c, "pixel-forge", version: "2.4.1")
        let bundle = app(c, "Pixel Forge.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.pixelforge", "CFBundleShortVersionString": "2.4.1"],
                                           format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let result = await restore(c).results["cask:pixel-forge"]
        #expect(result?.outcome == .alreadyPresent)
        #expect(!c.fresh.calls().contains { $0.hasPrefix("brew reinstall") })
    }

    @Test("If the reinstall does not bring the app back, the step fails instead of succeeding")
    func reinstallWithoutAppFails() async throws {
        let c = try await context("still-missing")
        try recordOnly(c, "pixel-forge", version: "2.4.1")
        try c.fresh.setFlag("reinstall-keeps-app", true)
        let result = await restore(c).results["cask:pixel-forge"]
        #expect(result?.outcome.label == "failed(verificationFailed)", "\(result?.outcome.label ?? "-")")
    }

    @Test("A package cask Homebrew lists without the package's receipt is reinstalled")
    func missingPackageIsReinstalled() async throws {
        let c = try await context("pkg")
        try recordOnly(c, "sound-bridge", version: "0.5.0")
        let result = await restore(c).results["cask:sound-bridge"]
        #expect(result?.outcome == .succeeded, "\(result?.outcome.label ?? "-")")
        #expect(result?.notes.contains(.reinstalledMissingParts(parts: "SoundBridge-0.5.0.pkg")) == true)
        #expect(FileManager.default.fileExists(atPath: c.fresh.state.appendingPathComponent("receipts/com.example.soundbridge").path))
    }

    @Test("A package cask whose receipt is installed stays 'already installed'")
    func installedPackageIsLeftAlone() async throws {
        let c = try await context("pkg-present")
        try recordOnly(c, "sound-bridge", version: "0.5.0")
        try c.fresh.setFlag("receipts/com.example.soundbridge", true)
        let result = await restore(c).results["cask:sound-bridge"]
        #expect(result?.outcome == .alreadyPresent)
        #expect(!c.fresh.calls().contains { $0.hasPrefix("brew reinstall") })
    }

    @Test("A fresh package install that leaves no receipt fails verification")
    func packageWithoutReceiptFailsVerification() async throws {
        let c = try await context("pkg-no-receipt")
        try c.fresh.setFlag("pkg-leaves-no-receipt", true)
        let result = await restore(c).results["cask:sound-bridge"]
        #expect(result?.outcome.label == "failed(verificationFailed)", "\(result?.outcome.label ?? "-")")
    }

    @Test("The full dry run announces an install for a cask whose app is missing")
    func dryRunPredictsInstall() async throws {
        let c = try await context("dry-run")
        try recordOnly(c, "pixel-forge", version: "2.4.1")
        try recordOnly(c, "sound-bridge", version: "0.5.0")
        let selection = RestoreSelection(components: [.brewCasks, .applications])
        let entries = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .dryRun(plan: RestorePlanner().plan(manifest: c.manifest, selection: selection), selection: selection)
        #expect(entries.first { $0.id == "cask:pixel-forge" }?.prediction == .willInstall)
        #expect(entries.first { $0.id == "cask:sound-bridge" }?.prediction == .willInstall)
    }

    // MARK: Reading Homebrew's definitions

    @Test("Apps, targets, packages and receipts are read from Homebrew 7's cask JSON")
    func parsesHomebrewSevenJSON() throws {
        // Shapes as printed by Homebrew 7.0.12 for keycastr, microsoft-teams and a renamed app (2026-11-03).
        let json = #"""
        {"casks":[{"token":"x","artifacts":[
          {"uninstall":[{"launchctl":"com.microsoft.teams.TeamsUpdaterDaemon","pkgutil":["com.microsoft.MSTeamsAudioDevice","com.microsoft.teams2"]}]},
          {"pkg":["MicrosoftTeams.pkg",{"choices":[{"choiceIdentifier":"com.microsoft.autoupdate","choiceAttribute":"selected","attributeSetting":0}]}]},
          {"app":["KeyCastr.app"],"target":"/Applications/KeyCastr.app"},
          {"app":["Foo.app",{"target":"Bar.app"}]},
          {"uninstall":[{"pkgutil":"com.adguard.mac.adguard-pkg"}]},
          {"zap":[{"trash":["~/Library/Preferences/io.github.keycastr.plist"]}]}
        ]}]}
        """#
        let contents = try #require(HomebrewClient.parseCaskContents(Data(json.utf8)))
        #expect(contents.appNames == ["KeyCastr.app", "Bar.app"])
        #expect(contents.appTargets == ["/Applications/KeyCastr.app"])
        #expect(contents.packages == ["MicrosoftTeams.pkg"])
        #expect(contents.receipts == ["com.microsoft.MSTeamsAudioDevice", "com.microsoft.teams2", "com.adguard.mac.adguard-pkg"])
        #expect(HomebrewClient.parseCaskContents(Data("{}".utf8)) == nil)
        #expect(HomebrewClient.parseCaskContents(Data(#"{"casks":[{"token":"y"}]}"#.utf8)) == CaskContents())
    }

    @Test("Receipts are asked for with pkgutil's own patterns: whole IDs, * and ?, case-sensitive")
    func receiptMatching() async throws {
        let c = try await context("receipts")
        for id in ["com.microsoft.teams2", "com.microsoft.dotnet.dev.10.0.403.component.osx.arm64"] { try c.fresh.setFlag("receipts/\(id)", true) }
        let client = TestEnvironment.restoreEnvironment(c.target).homebrew
        #expect(await client.hasReceipt(matching: ["com.microsoft.MSTeamsAudioDevice", "com.microsoft.teams2"]) == true)
        #expect(await client.hasReceipt(matching: ["com.microsoft.dotnet.*10.0*arm64"]) == true, "dotnet-sdk's pattern")
        #expect(await client.hasReceipt(matching: ["com.microsoft.teams?"]) == true)
        #expect(await client.hasReceipt(matching: ["com.microsoft.teams"]) == false, "a prefix is not a match")
        #expect(await client.hasReceipt(matching: ["COM.microsoft.teams2"]) == false)
        #expect(await client.hasReceipt(matching: []) == nil, "nothing to ask: cannot tell")
        #expect(c.fresh.calls().contains("pkgutil --pkgs=com.microsoft.dotnet.*10.0*arm64"))
    }

    @Test("A cask that needs a newer macOS is reported as not compatible, not as an unknown error")
    func newerMacOSIsIncompatible() {
        // The tester's output for rawtherapee on macOS 14.8.9 (Homebrew 6+, 2026-11-03), tap-trust notice included.
        let output = """
        casks and commands from the listed taps. Trust whole taps with:
        brew trust borgbackup/tap
        Error: rawtherapee: rawtherapee: This cask does not run on macOS versions older than Tahoe.
        Error: rawtherapee: rawtherapee: This cask does not run on macOS versions older than Tahoe.
        This is a Tier 3 configuration:
        """
        #expect(ErrorClassifier.classify(output, exitCode: 1) == .incompatible)
    }
}
