import CryptoKit
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Distribution channels")
struct ChannelTests {
    @Test(arguments: [
        ("firefox@nightly", ReleaseChannel.nightly), ("visual-studio-code@insiders", .insider), ("intellij-idea@eap", .preview),
        ("iterm2@beta", .beta), ("firefox@esr", .stable), ("google-chrome@canary", .nightly), ("firefox@developer-edition", .preview),
    ])
    func caskTokens(_ token: String, _ channel: ReleaseChannel) {
        #expect(ChannelDetector.channel(caskToken: token) == channel)
    }

    @Test func numericCaskSuffixesAreVersionsNotChannels() {
        #expect(ChannelDetector.channel(caskToken: "temurin@21") == nil)
        #expect(ChannelDetector.channel(caskToken: "firefox") == nil)
    }

    @Test(arguments: [
        ("com.google.Chrome.canary", ReleaseChannel.nightly), ("com.microsoft.VSCodeInsiders", .insider), ("org.mozilla.nightly", .nightly),
        ("com.jetbrains.intellij-EAP", .preview), ("com.brave.Browser.beta", .beta), ("dev.zed.Zed-Preview", .preview),
        ("org.mozilla.firefoxdeveloperedition", .preview), ("com.apple.SafariTechnologyPreview", .preview), ("com.microsoft.edgemac.Dev", .nightly),
    ])
    func bundleIdentifiers(_ identifier: String, _ channel: ReleaseChannel) {
        #expect(ChannelDetector.channel(bundleIdentifier: identifier) == channel)
    }

    @Test func ordinaryBundleIdentifiersAndNamesHaveNoChannel() {
        for identifier in ["com.example.markdownpreview", "com.example.betaflight", "org.mozilla.firefox", "com.example.devtools"] {
            #expect(ChannelDetector.channel(bundleIdentifier: identifier) == nil, "\(identifier)")
        }
        for name in ["Markdown Preview", "Dev Utils", "Alphabet Soup", "Firefox"] {
            #expect(ChannelDetector.channel(appName: name) == nil, "\(name)")
        }
    }

    @Test func namesVersionsAndFeeds() {
        #expect(ChannelDetector.channel(appName: "Firefox Nightly") == .nightly)
        #expect(ChannelDetector.channel(appName: "Xcode-beta") == .beta)
        #expect(ChannelDetector.channel(appName: "Visual Studio Code - Insiders") == .insider)
        #expect(ChannelDetector.channel(appName: "Firefox Developer Edition") == .preview)
        #expect(ChannelDetector.channel(version: "158.0b3") == .beta)
        #expect(ChannelDetector.channel(version: "159.0a1") == .nightly)
        #expect(ChannelDetector.channel(version: "1.141.0-insider") == .insider)
        #expect(ChannelDetector.channel(version: "8.12.40-27.BETA") == .beta)
        #expect(ChannelDetector.channel(version: "2.0-rc2") == .beta)
        #expect(ChannelDetector.channel(version: "128.0.1") == nil)
        #expect(ChannelDetector.channel(feedURL: "https://example.com/appcast-beta.xml") == .beta)
        let detected = ChannelDetector.detect(caskToken: nil, bundleIdentifier: "org.mozilla.firefox", appName: "Firefox", version: "158.0b3", feedURL: nil)
        #expect(detected?.0 == .beta && detected?.1 == .version)
        #expect(ChannelDetector.detect(caskToken: nil, bundleIdentifier: "com.example.app", appName: "App", version: "1.0", feedURL: nil) == nil,
                "no evidence: no channel is assumed")
    }

    @Test func updateFeedFromInfoPlist() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": key])
                == UpdateFeed(url: "https://updates.example.com/appcast.xml", publicEDKey: key))
        #expect(UpdateFeed.from(info: ["SUFeedURL": "SET_PROGRAMMATICALLY_BY_APPLICATION_HELPER"]) == nil)
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https://user:pass@updates.example.com/appcast.xml"]) == nil)
        #expect(UpdateFeed.from(info: ["SUFeedURL": "file:///etc/passwd"]) == nil)
        #expect(UpdateFeed.from(info: ["SUFeedURL": "https://updates.example.com/a.xml", "SUPublicEDKey": "short"])?.publicEDKey == nil)
    }
}

