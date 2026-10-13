import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.4: a printable guide for reinstalling macOS, right for the Mac it was made on. It only states what
/// Apple documents for that kind of Mac and never claims which macOS versions the Mac can install.
@Suite("Reinstall guide")
struct ReinstallGuideTests {
    static let builder = ReportBuilder(localizer: TestEnvironment.english)

    @Test func intelT2MacGetsItsStartupKeysAndT2Notes() {
        // The beta tester's Mac: MacBook Pro 2019 (Intel, T2), macOS 14.8.4.
        let profile = MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro16,1", macOSVersion: "14.8.4")
        #expect(profile.family == .intelT2 && profile.hasEraseAllContentAndSettings)
        let html = Self.builder.reinstallGuide(profile: profile, manifest: nil, backupFolderName: "MacReplica-Backup-2026-10-13-1500")
        for text in ["Command (⌘)-R", "Option-Command-R", "Shift-Option-Command-R", "Startup Security Utility", "Erase All Content and Settings",
                     "Intel Mac with the Apple T2 Security Chip", "MacReplica-Backup-2026-10-13-1500", AppleSupportLinks.startupSecurityUtility,
                     AppleSupportLinks.eraseIntel, AppleSupportLinks.reinstall] {
            #expect(html.contains(text), "\(text)")
        }
        #expect(!html.contains("Loading startup options"), "no Apple silicon steps on an Intel Mac")
        #expect(html.contains("Do not erase this Mac until the backup is saved"))
    }

    @Test func appleSiliconMacGetsTheStartupOptions() {
        let profile = MacProfile(architecture: .arm64, modelIdentifier: "Mac15,9", macOSVersion: "27.0.1")
        let html = Self.builder.reinstallGuide(profile: profile, manifest: nil, backupFolderName: nil)
        #expect(profile.family == .appleSilicon)
        #expect(html.contains("Loading startup options") && html.contains(AppleSupportLinks.eraseAppleSilicon))
        #expect(!html.contains("Command (⌘)-R") && !html.contains("Startup Security Utility") && !html.contains("firmware password"))
    }

    @Test func olderIntelMacWithoutT2() {
        let profile = MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro14,1", macOSVersion: "13.7")
        #expect(profile.family == .intel && !profile.hasEraseAllContentAndSettings)
        let html = Self.builder.reinstallGuide(profile: profile, manifest: nil, backupFolderName: nil)
        #expect(!html.contains("Erase All Content and Settings (System Settings") && !html.contains("Startup Security Utility"))
        #expect(html.contains("firmware password"))
        // Unknown model: treated as an Intel Mac without T2, so nothing is promised that might not exist.
        #expect(MacProfile(architecture: .x86_64, modelIdentifier: nil, macOSVersion: "14").family == .intel)
        // Erase All Content and Settings needs macOS 12.
        #expect(!MacProfile(architecture: .arm64, modelIdentifier: nil, macOSVersion: "11.7").hasEraseAllContentAndSettings)
    }

    @Test func theGuideIsInEveryBackupInTheChosenLanguage() async throws {
        let sandbox = try Sandbox("reinstall-guide")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        var service = TestEnvironment.inventory(source)
        service.modelIdentifier = "MacBookPro16,1"
        var result = try await service.run()
        result.manifest.architecture = .x86_64
        let german = Localizer(language: .german)
        let outcome = try BackupWriter(layout: source.layout, localizer: german)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let html = try String(contentsOf: outcome.url.appendingPathComponent(BackupWriter.reinstallGuidePath), encoding: .utf8)
        #expect(html.contains("macOS auf diesem Mac neu installieren") && html.contains("Wahltaste-Befehlstaste-R") && html.contains("lang=\"de\""))
        #expect(html.contains("Vollständig") || html.contains("Unvollständig"), "the backup's completeness is part of the guide")
        #expect(try ManifestIO.read(from: outcome.url).modelIdentifier == "MacBookPro16,1")
        // Every link points to Apple's support site.
        let links = html.components(separatedBy: "href=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
        #expect(!links.isEmpty && links.allSatisfy { $0.hasPrefix("https://support.apple.com/") })
    }

    @Test func aCopyThatCannotRunOnThisMacIsAWarning() {
        var manifest = Manifest(macreplicaVersion: "1.0.5", createdAt: Date(), macosVersion: "14.8.4", architecture: .x86_64)
        manifest.bootstrapApp = BootstrapAppRecord(path: "MacReplica.app", version: "1.0.5", build: nil, architectures: [.arm64], teamIdentifier: nil)
        let intel = MacProfile(architecture: .x86_64, modelIdentifier: "MacBookPro16,1", macOSVersion: "14.8.4")
        let html = Self.builder.reinstallGuide(profile: intel, manifest: manifest, backupFolderName: nil)
        #expect(html.contains("<p class=\"bad\">MacReplica 1.0.5 is in this backup") && html.contains("It does not run on this Mac&#39;s processor"))
        manifest.bootstrapApp?.architectures = [.arm64, .x86_64]
        let universal = Self.builder.reinstallGuide(profile: intel, manifest: manifest, backupFolderName: nil)
        #expect(universal.contains("<p class=\"ok\">MacReplica 1.0.5 is in this backup (runs on Apple silicon and Intel).</p>"))
    }
}
