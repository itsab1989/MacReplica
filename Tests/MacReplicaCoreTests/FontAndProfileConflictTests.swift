import CryptoKit
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A fresh simulated Mac plus a folder that plays the backup, for checking one font or profile at a time.
private struct Destination {
    let sandbox: Sandbox
    let root: SimulationRoot
    let layout: SystemLayout
    let backup: URL

    init(_ name: String) throws {
        sandbox = try Sandbox(name)
        root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("mac"), scenario: .freshMac)
        layout = try root.environment.layout
        backup = try sandbox.folder("backup")
    }

    /// Writes `data` as a backed-up file and returns its record, as the scanner on the old Mac would.
    func backedUp(_ data: Data, kind: BackupFileKind, name: String, domain: FileDomain = .user) throws -> FileRecord {
        let folder = kind == .font ? "fonts" : "icc_profiles"
        let backupPath = "\(folder)/\(domain.rawValue)/\(name)"
        let url = backup.appendingPathComponent(backupPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let profile = kind == .colorProfile ? FileScanner.profileIdentity(url) : nil
        return FileRecord(fileName: url.lastPathComponent, domain: domain, relativePath: name,
                          originalPath: "~/Library/\(name)", backupPath: backupPath, sha256: Hashing.sha256Hex(of: data),
                          size: Int64(data.count), font: kind == .font ? FileScanner.fontIdentity(url) : nil, profile: profile,
                          origin: FileScanner.origin(kind: kind, domain: domain, relativePath: name, profile: profile))
    }

    /// Puts a file onto the destination Mac.
    func install(_ data: Data, kind: BackupFileKind, at location: FileLocation, name: String) throws {
        let base: URL
        switch (kind, location) {
        case (.font, .user): base = layout.userFonts
        case (.font, .shared): base = layout.systemFonts
        case (.font, .macOS): base = layout.macOSFonts
        case (.colorProfile, .user): base = layout.userColorProfiles
        case (.colorProfile, .shared): base = layout.systemColorProfiles
        case (.colorProfile, .macOS): base = layout.macOSColorProfiles
        }
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func assess(_ record: FileRecord, kind: BackupFileKind) -> FileConflictAnalyzer.Result {
        let base = layout.baseFolder(for: kind, domain: record.domain)
        return FileConflictAnalyzer(index: DestinationFileIndex.build(kind: kind, layout: layout))
            .assess(record: record, kind: kind, source: backup.appendingPathComponent(record.backupPath),
                    destination: base.appendingPathComponent(record.relativePath), destinationLocation: record.domain == .user ? .user : .shared)
    }

    func status(_ record: FileRecord, kind: BackupFileKind) -> FileAssessment.Status { assess(record, kind: kind).assessment.status }
}

private func font(_ family: String, style: String = "Regular", version: String = "1.000", weight: UInt16 = 400) -> Data {
    SyntheticFont.make(family: family, style: style, version: version, weight: weight)
}

private func profile(_ description: String, deviceClass: String = "prtr", creator: String? = nil, copyright: String = "a",
                     flags: UInt32 = 0) -> Data {
    SimulationBuilder.makeICCProfile(description: description, deviceClass: deviceClass, creator: creator, copyright: copyright, flags: flags)
}

@Suite("Font conflicts on the destination Mac")
struct FontConflictTests {
    @Test func missingFontIsReadyToRestore() throws {
        let d = try Destination("font-missing")
        #expect(d.status(try d.backedUp(font("Unique Sans"), kind: .font, name: "UniqueSans.otf"), kind: .font) == .ready)
    }

    @Test func identicalFontIsAlreadyPresentEvenUnderAnotherNameOrFolder() throws {
        let d = try Destination("font-identical")
        let data = font("Twin Sans")
        let record = try d.backedUp(data, kind: .font, name: "TwinSans.otf")
        try d.install(data, kind: .font, at: .shared, name: "Renamed Copy.otf")
        let result = d.assess(record, kind: .font)
        #expect(result.assessment.status == .identical)
        #expect(result.assessment.existingLocation == .shared)
        #expect(result.assessment.existingFileName == "Renamed Copy.otf")
        #expect(result.replaceTarget == nil, "nothing is ever replaced for an identical file")
    }

    @Test func sameFontAndVersionWithDifferentBytesIsEquivalent() throws {
        let d = try Destination("font-equivalent")
        let record = try d.backedUp(font("Same Face"), kind: .font, name: "SameFace.otf")
        try d.install(font("Same Face", weight: 401), kind: .font, at: .user, name: "SameFace-Other.otf")
        #expect(d.status(record, kind: .font) == .equivalent)
    }

    @Test func sameFamilyDifferentVersionIsAConflictAtTheSamePath() throws {
        let d = try Destination("font-version")
        let record = try d.backedUp(font("Versioned", version: "2.000"), kind: .font, name: "Versioned.ttf")
        try d.install(font("Versioned", version: "1.000"), kind: .font, at: .user, name: "Versioned.ttf")
        let result = d.assess(record, kind: .font)
        #expect(result.assessment.status == .differentVersion)
        #expect(result.assessment.installedVersion == "1.000")
        #expect(result.assessment.backupVersion == "2.000")
        #expect(result.replaceTarget?.lastPathComponent == "Versioned.ttf")
        // Two versions of one font must never be active together, and nothing is overwritten by default.
        #expect(!result.assessment.conflictChoices(kind: .font).contains(.keepBoth))
        #expect(result.assessment.defaultResolution(kind: .font) == .keepExisting)
    }

    @Test func differentVersionInAnotherFolderIsNeverReplaced() throws {
        let d = try Destination("font-version-other-folder")
        let record = try d.backedUp(font("Shared Face", version: "2.000"), kind: .font, name: "SharedFace.ttf")
        try d.install(font("Shared Face", version: "1.000"), kind: .font, at: .shared, name: "SharedFace.ttf")
        let result = d.assess(record, kind: .font)
        #expect(result.assessment.status == .differentVersion)
        #expect(result.replaceTarget == nil, "a file outside the restore folder is never moved")
    }

    @Test func sameFileNameWithADifferentFontIsKeptBoth() throws {
        let d = try Destination("font-same-name")
        let record = try d.backedUp(font("Studio One"), kind: .font, name: "Studio.ttf")
        try d.install(font("Completely Other"), kind: .font, at: .user, name: "Studio.ttf")
        let result = d.assess(record, kind: .font)
        #expect(result.assessment.status == .differentFile)
        #expect(result.assessment.defaultResolution(kind: .font) == .keepBoth)
    }

    @Test func fontsProvidedByMacOSAreKeptByDefault() throws {
        let d = try Destination("font-system")
        // The simulated macOS provides "System Demo" (see SimulationBuilder.populateMacOSFiles).
        let record = try d.backedUp(font("System Demo", version: "1.500"), kind: .font, name: "System Demo.ttf")
        let result = d.assess(record, kind: .font)
        #expect(result.assessment.status == .providedByMacOS)
        #expect(result.assessment.existingLocation == .macOS)
        #expect(result.assessment.installedVersion == "3.000")
        #expect(result.replaceTarget == nil, "macOS's own files are never touched")
        #expect(RestoreExecutor.filePrediction(for: result.assessment, item: item(record, .font), selection: RestoreSelection()) == .keepsMacOSVersion)
        var selection = RestoreSelection()
        selection.conflictOverrides[item(record, .font).id] = .replace
        #expect(RestoreExecutor.filePrediction(for: result.assessment, item: item(record, .font), selection: selection) == .willCopy,
                "only an explicit choice installs the backup copy, into the user's own folder")
        // The general "replace" default never applies to macOS's own fonts.
        #expect(RestoreExecutor.filePrediction(for: result.assessment, item: item(record, .font), selection: RestoreSelection(conflictResolution: .replace))
                == .keepsMacOSVersion)
    }

    @Test func downloadableMacOSFontsCount() throws {
        let d = try Destination("font-assets")
        try FileManager.default.createDirectory(at: d.layout.macOSFontAssets.appendingPathComponent("com_apple_MobileAsset_Font8/x.asset"), withIntermediateDirectories: true)
        try font("Asset Face").write(to: d.layout.macOSFontAssets.appendingPathComponent("com_apple_MobileAsset_Font8/x.asset/AssetFace.ttf"))
        let record = try d.backedUp(font("Asset Face", version: "0.900"), kind: .font, name: "AssetFace.ttf")
        #expect(d.status(record, kind: .font) == .providedByMacOS)
    }

    @Test func unreadableFontsAreIncompatibleAndNotSelected() throws {
        let d = try Destination("font-broken")
        let record = try d.backedUp(Data("not a font".utf8), kind: .font, name: "Broken.otf")
        let assessment = d.assess(record, kind: .font).assessment
        #expect(assessment.status == .incompatible)
        #expect(!assessment.selectedByDefault)
        #expect(!assessment.canBeRestored)
    }

    @Test func legacyFormatsAreNotOpenedAndNotSelectedByDefault() throws {
        let d = try Destination("font-legacy")
        let record = try d.backedUp(Data("type 1 placeholder".utf8), kind: .font, name: "Old.pfb")
        #expect(record.font == nil)
        let assessment = d.assess(record, kind: .font).assessment
        #expect(assessment.status == .legacyFormat)
        #expect(!assessment.selectedByDefault)
        #expect(assessment.canBeRestored)
        // The identical legacy file on the destination is recognized (data and resource fork).
        try d.install(Data("type 1 placeholder".utf8), kind: .font, at: .user, name: "Old.pfb")
        #expect(d.status(record, kind: .font) == .identical)
    }
}