/// Synthetic vendor data: an app, its zip, an EdDSA key and an appcast, served by `LocalFetcher`.
struct VendorFixture {
    let sandbox: Sandbox
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    init(_ name: String) throws { sandbox = try Sandbox(name) }

    var root: URL { sandbox.url }

    /// Builds `<name>.app`, zips it with `ditto` into `downloads/<host>/<path>` and returns size and signature.
    func publishZip(appName: String, bundleID: String, version: String, path: String, architectures: [CPUArchitecture] = [.arm64, .x86_64],
                    minimumSystemVersion: String = "13.0") throws -> (length: Int64, signature: String, sha256: String) {
        let build = try sandbox.folder("build-\(UUID().uuidString)")
        let app = try SimulationBuilder.makeSyntheticApp(name: appName, bundleID: bundleID, version: version, architectures: architectures,
                                                         minimumSystemVersion: minimumSystemVersion, in: build)
        let zip = root.appendingPathComponent("downloads/" + path)
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: zip)
        return (Int64(data.count), try key.signature(for: data).base64EncodedString(), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func publishAppcast(_ xml: String, path: String) throws {
        let file = root.appendingPathComponent("downloads/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: file)
    }

    static func item(version: String, short: String, url: String, length: Int64, signature: String, channel: String? = nil,
                     minimum: String? = nil, hardware: String? = nil) -> String {
        """
        <item><title>\(short)</title><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>\(short)</sparkle:shortVersionString>
        \(channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? "")\(minimum.map { "<sparkle:minimumSystemVersion>\($0)</sparkle:minimumSystemVersion>" } ?? "")
        \(hardware.map { "<sparkle:hardwareRequirements>\($0)</sparkle:hardwareRequirements>" } ?? "")
        <enclosure url="\(url)" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(signature)"/></item>
        """
    }

    static func appcast(_ items: [String]) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Example</title>
        \(items.joined(separator: "\n"))
        </channel></rss>
        """
    }

    func installer(layout: SystemLayout, macOS: String = "15.0", architecture: CPUArchitecture = .arm64) -> DownloadInstaller {
        DownloadInstaller(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                                                       baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil)),
                          macOSVersion: macOS, architecture: architecture)
    }
}

@Suite("Download sources")
struct DownloadSourceTests {
    @Test func appcastParsingHandlesElementsAttributesDeltasAndInformationalItems() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>2.0</title><sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://dl.example.com/App-2.0.zip" length="1234" sparkle:edSignature="SIG"/>
          <sparkle:deltas><enclosure url="https://dl.example.com/delta" sparkle:deltaFrom="100" length="1"/></sparkle:deltas></item>
        <item><enclosure url="https://dl.example.com/App-1.9.zip" sparkle:version="190" sparkle:shortVersionString="1.9" length="10"/></item>
        <item><title>Info</title><sparkle:version>300</sparkle:version><sparkle:informationalUpdate/><link>https://example.com/news</link></item>
        </channel></rss>
        """
        let items = AppcastParser.parse(Data(xml.utf8))
        #expect(items.count == 3)
        #expect(items[0] == AppcastItem(title: "2.0", version: "200", shortVersion: "2.0", minimumSystemVersion: "13.0",
                                        enclosureURL: "https://dl.example.com/App-2.0.zip", length: 1234, edSignature: "SIG"))
        #expect(items[1].version == "190" && items[1].shortVersion == "1.9", "versions as enclosure attributes")
        #expect(items[2].isInformational && items[2].link == "https://example.com/news")
    }

    @Test func feedOffersPickTheNewestCompatibleItemPerChannelAndRecommendTheOriginalChannel() async throws {
        let fixture = try VendorFixture("feed-offers")
        let sig = String(repeating: "A", count: 86) + "=="
        let xml = VendorFixture.appcast([
            VendorFixture.item(version: "300", short: "3.0", url: "https://dl.example.com/3.0.zip", length: 10, signature: sig, minimum: "99.0"),
            VendorFixture.item(version: "210", short: "2.1", url: "https://dl.example.com/2.1.zip", length: 10, signature: sig),
            VendorFixture.item(version: "200", short: "2.0", url: "https://dl.example.com/2.0.zip", length: 10, signature: sig),
            VendorFixture.item(version: "220", short: "2.2b1", url: "https://dl.example.com/2.2b1.zip", length: 10, signature: sig, channel: "beta"),
            VendorFixture.item(version: "230", short: "2.3-arm", url: "https://dl.example.com/arm.zip", length: 10, signature: sig, hardware: "arm64"),
            VendorFixture.item(version: "240", short: "2.4", url: "http://dl.example.com/plain.zip", length: 10, signature: sig, channel: "nightly"),
            "<item><sparkle:version>250</sparkle:version><enclosure url=\"http://dl.example.com/unsigned.zip\" length=\"1\"/><sparkle:channel>alpha</sparkle:channel></item>",
        ])
        try fixture.publishAppcast(xml, path: "updates.example.com/appcast.xml")
        var app = AppRecord(name: "Example", version: "2.0", bundleIdentifier: "com.example.app", path: "/Applications/Example.app")
        app.updateFeed = UpdateFeed(url: "https://updates.example.com/appcast.xml", publicEDKey: fixture.publicKey)
        app.channel = .beta
        app.teamIdentifier = "ABCDE12345"
        let finder = DownloadSourceFinder(fetcher: LocalFetcher(root: fixture.root), catalog: nil, macOSVersion: "15.1", architecture: .x86_64)
        let offers = await finder.offers(for: app, itemID: "manual:/Applications/Example.app")
        #expect(offers.map(\.version) == ["2.1", "2.2b1", "2.4"], "too new for this macOS, Apple silicon only and unsigned plain HTTP are left out")
        #expect(offers.map(\.channel) == [.stable, .beta, .nightly])
        #expect(offers.filter(\.recommended).map(\.version) == ["2.2b1"], "the channel used on the old Mac")
        #expect(offers.allSatisfy { $0.trust == .vendorSignature && $0.expectedTeamIdentifier == "ABCDE12345" })
        // Feeds over plain HTTP are only read when the app declares a vendor key.
        app.updateFeed = UpdateFeed(url: "http://updates.example.com/appcast.xml")
        #expect(await finder.offers(for: app, itemID: "x").isEmpty)
    }

    @Test func caskOffersUseTheVendorURLWithHomebrewsChecksumAndPlatformVariations() async {
        let cask = CaskInfo(token: "example-app@beta", names: ["Example"], appArtifacts: ["Example.app"], bundleIdentifiers: ["com.example.app"],
                            homepage: "https://example.com", version: "2.2b1,abc",
                            download: CaskDownload(url: "https://dl.example.com/arm.dmg", sha256: String(repeating: "a", count: 64)),
                            downloadVariations: ["sequoia": CaskDownload(url: "https://dl.example.com/intel.dmg", sha256: nil)])
        let app = AppRecord(name: "Example", bundleIdentifier: "com.example.app", path: "/Applications/Example.app")
        let catalog = CaskCatalog(casks: [cask])
        let arm = await DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/nonexistent")), catalog: catalog,
                                             macOSVersion: "15.2", architecture: .arm64).offers(for: app, itemID: "x")
        #expect(arm.map(\.kind) == [.homebrewCask, .vendorWebsite])
        #expect(arm[0].url == "https://dl.example.com/arm.dmg" && arm[0].trust == .checksum && arm[0].version == "2.2b1" && arm[0].channel == .beta)
        let intel = await DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/nonexistent")), catalog: catalog,
                                               macOSVersion: "15.2", architecture: .x86_64).offers(for: app, itemID: "x")
        #expect(intel[0].url == "https://dl.example.com/intel.dmg")
        #expect(intel[0].trust == .none && !intel[0].isDownloadable, "no checksum and no developer team to compare: link only")
        #expect(intel.contains { $0.kind == .vendorWebsite && $0.url == "https://example.com" })
    }

    @Test func casksThatNeedABrowserOrADisabledCaskAreNotDownloaded() async {
        var cask = CaskInfo(token: "needs-cookie", appArtifacts: ["Example.app"],
                            download: CaskDownload(url: "https://dl.example.com/x.dmg", sha256: String(repeating: "b", count: 64), needsBrowser: true))
        let app = AppRecord(name: "Example", path: "/Applications/Example.app")
        var finder = DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/nonexistent")), catalog: CaskCatalog(casks: [cask]),
                                          macOSVersion: "15.0", architecture: .arm64)
        #expect(await finder.offers(for: app, itemID: "x").isEmpty)
        cask.download?.needsBrowser = false
        cask.disabled = true
        finder.catalog = CaskCatalog(casks: [cask])
        #expect(await finder.offers(for: app, itemID: "x").isEmpty)
    }

    @Test func appStoreAppsOfferTheStorePage() async {
        let app = AppRecord(name: "Ledger", path: "/Applications/Ledger.app", source: .appStore, restoreMethod: .appStore(id: 42))
        let offers = await DownloadSourceFinder(fetcher: LocalFetcher(root: URL(fileURLWithPath: "/x")), catalog: nil, macOSVersion: "15.0",
                                                architecture: .arm64).offers(for: app, itemID: "mas:42")
        #expect(offers == [DownloadOffer(id: "appstore:42", itemID: "mas:42", kind: .appStore, url: "macappstore://apps.apple.com/app/id42", recommended: true)])
    }
}

