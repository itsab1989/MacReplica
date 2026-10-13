import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.4: Cakebrew (its cask removed from Homebrew), DisplayCAL (cask disabled, eight apps in one
/// folder) and ChromIQ (cask only in the developer's tap). Homebrew must never be promised where it cannot install.
@Suite("Homebrew availability, taps and companion apps")
struct HomebrewAvailabilityTests {
    /// The full name of the ChromIQ cask in its vendor tap.
    static let chromiqCask = ["itsab1989", "chromiq", "chromiq"].joined(separator: "/")
    static func inventory(_ sandbox: Sandbox) async throws -> (SimulationRoot, SimulationEnvironment, InventoryResult) {
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addBetaFeedbackApps()
        return (root, source, try await TestEnvironment.inventory(source).run())
    }

    @Test func availabilityIsReadFromHomebrew() throws {
        // The shape Homebrew 5 printed for an installed cask whose definition was removed (checked on 2026-10-13).
        let removed: [String: Any] = ["token": "gone-tool", "full_token": "gone-tool", "tap": NSNull(), "url": "", "installed": "1.0",
                                      "artifacts": [["app": ["Gone Tool.app"]]]]
        #expect(HomebrewClient.availability(removed) == CaskAvailability(state: .removed))
        let disabled: [String: Any] = ["token": "displaycal", "tap": "homebrew/cask", "url": "https://x/y.pkg", "disabled": true,
                                       "disable_reason": "fails_gatekeeper_check", "disable_date": "2026-09-01"]
        #expect(HomebrewClient.availability(disabled) == CaskAvailability(state: .disabled, reason: "fails_gatekeeper_check", date: "2026-09-01"))
        #expect(HomebrewClient.availability(["token": "x", "tap": "homebrew/cask", "url": "https://x", "deprecated": true]).state == .deprecated)
        #expect(HomebrewClient.availability(["token": "x", "tap": "homebrew/cask", "url": "https://x"]).state == .available)
        #expect(CaskAvailability(state: .deprecated).isInstallable && !CaskAvailability(state: .removed).isInstallable)
        #expect(BrewCaskRecord(token: "old", version: "1").isInstallable, "backups of 1.0.4 have no availability: assumed installable")
        #expect(BrewTapRecord.tapName(ofToken: Self.chromiqCask) == "itsab1989/chromiq" && BrewTapRecord.tapName(ofToken: "firefox") == nil)
    }

    @Test func removedAndDisabledCasksAreExplainedNotPromised() async throws {
        let sandbox = try Sandbox("brew-availability")
        let (_, _, result) = try await Self.inventory(sandbox)
        let apps = result.manifest.applications
        let cakebrew = try #require(apps.first { $0.bundleIdentifier == "com.brunophilipe.Cakebrew" })
        #expect(cakebrew.source == .homebrewCask(token: "cakebrew") && cakebrew.restoreMethod == .manual, "installed with Homebrew, but not restorable with it")
        #expect(cakebrew.homebrewNote?.availability.state == .removed)
        let displaycal = try #require(apps.first { $0.bundleIdentifier == "net.displaycal.DisplayCAL" })
        #expect(displaycal.homebrewNote == HomebrewNote(token: "displaycal", availability: CaskAvailability(state: .disabled, reason: "fails_gatekeeper_check", date: "2026-09-01")))
        #expect(displaycal.restoreMethod.category != .homebrew)
        let l = TestEnvironment.english
        #expect(l.homebrewNoteText(cakebrew.homebrewNote!).contains("was removed from Homebrew"))
        #expect(l.homebrewNoteText(displaycal.homebrewNote!).contains("disabled on 2026-09-01 (it does not pass Apple's Gatekeeper check)"))

        // Restore plan: no `brew install --cask cakebrew`; both are guided installations instead.
        let plan = RestorePlanner().plan(manifest: result.manifest, selection: RestoreSelection(components: [.applications, .brewCasks]))
        #expect(!plan.items.contains { $0.identifier == "cakebrew" && $0.kind == .cask })
        #expect(plan.items.contains { $0.kind == .manualApp && $0.bundleIdentifier == "com.brunophilipe.Cakebrew" })
        #expect(plan.items.contains { $0.kind == .manualApp && $0.bundleIdentifier == "net.displaycal.DisplayCAL" })
    }

    @Test func companionAppsComeWithTheirMainApp() async throws {
        let sandbox = try Sandbox("brew-companions")
        let (_, _, result) = try await Self.inventory(sandbox)
        let apps = result.manifest.applications
        let main = try #require(apps.first { $0.bundleIdentifier == "net.displaycal.DisplayCAL" })
        let companions = apps.filter { $0.companionOf == main.id }
        #expect(Set(companions.compactMap(\.bundleIdentifier)) == ["net.displaycal.DisplayCAL-3DLUT-maker", "net.displaycal.DisplayCAL-curve-viewer"])
        #expect(main.suiteFolderName == "DisplayCAL" && main.companionOf == nil)
        let plan = RestorePlanner().plan(manifest: result.manifest, selection: RestoreSelection(components: [.applications]))
        let manual = plan.items.filter { $0.kind == .manualApp }.compactMap(\.bundleIdentifier)
        #expect(manual.contains("net.displaycal.DisplayCAL") && !manual.contains("net.displaycal.DisplayCAL-3DLUT-maker"),
                "installed with DisplayCAL, not a separate step")
        // Without the main app in the backup, a companion is restored on its own.
        var withoutMain = result
        withoutMain.excludeApplications([main.id])
        let alone = RestorePlanner().plan(manifest: withoutMain.manifest, selection: RestoreSelection(components: [.applications]))
        #expect(alone.items.contains { $0.bundleIdentifier == "net.displaycal.DisplayCAL-3DLUT-maker" })
        // Apps from the same developer that are not in one suite folder are not grouped.
        #expect(apps.first { $0.bundleIdentifier == "com.example.pixelforge" }?.companionOf == nil)
    }

    @Test func casksFromTapsAndVendorTapsAreFound() async throws {
        let sandbox = try Sandbox("brew-taps")
        let (_, _, result) = try await Self.inventory(sandbox)
        let apps = result.manifest.applications
        // A tap set up on this Mac: its casks are matched like Homebrew's own.
        #expect(apps.first { $0.bundleIdentifier == "com.example.taptool" }?.restoreMethod == .homebrewCask(token: "example/tools/tap-tool"))
        // ChromIQ: the developer's own tap, suggested and recorded so it can be allowed on the new Mac.
        #expect(apps.first { $0.bundleIdentifier == "com.chromiq.app" }?.restoreMethod == .homebrewCask(token: Self.chromiqCask))
        let tap = try #require(result.manifest.brewTaps.first { $0.name == "itsab1989/chromiq" })
        #expect(tap.remote == "https://github.com/itsab1989/homebrew-chromiq" && tap.suggestedFor == ["ChromIQ"])
        // The restore installs them only from an allowed tap.
        let selection = RestoreSelection(components: [.applications, .brewCasks, .brewFormulae])
        let plan = RestorePlanner().plan(manifest: result.manifest, selection: selection)
        let chromiq = try #require(plan.items.first { $0.identifier == "itsab1989/chromiq/chromiq" })
        #expect(chromiq.dependsOn.contains("tap:itsab1989/chromiq") && plan.items.contains { $0.id == "tap:itsab1989/chromiq" })
        #expect(plan.items.first { $0.identifier == "example/tools/tap-tool" }?.dependsOn.contains("tap:example/tools") == true)
    }

    @Test func vendorTapFollowsTheInstalledChannel() {
        var beta = AppRecord(name: "ChromIQ", version: "4.3.5-beta.2", bundleIdentifier: "com.chromiq.app", path: "/Applications/ChromIQ.app")
        beta.channel = .beta
        var stable = beta
        stable.channel = nil
        var apps = [beta]
        var taps: [BrewTapRecord] = []
        InventoryService.applyVendorTaps(to: &apps, taps: &taps)
        #expect(apps[0].restoreMethod == .homebrewCask(token: "itsab1989/chromiq/chromiq@beta"), "a beta stays on the beta channel")
        apps = [stable]
        InventoryService.applyVendorTaps(to: &apps, taps: &taps)
        #expect(apps[0].restoreMethod == .homebrewCask(token: Self.chromiqCask), "a stable install never becomes a beta")
        #expect(taps.count == 1, "the tap is recorded once")
    }

    @Test func homebrewFrontEndsAreNotHomebrew() async throws {
        let sandbox = try Sandbox("brew-frontends")
        let (_, _, result) = try await Self.inventory(sandbox)
        let cakebrew = try #require(result.manifest.applications.first { $0.bundleIdentifier == "com.brunophilipe.Cakebrew" })
        let frontEnd = try #require(PackageManagerFrontEnds.frontEnd(for: cakebrew))
        let l = TestEnvironment.english
        #expect(l.frontEndText(frontEnd, manifest: result.manifest).contains("does not restore Homebrew or your packages"))
        #expect(!result.manifest.brewFormulae.isEmpty, "Homebrew's own packages are recorded independently of Cakebrew")
        var withoutHomebrew = result.manifest
        withoutHomebrew.homebrew = nil
        #expect(l.frontEndText(frontEnd, manifest: withoutHomebrew).contains("This app alone does not install Homebrew"))
        #expect(PackageManagerFrontEnds.frontEnd(for: AppRecord(name: "Pixel Forge", bundleIdentifier: "com.example.pixelforge", path: "/x")) == nil)
    }

    /// `brew list --cask --versions user/tap/token` fails in Homebrew 5 even when the cask is installed: tap casks were
    /// reported as failed after a successful installation. They are checked by their short token now.
    @Test func casksFromTapsAreInstalledAndVerified() async throws {
        let sandbox = try Sandbox("brew-tap-restore")
        let (_, source, result) = try await Self.inventory(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        for (path, spec) in [("itsab1989/chromiq/chromiq", #"{"version": "4.3.4", "app": "ChromIQ.app", "bundle_id": "com.chromiq.app"}"#),
                             ("example/tools/tap-tool", #"{"version": "2.1", "app": "Tap Tool.app", "bundle_id": "com.example.taptool"}"#)] {
            let url = fresh.state.appendingPathComponent("brew/available/casks/\(path).json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(spec.utf8).write(to: url)
        }
        _ = source
        let selection = RestoreSelection(components: [.applications, .brewCasks], enabledTaps: ["itsab1989/chromiq"])
        let plan = RestorePlanner().plan(manifest: result.manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: try sandbox.folder("no-backup"), sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["cask:itsab1989/chromiq/chromiq"]?.outcome == .succeeded, "installed from the allowed tap and verified")
        #expect(session.results["cask:example/tools/tap-tool"]?.outcome.isFailure == false, "a tap that was not allowed is skipped, not failed")
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("Applications/ChromIQ.app").path))
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("Applications/Tap Tool.app").path))
        #expect(HomebrewClient.shortToken("itsab1989/chromiq/chromiq@beta") == "chromiq@beta" && HomebrewClient.shortToken("firefox") == "firefox")
    }
}

