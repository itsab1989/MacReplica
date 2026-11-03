import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The check for casks Homebrew lists without their apps or packages, run read-only against the real Homebrew of
/// the Mac running the tests. Opt-in (`MACREPLICA_LIVE_HOMEBREW=1`): never part of routine runs or CI. It prints what
/// it finds for every installed cask, so a false "missing" (which would make MacReplica reinstall a working app)
/// shows up; `MACREPLICA_LIVE_HOMEBREW_MISSING` names casks expected to be missing (comma-separated).
@Suite("Stale cask check on this Mac's Homebrew (opt-in)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MACREPLICA_LIVE_HOMEBREW"] == "1"))
struct StaleCaskLiveTests {
    @Test("Every installed cask is checked; only the expected ones are reported missing")
    func installedCasksOnThisMac() async throws {
        let sandbox = try Sandbox("stale-cask-live")
        let (_, simulation) = try TestEnvironment.freshMac(sandbox)
        let layout = SystemLayout.live()
        var environment = TestEnvironment.restoreEnvironment(simulation)
        environment.layout = layout
        environment.runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        let brew = try #require(await environment.homebrew.locate().installation)
        let installed = try await environment.homebrew.installedPackages(brew)
        let inspector = Inspector(environment: environment, backupRoot: sandbox.url, selection: RestoreSelection(), damagedFiles: [])
        let expected = Set((ProcessInfo.processInfo.environment["MACREPLICA_LIVE_HOMEBREW_MISSING"] ?? "").split(separator: ",").map(String.init))
        var reported: Set<String> = []
        for cask in installed.casks {
            let item = RestoreItem(id: "cask:\(cask.token)", kind: .cask, title: cask.token, identifier: cask.token, appBundleNames: cask.appArtifacts)
            let contents = await environment.homebrew.caskContents(brew, token: cask.token)
            let missing = await inspector.missingCaskParts(item, brew: brew)
            print("LIVE \(cask.token): apps \(contents?.appNames ?? []) packages \(contents?.packages ?? []) receipts \(contents?.receipts ?? []) → missing \(missing)")
            if !missing.isEmpty { reported.insert(cask.token) }
        }
        #expect(!installed.casks.isEmpty)
        #expect(reported == expected)
    }

    /// Changes this Mac: only with `MACREPLICA_LIVE_HOMEBREW_REPAIR=<token>` for a cask the operator installed and
    /// whose app they then deleted (what Time Machine leaves). Runs the real restore step with the real Homebrew.
    @Test("The restore step reinstalls a real cask whose app was deleted", .enabled(if: ProcessInfo.processInfo.environment["MACREPLICA_LIVE_HOMEBREW_REPAIR"] != nil))
    func repairsRealCask() async throws {
        let token = try #require(ProcessInfo.processInfo.environment["MACREPLICA_LIVE_HOMEBREW_REPAIR"])
        let sandbox = try Sandbox("stale-cask-repair")
        let (_, simulation) = try TestEnvironment.freshMac(sandbox)
        let layout = SystemLayout.live()
        var environment = TestEnvironment.restoreEnvironment(simulation)
        environment.layout = layout
        environment.runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        let brew = try #require(await environment.homebrew.locate().installation)
        #expect(try await environment.homebrew.installedCaskVersion(brew, token: token) != nil, "Homebrew lists it")
        let item = RestoreItem(id: "cask:\(token)", kind: .cask, title: token, identifier: token)
        let inspector = Inspector(environment: environment, backupRoot: sandbox.url, selection: RestoreSelection(), damagedFiles: [])
        let before = await inspector.missingCaskParts(item, brew: brew)
        print("LIVE before: missing \(before)")
        #expect(!before.isEmpty, "the app must have been deleted first")
        let plan = RestorePlan(items: [item], manualApps: [])
        let session = await RestoreExecutor(environment: environment, backupRoot: sandbox.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: sandbox.url.path, selection: RestoreSelection(), itemIDs: [item.id]), onEvent: { _ in })
        let result = session.results[item.id]
        print("LIVE result: \(result?.outcome.label ?? "-") notes \(result?.notes ?? [])")
        #expect(result?.outcome == .succeeded)
        #expect(await inspector.missingCaskParts(item, brew: brew).isEmpty)
    }
}