@Suite("Download queue")
struct DownloadQueueTests {
    actor Recorder {
        var states: [String: [DownloadState]] = [:]
        func record(_ id: String, _ state: DownloadState) { states[id, default: []].append(state) }
    }

    func offer(_ id: String, path: String, sha: String? = nil) -> DownloadOffer {
        DownloadOffer(id: "feed", itemID: id, kind: .vendorFeed, url: "https://dl.example.com/\(path)", sha256: sha, trust: .checksum)
    }

    /// Waits until a download has received its first bytes (independent of machine load).
    func waitUntilRunning(_ queue: DownloadQueue, _ id: String) async throws {
        for _ in 0..<400 {
            if case .downloading(let received, _)? = await queue.state(id), received > 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("\(id) did not start")
    }

    @Test func downloadsPauseResumeRetryAndCancel() async throws {
        let sandbox = try Sandbox("queue")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try sandbox.file("downloads/dl.example.com/big.zip")
        try payload.write(to: sandbox.url.appendingPathComponent("downloads/dl.example.com/big.zip"))
        let recorder = Recorder()
        let transport = LocalDownloadTransport(root: sandbox.url, chunkSize: 5_000, delayPerChunk: 0.01)
        let queue = DownloadQueue(transport: transport, folder: sandbox.url.appendingPathComponent("dl"), observer: { id, state in
            Task { await recorder.record(id, state) }
        })

        await queue.enqueue(offer("a", path: "big.zip"))
        try await waitUntilRunning(queue, "a")
        await queue.pause("a")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await queue.state("a") == .paused)
        await queue.resume("a")
        await queue.waitUntilIdle()
        guard case .finished(let file)? = await queue.state("a") else { Issue.record("not finished"); return }
        #expect(try Data(contentsOf: file) == payload, "resuming continued at the right offset")
        #expect(file.lastPathComponent.hasPrefix("download-") && file.pathExtension == "zip", "MacReplica names the file, not the server")

        await queue.enqueue(offer("missing", path: "nothing.zip"))
        await queue.waitUntilIdle()
        #expect(await queue.state("missing") == .failed(.httpStatus(404)))
        try payload.write(to: sandbox.url.appendingPathComponent("downloads/dl.example.com/nothing.zip"))
        await queue.retry("missing")
        await queue.waitUntilIdle()
        guard case .finished? = await queue.state("missing") else { Issue.record("retry did not finish"); return }

        await queue.enqueue(offer("c", path: "big.zip"))
        try await waitUntilRunning(queue, "c")
        await queue.cancel("c")
        await queue.waitUntilIdle()
        #expect(await queue.state("c") == .cancelled)
        let states = await recorder.states["a"] ?? []
        #expect(states.contains { if case .downloading(let received, _) = $0 { return received > 0 }; return false }, "progress is reported")
    }