@Suite("ICC profile conflicts on the destination Mac")
struct ProfileConflictTests {
    @Test func missingCustomProfileIsReady() throws {
        let d = try Destination("icc-missing")
        #expect(d.status(try d.backedUp(profile("Custom Paper"), kind: .colorProfile, name: "Custom Paper.icc"), kind: .colorProfile) == .ready)
    }

    @Test func sameNameIdenticalContentIsAlreadyPresent() throws {
        let d = try Destination("icc-identical")
        let data = profile("Twin Paper")
        let record = try d.backedUp(data, kind: .colorProfile, name: "Twin Paper.icc")
        try d.install(data, kind: .colorProfile, at: .user, name: "Twin Paper.icc")
        #expect(d.status(record, kind: .colorProfile) == .identical)
    }

    @Test func differentNameSameProfileIsEquivalentByComputedProfileID() throws {
        let d = try Destination("icc-equivalent")
        let record = try d.backedUp(profile("Proof"), kind: .colorProfile, name: "Proof.icc")
        // Only the header flags differ: different bytes, same ICC Profile ID (ICC.1:2022 §7.2.18).
        let other = profile("Proof", flags: 1)
        #expect(Hashing.sha256Hex(of: other) != record.sha256)
        #expect(ICCProfileHeader.computedProfileID(other) == record.profile?.computedID)
        try d.install(other, kind: .colorProfile, at: .shared, name: "Something Else.icc")
        #expect(d.status(record, kind: .colorProfile) == .equivalent)
    }

    @Test func sameNameDifferentContentIsAConflictInstalledNextToIt() throws {
        let d = try Destination("icc-same-name")
        let record = try d.backedUp(profile("Paper", copyright: "old measurement"), kind: .colorProfile, name: "Paper.icc")
        try d.install(profile("Paper", copyright: "new measurement"), kind: .colorProfile, at: .user, name: "Paper.icc")
        let result = d.assess(record, kind: .colorProfile)
        #expect(result.assessment.status == .differentVersion)
        #expect(result.assessment.defaultResolution(kind: .colorProfile) == .keepBoth)
        #expect(result.assessment.conflictChoices(kind: .colorProfile) == [.keepBoth, .keepExisting, .replace, .skip])
        #expect(result.replaceTarget?.lastPathComponent == "Paper.icc")
    }

