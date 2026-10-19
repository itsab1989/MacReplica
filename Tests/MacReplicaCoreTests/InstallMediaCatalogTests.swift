import Foundation
import Testing
@testable import MacReplicaCore

/// The installer catalog is read live from Software Update and Apple's support page; nothing about versions is in
/// the app. These tests feed both sources as they really answer (macOS 27, 2026-10-19).
@Suite("Install media: catalog")
struct InstallMediaCatalogTests {
    static let now = Date(timeIntervalSince1970: 1_792_400_000)

    /// `softwareupdate --list-full-installers` on the maintainer's Mac (27.0.1, 26A434, Apple silicon), abridged.
    static let softwareUpdate = """
    Finding available software
    Software Update found the following full installers:
    * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 17955378KiB, Build: 26A434, Deferred: NO
    * Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
    * Title: macOS Tahoe, Version: 26.7.1, Size: 17950170KiB, Build: 25G241, Deferred: NO
    * Title: macOS Tahoe, Version: 26.10, Size: 17950170KiB, Build: 25H9, Deferred: NO
    * Title: macOS Sequoia, Version: 15.8.1, Size: 15000000KiB, Build: 24H1, Deferred: NO
    * Title: macOS Sonoma, Version: 14.8.9, Size: 13334756KiB, Build: 23J631, Deferred: NO
    """

    static var applePage: String {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/InstallMedia/apple-102662-links.html")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func softwareUpdateLinesBecomeReleases() {
        let releases = MacOSInstallerCatalog.parseSoftwareUpdate(Self.softwareUpdate, checkedAt: Self.now)
        #expect(releases.count == 6)
        let sonoma = releases.last!
        #expect(sonoma.name == "macOS Sonoma")
        #expect(sonoma.major == "14")
        #expect(sonoma.version == "14.8.9")
        #expect(sonoma.build == "23J631")
        #expect(sonoma.sizeBytes == Int64(13_334_756) * 1024)
        #expect(sonoma.source == .softwareUpdate)
        #expect(sonoma.installerAppName == "Install macOS Sonoma.app")
        #expect(releases.first?.installerAppName == "Install macOS 27 Golden Gate.app")
        #expect(sonoma.provenance.hasPrefix("softwareupdate --list-full-installers"))
    }

    @Test func malformedOrHostileLinesAreDropped() {
        let output = """
        * Title: macOS Sonoma, Version: 14.8.9, Size: 1KiB, Build: 23J631, Deferred: NO
        * Title: ../../evil, Version: 14.8.9, Size: 1KiB, Build: 23J631
        * Title: macOS Sonoma, Version: 14.8.9; rm -rf, Size: 1KiB, Build: 23J631
        * Title: macOS Sonoma, Size: 1KiB, Build: 23J631
        Title: macOS Sonoma, Version: 14.8.8, Size: 1KiB, Build: 23J1
        * Title: macOS Sonoma, Version: 14.8.7, Size: hugeKiB, Build: $(x)
        """
        let releases = MacOSInstallerCatalog.parseSoftwareUpdate(output, checkedAt: Self.now)
        #expect(releases.map(\.version) == ["14.8.9", "14.8.7"])
        #expect(releases[1].sizeBytes == nil)
        #expect(releases[1].build == nil)
    }

    @Test func sizesAndMajorReleases() {
        #expect(MacOSInstallerCatalog.parseSize("2KiB") == 2048)
        #expect(MacOSInstallerCatalog.parseSize("3MB") == 3_000_000)
        #expect(MacOSInstallerCatalog.parseSize("1GiB") == 1_073_741_824)
        #expect(MacOSInstallerCatalog.parseSize("12") == 12)
        #expect(MacOSInstallerCatalog.parseSize("9223372036854775807KiB") == nil)
        #expect(MacOSInstallerCatalog.majorRelease(of: "14.8.9") == "14")
        #expect(MacOSInstallerCatalog.majorRelease(of: "10.15.7") == "10.15")
        #expect(MacOSInstallerCatalog.majorRelease(of: "27") == "27")
        #expect(MacOSInstallerCatalog.majorRelease(of: "10") == "10")
    }