    @Test func offersThatCannotBeVerifiedAreRefused() async throws {
        let sandbox = try Sandbox("queue-refuse")
        let queue = DownloadQueue(transport: LocalDownloadTransport(root: sandbox.url), folder: sandbox.url)
        await queue.enqueue(DownloadOffer(id: "w", itemID: "w", kind: .vendorWebsite, url: "https://example.com"))
        await queue.enqueue(DownloadOffer(id: "n", itemID: "n", kind: .vendorFeed, url: "https://dl.example.com/x.zip", trust: .none))
        await queue.enqueue(DownloadOffer(id: "h", itemID: "h", kind: .homebrewCask, url: "http://dl.example.com/x.zip", trust: .checksum))
        #expect(await queue.state("w") == .failed(.insecureURL("https://example.com")))
        #expect(await queue.state("n") == .failed(.insecureURL("https://dl.example.com/x.zip")))
        #expect(await queue.state("h") == .failed(.insecureURL("http://dl.example.com/x.zip")))
    }
}

@Suite("Download verification and installation")
struct DownloadInstallerTests {
    @Test func signedZipIsVerifiedUnpackedCheckedAndInstalledWithQuarantine() async throws {
        let fixture = try VendorFixture("install-zip")
        let published = try fixture.publishZip(appName: "Example Nightly", bundleID: "com.example.app.nightly", version: "3.0a1",
                                               path: "dl.example.com/nightly.zip")
        let layout = toolchainLayout(fixture.sandbox)
        try FileManager.default.createDirectory(at: layout.applicationFolders[0], withIntermediateDirectories: true)
        let installer = fixture.installer(layout: layout)
        let offer = DownloadOffer(id: "feed:nightly", itemID: "manual:x", kind: .vendorFeed, url: "https://dl.example.com/nightly.zip",
                                  version: "3.0a1", channel: .nightly, expectedLength: published.length, edSignature: published.signature,
                                  publicEDKey: fixture.publicKey, expectedBundleIdentifier: "com.example.app.nightly", trust: .vendorSignature)
        let downloaded = fixture.root.appendingPathComponent("work/nightly.zip")
        try FileManager.default.createDirectory(at: downloaded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("downloads/dl.example.com/nightly.zip"), to: downloaded)

        try installer.verifyFile(downloaded, offer: offer)
        #expect(BundleInspection.quarantineAgent(of: downloaded) == "MacReplica", "Gatekeeper assesses what MacReplica downloaded")
        let prepared = try await installer.prepare(downloaded, offer: offer, staging: fixture.root.appendingPathComponent("work/staging"))
        guard case .application(let bundle, nil) = prepared else { Issue.record("expected an application, got \(prepared)"); return }
        let installed = try installer.installApplication(bundle, source: offer.url)
        #expect(installed.path == layout.applicationFolders[0].appendingPathComponent("Example Nightly.app").path)
        #expect(BundleInspection.quarantineAgent(of: installed) == "MacReplica")
        #expect(throws: DownloadError.alreadyInstalled) { try installer.installApplication(bundle, source: offer.url) }
    }