    @Test func sameDescriptionUnderAnotherNameWarnsAboutTwoEntries() throws {
        let d = try Destination("icc-same-description")
        let record = try d.backedUp(profile("Gallery Paper", copyright: "a"), kind: .colorProfile, name: "Gallery A.icc")
        try d.install(profile("Gallery Paper", copyright: "b"), kind: .colorProfile, at: .user, name: "Gallery B.icc")
        let assessment = d.assess(record, kind: .colorProfile).assessment
        #expect(assessment.status == .differentVersion)
        #expect(assessment.advisories.contains(.sameNameListedTwice))
    }

    @Test func profilesMacOSProvidesArePreferred() throws {
        let d = try Destination("icc-system")
        // The simulated macOS ships "sRGB IEC61966-2.1" with other bytes.
        let record = try d.backedUp(profile("sRGB IEC61966-2.1", deviceClass: "mntr", copyright: "older copy"), kind: .colorProfile, name: "sRGB Copy.icc")
        let assessment = d.assess(record, kind: .colorProfile).assessment
        #expect(assessment.status == .providedByMacOS)
        #expect(assessment.existingLocation == .macOS)
        #expect(assessment.selectedByDefault, "selected, but the restore keeps macOS's version")
    }

    @Test func obsoleteAppleProfilesStartDeselected() throws {
        let d = try Destination("icc-obsolete")
        let record = try d.backedUp(profile("Retired Apple Filter", deviceClass: "abst", creator: "appl"), kind: .colorProfile,
                                    name: "Retired.icc", domain: .system)
        #expect(record.origin == .appleCreated)
        let assessment = d.assess(record, kind: .colorProfile).assessment
        #expect(assessment.status == .obsoleteAppleProfile)
        #expect(!assessment.selectedByDefault)
    }

    @Test func displayProfilesGeneratedByMacOSAreNeverRestored() throws {
        let d = try Destination("icc-display")
        let record = try d.backedUp(profile("Some Display", deviceClass: "mntr", creator: "appl"), kind: .colorProfile,
                                    name: "Displays/Some Display-0000.icc", domain: .system)
        #expect(record.origin == .displayGenerated)
        let assessment = d.assess(record, kind: .colorProfile).assessment
        #expect(assessment.status == .displayProfile)
        #expect(!assessment.canBeRestored)
        #expect(RestoreExecutor.filePrediction(for: assessment, item: item(record, .colorProfile), selection: RestoreSelection())
                == .willSkip(.displaySpecificProfile))
    }

    @Test func customDisplayCalibrationGetsAnAdvisory() throws {
        let d = try Destination("icc-calibration")
        let record = try d.backedUp(profile("My Calibration", deviceClass: "mntr"), kind: .colorProfile, name: "My Calibration.icc")
        let assessment = d.assess(record, kind: .colorProfile).assessment
        #expect(assessment.status == .ready)
        #expect(assessment.advisories == [.displayCalibration])
    }

    @Test func unreadableProfileIsIncompatible() throws {
        let d = try Destination("icc-broken")
        #expect(d.status(try d.backedUp(Data(count: 200), kind: .colorProfile, name: "Broken.icc"), kind: .colorProfile) == .incompatible)
    }

    @Test func colorSyncAcceptsRestoredProfiles() throws {
        let d = try Destination("icc-colorsync")
        let url = d.backup.appendingPathComponent("valid.icc")
        try profile("Valid", deviceClass: "prtr").write(to: url)
        #expect(FileVerification.isUsable(url, kind: .colorProfile))
        let broken = d.backup.appendingPathComponent("broken.icc")
        try Data(count: 300).write(to: broken)
        #expect(!FileVerification.isUsable(broken, kind: .colorProfile))
    }
}

private func item(_ record: FileRecord, _ kind: BackupFileKind) -> RestoreItem {
    RestoreItem(id: "\(kind == .font ? "font" : "icc"):\(record.id)", kind: kind == .font ? .font : .colorProfile,
                title: record.fileName, identifier: record.relativePath, file: record)
}

@Suite("Restoring fonts and profiles with decisions")
struct FileDecisionRestoreTests {
    typealias Context = (sandbox: Sandbox, backup: URL, manifest: Manifest, fresh: SimulationRoot, target: SimulationEnvironment)

    private func run(_ c: Context, _ selection: RestoreSelection) async -> RestoreSession {
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
        return await executor.run(plan: plan, session: RestoreSession(backupPath: "~/b", selection: selection, itemIDs: plan.items.map(\.id)),
                                  onEvent: { _ in })
    }

    private func context(_ name: String) async throws -> Context {
        let sandbox = try Sandbox(name)
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        return (sandbox, backup, manifest, fresh, target)
    }

    @Test func keepBothInstallsUnderANewNameAndLeavesTheExistingFile() async throws {
        let c = try await context("decide-keep-both")
        let session = await run(c, RestoreSelection(components: [.fonts]))
        let fonts = c.fresh.url.appendingPathComponent("home/Library/Fonts")
        #expect(session.results["font:user/Studio Grotesk.ttf"]?.decisionCode == "conflict_kept_both")
        #expect(FileScanner.fontIdentity(fonts.appendingPathComponent("Studio Grotesk.ttf"))?.families == ["Other Grotesk"])
        #expect(FileScanner.fontIdentity(fonts.appendingPathComponent("Studio Grotesk (MacReplica).ttf"))?.families == ["Studio Grotesk"])
    }

