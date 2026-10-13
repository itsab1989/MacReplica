import Foundation
import Testing
@testable import MacReplicaCore

/// Tool B reads the Software Update switches the way macOS shows them (missing keys included), compares them with
/// “stay on this version and stay secure”, and judges support only from what Apple still offers.
@Suite("Tools: update preferences")
struct ToolsUpdatesTests {
    @Test func missingKeysUseTheDefaultsMacOSShows() {
        // The plist of the maintainer's macOS 27 Mac: only AutomaticDownload is written.
        let settings = UpdateSettings(softwareUpdate: ["AutomaticDownload": 1, "SplatEnabled": 1, "LastResultCode": 2],
                                      commerce: ["AutoUpdate": 1])
        #expect(settings.checkAutomatically)
        #expect(settings.downloadAutomatically)
        #expect(!settings.installMacOSUpdates)
        #expect(settings.installSecurityUpdates)
        #expect(settings.appStoreAutoUpdate == true)
        #expect(settings.differences(to: .recommended) == [.installMacOS])
        #expect(!settings.securityUpdatesOff)
        let fresh = UpdateSettings(softwareUpdate: [:], commerce: nil)
        #expect(fresh.appStoreAutoUpdate == nil)
        #expect(fresh.differences(to: .recommended) == [.installMacOS])
    }

    @Test func securityIsOffIfEitherKeyIsOff() {
        let config = UpdateSettings(softwareUpdate: ["ConfigDataInstall": false, "CriticalUpdateInstall": true], commerce: nil)
        #expect(!config.installSecurityUpdates)
        #expect(config.securityUpdatesOff)
        let check = UpdateSettings(softwareUpdate: ["AutomaticCheckEnabled": 0], commerce: nil)
        #expect(check.securityUpdatesOff)
        #expect(Set(check.differences(to: .recommended)) == [.check, .installMacOS])
    }

    @Test func historyTextRoundTrips() {
        let settings = UpdateSettings(checkAutomatically: true, downloadAutomatically: false, installMacOSUpdates: true, installSecurityUpdates: true)
        #expect(settings.historyText == "check=1;download=0;installMacOS=1;installSecurity=1")
        #expect(UpdateSettings(historyText: settings.historyText) == settings)
        #expect(UpdateSettings(historyText: "check=1") == nil)
        #expect(UpdateSettings(historyText: "garbage") == nil)
    }

    static let installers = """
    Finding available software
    Software Update found the following full installers:
    * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 17955378KiB, Build: 26A434, Deferred: NO
    * Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
    * Title: macOS Tahoe, Version: 26.7.1, Size: 16000000KiB, Build: 25H1, Deferred: NO
    * Title: macOS Tahoe, Version: 26.10, Size: 16000000KiB, Build: 25H9, Deferred: NO
    * Title: macOS Sequoia, Version: 15.8.1, Size: 15000000KiB, Build: 24H1, Deferred: NO
    * Title: macOS Sonoma, Version: 14.8.9, Size: 14000000KiB, Build: 23H1, Deferred: NO
    """

    @Test func supportFollowsWhatAppleStillOffers() {
        let versions = MacOSSupportStatus.parseInstallers(Self.installers)
        #expect(versions == ["27.0.1", "27.0", "26.7.1", "26.10", "15.8.1", "14.8.9"])
        let current = MacOSSupportStatus.evaluate(installedVersion: "27.0.1", installers: versions)
        #expect(current.support == .current)
        #expect(!current.updateAvailable)
        let behind = MacOSSupportStatus.evaluate(installedVersion: "26.7", installers: versions)
        #expect(behind.support == .securityUpdates)
        // Versions compare numerically: 26.10 is newer than 26.7.1.
        #expect(behind.latestForThisMajor == "26.10")
        #expect(behind.updateAvailable)
        #expect(MacOSSupportStatus.evaluate(installedVersion: "15.8.1", installers: versions).support == .securityUpdates)
        #expect(MacOSSupportStatus.evaluate(installedVersion: "14.8.9", installers: versions).support == .likelyEnded)
        #expect(MacOSSupportStatus.evaluate(installedVersion: "13.7.8", installers: versions).support == .likelyEnded)
        // An Intel Mac is offered nothing newer than 26: for it, 26 is current.
        let intel = MacOSSupportStatus.evaluate(installedVersion: "26.10", installers: ["26.10", "26.7.1", "15.8.1", "14.8.9"])
        #expect(intel.support == .current)
        #expect(intel.newestMajor == 26)
        // No answer from Apple (offline): unknown, never a guess.
        let offline = MacOSSupportStatus.evaluate(installedVersion: "26.7", installers: [])
        #expect(offline.support == .unknown)
        #expect(!offline.updateAvailable)
    }

    @Test func deferralIsNeverOfferedAndExplainedPerVersion() {
        #expect(MajorUpgradeDeferral.forVersion(ToolEnvironment(macOSVersion: "27.0.1", architecture: .arm64)) == .onlyDeviceManagement)
        #expect(MajorUpgradeDeferral.forVersion(ToolEnvironment(macOSVersion: "26.7", architecture: .x86_64)) == .deprecatedProfileOnly)
        #expect(MajorUpgradeDeferral.delaysSecurityUpdates(ToolEnvironment(macOSVersion: "15.7.5", architecture: .arm64)))
        #expect(!MajorUpgradeDeferral.delaysSecurityUpdates(ToolEnvironment(macOSVersion: "15.7.4", architecture: .arm64)))
        #expect(!MajorUpgradeDeferral.delaysSecurityUpdates(ToolEnvironment(macOSVersion: "14.8", architecture: .x86_64)))
    }

    @Test func statusReadsFilesAndSeesManagement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = root.appendingPathComponent("Preferences")
        let managed = root.appendingPathComponent("Managed Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        var layout = SystemLayout.live()
        layout.managedPreferences = managed
        let inspector = UpdatePreferencesInspector(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: []), baseEnvironment: [:]),
                                                   preferencesFolder: prefs)
        // No file: every switch at macOS's default.
        let none = inspector.status()
        #expect(none.settings == UpdateSettings(softwareUpdate: [:], commerce: nil))
        #expect(none.capability == .requiresUserAction)
        try PropertyListSerialization.data(fromPropertyList: ["AutomaticallyInstallMacOSUpdates": true], format: .binary, options: 0)
            .write(to: prefs.appendingPathComponent("com.apple.SoftwareUpdate.plist"))
        #expect(inspector.status().settings?.installMacOSUpdates == true)
        // Unreadable content: unknown, not defaults.
        try Data("not a plist".utf8).write(to: prefs.appendingPathComponent("com.apple.SoftwareUpdate.plist"))
        #expect(inspector.status().settings == nil)
        #expect(inspector.status().capability == .unableToDetermine)
        try PropertyListSerialization.data(fromPropertyList: ["AutomaticDownload": false, "_manualProfile": true], format: .xml, options: 0)
            .write(to: managed.appendingPathComponent("com.apple.SoftwareUpdate.plist"))
        #expect(inspector.status().managed)
        #expect(inspector.status().capability == .managedExternally)
    }
}
