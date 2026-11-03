import Foundation
import Testing
@testable import MacReplicaCore

/// The tester's guided installation opened App Store pages that answered "App Not Available – This app is currently
/// not available in your country or region" (2026-11-03, TEST1111-006): the backup had the IDs 469067434 and 413817190,
/// which Apple's lookup no longer knows; the current editions (469068059, 413817051) were found by searching.
@Suite("App Store apps that are no longer offered")
struct AppStoreAvailabilityTests {
    /// Answers Apple's lookup like the real service: `resultCount` 1 for known IDs, 0 for the others.
    struct LookupFetcher: HTTPFetching {
        var known: Set<String>
        var failing = false
        let asked = Asked()
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            func add(_ url: URL) { lock.withLock { urls.append(url) } }
            var all: [URL] { lock.withLock { urls } }
        }

        func fetch(_ url: URL, maxBytes: Int) async throws -> (data: Data, finalURL: URL) {
            asked.add(url)
            if failing { throw DownloadError.network("offline") }
            guard url.host == "itunes.apple.com", url.path == "/lookup",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
            else { throw DownloadError.httpStatus(404) }
            let count = known.contains(id) ? 1 : 0
            return (Data(#"{"resultCount":\#(count),"results":[]}"#.utf8), url)
        }
    }

    func offers(_ fetcher: LookupFetcher, name: String, id: Int) async -> [DownloadOffer] {
        let app = AppRecord(name: name, path: "/Applications/\(name).app", source: .appStore, restoreMethod: .appStore(id: id))
        return await DownloadSourceFinder(fetcher: fetcher, catalog: nil, macOSVersion: "14.8", architecture: .arm64)
            .offers(for: app, itemID: "mas:\(id)")
    }

    @Test("An ID the App Store still has keeps its page link")
    func availableKeepsLink() async {
        let offer = await offers(LookupFetcher(known: ["469068059"]), name: "Daily Workouts", id: 469068059).first { $0.kind == .appStore }
        #expect(offer?.url == "macappstore://apps.apple.com/app/id469068059")
        #expect(offer?.appStoreSearchTerm == nil)
    }

    @Test("An ID the App Store no longer has becomes a search for the name, with the words split")
    func goneBecomesSearch() async {
        let fetcher = LookupFetcher(known: [])
        let offer = await offers(fetcher, name: "DailyWorkouts", id: 469067434).first { $0.kind == .appStore }
        #expect(offer?.appStoreSearchTerm == "Daily Workouts")
        #expect(offer?.url == "macappstore://apps.apple.com/search?term=Daily%20Workouts")
        #expect(offer?.recommended == true)
        // Asked for this Mac's region first (when it has one), then without a region, before giving up.
        #expect(fetcher.asked.all.last?.absoluteString == "https://itunes.apple.com/lookup?id=469067434")
        let step: GuidedStep = offer?.appStoreSearchTerm.map { .searchAppStore($0) } ?? .installFromAppStore
        #expect(step == .searchAppStore("Daily Workouts"))
    }

    @Test("This Mac's region is asked first when it has one; an invalid ID is not looked up")
    func regionAndInvalidID() async {
        let fetcher = LookupFetcher(known: [])
        _ = await offers(fetcher, name: "SimplyYoga", id: 413817190)
        let region = Locale.current.region?.identifier.lowercased().filter(\.isLetter) ?? ""
        let first = fetcher.asked.all.first?.absoluteString ?? ""
        #expect(first.contains("&country=") == (region.count == 2), "\(first)")
        if region.count == 2 { #expect(first == "https://itunes.apple.com/lookup?id=413817190&country=\(region)") }
        let none = LookupFetcher(known: [])
        let offer = await offers(none, name: "Zero", id: 0).first { $0.kind == .appStore }
        #expect(none.asked.all.isEmpty, "ID 0 is not asked for")
        #expect(offer?.url == "macappstore://apps.apple.com/app/id0")
    }

    @Test("Without an answer from Apple (offline) the page link is kept")
    func offlineKeepsLink() async {
        let offer = await offers(LookupFetcher(known: [], failing: true), name: "SimplyYoga", id: 413817190).first { $0.kind == .appStore }
        #expect(offer?.url == "macappstore://apps.apple.com/app/id413817190")
        #expect(offer?.appStoreSearchTerm == nil)
    }

    @Test("Search terms: run-together words are split, other names stay as they are")
    func searchTerms() {
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "SimplyYoga")?.term == "Simply Yoga")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "Brother iPrint&Scan")?.term == "Brother iPrint&Scan")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "Brother iPrint&Scan")?.url == "macappstore://apps.apple.com/search?term=Brother%20iPrint%26Scan")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "DaVinciResolve")?.term == "DaVinci Resolve")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "iMovie")?.term == "iMovie")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "OneDrive")?.term == "One Drive")
        #expect(DownloadSourceFinder.appStoreSearchURL(for: "  ") == nil)
    }

    @Test("The guided step and the offer say that the edition is gone and what to do")
    func texts() {
        let l = TestEnvironment.english
        var offer = DownloadOffer(id: "appstore-search:1", itemID: "mas:1", kind: .appStore, url: "macappstore://apps.apple.com/search?term=X")
        offer.appStoreSearchTerm = "Daily Workouts"
        #expect(l.offerText(offer).contains("no longer offered"))
        #expect(l.guidedStepText(.searchAppStore("Daily Workouts")).contains("“Daily Workouts”"))
        #expect(l.guidedStepText(.searchAppStore("Daily Workouts")).contains("Skip"))
    }

    actor StepRecorder: GuidedInstallInteraction {
        var opened: [String] = []
        var steps: [GuidedStep] = []
        func openPackage(_ url: URL) async {}
        func openInFinder(_ url: URL) async {}
        func open(_ url: URL) async { opened.append(url.absoluteString) }
        func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision { steps.append(step); return .later }
    }

    @Test("The guided installation opens the search and asks with the search step; a normal offer keeps the page step")
    func guidedSteps() async throws {
        let fixture = try VendorFixture("app-store-search")
        let layout = toolchainLayout(fixture.sandbox)
        let installer = fixture.installer(layout: layout)
        let guided = GuidedInstallation(installer: installer, queue: DownloadQueue(transport: LocalDownloadTransport(root: fixture.root),
                                                                                    folder: installer.downloadsFolder))
        let item = RestoreItem(id: "mas:469067434", kind: .appStoreApp, title: "DailyWorkouts", identifier: "469067434",
                               bundleIdentifier: "com.example.dailyworkouts", appBundleNames: ["DailyWorkouts.app"])
        var search = DownloadOffer(id: "appstore-search:469067434", itemID: item.id, kind: .appStore,
                                   url: "macappstore://apps.apple.com/search?term=Daily%20Workouts", recommended: true)
        search.appStoreSearchTerm = "Daily Workouts"
        let recorder = StepRecorder()
        _ = await guided.install(item, offer: search, interaction: recorder, isInstalled: { _ in nil })
        let page = DownloadOffer(id: "appstore:469068059", itemID: item.id, kind: .appStore, url: "macappstore://apps.apple.com/app/id469068059")
        _ = await guided.install(item, offer: page, interaction: recorder, isInstalled: { _ in nil })
        #expect(await recorder.steps == [.searchAppStore("Daily Workouts"), .installFromAppStore])
        #expect(await recorder.opened == [search.url, page.url])
    }
}
