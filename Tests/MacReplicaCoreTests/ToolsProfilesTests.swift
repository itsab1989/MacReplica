import Foundation
import Testing
@testable import MacReplicaCore

/// The profiles MacReplica prepares on request: exact payloads, own identifiers, and detection without root.
@Suite("Tools: configuration profiles")
struct ToolsProfilesTests {
    @Test func gatekeeperProfileHasOnlyTheOnePayload() throws {
        let plist = try ManagedProfile.gatekeeperOff.propertyList(displayName: "N", description: "D")
        #expect(plist["PayloadType"] as? String == "Configuration")
        #expect(plist["PayloadScope"] as? String == "System")
        #expect(plist["PayloadIdentifier"] as? String == "io.github.itsab1989.MacReplica.gatekeeper")
        #expect(plist["PayloadRemovalDisallowed"] as? Bool == false)
        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["PayloadType"] as? String == "com.apple.systempolicy.control")
        #expect(content[0]["EnableAssessment"] as? Bool == false)
        #expect(Set(content[0].keys) == ["PayloadType", "PayloadIdentifier", "PayloadUUID", "PayloadVersion", "EnableAssessment"])
    }

    @Test func deferralProfileIsLimitedTo90Days() throws {
        let plist = try ManagedProfile.deferMajorUpgrades(days: 90).propertyList(displayName: "N", description: "D")
        let content = try #require((plist["PayloadContent"] as? [[String: Any]])?.first)
        #expect(content["PayloadType"] as? String == "com.apple.applicationaccess")
        #expect(content["forceDelayedMajorSoftwareUpdates"] as? Bool == true)
        #expect(content["enforcedSoftwareUpdateMajorOSDeferredInstallDelay"] as? Int == 90)
        // Only the major deferral: never the keys that delay minor or security updates.
        #expect(content["forceDelayedSoftwareUpdates"] == nil)
        #expect(content["forceDelayedAppSoftwareUpdates"] == nil)
        #expect(throws: ProfileError.invalidDays) { try ManagedProfile.deferMajorUpgrades(days: 91).propertyList(displayName: "N", description: "D") }
        #expect(throws: ProfileError.invalidDays) { try ManagedProfile.deferMajorUpgrades(days: 0).propertyList(displayName: "N", description: "D") }
    }

    @Test func writtenFileIsAValidPlistAndReplacesTheEarlierOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ManagedProfile.deferMajorUpgrades(days: 30).write(to: folder, displayName: "N", description: "D")
        let second = try ManagedProfile.deferMajorUpgrades(days: 60).write(to: folder, displayName: "N", description: "D")
        #expect(first == second)
        let data = try Data(contentsOf: second)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(((plist["PayloadContent"] as? [[String: Any]])?.first?["enforcedSoftwareUpdateMajorOSDeferredInstallDelay"]) as? Int == 60)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
    }

    @Test func installedProfilesAreReadFromProfilesC() {
        // `profiles -C` on the maintainer's Mac (macOS 27, no root).
        let output = """
        _computerlevel[1] attribute: profileIdentifier: com.dhinakg.gatekeeper
        _computerlevel[2] attribute: profileIdentifier: io.github.itsab1989.MacReplica.gatekeeper
        There are 2 system configuration profiles installed
        """
        #expect(InstalledProfiles.identifiers(fromProfilesOutput: output) == ["com.dhinakg.gatekeeper", ManagedProfile.gatekeeperIdentifier])
        #expect(InstalledProfiles.identifiers(fromProfilesOutput: "There are no configuration profiles installed in the system domain").isEmpty)
    }

    @Test func deferralEffectIsReadFromManagedPreferencesAndTheInstallerList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ManagedProfileEffect.majorUpgradeDeferralDays(managedPreferences: folder) == nil)
        try PropertyListSerialization.data(fromPropertyList: ["forceDelayedMajorSoftwareUpdates": true, "enforcedSoftwareUpdateMajorOSDeferredInstallDelay": 60, "_manualProfile": true],
                                           format: .xml, options: 0).write(to: folder.appendingPathComponent("com.apple.applicationaccess.plist"))
        #expect(ManagedProfileEffect.majorUpgradeDeferralDays(managedPreferences: folder) == 60)
        let deferred = """
        * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 1KiB, Build: 26A434, Deferred: YES
        * Title: macOS Tahoe, Version: 26.7.1, Size: 1KiB, Build: 25H1, Deferred: NO
        """
        #expect(ManagedProfileEffect.newerMajorDeferred(installersOutput: deferred, installedMajor: 26) == true)
        #expect(ManagedProfileEffect.newerMajorDeferred(installersOutput: deferred.replacingOccurrences(of: "YES", with: "NO"), installedMajor: 26) == false)
        // Nothing newer offered (the newest macOS, or an Intel Mac on 26): the effect cannot be seen.
        #expect(ManagedProfileEffect.newerMajorDeferred(installersOutput: deferred, installedMajor: 27) == nil)
    }
}
