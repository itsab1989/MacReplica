import Foundation
import Testing
@testable import MacReplicaCore

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
