import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The user's own installers: inspected without running them, kept in the backup on request, and used on the new
/// Mac offline – only if they still match the checksum and the developer recorded on the old Mac.
@Suite("Own installers")
struct OwnInstallerTests {
    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments.first ?? "")")
    }

    /// A disk image with an app, like most vendor downloads.
    /// Created through MacReplica's disk-image queue, so parallel tests do not compete for macOS's disk-image service.
    /// Asynchronous: blocking a thread while waiting for the queue could starve Swift's thread pool on small CI machines.
    static func createImage(source: URL, name: String, at dmg: URL) async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/hdiutil"]), baseEnvironment: [:])
        let result = try await DiskImageCommands.run(runner, Command(executable: "/usr/bin/hdiutil",
            arguments: ["create", "-quiet", "-srcfolder", source.path, "-volname", name, "-format", "UDZO", dmg.path], environment: [:], timeout: 300))
        try #require(result.exitCode == 0, "hdiutil create")
    }

    static func diskImage(app: String, bundleID: String, version: String, in sandbox: Sandbox, name: String) async throws -> URL {
        let source = try sandbox.folder("image-\(name)")
        try SimulationBuilder.makeSyntheticApp(name: app, bundleID: bundleID, version: version, in: source)
        let dmg = sandbox.url.appendingPathComponent("\(name).dmg")
        try await createImage(source: source, name: name, at: dmg)
        return dmg
    }

    static func inspector(_ sandbox: Sandbox) -> (InstallerArchiveInspector, SystemLayout) {
        let layout = toolchainLayout(sandbox)
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:])
        return (InstallerArchiveInspector(layout: layout, runner: runner), layout)
    }

    @Test func installersAreInspectedWithoutRunningThem() async throws {
        let sandbox = try Sandbox("own-inspect")
        let (inspector, _) = Self.inspector(sandbox)
        let work = sandbox.url.appendingPathComponent("work")
        let dmg = try await Self.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenDriver")
        let fromImage = try await inspector.inspect(dmg, workFolder: work)
        #expect(fromImage.kind == .dmg && fromImage.bundleIdentifier == "com.example.pen" && fromImage.version == "4.0.14")
        #expect(fromImage.sha256 == (try Hashing.sha256Hex(ofFile: dmg)) && fromImage.id == String(fromImage.sha256.prefix(16)))
        #expect(!fromImage.trustedSignature, "the synthetic app has no Developer ID signature")
        // The XP-Pen shape: a zip that contains a disk image.
        let zip = sandbox.url.appendingPathComponent("PenDriver.zip")
        try Self.run("/usr/bin/ditto", ["-c", "-k", dmg.path, zip.path])
        let fromZip = try await inspector.inspect(zip, workFolder: work)
        #expect(fromZip.kind == .zip && fromZip.bundleIdentifier == "com.example.pen")
        // An installer package without a signature.
        let payload = try sandbox.folder("payload")
        try Data("x".utf8).write(to: payload.appendingPathComponent("file.txt"))
        let pkg = sandbox.url.appendingPathComponent("Activation.pkg")
        try Self.run("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "com.example.activation", "--version", "1", "--install-location", "/tmp/x", pkg.path])
        let package = try await inspector.inspect(pkg, workFolder: work)
        #expect(package.kind == .pkg && !package.trustedSignature && package.signer == nil)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("inspect-\(fromZip.id)").path), "nothing left behind")
        await #expect(throws: InstallerInspectionError.unsupportedType) {
            try await inspector.inspect(sandbox.url.appendingPathComponent("notes.txt"), workFolder: work)
        }
    }

    @Test func onlyInstallersOfTheAppsDeveloperAreUsed() {
        let app = AppRecord(name: "Word", bundleIdentifier: "com.microsoft.Word", path: "/Applications/Microsoft Word.app")
        var signedApp = app
        signedApp.teamIdentifier = "UBF8T346G9"
        let microsoft = InstallerArchive(id: "a", fileName: "Office.pkg", kind: .pkg, size: 1, sha256: "a", teamIdentifier: "UBF8T346G9",
                                         trustedSignature: true, originalPath: "/Volumes/USB/Office.pkg")
        var other = microsoft
        other.teamIdentifier = "OTHERTEAM1"
        var unsigned = microsoft
        unsigned.trustedSignature = false
        #expect(microsoft.matchesDeveloper(of: signedApp))
        #expect(!other.matchesDeveloper(of: signedApp), "a package signed by someone else is never opened by MacReplica")
        #expect(!unsigned.matchesDeveloper(of: signedApp) && !unsigned.matchesDeveloper(of: app))
        #expect(other.matchesDeveloper(of: app), "without a known app team, a trusted Developer ID signature is required")
    }

    @Test func includedInstallersAreBackedUpVerifiedAndUsedOffline() async throws {
        let sandbox = try Sandbox("own-backup")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        var inventory = try await TestEnvironment.inventory(source).run()
        let (inspector, _) = Self.inspector(sandbox)
        let drive = try sandbox.folder("Volumes/Installers")
        let dmg = try await Self.diskImage(app: "Quill Writer", bundleID: "com.example.quillwriter", version: "7.0.2", in: sandbox, name: "Quill")
        let kept = drive.appendingPathComponent("Quill-7.0.2.dmg")
        try FileManager.default.moveItem(at: dmg, to: kept)
        var archive = try await inspector.inspect(kept, workFolder: sandbox.url.appendingPathComponent("work"))
        archive.trustedSignature = true // stands for the vendor's Developer ID signature the synthetic image lacks
        let app = try #require(inventory.manifest.applications.first { $0.bundleIdentifier == "com.example.quillwriter" })
        inventory.attachInstallers([(archive, kept, true)], toApp: app.id)
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(inventory, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let recorded = try #require(outcome.manifest.applications.first { $0.id == app.id }?.ownInstallers?.first)
        #expect(recorded.includedPath == "installers/\(archive.id)/Quill-7.0.2.dmg")
        #expect(FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent(recorded.includedPath ?? "").path))
        let verification = BackupVerifier(layout: source.layout).verify(backupAt: outcome.url)
        #expect(verification.isIntact, "the installer is part of the checksummed backup")
        _ = root

        // The new Mac, without the drive: the copy in the backup is used.
        let restoredApp = try #require(outcome.manifest.applications.first { $0.id == app.id })
        let layout = toolchainLayout(sandbox)
        try FileManager.default.removeItem(at: drive)
        let offer = try #require(OwnInstallerSource.offer(for: restoredApp, itemID: "manual:quill", backupRoot: outcome.url, layout: layout))
        #expect(offer.kind == .ownInstaller && offer.recommended && offer.trust == .checksum && offer.sha256 == archive.sha256)
        #expect(offer.localPath?.hasPrefix(outcome.url.path) == true)
        // Not included and the drive is gone: no offer, and the installer is reported as not available.
        var notIncluded = restoredApp
        notIncluded.ownInstallers?[0].includedPath = nil
        #expect(OwnInstallerSource.offer(for: notIncluded, itemID: "x", backupRoot: outcome.url, layout: layout) == nil)
        #expect(OwnInstallerSource.unusable(for: notIncluded, backupRoot: outcome.url, layout: layout).count == 1)
    }

    @Test func guidedInstallFromTheOwnInstallerThenItsFurtherPackages() async throws {
        let fixture = try VendorFixture("own-guided")
        let layout = toolchainLayout(fixture.sandbox)
        let applications = layout.applicationFolders[0]
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let dmg = try await Self.diskImage(app: "Pen Tablet", bundleID: "com.example.pentablet", version: "4.0.14", in: fixture.sandbox, name: "Pen")
        let payload = try fixture.sandbox.folder("payload")
        try Data("x".utf8).write(to: payload.appendingPathComponent("licence.txt"))
        let pkg = fixture.root.appendingPathComponent("Activation.pkg")
        try Self.run("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "com.example.act", "--version", "1", "--install-location", "/tmp/x", pkg.path])
        var offer = DownloadOffer(id: "own:1", itemID: "manual:pen", kind: .ownInstaller, url: dmg.absoluteString, version: "4.0.14",
                                  sha256: try Hashing.sha256Hex(ofFile: dmg), expectedBundleIdentifier: "com.example.pentablet", trust: .checksum)
        offer.localPath = dmg.path
        // The further package is not signed: it is reported, never opened.
        offer.followUps = [DownloadOffer.LocalPackage(name: "Activation.pkg", path: pkg.path, sha256: try Hashing.sha256Hex(ofFile: pkg), teamIdentifier: nil)]
        let installer = fixture.installer(layout: layout)
        let queue = DownloadQueue(transport: LocalDownloadTransport(root: fixture.root), folder: installer.downloadsFolder)
        let guided = GuidedInstallation(installer: installer, queue: queue)
        let item = RestoreItem(id: "manual:pen", kind: .manualApp, title: "Pen Tablet", identifier: "/Applications/Pen Tablet.app",
                               bundleIdentifier: "com.example.pentablet", appBundleNames: ["Pen Tablet.app"], component: .applications)
        let interaction = GuidedInstallationTests.ScriptedInteraction([.checkAgain])
        let result = await guided.install(item, offer: offer, interaction: interaction, isInstalled: { item in
            guard let info = NSDictionary(contentsOf: applications.appendingPathComponent("Pen Tablet.app/Contents/Info.plist")) as? [String: Any],
                  (info["CFBundleIdentifier"] as? String) == item.bundleIdentifier else { return nil }
            return .some(info["CFBundleShortVersionString"] as? String)
        })
        #expect(result.outcome == .succeeded && result.installedVersion == "4.0.14", "installed from the user's disk image, offline")
        #expect(result.notes.contains(.additionalPackageNotInstalled(name: "Activation.pkg")))
        #expect(await interaction.opened.isEmpty, "an unsigned package is never opened")
        #expect(try Hashing.sha256Hex(ofFile: dmg) == offer.sha256, "the user's file is left as it was")

        // A changed file (not what the old Mac recorded) is refused.
        var changed = offer
        changed.sha256 = String(repeating: "0", count: 64)
        try FileManager.default.removeItem(at: applications.appendingPathComponent("Pen Tablet.app"))
        let refused = await guided.install(item, offer: changed, interaction: interaction, isInstalled: { _ in nil })
        #expect(refused.outcome.isFailure)
        #expect(!FileManager.default.fileExists(atPath: applications.appendingPathComponent("Pen Tablet.app").path))
    }

    @Test func signerFollowUpsAndUnusableInstallers() throws {
        let output = """
        Package "Office.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Certificate Chain:
            1. Developer ID Installer: Example Inc (TEAMID1234)
               Expires: 2030-01-01
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        #expect(InstallerArchiveInspector.signer(output) == "Developer ID Installer: Example Inc (TEAMID1234)", "the leaf certificate")
        #expect(InstallerArchiveInspector.signer("Status: no signature") == nil)
        let plain = InstallerArchive(id: "x", fileName: "a.pkg", kind: .pkg, size: 1, sha256: "x", originalPath: "/x")
        #expect(!plain.containsLicence && plain.includedPath == nil && !plain.trustedSignature && plain.architectures.isEmpty)

        let sandbox = try Sandbox("own-followups")
        let drive = try sandbox.folder("drive")
        for name in ["App.dmg", "Activation.pkg", "Extra.dmg", "Other.pkg"] { try Data(name.utf8).write(to: drive.appendingPathComponent(name)) }
        func archive(_ name: String, _ kind: InstallerArchive.Kind, team: String = "TEAMID1234") -> InstallerArchive {
            InstallerArchive(id: name, fileName: name, kind: kind, size: 1, sha256: name, teamIdentifier: team, trustedSignature: true,
                             originalPath: drive.appendingPathComponent(name).path)
        }
        var app = AppRecord(name: "Office", bundleIdentifier: "com.example.office", path: "/Applications/Office.app")
        app.teamIdentifier = "TEAMID1234"
        app.ownInstallers = [archive("App.dmg", .dmg), archive("Activation.pkg", .pkg), archive("Extra.dmg", .dmg),
                             archive("Other.pkg", .pkg, team: "OTHERTEAM1"), archive("Missing.pkg", .pkg)]
        let layout = toolchainLayout(sandbox)
        let offer = try #require(OwnInstallerSource.offer(for: app, itemID: "manual:office", backupRoot: nil, layout: layout))
        #expect(offer.localPath == drive.appendingPathComponent("App.dmg").path && !offer.isPackage)
        #expect(offer.followUps?.map(\.name) == ["Activation.pkg"],
                "only further packages of the same developer that are available; disk images and other developers' packages are not opened")
        #expect(Set(OwnInstallerSource.unusable(for: app, backupRoot: nil, layout: layout).map(\.fileName)) == ["Other.pkg", "Missing.pkg"])
        var firstMissing = app
        firstMissing.ownInstallers?.removeFirst(2)
        firstMissing.ownInstallers?.insert(archive("Gone.dmg", .dmg), at: 0)
        #expect(OwnInstallerSource.offer(for: firstMissing, itemID: "x", backupRoot: nil, layout: layout) == nil, "the first installer must be there")
        var packageFirst = app
        packageFirst.ownInstallers = [archive("Activation.pkg", .pkg)]
        #expect(OwnInstallerSource.offer(for: packageFirst, itemID: "x", backupRoot: nil, layout: layout)?.isPackage == true,
                "a package opens in Apple's Installer")
    }
}