    @Test func tamperedFilesAreRejectedBeforeAnythingIsOpened() throws {
        let fixture = try VendorFixture("install-tamper")
        let published = try fixture.publishZip(appName: "Example", bundleID: "com.example.app", version: "2.0", path: "dl.example.com/app.zip")
        let file = fixture.root.appendingPathComponent("downloads/dl.example.com/app.zip")
        let installer = fixture.installer(layout: toolchainLayout(fixture.sandbox))
        var offer = DownloadOffer(id: "f", itemID: "i", kind: .vendorFeed, url: "https://dl.example.com/app.zip", expectedLength: published.length,
                                  edSignature: published.signature, publicEDKey: fixture.publicKey, trust: .vendorSignature)
        try installer.verifyFile(file, offer: offer)
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        offer.publicEDKey = other
        #expect(throws: DownloadError.signatureInvalid) { try installer.verifyFile(file, offer: offer) }
        offer.publicEDKey = fixture.publicKey
        offer.expectedLength = published.length + 1
        #expect(throws: DownloadError.sizeMismatch(expected: published.length + 1, actual: published.length)) { try installer.verifyFile(file, offer: offer) }
        offer = DownloadOffer(id: "c", itemID: "i", kind: .homebrewCask, url: "https://dl.example.com/app.zip", sha256: String(repeating: "0", count: 64),
                              trust: .checksum)
        #expect(throws: DownloadError.checksumMismatch) { try installer.verifyFile(file, offer: offer) }
        offer.sha256 = published.sha256
        try installer.verifyFile(file, offer: offer)
    }

