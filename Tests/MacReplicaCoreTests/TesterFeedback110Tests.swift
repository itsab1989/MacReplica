import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A tester's restore with MacReplica 1.1.0 on an Intel Mac (macOS 14) after a clean reinstall, with the home folder
/// brought back from Time Machine first (docs/TESTER_FEEDBACK_1.1.0.md). Each test fails without its fix.
@Suite("Tester feedback on 1.1.0", .serialized)
struct TesterFeedback110Tests {
    struct Context {
        let sandbox: Sandbox
        let backup: URL
        let manifest: Manifest
        let fresh: SimulationRoot
        let target: SimulationEnvironment
    }

    func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox("tf110-\(name)")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        return Context(sandbox: sandbox, backup: backup, manifest: manifest, fresh: fresh, target: target)
    }

    func restore(_ c: Context, selection: RestoreSelection, manifest: Manifest? = nil, privileged: PrivilegedExecuting? = nil,
                 session: RestoreSession? = nil) async -> RestoreSession {
        let plan = RestorePlanner().plan(manifest: manifest ?? c.manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target, privileged: privileged),
                                       backupRoot: c.backup, sessionStore: nil)
        return await executor.run(plan: plan, session: session ?? RestoreSession(backupPath: c.backup.path, selection: selection,
                                                                                 itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    func label(_ session: RestoreSession, _ id: String) -> String? { session.results[id]?.outcome.label }

    /// Homebrew that is already there – like one Time Machine brought back – instead of a fresh installation.
    func preinstallHomebrew(_ c: Context) throws {
        let bin = c.fresh.url.appendingPathComponent("opt/homebrew/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: c.fresh.url.appendingPathComponent("tools/brew"), to: bin.appendingPathComponent("brew"))
    }

    // MARK: Outdated Homebrew (13 casks failed with "Unexpected method … called on Cask")

    @Test("The tester's Homebrew errors are recognised as an outdated Homebrew, not as unknown")
    func outdatedHomebrewIsClassified() {
        let samples = [
            "Error: Unexpected method 'postflight_steps' called on Cask chromiq.\nFollow the instructions here:\nhttps://github.com/Homebrew/homebrew-cask#reporting-bugs",
            "Error: Unexpected method 'command_wrapper' called on Cask gimp.",
            "/usr/local/Homebrew/Library/Homebrew/brew.rb:102:in '<main>'\nYou have disabled automatic updates and have not updated today.\nDo not report this issue until you've run `brew update` and tried again.",
        ]
        for sample in samples {
            #expect(ErrorClassifier.classify(sample, exitCode: 1) == .homebrewOutdated)
            #expect(HomebrewClient.isOutdatedHomebrewOutput(sample))
        }
        // A plain Ruby error alone is no evidence of an old Homebrew.
        #expect(ErrorClassifier.classify("Error: undefined method 'first' for nil", exitCode: 1) == .unknown)
        #expect(!HomebrewClient.isOutdatedHomebrewOutput("Error: undefined method 'first' for nil"))
        #expect(ErrorClassifier.classify("Error: No available cask with the name \"x\".", exitCode: 1) == .packageNotFound)
    }

    @Test("An outdated Homebrew is updated once, then the casks install")
    func outdatedHomebrewIsUpdatedOnce() async throws {
        let c = try await context("outdated")
        try preinstallHomebrew(c)
        try c.fresh.setHomebrewOutdated(true)
        let session = await restore(c, selection: RestoreSelection(components: [.brewCasks, .applications]))
        #expect(label(session, RestoreItem.homebrewID) == "alreadyPresent")
        let casks = session.results.filter { $0.key.hasPrefix("cask:") }
        #expect(casks.count >= 2)
        #expect(casks.values.allSatisfy { $0.outcome == .succeeded }, "\(casks.mapValues(\.outcome.label))")
        #expect(c.fresh.calls().filter { $0 == "brew update" }.count == 1)
        #expect(casks.values.contains { $0.notes.contains(.homebrewUpdated(version: "5.0.1")) })
    }

    @Test("When brew update does not help, the casks fail as 'Homebrew is too old' and it is not run again")
    func failingUpdateIsReportedHonestly() async throws {
        let c = try await context("outdated-fails")
        try preinstallHomebrew(c)
        try c.fresh.setHomebrewOutdated(true, failingUpdate: true)
        let session = await restore(c, selection: RestoreSelection(components: [.brewCasks, .applications]))
        let casks = session.results.filter { $0.key.hasPrefix("cask:") }
        #expect(!casks.isEmpty)
        #expect(casks.values.allSatisfy { $0.outcome.label == "failed(homebrewOutdated)" }, "\(casks.mapValues(\.outcome.label))")
        #expect(c.fresh.calls().filter { $0 == "brew update" }.count == 1)
    }

    @Test("A working Homebrew is never updated")
    func currentHomebrewIsLeftAlone() async throws {
        let c = try await context("current")
        try preinstallHomebrew(c)
        let session = await restore(c, selection: RestoreSelection(components: [.brewCasks, .applications]))
        #expect(session.results.filter { $0.key.hasPrefix("cask:") }.values.allSatisfy { $0.outcome == .succeeded })
        #expect(!c.fresh.calls().contains("brew update"))
    }

    // MARK: Administrator copy (52 profiles: "install: <backup>/…: Operation not permitted")

    /// Behaves like root on the tester's Mac: it may not read the backup drive (a share or volume the user mounted).
    final class RootLikeExecutor: PrivilegedExecuting, @unchecked Sendable {
        let backupRoot: URL
        /// Fail after this many installed files (nil: never).
        let stopAfter: Int?
        private let lock = NSLock()
        private var _sources: [URL] = []
        var sources: [URL] { lock.withLock { _sources } }

        init(backupRoot: URL, stopAfter: Int? = nil) {
            self.backupRoot = backupRoot
            self.stopAfter = stopAfter
        }

        func run(_ operations: [PrivilegedOperation], reason: String) async throws {
            let fm = FileManager.default
            var installed = 0
            for operation in operations {
                switch operation {
                case .createFolder(let url):
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                case .move(let source, let destination):
                    try fm.moveItem(at: source, to: destination)
                case .installFile(let source, let destination):
                    lock.withLock { _sources.append(source) }
                    if source.standardizedFileURL.path.hasPrefix(backupRoot.standardizedFileURL.path + "/") {
                        throw PrivilegedError.failed("572:652: execution error: install: \(source.path): Operation not permitted (71)")
                    }
                    if let stopAfter, installed == stopAfter {
                        throw PrivilegedError.failed("install: \(destination.path): Operation not permitted (71)")
                    }
                    let folder = destination.deletingLastPathComponent()
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
                    defer { try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: source, to: destination)
                    installed += 1
                default:
                    throw PrivilegedError.failed("unexpected operation")
                }
            }
        }
    }

    /// Makes the shared font and profile folders of the simulated Mac need administrator rights.
    func lockSharedFolders(_ c: Context) throws -> [URL] {
        let folders = [c.target.layout.systemFonts, c.target.layout.systemColorProfiles]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        return folders
    }

    func unlock(_ folders: [URL]) {
        for folder in folders { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    }

    func sharedFileIDs(_ session: RestoreSession) -> [String] {
        session.results.keys.filter { $0.hasPrefix("font:system/") || $0.hasPrefix("icc:system/") }.sorted()
    }

    @Test("Files for shared folders are installed from a checked local copy, never read from the backup as root")
    func administratorCopyDoesNotReadTheBackup() async throws {
        let c = try await context("admin-copy")
        let folders = try lockSharedFolders(c)
        defer { unlock(folders) }
        let root = RootLikeExecutor(backupRoot: c.backup)
        let session = await restore(c, selection: RestoreSelection(components: [.fonts, .colorProfiles]), privileged: root)
        #expect(!root.sources.isEmpty, "the shared folders needed administrator rights")
        let copied = sharedFileIDs(session).filter { session.results[$0]?.outcome == .succeeded }
        #expect(copied.count == root.sources.count, "\(sharedFileIDs(session).map { "\($0): \(label(session, $0) ?? "-")" })")
        #expect(root.sources.allSatisfy { !$0.path.hasPrefix(c.backup.path) })
        // The local copies are removed again.
        let work = c.target.layout.caches.appendingPathComponent("Work")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("admin-copy-") })
    }

    @Test("When the administrator copy stops part-way, files already in place count as restored, the rest as failed")
    func partialAdministratorCopyIsCountedByWhatIsOnDisk() async throws {
        let c = try await context("admin-partial")
        let folders = try lockSharedFolders(c)
        defer { unlock(folders) }
        let root = RootLikeExecutor(backupRoot: c.backup, stopAfter: 1)
        let session = await restore(c, selection: RestoreSelection(components: [.fonts, .colorProfiles]), privileged: root)
        #expect(root.sources.count >= 2, "needs at least two files for shared folders")
        let attempted = Set(root.sources.map(\.lastPathComponent))
        let outcomes = sharedFileIDs(session).filter { attempted.contains(URL(fileURLWithPath: $0).lastPathComponent) }
            .compactMap { session.results[$0]?.outcome.label }
        #expect(outcomes.filter { $0 == "succeeded" }.count == 1)
        #expect(outcomes.filter { $0 == "failed(permissionDenied)" }.count == root.sources.count - 1, "\(outcomes)")
    }

    @Test("A file whose local copy cannot be prepared fails on its own, with that reason, and is never installed")
    func localCopyThatCannotBePrepared() async throws {
        let c = try await context("admin-prepare")
        let folders = try lockSharedFolders(c)
        defer { unlock(folders) }
        // A file where the work folder should be: no local copy can be made.
        try FileManager.default.createDirectory(at: c.target.layout.caches, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: c.target.layout.caches.appendingPathComponent("Work"))
        let root = RootLikeExecutor(backupRoot: c.backup)
        let session = await restore(c, selection: RestoreSelection(components: [.fonts, .colorProfiles]), privileged: root)
        #expect(root.sources.isEmpty, "nothing reaches the administrator copy")
        let shared = sharedFileIDs(session).compactMap { session.results[$0] }.filter { $0.outcome.isFailure }
        #expect(!shared.isEmpty)
        for result in shared {
            guard case .failed(let failure) = result.outcome else { continue }
            #expect(failure.technicalDetail.contains("could not prepare the copy"), "\(failure.technicalDetail)")
        }
    }

    // MARK: "Damaged in the backup" on retry

    @Test("A backup copy that cannot be found is 'could not be read', not 'damaged'; changed bytes are 'damaged'")
    func unreachableIsNotDamaged() async throws {
        let c = try await context("unreachable")
        let fonts = c.manifest.fonts.filter { $0.domain == .user }
        #expect(fonts.count >= 2)
        let missing = fonts[0], changed = fonts[1]
        try FileManager.default.removeItem(at: c.backup.appendingPathComponent(missing.backupPath))
        try Data("not the font".utf8).write(to: c.backup.appendingPathComponent(changed.backupPath))
        let session = await restore(c, selection: RestoreSelection(components: [.fonts]))
        let missingResult = session.results.first { $0.key.hasSuffix("/" + missing.relativePath) }?.value
        let changedResult = session.results.first { $0.key.hasSuffix("/" + changed.relativePath) }?.value
        #expect(missingResult?.outcome.label == "failed(backupUnreachable)")
        if case .failed(let failure) = missingResult?.outcome { #expect(failure.technicalDetail.hasPrefix("not found in the backup: ")) }
        #expect(changedResult?.outcome.label == "failed(backupFileDamaged)")
    }

    @Test("Without the backup drive, every file says the backup is not reachable")
    func disconnectedBackupDrive() async throws {
        let c = try await context("disconnected")
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.fonts]))
        let moved = c.backup.deletingLastPathComponent().appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: c.backup, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: c.backup) }
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: c.backup.path, selection: RestoreSelection(components: [.fonts]),
                                                                             itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        let fonts = session.results.filter { $0.key.hasPrefix("font:") }.values
        #expect(!fonts.isEmpty)
        for result in fonts {
            guard case .failed(let failure) = result.outcome else { Issue.record("not failed: \(result.outcome.label)"); continue }
            #expect(failure.category == .backupUnreachable)
            #expect(failure.technicalDetail.hasPrefix("backup not reachable: "))
        }
    }

    // MARK: Retry Failed Items keeps the restore together

    @Test("Retry keeps successes and guided steps, and retries failed steps and those that waited on them")
    func preparedForRetry() {
        var session = RestoreSession(backupPath: "~/B", selection: RestoreSelection(), itemIDs: ["a", "b", "c", "d", "e"])
        session.results["a"] = ItemResult(itemID: "a", outcome: .succeeded)
        session.results["b"] = ItemResult(itemID: "b", outcome: .failed(RestoreFailure(category: .homebrewOutdated)))
        session.results["c"] = ItemResult(itemID: "c", outcome: .skipped(.dependencyFailed(itemTitle: "b")))
        session.results["d"] = ItemResult(itemID: "d", outcome: .skipped(.manualStepRequired))
        session.results["e"] = ItemResult(itemID: "e", outcome: .skipped(.userSkipped))
        session.status = .completed
        #expect(session.retryableItemIDs == ["b", "c"])
        let retry = session.preparedForRetry()
        #expect(retry.id == session.id, "the same session, not a new one")
        #expect(retry.status == .inProgress)
        #expect(retry.results["a"]?.outcome == .succeeded)
        #expect(retry.results["b"] == nil && retry.results["c"] == nil)
        #expect(retry.results["d"]?.outcome == .skipped(.manualStepRequired))
        #expect(retry.results["e"]?.outcome == .skipped(.userSkipped))
        #expect(retry.remainingItemIDs == ["b", "c", "d"])
    }

    @Test("A retry in the same session fixes the failed cask and leaves every earlier result in place")
    func retryInTheSameSession() async throws {
        let c = try await context("retry")
        try c.fresh.failOnce("pixel-forge", message: "Error: Unexpected method 'postflight_steps' called on Cask pixel-forge.")
        try c.fresh.setFlag("brew-update-fails", true)
        let selection = RestoreSelection(components: [.brewCasks, .applications, .fonts])
        let first = await restore(c, selection: selection)
        #expect(label(first, "cask:pixel-forge") == "failed(homebrewOutdated)")
        let succeededBefore = first.results.filter { $0.value.outcome.isSuccessLike }.keys
        #expect(!succeededBefore.isEmpty)
        try c.fresh.setFlag("brew-update-fails", false)
        let second = await restore(c, selection: selection, session: first.preparedForRetry())
        #expect(second.id == first.id)
        #expect(label(second, "cask:pixel-forge") == "succeeded")
        for id in succeededBefore { #expect(second.results[id]?.outcome == first.results[id]?.outcome, "\(id)") }
        #expect(second.results.count == first.results.count)
    }

    // MARK: Own installers for apps that also have a cask

    func ownInstaller(for app: AppRecord, approved: Bool) -> InstallerArchive {
        InstallerArchive(id: "0123456789abcdef", fileName: "\(app.name).dmg", kind: .dmg, size: 10, sha256: String(repeating: "a", count: 64),
                         teamIdentifier: approved ? app.teamIdentifier : nil, trustedSignature: approved,
                         bundleIdentifier: app.bundleIdentifier, includedPath: "installers/0123456789abcdef/\(app.name).dmg",
                         originalPath: "/Volumes/Installers/\(app.name).dmg")
    }

    @Test("An app with the user's own installer is restored from it (guided), not from its cask")
    func ownInstallerWinsOverCask() async throws {
        let c = try await context("own-installer")
        var manifest = c.manifest
        guard let index = manifest.applications.firstIndex(where: { if case .homebrewCask("nimbus-notes") = $0.source { return true }; return false }) else {
            Issue.record("no cask-installed app in the test backup"); return
        }
        let selection = RestoreSelection(components: [.brewCasks, .applications])
        let before = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(before.items.contains { $0.id == "cask:nimbus-notes" })

        manifest.applications[index].ownInstallers = [ownInstaller(for: manifest.applications[index], approved: true)]
        let app = manifest.applications[index]
        #expect(RestorePlanner.usesOwnInstaller(app))
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(!plan.items.contains { $0.id == "cask:nimbus-notes" })
        let manual = plan.items.first { $0.id == "manual:\(app.path)" }
        #expect(manual?.kind == .manualApp)
        #expect(manual?.app?.ownInstallers?.isEmpty == false)
        #expect(TestEnvironment.english.manualHint(for: app) == TestEnvironment.english.t("manual.hint.ownInstaller"))

        // An installer that may not be used (unverified, not confirmed) changes nothing.
        manifest.applications[index].ownInstallers = [ownInstaller(for: app, approved: false)]
        #expect(RestorePlanner().plan(manifest: manifest, selection: selection).items.contains { $0.id == "cask:nimbus-notes" })

        // A match decided on the restore screen still wins.
        manifest.applications[index].ownInstallers = [ownInstaller(for: app, approved: true)]
        var decided = selection
        decided.matchDecisions[app.path] = "nimbus-notes"
        #expect(RestorePlanner().plan(manifest: manifest, selection: decided).items.contains { $0.id == "cask:nimbus-notes" })
    }

    // MARK: Reinstall guide

    @Test("The backup state reads as two sentences in every language")
    func completenessSentenceHasAFullStop() {
        var manifest = Manifest(macreplicaVersion: "1.1.0", createdAt: Date(), macosVersion: "14.8.9", architecture: .x86_64)
        manifest.backupIssues = [BackupIssue(path: "~/Documents/a", reason: .unreadable), BackupIssue(path: "~/Documents/b", reason: .unreadable)]
        let english = TestEnvironment.english.completenessSentence(manifest)
        #expect(english.hasPrefix("Partial: 2 selected files are missing. Everything else was saved and checked."))
        for language in AppLanguage.allCases {
            let l = Localizer(language: language)
            #expect(l.completenessSentence(manifest).contains(l.completenessTitle(manifest) + ". "))
            let guide = ReportBuilder(localizer: l).reinstallGuide(profile: MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro15,1", macOSVersion: "14.8.9"),
                                                                    manifest: manifest, backupFolderName: nil)
            #expect(guide.contains(HTML.escape(l.completenessSentence(manifest))))
            let instructions = ReportBuilder(localizer: l).restoreInstructions(manifest, folderName: "B")
            #expect(instructions.contains("</b>. " + HTML.escape(l.completenessMessage(manifest))))
        }
        // A title that already ends with a full stop gets no second one.
        let complete = Manifest(macreplicaVersion: "1.1.0", createdAt: Date(), macosVersion: "14.8.9", architecture: .x86_64)
        #expect(!TestEnvironment.english.completenessSentence(complete).contains(".."))
        #expect(Localizer.separator(after: "Done!") == " ")
        #expect(Localizer.separator(after: "Partial") == ". ")
        #expect(Localizer.separator(after: "") == "")
    }

    @Test("The printed guide explains the USB installer completely and warns T2 Macs before erasing")
    func usbInstallerIsWrittenOut() {
        let l = TestEnvironment.english
        let builder = ReportBuilder(localizer: l)
        let t2 = builder.reinstallGuide(profile: MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro15,1", macOSVersion: "14.8.9"),
                                        manifest: nil, backupFolderName: nil)
        // Apple's command for the installed version, with the escaped spaces Terminal needs.
        #expect(t2.contains("sudo /Applications/Install\\ macOS\\ Sonoma.app/Contents/Resources/createinstallmedia --volume /Volumes/MyVolume"))
        #expect(t2.contains(HTML.escape(l.t("reinstall.usb.start.intel.2"))))
        #expect(!t2.contains(HTML.escape(l.t("reinstall.usb.start.as.2"))))
        // The T2 warning comes before the erase section; it is the only place it can still be acted on.
        let warning = t2.range(of: HTML.escape(l.t("reinstall.preflight.t2External")))
        let erase = t2.range(of: HTML.escape(l.t("reinstall.erase.title")))
        #expect(warning != nil && erase != nil && warning!.lowerBound < erase!.lowerBound)
        #expect(t2.contains(HTML.escape(l.t("reinstall.usb.start.t2"))))

        let intel = builder.reinstallGuide(profile: MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro11,1", macOSVersion: "12.7"),
                                           manifest: nil, backupFolderName: nil)
        #expect(!intel.contains(HTML.escape(l.t("reinstall.preflight.t2External"))))
        #expect(intel.contains("Install\\ macOS\\ Monterey.app"))

        let appleSilicon = builder.reinstallGuide(profile: MacProfile(architecture: .arm64, modelIdentifier: "Mac15,9", macOSVersion: "26.1"),
                                                  manifest: nil, backupFolderName: nil)
        #expect(appleSilicon.contains("Install\\ macOS\\ Tahoe.app"))
        #expect(appleSilicon.contains(HTML.escape(l.t("reinstall.usb.start.as.2"))))
        #expect(!appleSilicon.contains(HTML.escape(l.t("reinstall.preflight.t2External"))))
        #expect(ReportBuilder.installerAppName(macOSVersion: "99.0") == "Install macOS …")
        // Starting up from the USB installer is a sequence: numbered steps on both kinds of Mac.
        #expect(t2.contains("<ol><li>" + HTML.escape(l.t("reinstall.usb.start.intel.1"))))
        #expect(appleSilicon.contains("<ol><li>" + HTML.escape(l.t("reinstall.usb.start.as.1"))))
    }

    // MARK: Restore report (second report: "Waiting for you – see the guided steps", but no guided steps found)

    @Test("The restore report counts the waiting steps, says where the guided steps are, and lists only apps still to install")
    func restoreReportIsHonestAboutWaitingSteps() {
        let l = TestEnvironment.english
        let installed = AppRecord(name: "MacReplica", path: "/Applications/MacReplica.app")
        let missing = AppRecord(name: "Get It", path: "/Applications/Get It.app")
        let items = [installed, missing].map { app -> RestoreItem in
            var item = RestoreItem(id: "manual:\(app.path)", kind: .manualApp, title: app.name, identifier: app.path)
            item.app = app
            return item
        } + [RestoreItem(id: "scanner:com.example.scanner", kind: .printer, title: "Example Scanner", identifier: "com.example.scanner")]
        let plan = RestorePlan(items: items, manualApps: [installed, missing])
        var session = RestoreSession(backupPath: "~/B", selection: RestoreSelection(), itemIDs: items.map(\.id))
        session.results["manual:/Applications/MacReplica.app"] = ItemResult(itemID: "manual:/Applications/MacReplica.app", outcome: .alreadyPresent)
        session.results["manual:/Applications/Get It.app"] = ItemResult(itemID: "manual:/Applications/Get It.app", outcome: .skipped(.manualStepRequired))
        session.results["scanner:com.example.scanner"] = ItemResult(itemID: "scanner:com.example.scanner", outcome: .skipped(.manualStepRequired))
        let manifest = Manifest(macreplicaVersion: "1.1.0", createdAt: Date(), macosVersion: "14.8.4", architecture: .x86_64)
        let html = ReportBuilder(localizer: l).restoreSummaryReport(plan: plan, session: session, manifest: manifest)
        #expect(html.contains("<div class=\"card\"><b>2</b>\(HTML.escape(l.t("summary.waiting")))</div>"))
        #expect(html.contains(HTML.escape(l.p("report.restore.waitingHint", 2))))
        let manualSection = html.components(separatedBy: HTML.escape(l.t("report.manual.title"))).last ?? ""
        #expect(manualSection.contains("Get It"))
        #expect(!manualSection.contains("MacReplica</td>") && !manualSection.contains(">MacReplica<"), "already installed, not to install")

        // Nothing waiting: no hint.
        session.results["manual:/Applications/Get It.app"] = ItemResult(itemID: "manual:/Applications/Get It.app", outcome: .succeeded)
        session.results["scanner:com.example.scanner"] = ItemResult(itemID: "scanner:com.example.scanner", outcome: .succeeded)
        let done = ReportBuilder(localizer: l).restoreSummaryReport(plan: plan, session: session, manifest: manifest)
        #expect(!done.contains(HTML.escape(l.p("report.restore.waitingHint", 2))))
        #expect(!done.contains(HTML.escape(l.p("report.restore.waitingHint", 0))))
        #expect(!done.contains(HTML.escape(l.t("summary.waiting"))), "no waiting card when nothing waits")
        #expect(!done.contains(HTML.escape(l.t("report.manual.title"))))
    }

    // MARK: Third report (1.1.3): an outdated Homebrew installed the Apple-silicon GIMP on an Intel Mac

    /// Reproduced on a real Intel runner with Homebrew 4.2.0: `brew install --cask gimp` failed (“Unexpected method
    /// 'command_wrapper'”) but still moved the arm64-only GIMP into Applications and recorded the cask; after
    /// `brew update`, Homebrew said “already installed” – and MacReplica reported it as already installed.
    func wrongProcessorCask(_ c: Context, keepsApp: Bool = false) throws -> URL {
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: c.fresh.state.appendingPathComponent("brew/available/casks/pixel-forge.json"))) as? [String: Any]
        let app = c.target.layout.applicationFolders[0].appendingPathComponent(spec?["app"] as? String ?? "Pixel Forge.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": spec?["bundle_id"] as? String ?? "com.example.pixelforge",
                                   "CFBundleShortVersionString": "2.4.1", "CFBundleExecutable": "PixelForge"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try SimulationBuilder.machOHeader([.arm64]).write(to: app.appendingPathComponent("Contents/MacOS/PixelForge"))
        try c.fresh.setFlag("brew/casks/pixel-forge", true, content: "2.4.1")
        try c.fresh.setFlag("reinstall-keeps-app", keepsApp)
        return app
    }

    func restoreOnIntel(_ c: Context) async -> RestoreSession {
        let selection = RestoreSelection(components: [.brewCasks, .applications])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let environment = TestEnvironment.restoreEnvironment(c.target, architecture: .x86_64)
        return await RestoreExecutor(environment: environment, backupRoot: c.backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: c.backup.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    @Test("Homebrew's app without code for this Mac is reinstalled, not reported as already installed")
    func wrongProcessorAppFromHomebrewIsReinstalled() async throws {
        let c = try await context("wrong-cpu")
        try preinstallHomebrew(c)
        let app = try wrongProcessorCask(c)
        let session = await restoreOnIntel(c)
        let result = session.results["cask:pixel-forge"]
        #expect(result?.outcome == .succeeded, "\(result?.outcome.label ?? "-")")
        #expect(result?.notes.contains(.reinstalledForThisProcessor(found: "arm64")) == true)
        #expect(c.fresh.calls().contains("brew reinstall --cask pixel-forge"))
        #expect(MachO.architectures(ofFile: app.appendingPathComponent("Contents/MacOS/PixelForge")) != [.arm64], "the arm64-only copy is gone")
    }

    @Test("If the reinstall does not help, the step fails as 'wrong processor' instead of succeeding")
    func wrongProcessorAfterReinstallFails() async throws {
        let c = try await context("wrong-cpu-stays")
        try preinstallHomebrew(c)
        _ = try wrongProcessorCask(c, keepsApp: true)
        let session = await restoreOnIntel(c)
        #expect(session.results["cask:pixel-forge"]?.outcome.label == "failed(wrongProcessor)")
    }

    @Test("An app not from Homebrew without code for this Mac is left alone and reported honestly")
    func wrongProcessorAppNotFromHomebrewIsLeftAlone() async throws {
        let c = try await context("wrong-cpu-user")
        try preinstallHomebrew(c)
        let app = try wrongProcessorCask(c)
        try c.fresh.setFlag("brew/casks/pixel-forge", false)
        let before = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/PixelForge"))
        let session = await restoreOnIntel(c)
        #expect(session.results["cask:pixel-forge"]?.outcome.label == "failed(wrongProcessor)")
        #expect(!c.fresh.calls().contains { $0.hasPrefix("brew reinstall") })
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/PixelForge")) == before, "the user's app is never replaced")
    }

    @Test("Apps that can run here stay 'already installed': universal, Intel on Apple silicon (Rosetta), unreadable")
    func appsThatRunHereAreAlreadyPresent() async throws {
        let c = try await context("cpu-ok")
        let folder = try c.sandbox.folder("apps")
        func app(_ archs: [CPUArchitecture]?) throws -> URL {
            let url = folder.appendingPathComponent("A\(UUID().uuidString.prefix(6)).app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "X"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try (archs.map { SimulationBuilder.machOHeader($0) } ?? Data("#!/bin/sh".utf8)).write(to: url.appendingPathComponent("Contents/MacOS/X"))
            return url
        }
        let intel = Inspector(environment: TestEnvironment.restoreEnvironment(c.target, architecture: .x86_64), backupRoot: c.backup, selection: RestoreSelection(), damagedFiles: [])
        let appleSilicon = Inspector(environment: TestEnvironment.restoreEnvironment(c.target, architecture: .arm64), backupRoot: c.backup, selection: RestoreSelection(), damagedFiles: [])
        #expect(!intel.appRunsHere(try app([.arm64])))
        #expect(intel.appRunsHere(try app([.arm64, .x86_64])))
        #expect(intel.appRunsHere(try app([.x86_64])))
        #expect(appleSilicon.appRunsHere(try app([.x86_64])), "Rosetta")
        #expect(appleSilicon.appRunsHere(try app([.arm64])))
        #expect(intel.appRunsHere(try app(nil)), "not readable: no claim")
    }
}