    @Test func userChoicesOverrideTheDefault() async throws {
        let c = try await context("decide-override")
        var selection = RestoreSelection(components: [.fonts, .colorProfiles])
        selection.conflictOverrides = ["font:user/Studio Grotesk.ttf": .skip, "icc:user/Example Fine Art Paper.icm": .replace,
                                       "font:user/System Demo.ttf": .replace]
        let session = await run(c, selection)
        #expect(session.results["font:user/Studio Grotesk.ttf"]?.decisionCode == "skipped_by_user")
        #expect(session.results["icc:user/Example Fine Art Paper.icm"]?.decisionCode == "conflict_restored_backup")
        let profiles = c.fresh.url.appendingPathComponent("home/Library/ColorSync/Profiles")
        let restored = try Data(contentsOf: profiles.appendingPathComponent("Example Fine Art Paper.icm"))
        #expect(Hashing.sha256Hex(of: restored) == c.manifest.iccProfiles.first { $0.fileName == "Example Fine Art Paper.icm" }?.sha256)
        // The macOS-provided font is only added to the user's folder after an explicit choice.
        #expect(session.results["font:user/System Demo.ttf"]?.decisionCode == "restored")
        #expect(FileManager.default.fileExists(atPath: c.fresh.url.appendingPathComponent("System/Library/Fonts/SystemDemo.ttf").path))
    }

    @Test func choicesThatAreNotOfferedAreIgnored() async throws {
        let c = try await context("decide-invalid")
        var selection = RestoreSelection(components: [.fonts])
        // "Keep both" is not offered for two versions of one font: the safe default applies.
        selection.conflictOverrides = ["font:user/ExampleSerif.ttf": .keepBoth]
        let session = await run(c, selection)
        #expect(session.results["font:user/ExampleSerif.ttf"]?.outcome == .skipped(.keptExisting))
        #expect(!FileManager.default.fileExists(atPath: c.fresh.url.appendingPathComponent("home/Library/Fonts/ExampleSerif (MacReplica).ttf").path))
    }

    @Test func unwritableUserFolderFailsOnlyThoseItems() async throws {
        let c = try await context("decide-permission")
        let fonts = c.fresh.url.appendingPathComponent("home/Library/Fonts")
        let locked = [fonts, fonts.appendingPathComponent("Example Sans")]
        for folder in locked { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }
        let session = await run(c, RestoreSelection(components: [.fonts, .colorProfiles]))
        #expect(session.results["font:user/Example Sans/ExampleSans-Bold.otf"]?.outcome.isFailure == true)
        #expect(session.results["icc:user/Example Studio Display.icc"]?.outcome == .succeeded, "independent items continue")
        #expect(session.status == .completed)
    }

    @Test func dryRunPredictsExactlyWhatTheRestoreDoes() async throws {
        let c = try await context("decide-dry-run")
        let selection = RestoreSelection(components: [.fonts, .colorProfiles])
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: selection)
        #expect(entries.allSatisfy { $0.fileAssessment != nil })
        let session = await run(c, selection)
        for entry in entries {
            let outcome = session.results[entry.item.id]?.outcome
            switch entry.prediction {
            case .identicalFileExists, .equivalentFileExists, .keepsMacOSVersion: #expect(outcome == .alreadyPresent, "\(entry.item.id)")
            case .willCopy, .conflict(.replace), .conflict(.keepBoth): #expect(outcome == .succeeded, "\(entry.item.id)")
            case .conflict(.keepExisting): #expect(outcome == .skipped(.keptExisting), "\(entry.item.id)")
            case .willSkip(let reason): #expect(outcome == .skipped(reason), "\(entry.item.id)")
            default: Issue.record("unexpected prediction \(entry.prediction) for \(entry.item.id)")
            }
        }
        // Nothing in macOS's own folders was changed.
        let systemFonts = try FileManager.default.contentsOfDirectory(atPath: c.fresh.url.appendingPathComponent("System/Library/Fonts").path)
        #expect(systemFonts == ["SystemDemo.ttf"])
    }

    @Test func defaultSelectionLeavesOutWhatIsNotRecommended() async throws {
        let c = try await context("decide-defaults")
        let selection = RestoreSelection()
        let plan = RestorePlanner().plan(manifest: c.manifest, selection: RestoreSelection(components: Set(RestoreComponent.allCases)))
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(c.target), backupRoot: c.backup, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: selection, checkPackages: false)
        let notRecommended = RestoreSelection.notRecommended(entries)
        #expect(notRecommended == ["font:user/Broken.otf", "font:user/OldFace.pfb", "icc:system/Example Legacy Filter.icc",
                                   "icc:system/Displays/Example Display-00000000-0000-0000-0000-SYNTHETIC000.icc"])
        // Credentials stay opt-in whatever the destination check says.
        #expect(!RestoreComponent.defaultSelection.contains(.credentials))
        // The quick check does not look up Homebrew packages one by one.
        #expect(entries.first { $0.item.id == "formula:git" }?.prediction == .checkedWhenRestoring)
    }
}

