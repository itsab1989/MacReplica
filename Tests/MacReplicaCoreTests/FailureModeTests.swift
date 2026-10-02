import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// One test per failure mode from the failure-mode review (docs/FAILURE_MODES.md).
/// Each runs the real engine against a simulated Mac with the failure switched on.
@Suite("Failure modes", .serialized)
struct FailureModeTests {
    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
        let fresh: SimulationRoot
        let target: SimulationEnvironment
    }

    func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox("fm-\(name)")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        return Context(sandbox: sandbox, backup: backup, manifest: manifest, fresh: fresh, target: target)
    }

    func restore(_ c: Context, selection: RestoreSelection = RestoreSelection(), environment: RestoreEnvironment? = nil) async -> RestoreSession {
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let executor = RestoreExecutor(environment: environment ?? TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
        return await executor.run(plan: plan, session: RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)),
                                  onEvent: { _ in })
    }

    func label(_ session: RestoreSession, _ id: String) -> String? { session.results[id]?.outcome.label }

    @Test("Missing Homebrew is installed and verified")
    func missingHomebrew() async throws {
        let c = try await context("missing-brew")
        let session = await restore(c, selection: RestoreSelection(components: [.brewFormulae]))
        #expect(label(session, RestoreItem.homebrewID) == "succeeded")
        #expect(session.results[RestoreItem.homebrewID]?.installedVersion == "4.4.0")
        #expect(FileManager.default.isExecutableFile(atPath: c.fresh.url.appendingPathComponent("opt/homebrew/bin/brew").path))
    }

    @Test("Broken Homebrew is reported and never modified")
    func brokenHomebrew() async throws {
        let c = try await context("broken-brew")
        try FileManager.default.copyItem(at: c.fresh.url.appendingPathComponent("tools/brew"), to: c.fresh.url.appendingPathComponent("opt/homebrew/bin/brew"))
        try c.fresh.setHomebrewBroken(true)
        let session = await restore(c, selection: RestoreSelection(components: [.brewFormulae, .fonts]))
        #expect(label(session, RestoreItem.homebrewID) == "failed(homebrewBroken)")
        #expect(label(session, "formula:git") == "skipped(dependencyFailed(itemTitle: \"Homebrew\"))")
        #expect(!c.fresh.calls().contains { $0.hasPrefix("brew install") })
        #expect(label(session, "font:system/ExampleMono.ttc") == "succeeded")
    }

    @Test("A misleading PATH is never used to find tools")
    func wrongPath() async throws {
        let c = try await context("wrong-path")
        // A fake brew earlier in a polluted PATH must not be picked up.
        let fakeBin = try c.sandbox.folder("evil/bin")
        try Data("#!/bin/sh\necho Homebrew 0.0.1\n".utf8).write(to: fakeBin.appendingPathComponent("brew"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.appendingPathComponent("brew").path)
        setenv("PATH", fakeBin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        defer { setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1) }
        #expect(await HomebrewClient(layout: c.target.layout, runner: c.target.makeRunner()).locate() == .notInstalled)
        let session = await restore(c, selection: RestoreSelection(components: [.brewFormulae]))
        #expect(session.results[RestoreItem.homebrewID]?.installedVersion == "4.4.0")
    }

    @Test("A cask that no longer exists fails with a clear category; others continue")
    func missingCask() async throws {
        let c = try await context("missing-cask")
        try FileManager.default.removeItem(at: c.fresh.state.appendingPathComponent("brew/available/casks/nimbus-notes.json"))
        let session = await restore(c, selection: RestoreSelection(components: [.brewCasks, .applications]))
        #expect(label(session, "cask:nimbus-notes") == "failed(packageNotFound)")
        #expect(label(session, "cask:pixel-forge") == "succeeded")
    }

    @Test("App Store without sign-in does not stop the restore and can be retried")
    func appStoreNotSignedIn() async throws {
        let c = try await context("mas-signin")
        try c.fresh.setAppStoreSignedOut(true)
        let selection = RestoreSelection(components: [.appStore, .fonts])
        let session = await restore(c, selection: selection)
        #expect(label(session, "mas:1234567890") == "failed(appStoreNotSignedIn)")
        #expect(label(session, "font:system/ExampleMono.ttc") == "succeeded")
        try c.fresh.setAppStoreSignedOut(false)
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection).subset(retrying: ["mas:1234567890"])
        let retry = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(label(retry, "mas:1234567890") == "succeeded")
    }

    @Test("Apps without automatic source end up in the manual list")
    func missingApp() async throws {
        let c = try await context("manual")
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection())
        #expect(plan.manualApps.map(\.name) == ["Orbit Browser", "Quill Writer", "Studio Mixer"])
        let html = ReportBuilder(localizer: TestEnvironment.english).manualInstallationsReport(c.manifest)
        #expect(html.contains("Studio Mixer") && html.contains("https://quill.example.com/"))
    }

    @Test("Network errors are classified and retryable")
    func networkError() async throws {
        let c = try await context("network")
        try c.fresh.failOnce("pixel-forge", message: "curl: (6) Could not resolve host: pixelforge.example.com")
        let selection = RestoreSelection(components: [.applications])
        let session = await restore(c, selection: selection)
        #expect(label(session, "cask:pixel-forge") == "failed(network)")
        if case .failed(let failure) = session.results["cask:pixel-forge"]?.outcome {
            #expect(failure.technicalDetail.contains("Could not resolve host"))
        }
        let again = await restore(c, selection: selection)
        #expect(label(again, "cask:pixel-forge") == "succeeded")
        try c.fresh.setOffline(true)
        let offline = await restore(c, selection: RestoreSelection(components: [.brewFormulae]))
        #expect(label(offline, "formula:git") == "failed(network)")
    }

    @Test("Missing administrator rights fail only the affected step")
    func missingAdminRights() async throws {
        let c = try await context("admin")
        let environment = TestEnvironment.restoreEnvironment(c.target, privileged: RecordingPrivileged(grant: false))
        let session = await restore(c, selection: RestoreSelection(components: [.brewFormulae, .fonts]), environment: environment)
        #expect(label(session, RestoreItem.homebrewID) == "failed(adminRightsDenied)")
        #expect(label(session, "font:user/Example Sans/ExampleSans-Bold.otf") == "succeeded")
        // A cask that needs sudo without the askpass helper fails with the admin category.
        let c2 = try await context("admin-cask")
        try c2.fresh.setFlag("needs-admin/pixel-forge", true)
        let s2 = await restore(c2, selection: RestoreSelection(components: [.applications]))
        #expect(label(s2, "cask:pixel-forge") == "failed(adminRightsDenied)")
        let s3 = await restore(c2, selection: RestoreSelection(components: [.applications]),
                               environment: TestEnvironment.restoreEnvironment(c2.target, askpass: "/usr/bin/true"))
        #expect(label(s3, "cask:pixel-forge") == "succeeded")
    }

    @Test("Damaged backups and unknown manifest versions are detected before restoring")
    func damagedBackupAndUnknownVersion() async throws {
        let c = try await context("damaged")
        try Data("x".utf8).write(to: c.backup.appendingPathComponent("icc_profiles/user/Example Fine Art Paper.icm"))
        #expect(BackupVerifier(layout: c.target.layout).verify(backupAt: c.backup).damagedFiles == ["icc_profiles/user/Example Fine Art Paper.icm"])
        try Data(#"{"manifest_version": 99, "applications": []}"#.utf8).write(to: c.backup.appendingPathComponent("manifest.json"))
        let report = BackupVerifier(layout: c.target.layout).verify(backupAt: c.backup)
        #expect(!report.isUsable)
        #expect(report.issues.contains(.unsupportedVersion(found: 99, supported: 1)))
    }

    @Test("Wrong hashes in the target are treated as conflicts, identical files as present")
    func existingFontsAndProfilesAndWrongHashes() async throws {
        let c = try await context("existing")
        let profile = c.fresh.url.appendingPathComponent("home/Library/ColorSync/Profiles/Example Studio Display.icc")
        try FileManager.default.copyItem(at: c.backup.appendingPathComponent("icc_profiles/user/Example Studio Display.icc"), to: profile)
        try Data("different".utf8).write(to: c.fresh.url.appendingPathComponent("home/Library/ColorSync/Profiles/Example Fine Art Paper.icm"))
        let session = await restore(c, selection: RestoreSelection(components: [.fonts, .colorProfiles]))
        #expect(label(session, "icc:user/Example Studio Display.icc") == "alreadyPresent")
        #expect(label(session, "icc:user/Example Fine Art Paper.icm") == "skipped(keptExisting)")
        #expect(label(session, "font:user/ExampleSerif.ttf") == "skipped(keptExisting)")
    }

    @Test("Intel and Apple silicon")
    func architectures() async throws {
        let c = try await context("arch")
        let intel = await restore(c, selection: RestoreSelection(components: [.applications]),
                                  environment: TestEnvironment.restoreEnvironment(c.target, architecture: .x86_64))
        #expect(label(intel, "cask:terminal-plus") == "skipped(incompatibleArchitecture(required: [MacReplicaCore.CPUArchitecture.arm64]))")
        let layout = SystemLayout.live(architecture: .x86_64)
        #expect(layout.homebrewPrefixes == [URL(fileURLWithPath: "/usr/local")])
        #expect(SystemLayout.live(architecture: .arm64).preferredHomebrewPrefix == URL(fileURLWithPath: "/opt/homebrew"))
    }

    @Test("Repeated restores change nothing the second time")
    func repeatedRestore() async throws {
        let c = try await context("repeat")
        var selection = RestoreSelection()
        selection.enabledTaps = ["example/tools"]
        _ = await restore(c, selection: selection)
        c.fresh.clearCalls()
        let second = await restore(c, selection: selection)
        #expect(!second.results.values.contains { $0.outcome == .succeeded || $0.outcome.isFailure })
        #expect(!c.fresh.calls().contains { $0.contains(" install ") || $0.hasPrefix("brew tap example") })
    }

    @Test("Command Line Tools that never finish installing time out cleanly")
    func commandLineToolsTimeout() async throws {
        let c = try await context("clt")
        try c.fresh.setFlag("clt-never", true)
        var environment = TestEnvironment.restoreEnvironment(c.target)
        environment.commandLineToolsTimeout = 0.6
        let session = await restore(c, selection: RestoreSelection(components: [.brewFormulae]), environment: environment)
        #expect(label(session, RestoreItem.commandLineToolsID) == "failed(commandLineToolsUnavailable)")
        #expect(session.status == .completed)
    }
}

