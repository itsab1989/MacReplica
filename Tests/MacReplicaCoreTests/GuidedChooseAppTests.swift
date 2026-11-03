import Foundation
import Testing
@testable import MacReplicaCore

/// The tester installed an app himself and clicked Done; MacReplica did not find it and showed the same window again
/// without a word, the only ways out being Skip, Later or Cancel (2026-11-03, TEST1111-008).
@Suite("Guided installation: Done without the app, choosing the installed app")
struct GuidedChooseAppTests {
    actor Scripted: GuidedInstallInteraction {
        var decisions: [GuidedDecision]
        var asked: [Bool] = []
        init(_ decisions: [GuidedDecision]) { self.decisions = decisions }
        func openPackage(_ url: URL) async {}
        func openInFinder(_ url: URL) async {}
        func open(_ url: URL) async {}
        func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision { .later }
        func waitForUser(itemID: String, step: GuidedStep, notFound: Bool) async -> GuidedDecision {
            asked.append(notFound)
            return decisions.isEmpty ? .later : decisions.removeFirst()
        }
    }

    func setup(_ name: String) throws -> (GuidedInstallation, URL, VendorFixture) {
        let fixture = try VendorFixture(name)
        let layout = toolchainLayout(fixture.sandbox)
        let installer = fixture.installer(layout: layout)
        let guided = GuidedInstallation(installer: installer, queue: DownloadQueue(transport: LocalDownloadTransport(root: fixture.root),
                                                                                    folder: installer.downloadsFolder))
        let folder = fixture.sandbox.url.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (guided, folder, fixture)
    }

    func makeApp(_ url: URL, id: String?, version: String = "2.54.0") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    let item = RestoreItem(id: "manual:/Applications/Gamut Viewer.app", kind: .manualApp, title: "Gamut Viewer", identifier: "/Applications/Gamut Viewer.app",
                           bundleIdentifier: "com.example.gamutviewer", appBundleNames: ["Gamut Viewer.app"], component: .applications)

    @Test("Done without the app asks again and says that it was not found")
    func doneNotFoundSaysSo() async throws {
        let (guided, _, fixture) = try setup("done-not-found")
        let interaction = Scripted([.checkAgain, .checkAgain, .skip])
        let result = await guided.install(item, offer: nil, interaction: interaction, isInstalled: { _ in nil })
        #expect(await interaction.asked == [false, true, true])
        #expect(result.outcome == .skipped(.userSkipped))
        withExtendedLifetime(fixture) {}
    }

    @Test("The app chosen by the user counts when its identifier matches, with a note")
    func chosenMatchingApp() async throws {
        let (guided, folder, fixture) = try setup("chosen")
        let app = folder.appendingPathComponent("Gamut Viewer 2.app")
        try makeApp(app, id: "COM.example.GamutViewer")
        let interaction = Scripted([.checkAgain, .chosen(app, confirmed: false)])
        let result = await guided.install(item, offer: nil, interaction: interaction, isInstalled: { _ in nil })
        #expect(result.outcome == .succeeded)
        #expect(result.installedVersion == "2.54.0")
        #expect(result.notes == [.chosenByUser(app: "Gamut Viewer 2.app", confirmed: false)])
        withExtendedLifetime(fixture) {}
    }

    @Test("Another app counts only when the user confirmed it; unconfirmed it is asked again")
    func chosenDifferentApp() async throws {
        let (guided, folder, fixture) = try setup("chosen-other")
        let other = folder.appendingPathComponent("Viewer.app")
        try makeApp(other, id: "com.example.other")
        let interaction = Scripted([.chosen(other, confirmed: false), .chosen(other, confirmed: true)])
        let result = await guided.install(item, offer: nil, interaction: interaction, isInstalled: { _ in nil })
        #expect(await interaction.asked == [false, true])
        #expect(result.outcome == .succeeded)
        #expect(result.notes == [.chosenByUser(app: "Viewer.app", confirmed: true)])
        withExtendedLifetime(fixture) {}
    }

    @Test("Matching: the identifier decides; without one, the bundle name; no Info.plist never matches")
    func matching() throws {
        let fixture = try VendorFixture("matching")
        let folder = fixture.sandbox.url.appendingPathComponent("Apps")
        try makeApp(folder.appendingPathComponent("Gamut Viewer.app"), id: "com.example.other")
        try makeApp(folder.appendingPathComponent("Renamed.app"), id: "com.example.gamutviewer")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty.app"), withIntermediateDirectories: true)
        #expect(!GuidedInstallation.matches(item, app: folder.appendingPathComponent("Gamut Viewer.app")), "same name, other identifier")
        #expect(GuidedInstallation.matches(item, app: folder.appendingPathComponent("Renamed.app")))
        var noID = item
        noID.bundleIdentifier = nil
        #expect(GuidedInstallation.matches(noID, app: folder.appendingPathComponent("Gamut Viewer.app")))
        #expect(!GuidedInstallation.matches(noID, app: folder.appendingPathComponent("Renamed.app")))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Gamut Viewer.app/x"), withIntermediateDirectories: true)
        noID.appBundleNames = ["Empty.app"]
        #expect(!GuidedInstallation.matches(noID, app: folder.appendingPathComponent("Empty.app")), "no Info.plist")
    }

    @Test("Texts: not found, the confirmed and the checked choice")
    func texts() {
        let l = TestEnvironment.english
        #expect(l.t("guided.pending.notFound", "Gamut Viewer").contains("Choose the App…"))
        #expect(l.t("guided.pending.notFound", "Gamut Viewer").contains(l.t("guided.choose")))
        #expect(l.noteText(.chosenByUser(app: "X.app", confirmed: true)).contains("confirmed"))
        #expect(l.noteText(.chosenByUser(app: "X.app", confirmed: false)).contains("checked"))
    }
}