@Suite("Two-stage selection")
struct TwoStageSelectionTests {
    @Test func backupSelectionKeepsExactlyTheChosenFiles() async throws {
        let sandbox = try Sandbox("backup-selection")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        var result = try await TestEnvironment.inventory(source).run()
        // Display profiles of the old Mac are not pre-selected.
        #expect(result.filesNotSelectedByDefault == ["icc:system/Displays/Example Display-00000000-0000-0000-0000-SYNTHETIC000.icc"])
        var excluded = result.filesNotSelectedByDefault
        excluded.insert("font:user/ExampleSerif.ttf")
        result.excludeFiles(excluded)
        #expect(!result.manifest.fonts.contains { $0.fileName == "ExampleSerif.ttf" })
        #expect(!result.fonts.contains { $0.record.fileName == "ExampleSerif.ttf" })
        #expect(result.manifest.backupSelection == BackupSelectionSummary(fontsFound: 9, fontsSelected: 8, profilesFound: 7, profilesSelected: 6))
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("out"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        #expect(!FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent("fonts/user/ExampleSerif.ttf").path))
        let reread = try ManifestIO.read(from: outcome.url)
        #expect(reread.fonts.count == 8)
        #expect(reread.backupSelection?.fontsSelected == 8)
        // Identity information is kept in the manifest for the second selection on the new Mac.
        #expect(reread.fonts.first { $0.fileName == "Example Script.otf" }?.font?.postScriptNames == ["ExampleScript-Regular"])
        #expect(reread.iccProfiles.allSatisfy { $0.profile?.computedID?.count == 32 })
    }

    @Test func restoreSelectionCanOnlyChooseFromTheBackup() async throws {
        let sandbox = try Sandbox("restore-selection")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        var selection = RestoreSelection(components: [.fonts, .colorProfiles])
        selection.excludedItemIDs = ["font:user/Example Script.otf", "icc:user/Example Proof Flags.icc", "font:user/NotInBackup.otf"]
        let ids = Set(RestorePlanner().plan(manifest: manifest, selection: selection).items.map(\.id))
        #expect(!ids.contains("font:user/Example Script.otf"))
        #expect(!ids.contains("icc:user/Example Proof Flags.icc"))
        #expect(ids.contains("font:user/ExampleSerif.ttf"))
        let backedUp = Set(manifest.fonts.map { "font:\($0.id)" } + manifest.iccProfiles.map { "icc:\($0.id)" })
        #expect(ids.isSubset(of: backedUp), "nothing outside the backup can be restored")
    }

    @Test func resumeKeepsFinishedStepsAndTheReviewedSelection() async throws {
        let sandbox = try Sandbox("resume-review")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let store = SessionStore(folder: target.layout.applicationSupport.appendingPathComponent("Sessions"), homeDirectory: target.layout.homeDirectory)
        var selection = RestoreSelection(components: [.fonts, .colorProfiles])
        selection.conflictOverrides = ["font:user/Studio Grotesk.ttf": .skip]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        // Simulate an interruption after the first two steps.
        var session = RestoreSession(backupPath: backup.path, selection: selection, itemIDs: plan.items.map(\.id))
        for item in plan.items.prefix(2) { session.results[item.id] = ItemResult(itemID: item.id, outcome: .succeeded) }
        try store.save(session)
        let saved = try #require(store.unfinishedSession())
        #expect(saved.selection == selection, "choices survive a restart")
        #expect(saved.results.count == 2)

        // The user reviews: deselects an unfinished profile and tries to deselect a finished font.
        let finished = Array(saved.results.keys)
        var reviewed = saved.selection
        reviewed.excludedItemIDs = Set([finished[0], "icc:user/Example Studio Display.icc"])
        let (continued, continuedSession) = RestorePlanner().continuation(of: saved, manifest: manifest, selection: reviewed)
        let ids = continued.items.map(\.id)
        #expect(ids.contains(finished[0]), "finished steps stay with their results")
        #expect(!ids.contains("icc:user/Example Studio Display.icc"))
        #expect(continuedSession.results.count == 2)
        #expect(continuedSession.selection == reviewed)
        #expect(continuedSession.selection.conflictOverrides["font:user/Studio Grotesk.ttf"] == .skip)
        #expect(Set(continuedSession.remainingItemIDs).isDisjoint(with: finished), "successful work is not repeated")

        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: store)
        let recorder = EventRecorder()
        let final = await executor.run(plan: continued, session: continuedSession, onEvent: recorder.record)
        #expect(Set(recorder.startedIDs).isDisjoint(with: finished))
        #expect(final.results["font:user/Studio Grotesk.ttf"]?.outcome == .skipped(.userSkipped))
        #expect(final.status == .completed)
    }

    @Test func decisionCodesAreStable() {
        func code(_ outcome: ItemOutcome, _ notes: [ResultNote] = []) -> String { ItemResult(itemID: "x", outcome: outcome, notes: notes).decisionCode }
        #expect(code(.succeeded) == "restored")
        #expect(code(.succeeded, [.existingFileMovedAside(path: "~/x")]) == "conflict_restored_backup")
        #expect(code(.succeeded, [.installedUnderNewName(name: "x")]) == "conflict_kept_both")
        #expect(code(.alreadyPresent, [.identicalFileExists]) == "identical_existing")
        #expect(code(.alreadyPresent, [.equivalentFileInstalled]) == "equivalent_existing")
        #expect(code(.alreadyPresent, [.providedByMacOS]) == "kept_macos_version")
        #expect(code(.alreadyPresent) == "already_present")
        #expect(code(.skipped(.keptExisting)) == "conflict_kept_destination")
        #expect(code(.skipped(.userSkipped)) == "skipped_by_user")
        #expect(code(.skipped(.fileNotSupported)) == "incompatible")
        #expect(code(.skipped(.passphraseNotProvided)) == "manual_action_required")
        #expect(code(.failed(RestoreFailure(category: .unknown))) == "failed")
    }

    @Test func alternativeNamesNeverCollide() throws {
        let sandbox = try Sandbox("alt-names")
        let existing = try sandbox.write("a", to: "Paper.icc")
        let first = try #require(RestoreExecutor.alternativeName(for: existing))
        #expect(first.lastPathComponent == "Paper (MacReplica).icc")
        try Data("b".utf8).write(to: first)
        #expect(RestoreExecutor.alternativeName(for: existing)?.lastPathComponent == "Paper (MacReplica 2).icc")
    }
}

@Suite("Selection rules in the planner")
struct SelectionPlannerTests {
    @Test func deselectedEnvironmentsDataAndCredentialsAreNotPlanned() async throws {
        let sandbox = try Sandbox("planner-selection")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        var selection = RestoreSelection(components: Set(RestoreComponent.allCases))
        let environment = try #require(manifest.python.environments.first)
        let data = try #require(manifest.applicationData.first)
        selection.excludedItemIDs = ["python:\(environment.id)", "appdata:\(data.id)"]
        let ids = RestorePlanner().plan(manifest: manifest, selection: selection).items.map(\.id)
        #expect(!ids.contains("python:\(environment.id)"))
        #expect(!ids.contains("appdata:\(data.id)"))
        #expect(ids.contains { $0.hasPrefix("python:") }, "other environments stay")
        #expect(ids.contains { $0.hasPrefix("appdata:") }, "other data stays")
        #expect(Set(ids).count == ids.count, "no item is planned twice")
    }