@Suite("Error classification and progress")
struct ClassifierAndProgressTests {
    @Test(arguments: [
        ("curl: (6) Could not resolve host: example.com", FailureCategory.network),
        ("Error: Download failed on Cask 'x' with message: Failed to connect", .network),
        ("Error: Not signed in", .appStoreNotSignedIn),
        ("Error: No available formula with the name \"nope\".", .packageNotFound),
        ("Error: Cask 'x' is unavailable: No Cask with this name exists.", .packageNotFound),
        ("sudo: a terminal is required to read the password", .adminRightsDenied),
        ("Error: It seems there is already an App at '/Applications/X.app'.", .appAlreadyExists),
        ("Error: Cask x depends on hardware architecture being one of [arm64]", .incompatible),
        ("Error: No space left on device", .diskFull),
        ("Error: something odd", .unknown),
        ("Error: Cask 'x' failed for a strange reason", .unknown),
    ])
    func classifiesToolOutput(_ output: String, _ expected: FailureCategory) {
        #expect(ErrorClassifier.classify(output, exitCode: 1) == expected)
    }

    @Test func timeoutsWinAndDetailIsTrimmedAndRedacted() {
        #expect(ErrorClassifier.classify("curl: (6)", exitCode: 15, timedOut: true) == .timeout)
        var layout = SystemLayout.live()
        layout.homeDirectory = URL(fileURLWithPath: "/Users/jane")
        let output = (1...20).map { "line \($0) /Users/jane/x" }.joined(separator: "\n") + "\n\n"
        let detail = ErrorClassifier.technicalDetail(output, layout: layout, maxLines: 3)
        #expect(detail == "line 18 ~/x\nline 19 ~/x\nline 20 ~/x")
    }

