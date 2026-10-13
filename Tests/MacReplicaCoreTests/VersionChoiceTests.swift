import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.4: “restore the exact version or install the latest stable one?” Each source states which
/// version it installs compared with the old Mac, and the channel (stable, beta …) is never switched silently.
@Suite("Version choice")
struct VersionChoiceTests {
    static func offer(_ id: String, _ kind: DownloadOffer.Kind, version: String?, channel: ReleaseChannel? = nil, recommended: Bool = false) -> DownloadOffer {
        DownloadOffer(id: id, itemID: "manual:x", kind: kind, url: "https://example.com/\(id)", version: version, channel: channel,
                      recommended: recommended, trust: .vendorSignature)
    }

    @Test func eachSourceSaysWhichVersionItInstalls() {
        let l = TestEnvironment.english
        #expect(l.installedVersionText(Self.offer("a", .vendorFeed, version: "2.4"), original: "2.4") == "Installs version 2.4 – the same version as on the old Mac")
        #expect(l.installedVersionText(Self.offer("a", .vendorFeed, version: "2.10"), original: "2.9")?.hasPrefix("Installs version 2.10 – newer than the 2.9 you had") == true)
        #expect(l.installedVersionText(Self.offer("a", .ownInstaller, version: "2.3"), original: "2.4")?.hasPrefix("Installs version 2.3 – older") == true)
        #expect(l.installedVersionText(Self.offer("a", .vendorWebsite, version: nil), original: "2.4") == nil, "unknown versions are not invented")
        #expect(l.installedVersionText(Self.offer("a", .homebrewCask, version: "5"), original: nil) == "Installs version 5")
    }

    @Test func aChannelIsNeverSwitchedSilently() {
        let stable = Self.offer("stable", .vendorFeed, version: "130.0", channel: .stable)
        let beta = Self.offer("beta", .vendorFeed, version: "131.0b2", channel: .beta)
        let website = Self.offer("web", .vendorWebsite, version: nil)
        // A beta app with only a stable download: no default (the user decides), the website is still a neutral choice.
        #expect(DownloadSourceFinder.defaultOffer([stable], originalChannel: .beta) == nil)
        #expect(DownloadSourceFinder.defaultOffer([stable, website], originalChannel: .beta)?.id == "web")
        // A stable app is never given a beta.
        #expect(DownloadSourceFinder.defaultOffer([beta], originalChannel: nil) == nil)
        #expect(DownloadSourceFinder.defaultOffer([beta, stable], originalChannel: nil)?.id == "stable")
        #expect(DownloadSourceFinder.defaultOffer([beta, stable], originalChannel: .beta)?.id == "beta")
        // The recommended offer (same channel, best verification) always wins; the own installer is exact and channel-neutral.
        let own = Self.offer("own", .ownInstaller, version: "130.0", recommended: true)
        #expect(DownloadSourceFinder.defaultOffer([stable, own], originalChannel: .beta)?.id == "own")
        let marked = DownloadSourceFinder.markRecommended([beta, stable], originalChannel: .beta)
        #expect(marked.first(where: \.recommended)?.id == "beta")
    }
}

/// Beta feedback 1.0.4: Office LTSC 2024 16.113.4 – which of the offered packages is it? All install the same apps; the
/// licence decides. MacReplica reports how Office is activated from the existence of the licence file only.
@Suite("Microsoft Office edition")
struct OfficeEditionTests {
    @Test func activationIsTakenFromTheLicenceFileItsContentsNeverRead() async throws {
        let sandbox = try Sandbox("office-edition")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        _ = try SimulationBuilder.makeSyntheticApp(name: "Microsoft Word", bundleID: "com.microsoft.Word", version: "16.113.4",
                                                   in: root.url.appendingPathComponent("Applications"))
        var result = try await TestEnvironment.inventory(source).run()
        #expect(result.manifest.officeActivation == .signIn)
        let licence = source.layout.sharedLibrary.appendingPathComponent("Preferences/com.microsoft.office.licensingV2.plist")
        try FileManager.default.createDirectory(at: licence.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("encrypted, bound to this Mac".utf8).write(to: licence)
        result = try await TestEnvironment.inventory(source).run()
        #expect(result.manifest.officeActivation == .volumeLicence)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        #expect(!outcome.manifest.allFileRecords.contains { $0.fileName.contains("licensingV2") }, "the licence file is never copied")
        let guide = try String(contentsOf: outcome.url.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("volume licence (Office LTSC 2024 or 2021") && guide.contains("Volume License Serializer"))
        // No Office app: nothing is said about Office.
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("Applications/Microsoft Word.app"))
        #expect(try await TestEnvironment.inventory(source).run().manifest.officeActivation == nil)
    }

    @Test func candidatesCarryHomebrewsDescription() {
        let catalog = CaskCatalog(casks: [
            CaskInfo(token: "microsoft-word", names: ["Microsoft Word"], appArtifacts: ["Microsoft Word.app"], bundleIdentifiers: ["com.microsoft.word"], desc: "Word processor"),
            CaskInfo(token: "microsoft-office", names: ["Microsoft Office"], appArtifacts: ["Microsoft Word.app", "Microsoft Excel.app"],
                     bundleIdentifiers: ["com.microsoft.word"], desc: "Office suite")])
        let app = AppRecord(name: "Microsoft Word", version: "16.113.4", bundleIdentifier: "com.microsoft.Word", path: "/Applications/Microsoft Word.app")
        guard case .needsDecision(let candidates) = Matcher(catalog: catalog).match(app) else { Issue.record("expected a decision"); return }
        #expect(Set(candidates.compactMap(\.summary)) == ["Word processor", "Office suite"])
        #expect(OfficeActivation.isOfficeApp(app) && !OfficeActivation.isOfficeApp(AppRecord(name: "X", bundleIdentifier: "com.microsoft.VSCode", path: "/x")))
    }
}