    @Test func applicationChecksCompareIdentityDeveloperArchitectureAndMacOS() throws {
        let sandbox = try Sandbox("app-checks")
        let folder = try sandbox.folder("apps")
        let intelOnly = try SimulationBuilder.makeSyntheticApp(name: "Intel", bundleID: "com.example.intel", version: "1", architectures: [.x86_64], in: folder)
        let armOnly = try SimulationBuilder.makeSyntheticApp(name: "Arm", bundleID: "com.example.arm", version: "1", architectures: [.arm64], in: folder)
        let newer = try SimulationBuilder.makeSyntheticApp(name: "New", bundleID: "com.example.new", version: "1", minimumSystemVersion: "99.0", in: folder)
        let layout = toolchainLayout(sandbox)
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:])
        var installer = DownloadInstaller(layout: layout, runner: runner, macOSVersion: "15.0", architecture: .arm64, rosettaInstalled: false)
        func offer(_ bundleID: String, team: String? = nil) -> DownloadOffer {
            DownloadOffer(id: "o", itemID: "i", kind: .vendorFeed, url: "https://x", expectedBundleIdentifier: bundleID, expectedTeamIdentifier: team,
                          trust: .vendorSignature)
        }
        #expect(throws: DownloadError.wrongApplication("com.example.arm")) { try installer.checkApplication(armOnly, offer: offer("com.example.other")) }
        #expect(throws: DownloadError.wrongDeveloper(expected: "ABCDE12345", actual: nil)) {
            try installer.checkApplication(armOnly, offer: offer("com.example.arm", team: "ABCDE12345"))
        }
        #expect(throws: DownloadError.incompatibleArchitecture) { try installer.checkApplication(intelOnly, offer: offer("com.example.intel")) }
        installer.rosettaInstalled = true
        try installer.checkApplication(intelOnly, offer: offer("com.example.intel"))
        installer.architecture = .x86_64
        #expect(throws: DownloadError.incompatibleArchitecture) { try installer.checkApplication(armOnly, offer: offer("com.example.arm")) }
        #expect(throws: DownloadError.requiresNewerMacOS("99.0")) { try installer.checkApplication(newer, offer: offer("com.example.new")) }
    }

    @Test func diskImagesAreMountedReadOnlyAndDetached() async throws {
        let fixture = try VendorFixture("install-dmg")
        let source = try fixture.sandbox.folder("image")
        try SimulationBuilder.makeSyntheticApp(name: "Disk App", bundleID: "com.example.diskapp", version: "1.0", in: source)
        let dmg = fixture.root.appendingPathComponent("disk.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-quiet", "-srcfolder", source.path, "-volname", "MacReplicaTest", "-format", "UDZO", dmg.path]
        create.standardError = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        try #require(create.terminationStatus == 0, "hdiutil create")
        let layout = toolchainLayout(fixture.sandbox)
        try FileManager.default.createDirectory(at: layout.applicationFolders[0], withIntermediateDirectories: true)
        let installer = fixture.installer(layout: layout)
        let offer = DownloadOffer(id: "c", itemID: "i", kind: .homebrewCask, url: "https://dl.example.com/disk.dmg",
                                  sha256: try Hashing.sha256Hex(ofFile: dmg), expectedBundleIdentifier: "com.example.diskapp", trust: .checksum)
        try installer.verifyFile(dmg, offer: offer)
        let prepared = try await installer.prepare(dmg, offer: offer, staging: fixture.root.appendingPathComponent("staging"))
        guard case .application(let bundle, let mountPoint?) = prepared else { Issue.record("expected a mounted application"); return }
        #expect(!FileManager.default.isWritableFile(atPath: mountPoint.path), "mounted read-only")
        let installed = try installer.installApplication(bundle, source: offer.url)
        await installer.detach(mountPoint)
        #expect(!FileManager.default.fileExists(atPath: bundle.path), "detached")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test func parsers() {
        let signed = """
        Package "dotnet-sdk.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Example Corporation (UBF8T346G9)
            2. Developer ID Certification Authority
        """
        #expect(DownloadInstaller.parsePackageSignature(signed) == (true, "UBF8T346G9"))
        #expect(DownloadInstaller.parsePackageSignature("Package \"x.pkg\":\n   Status: no signature\n") == (false, nil))
        let info = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Software License Agreement</key><true/></dict></plist>"
        #expect(DownloadInstaller.hasLicenseAgreement(imageInfo: info))
        let attach = "WARNING: deprecated\n<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>system-entities</key><array>"
            + "<dict><key>dev-entry</key><string>/dev/disk9</string></dict>"
            + "<dict><key>mount-point</key><string>/private/tmp/m/dmg.x</string></dict></array></dict></plist>"
        #expect(DownloadInstaller.mountPoint(fromAttachOutput: attach)?.path == "/private/tmp/m/dmg.x")
    }
}