    @Test func estimatorUsesObservedSpeed() {
        let items = [RestoreItem(id: "a", kind: .cask, title: "A", identifier: "a"),
                     RestoreItem(id: "b", kind: .cask, title: "B", identifier: "b"),
                     RestoreItem(id: "f", kind: .font, title: "F", identifier: "f")]
        var estimator = ProgressEstimator(items: items)
        #expect(estimator.remainingSeconds == nil)
        #expect(estimator.fractionComplete == 0)
        estimator.record(itemID: "f", duration: 0.1, didWork: false)
        #expect(estimator.remainingSeconds == nil, "steps without work do not distort the estimate")
        estimator.record(itemID: "a", duration: 30, didWork: true)
        #expect(estimator.remainingSeconds == 30)
        estimator.record(itemID: "a", duration: 999, didWork: true)
        #expect(estimator.remainingSeconds == 30, "duplicate records are ignored")
        estimator.record(itemID: "unknown", duration: 5, didWork: true)
        estimator.record(itemID: "b", duration: 10, didWork: true)
        #expect(estimator.remainingSeconds == 0)
        #expect(estimator.fractionComplete == 1)
        let resumed = ProgressEstimator(items: items, alreadyFinished: ["a", "zzz"])
        #expect(resumed.remainingWeight == 60.3)
        #expect(ProgressEstimator(items: []).fractionComplete == 1)
    }