    @Test func applePageLinksAreReadAsServed() {
        let releases = MacOSInstallerCatalog.parseApplePage(Self.applePage, checkedAt: Self.now)
        #expect(releases.map(\.major) == ["15", "14", "13", "12", "11", "10.15", "10.14", "10.13", "10.12", "10.11", "10.10", "10.8", "10.7"])
        #expect(releases.map(\.name) == ["macOS Sequoia", "macOS Sonoma", "macOS Ventura", "macOS Monterey", "macOS Big Sur",
                                         "macOS Catalina", "macOS Mojave", "macOS High Sierra", "macOS Sierra", "OS X El Capitan",
                                         "OS X Yosemite", "OS X Mountain Lion", "Mac OS X Lion"])
        #expect(releases[1].source == .appStore(id: 6450717509, url: "macappstores://apps.apple.com/app/id6450717509?mt=12"))
        // The page's http links are served over https from Apple's CDN.
        #expect(releases[8].source == .appleDiskImage(url: "https://updates.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg"))
        #expect(releases.allSatisfy { $0.version == nil && $0.provenance.hasPrefix("support.apple.com/102662") })
        #expect(releases[9].installerAppName == "Install OS X El Capitan.app")
    }

    @Test func onlyApplesOwnLinksAreTaken() {
        let html = """
        <a href="macappstores://apps.example.com/app/macos-x/id1?mt=12">macOS Fake 30</a>
        <a href="https://updates.cdn-apple.com.evil.example/x/InstallOS.dmg">Fake 10.12</a>
        <a href="https://evil.example/updates.cdn-apple.com/InstallOS.dmg">Fake 10.11</a>
        <a href="ftp://updates.cdn-apple.com/x/InstallOS.dmg">Fake 10.10</a>
        <a href="https://updates.cdn-apple.com/x/InstallOS.pkg">Fake 10.9</a>
        <a href="https://updates.cdn-apple.com/x/../../InstallOS.dmg">Fake 10.6</a>
        <a href="https://apps.apple.com/app/macos-real/idabc">macOS Bad 31</a>
        <a href="https://apps.apple.com/app/macos-real/id42">macOS Real 32</a>
        <a href="macappstores://apps.apple.com/app/macos-x/id7">macOS &lt;script&gt; 33</a>
        <a href="https://apps.apple.com/app/x/id8">Not a release</a>
        """
        let releases = MacOSInstallerCatalog.parseApplePage(html, checkedAt: Self.now)
        #expect(releases.map(\.major) == ["32"])
        #expect(releases.first?.source == .appStore(id: 42, url: "macappstores://apps.apple.com/app/id42?mt=12"))
    }

    @Test func groupedNewestMajorFirstThenNewestVersion() {
        let su = MacOSInstallerCatalog.parseSoftwareUpdate(Self.softwareUpdate, checkedAt: Self.now)
        let page = MacOSInstallerCatalog.parseApplePage(Self.applePage, checkedAt: Self.now)
        let catalog = MacOSInstallerCatalog(releases: MacOSInstallerCatalog.merged(softwareUpdate: su, applePage: page))
        let groups = catalog.grouped
        #expect(groups.map(\.major) == ["27", "26", "15", "14", "13", "12", "11", "10.15", "10.14", "10.13", "10.12", "10.11", "10.10", "10.8", "10.7"])
        // 26.10 is newer than 26.7.1 (numbers, not text).
        #expect(groups[1].releases.map(\.version) == ["26.10", "26.7.1"])
        // Software Update covers 15 and 14, so the page's App Store entries for them are not shown twice.
        #expect(groups[2].releases.map(\.source) == [.softwareUpdate])
        #expect(groups[0].name == "macOS 27 Golden Gate")
        #expect(groups[4].releases.first?.source == .appStore(id: 1638787999, url: "macappstores://apps.apple.com/app/id1638787999?mt=12"))
    }

    @Test func aFutureReleaseNeedsNoAppUpdate() {
        let output = "* Title: macOS 28 Cupertino, Version: 28.0, Size: 18000000KiB, Build: 27A100, Deferred: NO\n"
            + Self.softwareUpdate
        let catalog = MacOSInstallerCatalog(releases: MacOSInstallerCatalog.parseSoftwareUpdate(output, checkedAt: Self.now))
        #expect(catalog.grouped.first?.major == "28")
        #expect(catalog.grouped.first?.releases.first?.installerAppName == "Install macOS 28 Cupertino.app")
        #expect(MacOSInstallerCatalog.suitability(of: catalog.grouped[0].releases[0],
                                                  on: ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64)) == .downloadHere)
    }

    @Test func appleSiliconStartsOnlyMacOS11AndLater() {
        let page = MacOSInstallerCatalog.parseApplePage(Self.applePage, checkedAt: Self.now)
        let arm = ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64)
        let intel = ToolEnvironment(macOSVersion: "14.8.9", architecture: .x86_64)
        let bigSur = page.first { $0.major == "11" }!
        let catalina = page.first { $0.major == "10.15" }!
        let sierra = page.first { $0.major == "10.12" }!
        #expect(MacOSInstallerCatalog.suitability(of: bigSur, on: arm) == .appStore)
        #expect(MacOSInstallerCatalog.suitability(of: catalina, on: arm) == .intelMacsOnly)
        #expect(MacOSInstallerCatalog.suitability(of: sierra, on: arm) == .intelMacsOnly)
        #expect(MacOSInstallerCatalog.suitability(of: catalina, on: intel) == .appStore)
        #expect(MacOSInstallerCatalog.suitability(of: sierra, on: intel) == .appleDiskImage)
    }

    @Test func loaderReadsBothSourcesAndCachesThem() async throws {
        let sandbox = try Sandbox("catalog")
        let layout = toolchainLayout(sandbox)
        let runner = ScriptedRunner { command in
            #expect(command.arguments == ["--list-full-installers"])
            return CommandResult(exitCode: 0, stdout: Self.softwareUpdate, stderr: "")
        }
        let cache = sandbox.url.appendingPathComponent("cache/catalog.json")
        let page = Self.applePage
        let loader = MacOSInstallerCatalogLoader(layout: layout, runner: runner, cacheFile: cache) { _ in page }
        #expect(loader.cached() == MacOSInstallerCatalog())
        let catalog = await loader.refresh(now: Self.now)
        #expect(runner.commands.map(\.executable) == [layout.softwareupdate])
        #expect(catalog.softwareUpdateCheckedAt == Self.now)
        #expect(catalog.applePageCheckedAt == Self.now)
        #expect(catalog.softwareUpdateProblem == nil && catalog.applePageProblem == nil)
        #expect(catalog.grouped.count == 15)
        #expect(loader.cached() == catalog)
    }

    @Test func aFailingSourceKeepsItsLastEntriesAndSaysWhy() async throws {
        let sandbox = try Sandbox("catalog-fail")
        let layout = toolchainLayout(sandbox)
        let cache = sandbox.url.appendingPathComponent("catalog.json")
        let page = Self.applePage
        let good = MacOSInstallerCatalogLoader(layout: layout, runner: ScriptedRunner { _ in
            CommandResult(exitCode: 0, stdout: Self.softwareUpdate, stderr: "")
        }, cacheFile: cache) { _ in page }
        let first = await good.refresh(now: Self.now)

        let later = Self.now.addingTimeInterval(3600)
        let offline = MacOSInstallerCatalogLoader(layout: layout, runner: ScriptedRunner { _ in
            CommandResult(exitCode: 1, stdout: "", stderr: "Install failed with error: The network connection was lost.")
        }, cacheFile: cache) { _ in throw MacOSInstallerCatalogError.pageUnavailable("offline") }
        let second = await offline.refresh(now: later)
        #expect(second.releases == first.releases)
        #expect(second.softwareUpdateCheckedAt == Self.now)
        #expect(second.applePageCheckedAt == Self.now)
        #expect(second.softwareUpdateProblem?.contains("network connection was lost") == true)
        #expect(second.applePageProblem?.contains("offline") == true)

        let changedPage = MacOSInstallerCatalogLoader(layout: layout, runner: ScriptedRunner { _ in
            CommandResult(exitCode: 0, stdout: "Finding available software\n", stderr: "")
        }, cacheFile: cache) { _ in "<html>redesigned</html>" }
        let third = await changedPage.refresh(now: later)
        #expect(third.softwareUpdateCheckedAt == later)
        #expect(third.softwareUpdateProblem == "Software Update listed no full installers")
        #expect(third.releases.allSatisfy { $0.source != .softwareUpdate })
        #expect(third.applePageCheckedAt == Self.now)
        #expect(third.applePageProblem != nil)
        #expect(!third.releases.isEmpty)
    }
}