@Suite("Guided installation")
struct GuidedInstallationTests {
    actor ScriptedInteraction: GuidedInstallInteraction {
        var decisions: [GuidedDecision]
        var opened: [String] = []
        var onWait: (@Sendable (String) -> Void)?

        init(_ decisions: [GuidedDecision], onWait: (@Sendable (String) -> Void)? = nil) {
            self.decisions = decisions
            self.onWait = onWait
        }

        func openPackage(_ url: URL) async { opened.append("package") }
        func openInFinder(_ url: URL) async { opened.append("finder") }
        func open(_ url: URL) async { opened.append(url.absoluteString) }
        func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision {
            onWait?(itemID)
            return decisions.isEmpty ? .later : decisions.removeFirst()
        }
    }

    func item(_ name: String, bundleID: String) -> RestoreItem {
        RestoreItem(id: "manual:/Applications/\(name).app", kind: .manualApp, title: name, identifier: "/Applications/\(name).app",
                    bundleIdentifier: bundleID, appBundleNames: ["\(name).app"], component: .applications)
    }

    @Test func sequenceDownloadsInstallsWaitsAndDistinguishesUserIntentFromFailures() async throws {
        let fixture = try VendorFixture("guided")
        let layout = toolchainLayout(fixture.sandbox)
        let applications = layout.applicationFolders[0]
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let a = try fixture.publishZip(appName: "Alpha", bundleID: "com.example.alpha", version: "1.0", path: "dl.example.com/alpha.zip")
        let installer = fixture.installer(layout: layout)
        let queue = DownloadQueue(transport: LocalDownloadTransport(root: fixture.root), folder: installer.downloadsFolder)
        let guided = GuidedInstallation(installer: installer, queue: queue)
        let alpha = item("Alpha", bundleID: "com.example.alpha")
        let beta = item("Beta", bundleID: "com.example.beta")
        let gamma = item("Gamma", bundleID: "com.example.gamma")
        let delta = item("Delta", bundleID: "com.example.delta")
        let offers: [String: DownloadOffer] = [
            alpha.id: DownloadOffer(id: "f", itemID: alpha.id, kind: .vendorFeed, url: "https://dl.example.com/alpha.zip", expectedLength: a.length,
                                    edSignature: a.signature, publicEDKey: fixture.publicKey, expectedBundleIdentifier: "com.example.alpha", trust: .vendorSignature),
            beta.id: DownloadOffer(id: "w", itemID: beta.id, kind: .vendorWebsite, url: "https://beta.example.com"),
            gamma.id: DownloadOffer(id: "f", itemID: gamma.id, kind: .vendorFeed, url: "https://dl.example.com/alpha.zip", expectedLength: a.length,
                                    edSignature: a.signature, publicEDKey: fixture.publicKey, expectedBundleIdentifier: "com.example.gamma", trust: .vendorSignature),
        ]
        // Beta: the user installs it from the website, then says "Done".
        let interaction = ScriptedInteraction([.checkAgain, .later], onWait: { id in
            if id == beta.id { try? SimulationBuilder.makeSyntheticApp(name: "Beta", bundleID: "com.example.beta", version: "5", in: applications) }
        })
        let isInstalled: @Sendable (RestoreItem) -> String?? = { item in
            let url = applications.appendingPathComponent(item.appBundleNames[0])
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  (info["CFBundleIdentifier"] as? String) == item.bundleIdentifier else { return nil }
            return .some(info["CFBundleShortVersionString"] as? String)
        }
        actor Results { var values: [String: ItemResult] = [:]; func set(_ id: String, _ r: ItemResult) { values[id] = r } }
        let results = Results()
        await guided.runSequence([(alpha, offers[alpha.id]), (beta, offers[beta.id]), (gamma, offers[gamma.id]), (delta, nil)],
                                 interaction: interaction, isInstalled: isInstalled, record: { await results.set($0, $1) })
        let values = await results.values
        #expect(values[alpha.id]?.outcome == .succeeded && values[alpha.id]?.installedVersion == "1.0")
        #expect(values[beta.id]?.outcome == .succeeded, "installed by the user and verified")
        #expect(values[gamma.id]?.outcome.isFailure == true, "a download of another app is never installed")
        if case .failed(let failure)? = values[gamma.id]?.outcome { #expect(failure.category == .downloadNotTrusted) }
        #expect(values[delta.id]?.outcome == .skipped(.postponedByUser), "later is not a failure")
        #expect(await interaction.opened == ["https://beta.example.com"])
        #expect(!FileManager.default.fileExists(atPath: applications.appendingPathComponent("Gamma.app").path))

        // Cancelling stops the sequence and is recorded as the user's decision.
        let stop = ScriptedInteraction([.cancel])
        let more = Results()
        await guided.runSequence([(delta, nil), (gamma, nil)], interaction: stop, isInstalled: isInstalled, record: { await more.set($0, $1) })
        #expect(await more.values[delta.id]?.outcome == .skipped(.cancelledByUser))
        #expect(await more.values[gamma.id] == nil, "the rest stays open")
        #expect(ItemResult(itemID: "x", outcome: .skipped(.cancelledByUser)).decisionCode == "cancelled_by_user")
        #expect(ItemOutcome.skipped(.postponedByUser).isOpen && !ItemOutcome.skipped(.userSkipped).isOpen)
    }
}
