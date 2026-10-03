import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Display profile assignments", .serialized)
struct DisplayProfileTests {
    static let builtIn = SimulationBuilder.builtInDisplay
    static let external = SimulationBuilder.externalDisplay
    static let calibrated = "home/Library/ColorSync/Profiles/Built-in Calibrated.icc"
    static let studio = "home/Library/ColorSync/Profiles/Example Studio Display.icc"

    struct Context {
        let sandbox: Sandbox
        let source: SimulationRoot
        let backup: URL
        let manifest: Manifest
    }

    func backup(_ name: String) async throws -> Context {
        let sandbox = try Sandbox(name)
        let source = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("source"), scenario: .developerMac)
        let environment = try source.environment
        let inventory = try await TestEnvironment.inventory(environment).run()
        let outcome = try BackupWriter(layout: environment.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: environment.layout.homeDirectory))
        return Context(sandbox: sandbox, source: source, backup: outcome.url, manifest: try ManifestIO.read(from: outcome.url))
    }

    func restore(_ c: Context, on fresh: SimulationEnvironment, selection: RestoreSelection = RestoreSelection(components: [.colorProfiles]),
                 session: RestoreSession? = nil) async -> (RestorePlan, RestoreSession) {
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(fresh), backupRoot: c.backup, sessionStore: nil)
        let result = await executor.run(plan: plan, session: session ?? RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)),
                                        onEvent: { _ in })
        return (plan, result)
    }

    func item(_ plan: RestorePlan, display: String, keys: HardwareKeys) -> RestoreItem? {
        plan.items.first { $0.displayAssignment?.displayKey == keys.key(for: display) }
    }

    @Test func backupRecordsAssignmentsWithoutIdentifiers() async throws {
        let c = try await backup("display-backup")
        let keys = try #require(c.manifest.hardwareKeys)
        #expect(c.manifest.displayProfiles.count == 2)
        let builtIn = try #require(c.manifest.displayProfiles.first { $0.displayKey == keys.key(for: Self.builtIn) })
        #expect(builtIn.isBuiltIn == true && builtIn.source == .backedUp && builtIn.profileFileID == "user/Built-in Calibrated.icc")
        #expect(builtIn.profileDescription == "Built-in Calibrated")
        #expect(c.manifest.iccProfiles.contains { $0.id == builtIn.profileFileID }, "the assigned profile is in the backup")
        #expect(keys.isSameMac(platformIdentifier: "SIMULATED-MAC-A") == true)
        #expect(keys.isSameMac(platformIdentifier: "SIMULATED-MAC-B") == false)
        let json = try String(contentsOf: c.backup.appendingPathComponent(ManifestIO.fileName), encoding: .utf8)
        #expect(!json.contains(Self.builtIn) && !json.contains(Self.external) && !json.contains("SIMULATED-MAC-A"),
                "no display or Mac identifier is stored, only salted hashes")
        // A second backup uses another salt, so backups cannot be linked through these values.
        let other = HardwareKeys.make(platformIdentifier: "SIMULATED-MAC-A")
        #expect(other.macKey != keys.macKey)
    }

    @Test func sameMacReinstallAssignsBothDisplaysAndVerifies() async throws {
        let c = try await backup("display-same-mac")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-A", displays: [
            (Self.builtIn, "Built-in Display", true, true, nil), (Self.external, "Example Studio Display", false, true, nil)])
        let keys = try #require(c.manifest.hardwareKeys)
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: [.colorProfiles]))
        let builtInItem = try #require(item(plan, display: Self.builtIn, keys: keys))
        #expect(builtInItem.dependsOn == ["icc:user/Built-in Calibrated.icc"])
        let dry = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: c.backup, sessionStore: nil)
            .dryRun(plan: plan, selection: RestoreSelection(components: [.colorProfiles]))
        #expect(dry.first { $0.item.id == builtInItem.id }?.prediction == .dependsOnEarlierStep, "the profile is restored first")
        let (_, session) = await restore(c, on: target)
        #expect(session.results[builtInItem.id]?.outcome == .succeeded)
        #expect(fresh.assignedProfile(display: Self.builtIn) == Self.calibrated)
        #expect(fresh.assignedProfile(display: Self.external) == Self.studio)
        // Running again finds the assignments in place.
        let (_, again) = await restore(c, on: target)
        #expect(again.results[builtInItem.id]?.outcome == .alreadyPresent)
    }

    @Test func differentMacSkipsTheBuiltInDisplayButKeepsTheSameExternalDisplay() async throws {
        let c = try await backup("display-other-mac")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-B", displays: [
            ("00000000-0000-4000-8000-00000000C333", "Built-in Display", true, true, nil), (Self.external, "Example Studio Display", false, true, nil)])
        let keys = try #require(c.manifest.hardwareKeys)
        let (plan, session) = await restore(c, on: target)
        #expect(session.results[try #require(item(plan, display: Self.builtIn, keys: keys)).id]?.outcome == .skipped(.displayOfAnotherMac))
        #expect(session.results[try #require(item(plan, display: Self.external, keys: keys)).id]?.outcome == .succeeded)
        #expect(fresh.assignedProfile(display: "00000000-0000-4000-8000-00000000C333") == nil, "never applied to another Mac's display")
        #expect(fresh.assignedProfile(display: Self.external) == Self.studio)
    }

    @Test func aDisplayThatIsNotConnectedWaitsAndIsAssignedWhenConnected() async throws {
        let c = try await backup("display-later")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-A", displays: [
            (Self.builtIn, "Built-in Display", true, true, nil), (Self.external, "Example Studio Display", false, false, nil)])
        let keys = try #require(c.manifest.hardwareKeys)
        let (plan, session) = await restore(c, on: target)
        let externalItem = try #require(item(plan, display: Self.external, keys: keys))
        #expect(session.results[externalItem.id]?.outcome == .skipped(.displayNotConnected(name: "Example Studio Display")))
        #expect(session.results[externalItem.id]?.outcome.isOpen == true, "waits for the user; not a failure")
        #expect(session.status == .inProgress)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-A", displays: [
            (Self.builtIn, "Built-in Display", true, true, Self.calibrated), (Self.external, "Example Studio Display", false, true, nil)])
        let (_, resumed) = await restore(c, on: target, session: session)
        #expect(resumed.results[externalItem.id]?.outcome == .succeeded)
        #expect(resumed.status == .completed)
        #expect(fresh.assignedProfile(display: Self.external) == Self.studio)
    }

    @Test func anAssignmentThatDoesNotTakeEffectIsAFailure() async throws {
        let c = try await backup("display-refused")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-A", displays: [(Self.external, "Example Studio Display", false, true, nil)],
                                    refuseAssignments: true)
        let keys = try #require(c.manifest.hardwareKeys)
        let (plan, session) = await restore(c, on: target)
        let externalItem = try #require(item(plan, display: Self.external, keys: keys))
        guard case .failed(let failure)? = session.results[externalItem.id]?.outcome else { Issue.record("not a failure"); return }
        #expect(failure.category == .verificationFailed)
    }

    @Test func conflictingProfilesNeedADecisionAndAreNeverOverwritten() async throws {
        let c = try await backup("display-conflict")
        let (fresh, target) = try TestEnvironment.freshMac(c.sandbox)
        try fresh.configureDisplays(platform: "SIMULATED-MAC-A", displays: [(Self.external, "Example Studio Display", false, true, nil)])
        // A different profile with the same file name already exists on the new Mac.
        let existing = fresh.url.appendingPathComponent(Self.studio)
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SimulationBuilder.makeICCProfile(description: "Example Studio Display", copyright: "Other calibration").write(to: existing)
        let before = try Data(contentsOf: existing)
        let keys = try #require(c.manifest.hardwareKeys)

        var keepBoth = RestoreSelection(components: [.colorProfiles])
        keepBoth.conflictOverrides = ["icc:user/Example Studio Display.icc": .keepBoth]
        let (plan, session) = await restore(c, on: target, selection: keepBoth)
        let externalItem = try #require(item(plan, display: Self.external, keys: keys))
        #expect(try Data(contentsOf: existing) == before, "the existing profile is untouched")
        #expect(session.results[externalItem.id]?.outcome == .succeeded)
        #expect(fresh.assignedProfile(display: Self.external) == "home/Library/ColorSync/Profiles/Example Studio Display (MacReplica).icc",
                "the backed-up profile is assigned, under its new name")

        let (fresh2, target2) = try TestEnvironment.freshMac(c.sandbox, name: "fresh-keep")
        try fresh2.configureDisplays(platform: "SIMULATED-MAC-A", displays: [(Self.external, "Example Studio Display", false, true, nil)])
        let existing2 = fresh2.url.appendingPathComponent(Self.studio)
        try FileManager.default.createDirectory(at: existing2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try before.write(to: existing2)
        var keep = RestoreSelection(components: [.colorProfiles])
        keep.conflictOverrides = ["icc:user/Example Studio Display.icc": .keepExisting]
        let (_, kept) = await restore(c, on: target2, selection: keep)
        #expect(try Data(contentsOf: existing2) == before)
        #expect(kept.results[externalItem.id]?.outcome.isSuccessLike == false, "the old assignment needs the backed-up profile, which was not restored")
        #expect(fresh2.assignedProfile(display: Self.external) == nil, "nothing is assigned without the profile")
    }

    @Test func theSimulatedManagerOnlyAssignsToConnectedDisplaysAndReportsWriteFailures() throws {
        let sandbox = try Sandbox("display-simulated")
        let state = try sandbox.folder("state")
        let file = state.appendingPathComponent("colorsync.json")
        try JSONEncoder().encode(SimulatedDisplayColorManager.State(platform: "SIMULATED-MAC-A", displays: [
            .init(uuid: "A", name: "Built-in Display", builtIn: true, connected: true, profile: nil),
            .init(uuid: "B", name: "Example Studio Display", builtIn: false, connected: false, profile: nil),
        ], refuseAssignments: nil)).write(to: file)
        let manager = SimulatedDisplayColorManager(file: file)
        let profile = sandbox.url.appendingPathComponent("Calibrated.icc")
        #expect(!manager.assign(profile, toDisplay: "B"), "a display that is not connected")
        #expect(!manager.assign(profile, toDisplay: "C"), "an unknown display")
        #expect(manager.displays().allSatisfy { $0.customProfile == nil }, "nothing was assigned")
        #expect(manager.assign(profile, toDisplay: "A"))
        #expect(manager.displays().first { $0.uuid == "A" }?.customProfile == profile)
        #expect(manager.displays().first { $0.uuid == "B" }?.customProfile == nil)
        // An assignment that cannot be saved did not happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }
        #expect(!manager.assign(sandbox.url.appendingPathComponent("Other.icc"), toDisplay: "A"))
        #expect(manager.displays().first { $0.uuid == "A" }?.customProfile == profile)
    }

    @Test func macOSProfilesAndGeneratedProfilesInAssignments() throws {
        let sandbox = try Sandbox("display-scanner")
        var layout = toolchainLayout(sandbox)
        layout.macOSColorProfiles = sandbox.url.appendingPathComponent("System/Library/ColorSync/Profiles")
        let keys = HardwareKeys(salt: "s", macKey: nil)
        let generated = FileRecord(fileName: "D.icc", domain: .system, relativePath: "Displays/D.icc", originalPath: "/Library/ColorSync/Profiles/Displays/D.icc",
                                   backupPath: "x", sha256: "a", size: 1, origin: .displayGenerated)
        let displays = [
            DisplayDevice(uuid: "U1", customProfile: sandbox.url.appendingPathComponent("System/Library/ColorSync/Profiles/Display P3.icc")),
            DisplayDevice(uuid: "U2", customProfile: sandbox.url.appendingPathComponent("Library/ColorSync/Profiles/Displays/D.icc")),
            DisplayDevice(uuid: "U3", customProfile: nil),
            DisplayDevice(uuid: "U4", customProfile: URL(fileURLWithPath: "/Volumes/Elsewhere/x.icc")),
        ]
        let assignments = DisplayProfileScanner.assignments(displays: displays, profiles: [generated], layout: layout, keys: keys)
        #expect(assignments.map(\.displayKey) == [keys.key(for: "U1")], "macOS-generated, unassigned and unknown profiles are left out")
        #expect(assignments.first?.source == .macOS && assignments.first?.macOSProfile == "Display P3.icc")
    }
}