/// End-to-end finding (real Homebrew 7, 2026-10-14): a developer tap MacReplica documents must start allowed, or the
/// app's restore is skipped; any other third-party tap still waits for the user.
@Suite("Homebrew: documented developer taps")
struct DocumentedTapTests {
    @Test func documentedTapsStartAllowedOnlyWithTheirAddress() {
        var manifest = Manifest(macreplicaVersion: "1.0.6", createdAt: Date(), macosVersion: "27.0", architecture: .arm64)
        manifest.brewTaps = [BrewTapRecord(name: "itsab1989/chromiq", remote: "https://github.com/itsab1989/homebrew-chromiq"),
                             BrewTapRecord(name: "someone/tools", remote: "https://github.com/someone/homebrew-tools")]
        #expect(VendorTaps.defaultEnabledTaps(manifest) == ["itsab1989/chromiq"])
        manifest.brewTaps = [BrewTapRecord(name: "ItsAB1989/ChromIQ", remote: nil)]
        #expect(VendorTaps.defaultEnabledTaps(manifest) == ["itsab1989/chromiq"], "Homebrew's default remote for the name")
        manifest.brewTaps = [BrewTapRecord(name: "itsab1989/chromiq", remote: "https://example.com/evil/homebrew-chromiq")]
        #expect(VendorTaps.defaultEnabledTaps(manifest).isEmpty, "another address is treated like any third-party tap")
        #expect(VendorTaps.defaultEnabledTaps(Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "27", architecture: .arm64)).isEmpty)
    }
}