    @Test func credentialsAreOnlyPlannedWhenChosen() {
        var manifest = Manifest(macreplicaVersion: "1.0.0", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
        manifest.credentials = [CredentialRecord(provider: "ssh", items: ["id_ed25519"], vaultPath: "credentials/ssh.macreplica-vault")]
        #expect(!RestorePlanner().plan(manifest: manifest, selection: RestoreSelection()).items.contains { $0.kind == .credential })
        let chosen = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.credentials])).items
        #expect(chosen.map(\.id) == ["credential:ssh"])
    }

    @Test func homebrewIsOnlyPlannedWhenSomethingNeedsIt() async throws {
        let sandbox = try Sandbox("planner-prereq")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let filesOnly = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.fonts, .colorProfiles])).items
        #expect(!filesOnly.contains { $0.kind == .homebrew || $0.kind == .commandLineTools })
        for component in [RestoreComponent.brewFormulae, .brewCasks, .appStore, .python] {
            let items = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [component])).items
            #expect(items.first?.kind == .commandLineTools, "\(component)")
            #expect(items.contains { $0.kind == .homebrew }, "\(component)")
        }
    }

    @Test func itemsAreOrderedPredictably() async throws {
        let sandbox = try Sandbox("planner-order")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        var selection = RestoreSelection(components: Set(RestoreComponent.allCases))
        selection.enabledTaps = ["example/tools"]
        let items = RestorePlanner().plan(manifest: manifest, selection: selection).items
        let formulae = items.filter { $0.kind == .formula }.map(\.identifier)
        #expect(formulae == formulae.sorted())
        let casks = items.filter { $0.kind == .cask }.map(\.title)
        #expect(casks == casks.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let taps = items.filter { $0.kind == .tap }.map(\.id)
        #expect(taps == taps.sorted())
        // Taps come before the packages that need them.
        if let tap = items.firstIndex(where: { $0.kind == .tap }), let formula = items.firstIndex(where: { $0.id == "formula:example-tool" }) {
            #expect(tap < formula)
        }
    }

    @Test func appStoreAppsWithoutAListEntryAreStillPlanned() {
        var manifest = Manifest(macreplicaVersion: "1.0.0", createdAt: Date(), macosVersion: "15.0", architecture: .arm64)
        // One app is only known from its App Store receipt, one only from the App Store list.
        let receiptOnly = AppRecord(name: "Ledger Lite", bundleIdentifier: "com.example.ledger", path: "/Applications/Ledger Lite.app",
                                    restoreMethod: .appStore(id: 42))
        let listed = AppRecord(name: "Note Pad Pro", bundleIdentifier: "com.example.notepad", path: "/Applications/Note Pad Pro.app")
        manifest.applications = [receiptOnly, listed]
        manifest.masApps = [MASAppRecord(appStoreID: 7, name: "Note Pad Pro", version: "1.0", bundleIdentifier: "com.example.notepad"),
                            MASAppRecord(appStoreID: 7, name: "Note Pad Pro", version: "1.0", bundleIdentifier: "com.example.notepad"),
                            MASAppRecord(appStoreID: 9, name: "Unknown", version: "1.0", bundleIdentifier: nil)]
        let items = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.appStore])).items.filter { $0.kind == .appStoreApp }
        #expect(items.map(\.identifier).sorted() == ["42", "7", "9"], "each app once")
        #expect(items.first { $0.identifier == "42" }?.bundleIdentifier == "com.example.ledger")
        #expect(items.first { $0.identifier == "42" }?.appBundleNames == ["Ledger Lite.app"])
        #expect(items.first { $0.identifier == "7" }?.appBundleNames == ["Note Pad Pro.app"], "matched by bundle identifier")
        #expect(items.first { $0.identifier == "9" }?.appBundleNames == [], "no bundle identifier, no guess")
    }
}

@Suite("Destination index and assessment flags")
struct DestinationIndexTests {
    @Test func flagsFollowTheStatus() {
        func a(_ status: FileAssessment.Status) -> FileAssessment { FileAssessment(status: status) }
        let all: [FileAssessment.Status] = [.ready, .identical, .equivalent, .providedByMacOS, .differentVersion, .differentFile,
                                            .incompatible, .obsoleteAppleProfile, .displayProfile, .legacyFormat]
        #expect(all.filter { a($0).isSatisfied } == [.identical, .equivalent])
        #expect(all.filter { a($0).needsDecision } == [.differentVersion, .differentFile])
        #expect(all.filter { !a($0).selectedByDefault } == [.incompatible, .obsoleteAppleProfile, .displayProfile, .legacyFormat])
        #expect(all.filter { !a($0).canBeRestored } == [.incompatible, .displayProfile])
        #expect(a(.providedByMacOS).conflictChoices(kind: .font) == [.keepExisting, .replace])
        #expect(a(.ready).conflictChoices(kind: .font).isEmpty)
        #expect(a(.differentFile).defaultResolution(kind: .colorProfile) == .keepBoth)
        #expect(a(.differentVersion).defaultResolution(kind: .colorProfile) == .keepBoth)
        #expect(a(.providedByMacOS).defaultResolution(kind: .font) == .keepExisting)
    }

    @Test func userFoldersAreReadAgainForEveryCheck() throws {
        let d = try Destination("index-fresh")
        let before = DestinationFileIndex.build(kind: .font, layout: d.layout).entries.count
        try d.install(font("Added Later"), kind: .font, at: .user, name: "AddedLater.otf")
        try d.install(font("Added Shared"), kind: .font, at: .shared, name: "AddedShared.otf")
        let after = DestinationFileIndex.build(kind: .font, layout: d.layout).entries
        #expect(after.count == before + 2)
        #expect(after.contains { $0.font?.families == ["Added Later"] && $0.location == .user })
        #expect(after.contains { $0.font?.families == ["Added Shared"] && $0.location == .shared })
    }