    @Test func summaryCounts() {
        let summary = RestoreSummary(results: [
            ItemResult(itemID: "a", outcome: .succeeded), ItemResult(itemID: "b", outcome: .alreadyPresent),
            ItemResult(itemID: "c", outcome: .skipped(.userSkipped)), ItemResult(itemID: "d", outcome: .failed(RestoreFailure(category: .network))),
        ], total: 5)
        #expect(summary == RestoreSummary(results: [], total: 5).replacing(succeeded: 2, failed: 1, skipped: 1))
    }
}

extension RestoreSummary {
    func replacing(succeeded: Int, failed: Int, skipped: Int) -> RestoreSummary {
        var copy = self
        copy.succeeded = succeeded
        copy.failed = failed
        copy.skipped = skipped
        return copy
    }
}

@Suite("Reports")
struct ReportTests {
    @Test func inventoryReportShowsCountsAndSections() {
        let html = ReportBuilder(localizer: TestEnvironment.english).inventoryReport(ManifestTests.sample())
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("MacReplica Inventory"))
        #expect(html.contains("<b>3</b>Applications"))
        #expect(html.contains("Restorable with Homebrew"))
        #expect(html.contains("<code>example-editor</code>"))
        #expect(html.contains("example/tools"))
        #expect(html.contains("prefers-color-scheme: dark"))
    }

    @Test func reportsFollowTheSelectedLanguage() {
        let manifest = ManifestTests.sample()
        let german = ReportBuilder(localizer: Localizer(language: .german)).inventoryReport(manifest)
        #expect(german.contains("<html lang=\"de\">"))
        #expect(german.contains(Localizer(language: .german).t("report.inventory.title")))
        #expect(!german.contains("Restorable with Homebrew"))
        let norwegian = ReportBuilder(localizer: Localizer(language: .norwegianBokmal)).manualInstallationsReport(manifest)
        #expect(norwegian.contains(Localizer(language: .norwegianBokmal).t("report.manual.title")))
        // Machine-readable data stays language independent.
        #expect(String(decoding: try! ManifestIO.encode(manifest), as: UTF8.self).contains("\"restore_method\""))
    }

    @Test func manualReportListsOnlyAppsThatNeedAction() {
        let html = ReportBuilder(localizer: TestEnvironment.english).manualInstallationsReport(ManifestTests.sample())
        #expect(html.contains("Tool"))
        #expect(!html.contains(">Example Editor<"))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(html.contains("Possible Homebrew packages: tool"))
    }

    @Test func dryRunAndRestoreReports() {
        let manifest = ManifestTests.sample()
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        let entries = plan.items.map { DryRunEntry(item: $0, prediction: .willInstall, requiresAdmin: $0.kind == .homebrew, notes: []) }
        let dry = ReportBuilder(localizer: TestEnvironment.english).dryRunReport(entries, manualApps: plan.manualApps, manifest: manifest)
        #expect(dry.contains("Nothing was changed"))
        #expect(dry.contains("Needs your administrator password"))
        var session = RestoreSession(backupPath: "~/b", selection: RestoreSelection(), itemIDs: plan.items.map(\.id))
        session.results["formula:git"] = ItemResult(itemID: "formula:git", outcome: .failed(RestoreFailure(category: .network, technicalDetail: "x")))
        session.results["font:user/A.otf"] = ItemResult(itemID: "font:user/A.otf", outcome: .succeeded, notes: [.identicalFileExists])
        let summary = ReportBuilder(localizer: TestEnvironment.english).restoreSummaryReport(plan: plan, session: session, manifest: manifest)
        #expect(summary.contains("class=\"bad\">No internet connection"))
        #expect(summary.contains("Not done yet"))
        #expect(summary.contains("An identical file was already there."))
    }

    @Test func inventoryCounts() {
        let counts = InventoryCounts(ManifestTests.sample())
        #expect(counts.applications == 3)
        #expect(counts.homebrew == 1)
        #expect(counts.appStore == 1)
        #expect(counts.officialDownload == 1)
        #expect(counts.manual == 0)
        #expect(counts.needsDecision == 1)
        #expect(counts.formulae == 1 && counts.casks == 1 && counts.fonts == 1 && counts.colorProfiles == 1)
    }
}