    @Test func filesInstalledDuringARunAreRecognized() throws {
        let d = try Destination("index-record")
        let index = DestinationFileIndex.build(kind: .font, layout: d.layout)
        let count = index.entries.count
        let installed = d.layout.userFonts.appendingPathComponent("Twin.otf")
        let data = font("Twin")
        try data.write(to: installed)
        index.record(installed: installed, location: .user, kind: .font, sha256: Hashing.sha256Hex(of: data))
        #expect(index.entries.count == count + 1)
        #expect(index.entries.first { $0.url.lastPathComponent == "Twin.otf" }?.font?.postScriptNames == ["Twin-Regular"])
        // Recording the same file again replaces its entry instead of adding a second one.
        index.record(installed: installed, location: .user, kind: .font, sha256: Hashing.sha256Hex(of: data))
        #expect(index.entries.count == count + 1)
        // A second copy of the same font in the backup is then recognized as already installed.
        let duplicate = try d.backedUp(font("Twin", weight: 402), kind: .font, name: "Twin Copy.otf")
        let analyzer = FileConflictAnalyzer(index: index)
        let status = analyzer.assess(record: duplicate, kind: .font, source: d.backup.appendingPathComponent(duplicate.backupPath),
                                     destination: d.layout.userFonts.appendingPathComponent("Twin Copy.otf"), destinationLocation: .user).assessment.status
        #expect(status == .equivalent)
        index.remove(installed)
        #expect(index.entries.count == count)
    }

    @Test func sameFontAndVersionAtTheSamePathIsEquivalent() throws {
        let d = try Destination("font-same-path")
        let record = try d.backedUp(font("Same Path"), kind: .font, name: "SamePath.otf")
        try d.install(font("Same Path", weight: 405), kind: .font, at: .user, name: "SamePath.otf")
        #expect(d.status(record, kind: .font) == .equivalent)
    }

    @Test func sameDescriptionInTheRestoreFolderCanBeReplacedButNotElsewhere() throws {
        let d = try Destination("icc-replace-target")
        let record = try d.backedUp(profile("Gallery Paper", copyright: "a"), kind: .colorProfile, name: "Gallery A.icc")
        try d.install(profile("Gallery Paper", copyright: "b"), kind: .colorProfile, at: .user, name: "Gallery B.icc")
        #expect(d.assess(record, kind: .colorProfile).replaceTarget?.lastPathComponent == "Gallery B.icc")

        let other = try Destination("icc-replace-other-folder")
        let shared = try other.backedUp(profile("Studio Paper", copyright: "a"), kind: .colorProfile, name: "Studio A.icc")
        try other.install(profile("Studio Paper", copyright: "b"), kind: .colorProfile, at: .shared, name: "Studio B.icc")
        #expect(other.assess(shared, kind: .colorProfile).replaceTarget == nil)
    }
}

@Suite("Executor predictions")
struct ExecutorPredictionTests {
    @Test func quickCheckSkipsPackageLookupsButKeepsTheRules() async throws {
        let sandbox = try Sandbox("quick-check")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        var selection = RestoreSelection(components: [.brewFormulae, .brewCasks])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        func prediction(_ entries: [DryRunEntry], _ id: String) -> Prediction? { entries.first { $0.item.id == id }?.prediction }

        let full = await executor.dryRun(plan: plan, selection: selection)
        #expect(prediction(full, "formula:git") == .dependsOnEarlierStep, "no Homebrew on the fresh Mac yet")
        #expect(full.filter { $0.item.kind != .homebrew }.allSatisfy { !$0.requiresAdmin || $0.item.kind.isFile },
                "only Homebrew itself and shared files need administrator rights")
        #expect(full.first { $0.item.kind == .homebrew }?.requiresAdmin == true)

        let quick = await executor.dryRun(plan: plan, selection: selection, checkPackages: false)
        #expect(prediction(quick, "formula:git") == .checkedWhenRestoring)
        #expect(prediction(quick, "tap:example/tools") == .willSkip(.tapNotEnabled(tap: "example/tools")))
        selection.enabledTaps = ["example/tools"]
        let allowed = await executor.dryRun(plan: plan, selection: selection, checkPackages: false)
        #expect(prediction(allowed, "tap:example/tools") == .checkedWhenRestoring)
    }

    @Test func credentialPredictionDependsOnThePassphrase() async throws {
        let sandbox = try Sandbox("credential-prediction")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        var withCredential = manifest
        withCredential.credentials = [CredentialRecord(provider: "ssh", items: ["id_ed25519"], vaultPath: "credentials/ssh.macreplica-vault")]
        let selection = RestoreSelection(components: [.credentials])
        let plan = RestorePlanner().plan(manifest: withCredential, selection: selection)
        var environment = TestEnvironment.restoreEnvironment(target)
        let without = await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil).dryRun(plan: plan, selection: selection)
        #expect(without.first?.prediction == .willSkip(.passphraseNotProvided))
        environment.credentialPassphrase = "synthetic passphrase"
        let with = await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil).dryRun(plan: plan, selection: selection)
        #expect(with.first?.prediction == .willCopy)
    }

    @Test func replacingAVersionUnderAnotherNameMovesOnlyThatFile() async throws {
        let sandbox = try Sandbox("replace-other-name")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        // The new Mac has Example Mono 0.9 in the shared folder under another file name.
        let shared = fresh.url.appendingPathComponent("Library/Fonts")
        try SyntheticFont.make(family: "Example Mono", version: "0.900").write(to: shared.appendingPathComponent("Mono-Old.ttf"))
        var selection = RestoreSelection(components: [.fonts])
        selection.conflictOverrides = ["font:system/ExampleMono.ttc": .replace]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "~/b", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["font:system/ExampleMono.ttc"]?.decisionCode == "conflict_restored_backup")
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("Mono-Old.ttf").path), "the old version was moved aside")
        #expect(FileScanner.fontIdentity(shared.appendingPathComponent("ExampleMono.ttc"))?.shortVersion == "1.000")
        let aside = target.layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/fonts/system/Mono-Old.ttf")
        #expect(FileScanner.fontIdentity(aside)?.shortVersion == "0.900", "kept, never deleted")
    }
}

@Suite("Executor edge cases")
struct ExecutorEdgeTests {
    private func run(_ executor: RestoreExecutor, _ plan: RestorePlan, _ selection: RestoreSelection) async -> RestoreSession {
        await executor.run(plan: plan, session: RestoreSession(backupPath: "~/b", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    }

    @Test func appStoreAppsWithoutBundleInformationAreVerifiedThroughTheAppStoreList() async throws {
        let sandbox = try Sandbox("mas-unidentifiable")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.appStore])
        var plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        plan.items = plan.items.map { item in
            guard item.kind == .appStoreApp else { return item }
            var copy = item
            copy.bundleIdentifier = nil
            copy.appBundleNames = []
            return copy
        }
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        let first = await run(executor, plan, selection)
        #expect(first.results["mas:1234567890"]?.outcome == .succeeded)
        #expect(first.results["mas:1234567890"]?.installedVersion == "5.1", "version from the App Store list")
        let second = await run(executor, plan, selection)
        #expect(second.results["mas:1234567890"]?.outcome == .alreadyPresent, "found in the App Store list, not installed again")
    }

    @Test func installedAppsAreFoundByBundleIdentifierUnderAnotherName() async throws {
        let sandbox = try Sandbox("bundle-id-search")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let bundle = fresh.url.appendingPathComponent("Applications/Renamed Ledger.app/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.ledgerlite", "CFBundleShortVersionString": "5.0", "CFBundleName": "Renamed Ledger"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        let selection = RestoreSelection(components: [.appStore])
        var plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        plan.items = plan.items.map { item in
            guard item.kind == .appStoreApp else { return item }
            var copy = item
            copy.appBundleNames = []
            return copy
        }
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        let entries = await executor.dryRun(plan: plan, selection: selection)
        #expect(entries.first { $0.item.id == "mas:1234567890" }?.prediction == .alreadyPresent(version: "5.0"))
        let session = await run(executor, plan, selection)
        #expect(session.results["mas:1234567890"]?.outcome == .alreadyPresent)
    }

    @Test func unwritableFoldersFailOnlyTheirItems() async throws {
        let sandbox = try Sandbox("permission-category")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let sans = fresh.url.appendingPathComponent("home/Library/Fonts/Example Sans")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sans.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sans.path) }
        let selection = RestoreSelection(components: [.fonts])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await run(RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil), plan, selection)
        // An unwritable folder is handed to the administrator copy; if that fails too, the item fails — never "restored".
        let result = try #require(session.results["font:user/Example Sans/ExampleSans-Bold.otf"])
        #expect(result.decisionCode == "failed")
        #expect(session.results["font:user/Example Sans/ExampleSans-Regular.otf"]?.outcome == .alreadyPresent)
    }

    @Test func retryingIncludesEveryPrerequisiteTransitively() async throws {
        let sandbox = try Sandbox("retry-subset")
        let (_, manifest) = try await TestEnvironment.makeBackup(sandbox)
        var selection = RestoreSelection(components: [.brewFormulae])
        selection.enabledTaps = ["example/tools"]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let subset = plan.subset(retrying: ["formula:example-tool"]).items.map(\.id)
        #expect(subset == [RestoreItem.commandLineToolsID, RestoreItem.homebrewID, "tap:example/tools", "formula:example-tool"])
        #expect(plan.subset(retrying: []).items.isEmpty)
    }

    @Test func sharedFilesNeedOneRequestWithExactCountsAndKeepReplacedFiles() async throws {
        let sandbox = try Sandbox("privileged-replace")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let fonts = fresh.url.appendingPathComponent("Library/Fonts")
        let profiles = fresh.url.appendingPathComponent("Library/ColorSync/Profiles")
        try SyntheticFont.make(family: "Example Mono", version: "0.900").write(to: fonts.appendingPathComponent("ExampleMono.ttc"))
        for folder in [fonts, profiles] { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in [fonts, profiles] { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }
        let privileged = RecordingPrivileged(grant: true, unlock: [fonts, profiles])
        var selection = RestoreSelection(components: [.fonts, .colorProfiles])
        selection.conflictOverrides = ["font:system/ExampleMono.ttc": .replace]
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await run(RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target, privileged: privileged), backupRoot: backup,
                                                sessionStore: nil), plan, selection)
        #expect(privileged.calls.count == 1)
        #expect(privileged.calls.first?.reason == TestEnvironment.english.t("admin.reason.files", 1, 1))
        #expect(session.results["font:system/ExampleMono.ttc"]?.decisionCode == "conflict_restored_backup")
        let aside = target.layout.applicationSupport.appendingPathComponent("Replaced Files/\(session.id)/fonts/system/ExampleMono.ttc")
        #expect(FileScanner.fontIdentity(aside)?.shortVersion == "0.900")
    }
}

@Suite("ICC computed ID boundary")
struct ICCComputedIDBoundaryTests {
    @Test func fieldEndingExactlyAtTheEndIsZeroed() {
        let data = Data((0..<48).map { UInt8($0) })
        var expected = [UInt8](data)
        for index in 44..<48 { expected[index] = 0 }
        #expect(ICCProfileHeader.computedProfileID(data) == Insecure.MD5.hash(data: expected).map { String(format: "%02x", $0) }.joined())
    }
}
