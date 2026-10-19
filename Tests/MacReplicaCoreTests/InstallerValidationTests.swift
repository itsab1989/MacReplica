import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.7 (Knut): working disk images – the DisplayCAL installer he had just installed from, AppPolice, Adobe's
/// Color Printer Utility – were reported as "damaged, incomplete or encrypted". MacReplica called every failed `hdiutil`
/// step damage. Now each step has its own verdict: only the file's own bytes or its own checksum prove damage; an intact
/// installer that cannot be inspected is kept with the reason. These tests use real `hdiutil`, `pkgutil` and `ditto`.
@Suite("Installer validation")
struct InstallerValidationTests {
    /// Passes every command to the real runner and records it.
    final class RecordingRunner: CommandRunning, @unchecked Sendable {
        let inner: CommandRunning
        private let lock = NSLock()
        private var recorded: [Command] = []
        init(_ inner: CommandRunning) { self.inner = inner }
        var commands: [Command] { lock.withLock { recorded } }
        func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            lock.withLock { recorded.append(command) }
            return try await inner.run(command, onOutputLine: onOutputLine)
        }
    }

    static func setup(_ name: String) throws -> (Sandbox, InstallerArchiveInspector, RecordingRunner, SystemLayout, URL) {
        let sandbox = try Sandbox(name)
        let layout = toolchainLayout(sandbox)
        let runner = RecordingRunner(ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]))
        var inspector = InstallerArchiveInspector(layout: layout, runner: runner)
        inspector.retryPause = 50_000_000
        return (sandbox, inspector, runner, layout, sandbox.url.appendingPathComponent("work"))
    }

    static func hdiutil(_ arguments: [String]) async throws -> CommandResult {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/hdiutil"]), baseEnvironment: [:])
        return try await DiskImageCommands.run(runner, Command(executable: "/usr/bin/hdiutil", arguments: arguments, timeout: 300))
    }

    /// Whether macOS still has the image attached.
    static func isAttached(_ image: URL) async -> Bool {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/hdiutil"]), baseEnvironment: [:])
        return await !DownloadInstaller.attachments(of: image.path, runner: runner, hdiutil: "/usr/bin/hdiutil", environment: [:]).isEmpty
    }

    static func detachAll(_ image: URL) async {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/hdiutil"]), baseEnvironment: [:])
        await DownloadInstaller.detachAttachments(of: image.path, runner: runner, hdiutil: "/usr/bin/hdiutil", environment: [:])
    }

    static let app = AppRecord(name: "Pen Driver", bundleIdentifier: "com.example.pen", path: "/Applications/Pen Driver.app")



    // MARK: Intact images that cannot be inspected are kept

    /// Answers `hdiutil verify` like a busy disk-image service ("Resource temporarily unavailable", exit 1, no report)
    /// for the first `busy` calls; everything else runs the real tool.
    final class BusyVerifyRunner: CommandRunning, @unchecked Sendable {
        let base: CommandRunning
        private let lock = NSLock()
        private var remaining: Int
        private(set) var verifyCalls = 0
        init(_ base: CommandRunning, busy: Int) { self.base = base; remaining = busy }
        func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            if command.arguments.first == "verify" {
                let busy: Bool = lock.withLock { verifyCalls += 1; if remaining > 0 { remaining -= 1; return true }; return false }
                if busy { return CommandResult(exitCode: 1, stdout: "", stderr: "hdiutil: verify failed - Resource temporarily unavailable\n", timedOut: false) }
            }
            return try await base.run(command, onOutputLine: onOutputLine)
        }
    }

    func intactUnmountableImage(_ sandbox: Sandbox) async throws -> URL {
        let raw = sandbox.url.appendingPathComponent("blank.dmg")
        let image = sandbox.url.appendingPathComponent("Busy Installer.dmg")
        #expect(try await Self.hdiutil(["create", "-quiet", "-size", "2m", "-layout", "NONE", raw.path]).succeeded)
        #expect(try await Self.hdiutil(["convert", "-quiet", raw.path, "-format", "UDZO", "-o", image.path]).succeeded)
        return image
    }

    /// The 1.1.7 release run: an intact image was called damaged because `hdiutil verify` failed while the service was
    /// busy. Without a checksum report there is no proof: it is tried again and the image is kept, never “damaged”.
    @Test func aBusyVerifyIsNoProofOfDamage() async throws {
        let (sandbox, _, _, layout, work) = try Self.setup("validate-busy")
        let image = try await intactUnmountableImage(sandbox)
        let busy = BusyVerifyRunner(ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]), busy: 99)
        var inspector = InstallerArchiveInspector(layout: layout, runner: busy)
        inspector.retryPause = 10_000_000
        let selection = await inspector.select(image, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("bundles"))
        let archive = try selection.result.get().archive
        #expect(archive.contentsLimit == .notMountable)
        #expect(archive.inspectionNote?.contains("checksum not checked – hdiutil verify: exit 1") == true, "\(archive.inspectionNote ?? "-")")
        #expect(archive.inspectionNote?.contains("checksum verified") == false, "never claimed")
        #expect(busy.verifyCalls == 3, "tried three times")
    }

    @Test func aVerifyThatSucceedsOnRetryCounts() async throws {
        let (sandbox, _, _, layout, work) = try Self.setup("validate-busy-once")
        let image = try await intactUnmountableImage(sandbox)
        let busy = BusyVerifyRunner(ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]), busy: 1)
        var inspector = InstallerArchiveInspector(layout: layout, runner: busy)
        inspector.retryPause = 10_000_000
        let archive = try await inspector.select(image, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("bundles")).result.get().archive
        #expect(archive.inspectionNote?.contains("checksum verified") == true)
        #expect(busy.verifyCalls == 2)
    }

    /// `hdiutil verify -plist` (macOS 27, all image formats): calculated and expected checksum; English keys whatever the
    /// user's language.
    @Test func checksumsAreReadFromTheVerifyReport() {
        func report(_ calculated: String, _ expected: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>calculated</key><dict><key>Checksum Type</key><string>CRC32</string><key>Checksum Value</key><string>\(calculated)</string></dict>
            <key>expected</key><dict><key>Checksum Type</key><string>CRC32</string><key>Checksum Value</key><string>\(expected)</string></dict>
            </dict></plist>
            """
        }
        let same = InstallerArchiveInspector.checksums(inVerifyOutput: report("$409D9D0F", "$409D9D0F"))
        #expect(same?.calculated == "CRC32 $409D9D0F" && same?.expected == "CRC32 $409D9D0F")
        let differs = InstallerArchiveInspector.checksums(inVerifyOutput: "verifying…\n" + report("$85FB4511", "$409D9D0F"))
        #expect(differs?.calculated != differs?.expected)
        #expect(InstallerArchiveInspector.checksums(inVerifyOutput: "") == nil)
        #expect(InstallerArchiveInspector.checksums(inVerifyOutput: "hdiutil: verify failed - Resource temporarily unavailable") == nil)
        #expect(InstallerArchiveInspector.checksums(inVerifyOutput: report("", "$409D9D0F")) == nil, "an empty value is no report")
    }

    /// The regression: an intact disk image that macOS does not mount here ("no mountable file systems" – the same
    /// message an attach gets when its folder disappears) was "damaged". Its own checksum is intact, so it is kept.
    @Test func intactImageThatDoesNotMountIsKeptNotCalledDamaged() async throws {
        let (sandbox, inspector, runner, _, work) = try Self.setup("validate-nomount")
        let raw = sandbox.url.appendingPathComponent("blank.dmg")
        let image = sandbox.url.appendingPathComponent("Blank Installer ÆØÅ.dmg")
        #expect(try await Self.hdiutil(["create", "-quiet", "-size", "2m", "-layout", "NONE", raw.path]).succeeded)
        #expect(try await Self.hdiutil(["convert", "-quiet", raw.path, "-format", "UDZO", "-o", image.path]).succeeded)
        #expect(FileFormatEvidence.examine(image) == .udif(hasChecksum: true))

        let selection = await inspector.select(image, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("bundles"))
        let archive = try selection.result.get().archive
        #expect(archive.contentsLimit == .notMountable)
        #expect(archive.inspectionNote?.contains("hdiutil attach: exit") == true && archive.inspectionNote?.contains("checksum verified") == true)
        #expect(runner.commands.contains { $0.arguments.first == "verify" }, "the image's own checksum decided")
        #expect(archive.usability(for: Self.app) == .unverified(.contentsNotInspected) && !archive.isUsable(for: Self.app), "used only after the user confirms")
        #expect(await !Self.isAttached(image), "nothing stays attached")
        let description = TestEnvironment.english.installerDescription(archive, for: Self.app)
        #expect(description.summary.contains("could not be opened on this Mac") && description.status.contains("not found damaged"))
        #expect(!description.status.lowercased().contains("is damaged") && description.canApproveUnverified)
        var approved = archive
        approved.userApprovedUnverified = true
        #expect(TestEnvironment.english.installerDescription(approved, for: Self.app).nextAction?.contains("opens it in Finder") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty, "no work folder left")
    }

    /// Knut had just installed DisplayCAL from its image: it may still be open in Finder. MacReplica reads it there and
    /// leaves it open (before, the retry force-ejected the user's volume).
    @Test func imageAlreadyOpenIsReadWhereItIsAndStaysOpen() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-open")
        let dmg = try await OwnInstallerTests.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenDriver")
        let mount = try sandbox.folder("users-mount")
        #expect(try await Self.hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.appendingPathComponent("PenDriver").path, dmg.path]).succeeded)
        defer { Task { await Self.detachAll(dmg) } }
        let archive = try await inspector.inspect(dmg, workFolder: work)
        #expect(archive.bundleIdentifier == "com.example.pen" && archive.contentsLimit == nil)
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("PenDriver/Pen Driver.app").path), "the user's volume is still open")
        await Self.detachAll(dmg)
    }

    /// Attached by someone else without a volume: MacReplica's attach is refused ("resource busy"); the retries never
    /// detach the other attachment, and the intact image is kept.
    @Test func attachmentsMadeByOthersAreNeverDetached() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-busy")
        let dmg = try await OwnInstallerTests.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenBusy")
        #expect(try await Self.hdiutil(["attach", "-nomount", "-readonly", "-noautoopen", dmg.path]).succeeded)
        let archive = try await inspector.inspect(dmg, workFolder: work)
        #expect(archive.contentsLimit == .notMountable && archive.inspectionNote?.contains("already attached") == true)
        #expect(await Self.isAttached(dmg), "the other attachment survived")
        await Self.detachAll(dmg)
    }

    /// Two inspections of one file at the same time in the same work folder: neither removes the other's folder.
    @Test func concurrentInspectionsDoNotPullTheFolderFromUnderEachOther() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-parallel")
        let dmg = try await OwnInstallerTests.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenTwice")
        let (store1, store2) = (sandbox.url.appendingPathComponent("b1"), sandbox.url.appendingPathComponent("b2"))
        async let first = inspector.select(dmg, workFolder: work, bundleStore: store1)
        async let second = inspector.select(dmg, workFolder: work, bundleStore: store2)
        for selection in await [first, second] {
            let archive = try selection.result.get().archive
            #expect(archive.bundleIdentifier == "com.example.pen" && archive.contentsLimit == nil)
        }
    }

    @Test func encryptedImageIsKeptWithoutAskingForItsPassword() async throws {
        let (sandbox, inspector, runner, _, work) = try Self.setup("validate-encrypted")
        let source = try sandbox.folder("secret")
        try Data("x".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let dmg = sandbox.url.appendingPathComponent("Protected.dmg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-encryption", "AES-128", "-stdinpass", "-srcfolder", source.path, "-format", "UDZO", dmg.path]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("not-a-real-secret".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        // `hdiutil create -encryption -srcfolder` can leave the new image attached ("write once"); it is detached first.
        await Self.detachAll(dmg)
        let archive = try await inspector.inspect(dmg, workFolder: work)
        #expect(archive.contentsLimit == .encrypted)
        #expect(!runner.commands.contains { $0.executable.hasSuffix("hdiutil") }, "hdiutil would wait for the password in a dialog")
    }

    @Test func unusualLayoutsAreKept() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-layout")
        // The app three folders down, next to a manual: nothing where MacReplica looks.
        let source = try sandbox.folder("deep")
        try SimulationBuilder.makeSyntheticApp(name: "Deep", bundleID: "com.example.deep", version: "1.0", in: try sandbox.folder("deep/Mac/Universal/Install"))
        try Data("%PDF-1.4".utf8).write(to: source.appendingPathComponent("Manual.pdf"))
        let dmg = sandbox.url.appendingPathComponent("Deep Layout.dmg")
        try await OwnInstallerTests.createImage(source: source, name: "Deep", at: dmg)
        let fromImage = try await inspector.inspect(dmg, workFolder: work)
        #expect(fromImage.contentsLimit == .notRecognised && fromImage.containedApps.isEmpty)
        #expect(await !Self.isAttached(dmg))
        let zip = sandbox.url.appendingPathComponent("Deep.zip")
        try OwnInstallerTests.run("/usr/bin/ditto", ["-c", "-k", source.path, zip.path])
        #expect(try await inspector.inspect(zip, workFolder: work).contentsLimit == .notRecognised)
        // Apps one folder down (a suite folder such as DisplayCAL/) are still found, as before.
        let suite = try sandbox.folder("suite")
        try SimulationBuilder.makeSyntheticApp(name: "Suite", bundleID: "com.example.suite", version: "2.0", in: try sandbox.folder("suite/Suite"))
        let suiteImage = sandbox.url.appendingPathComponent("Suite.dmg")
        try await OwnInstallerTests.createImage(source: suite, name: "Suite", at: suiteImage)
        #expect(try await inspector.inspect(suiteImage, workFolder: work).bundleIdentifier == "com.example.suite")
    }

    // MARK: Damage is still found – and only with proof

    /// Packages inside disk images (as in Karabiner-Elements' image), readable or not, and package files that are none.
    @Test func packagesAreRecognisedInsideImagesAndBytesDecideForPackageFiles() async throws {
        let (sandbox, inspector, runner, _, work) = try Self.setup("validate-packages")
        let payload = try sandbox.write("x", to: "payload/file.txt").deletingLastPathComponent()
        let folder = try sandbox.folder("withPackage")
        try OwnInstallerTests.run("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "com.example.driver", "--version", "1",
                                                        "--install-location", "/tmp/x", folder.appendingPathComponent("Driver.pkg").path])
        let image = sandbox.url.appendingPathComponent("Driver.dmg")
        try await OwnInstallerTests.createImage(source: folder, name: "Driver", at: image)
        let withPackage = try await inspector.inspect(image, workFolder: work)
        #expect(withPackage.containsPackage && withPackage.contentsLimit == nil && withPackage.containedApps.isEmpty)
        // A package header pkgutil cannot read: kept, and still recorded as a package.
        let broken = try sandbox.folder("withBrokenPackage")
        try (Data("xar!".utf8) + Data(repeating: 0x41, count: 2000)).write(to: broken.appendingPathComponent("Broken.pkg"))
        let brokenImage = sandbox.url.appendingPathComponent("Broken.dmg")
        try await OwnInstallerTests.createImage(source: broken, name: "Broken", at: brokenImage)
        let unreadable = try await inspector.inspect(brokenImage, workFolder: work)
        #expect(unreadable.containsPackage && unreadable.contentsLimit == .notReadable)
        #expect(unreadable.inspectionNote?.hasPrefix("pkgutil --check-signature: exit") == true)
        // A .pkg file without a package header: pkgutil is not even asked.
        var noise = Data(count: 3001)
        for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        let fake = sandbox.url.appendingPathComponent("Setup.pkg")
        try noise.write(to: fake)
        let before = runner.commands.count
        #expect(try await Self.error(inspector, fake, work) == .notRecognised)
        #expect(!runner.commands.dropFirst(before).contains { $0.executable.hasSuffix("pkgutil") })
    }

    /// Where a UDIF image keeps its data and its list of contents, from its own trailer (koly block, big-endian).
    static func udifRegions(_ dmg: URL) throws -> (data: Range<Int>, xml: Range<Int>) {
        let bytes = try Data(contentsOf: dmg)
        let trailer = bytes.suffix(512)
        func u64(_ offset: Int) -> Int { trailer.dropFirst(offset).prefix(8).reduce(0) { $0 << 8 | Int($1) } }
        return (u64(24)..<(u64(24) + u64(32)), u64(216)..<(u64(216) + u64(224)))
    }

    static func overwrite(_ dmg: URL, at offset: Int) throws {
        let handle = try FileHandle(forUpdating: dmg)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 16))
        try handle.close()
    }

    /// Changed data: `hdiutil verify` reports a calculated checksum that differs – damage proven. The image has no file
    /// system, so the mount always fails and the checksum always decides (an image with an app may mount despite the
    /// damage, read only where needed – which made this test accept the changed image on a build machine once).
    @Test func changedImageIsDamagedByItsOwnChecksum() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-bitflip")
        let dmg = try await intactUnmountableImage(sandbox)
        let regions = try Self.udifRegions(dmg)
        try Self.overwrite(dmg, at: regions.data.lowerBound + regions.data.count / 2)
        #expect(FileFormatEvidence.examine(dmg) == .udif(hasChecksum: true), "the list of contents is intact")
        let selection = await inspector.select(dmg, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("b"))
        guard case .failure(let error) = selection.result else { Issue.record("a changed image was accepted"); return }
        #expect(error == .damaged(.checksumMismatch))
        #expect(selection.note?.contains("hdiutil verify: calculated CRC32 $") == true, "\(selection.note ?? "-")")
        #expect(await !Self.isAttached(dmg))
        #expect(TestEnvironment.english.installerProblemText(error).contains("damaged"))
    }

    /// An image without an XML list of contents (older images keep it in a resource fork) is not called damaged: only a
    /// list that exists and cannot be read proves damage.
    @Test func anImageWithoutAnXMLListIsNotDamaged() throws {
        let sandbox = try Sandbox("validate-noxml")
        func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (56 - 8 * $0) & 0xFF) } }
        func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (24 - 8 * $0) & 0xFF) } }
        let data = [UInt8](repeating: 0x5A, count: 4096)
        var koly = [UInt8](repeating: 0, count: 512)
        koly.replaceSubrange(0..<4, with: Array("koly".utf8))
        koly.replaceSubrange(4..<8, with: be32(4)); koly.replaceSubrange(8..<12, with: be32(512))
        koly.replaceSubrange(24..<32, with: be64(0)); koly.replaceSubrange(32..<40, with: be64(UInt64(data.count)))
        koly.replaceSubrange(216..<224, with: be64(0)); koly.replaceSubrange(224..<232, with: be64(0))   // no XML list
        koly.replaceSubrange(352..<356, with: be32(2))                                                    // master checksum CRC32
        let file = sandbox.url.appendingPathComponent("old.dmg")
        try Data(data + koly).write(to: file)
        #expect(FileFormatEvidence.examine(file) == .udif(hasChecksum: true))
        // With a list that is not a property list, the same image is damaged.
        let xml = Array("<?xml version=\"1.0\"?><plist><dict><key>broken".utf8)
        koly.replaceSubrange(216..<224, with: be64(UInt64(data.count))); koly.replaceSubrange(224..<232, with: be64(UInt64(xml.count)))
        try Data(data + xml + koly).write(to: file)
        #expect(FileFormatEvidence.examine(file) == .udifDirectoryDamaged)
    }

    /// A damaged list of contents: `hdiutil` fails without a checksum report ("error 3840"); MacReplica proves the
    /// damage from the file's bytes – the list is not a property list.
    @Test func aDamagedListOfContentsIsProvenFromTheBytes() async throws {
        let (sandbox, inspector, runner, _, work) = try Self.setup("validate-xml")
        let dmg = try await intactUnmountableImage(sandbox)
        let regions = try Self.udifRegions(dmg)
        #expect(!regions.xml.isEmpty)
        try Self.overwrite(dmg, at: regions.xml.lowerBound + regions.xml.count / 2)
        #expect(FileFormatEvidence.examine(dmg) == .udifDirectoryDamaged)
        let before = runner.commands.count
        let selection = await inspector.select(dmg, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("b"))
        guard case .failure(let error) = selection.result else { Issue.record("a damaged image was accepted"); return }
        #expect(error == .damaged(.directoryDamaged))
        #expect(!runner.commands.dropFirst(before).contains { $0.executable.hasSuffix("hdiutil") }, "decided without hdiutil")
        #expect(TestEnvironment.english.installerProblemText(error).contains("damaged"))
        #expect(FileFormatEvidence.directoryIsReadable(Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)))
        #expect(!FileFormatEvidence.directoryIsReadable(Data("<?xml version=\"1.0\"?><plist><dict><key>x".utf8)))
    }

    @Test func cutShortFilesAreIncomplete() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-truncated")
        let dmg = try await OwnInstallerTests.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenCut")
        let data = try Data(contentsOf: dmg)
        let cut = sandbox.url.appendingPathComponent("PenCut-partial.dmg")
        try data.prefix(data.count / 2).write(to: cut)
        await #expect(throws: InstallerInspectionFailure.self) { try await inspector.inspect(cut, workFolder: work) }
        #expect(try await Self.error(inspector, cut, work) == .damaged(.truncated))
        // A directory whose end points past the file (cut inside the directory's data).
        let lastBytes = sandbox.url.appendingPathComponent("PenCut-tail.dmg")
        try (data.prefix(data.count - 1000) + data.suffix(512)).write(to: lastBytes)
        #expect(try await Self.error(inspector, lastBytes, work) == .damaged(.truncated))
        // Zip archives without their end.
        let zip = sandbox.url.appendingPathComponent("Pen.zip")
        try OwnInstallerTests.run("/usr/bin/ditto", ["-c", "-k", dmg.path, zip.path])
        let zipData = try Data(contentsOf: zip)
        let cutZip = sandbox.url.appendingPathComponent("Pen-partial.zip")
        try zipData.prefix(zipData.count - 30).write(to: cutZip)
        #expect(try await Self.error(inspector, cutZip, work) == .damaged(.truncated))
        // A package cut short: pkgutil reports "package is invalid" – it used to count as merely unsigned.
        let payload = try sandbox.folder("payload")
        var blob = Data(count: 400_000)
        for index in blob.indices { blob[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 13) }
        try blob.write(to: payload.appendingPathComponent("blob.bin"))
        let pkg = sandbox.url.appendingPathComponent("Pen.pkg")
        try OwnInstallerTests.run("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "com.example.pen", "--version", "1", "--install-location", "/tmp/x", pkg.path])
        #expect(try await inspector.inspect(pkg, workFolder: work).kind == .pkg, "the complete package is fine")
        let pkgData = try Data(contentsOf: pkg)
        let cutPkg = sandbox.url.appendingPathComponent("Pen-partial.pkg")
        try pkgData.prefix(pkgData.count * 2 / 3).write(to: cutPkg)
        #expect(try await Self.error(inspector, cutPkg, work) == .damaged(.checksumMismatch))
    }

    @Test func filesThatAreNotInstallersSayWhatTheyAre() async throws {
        let (sandbox, inspector, runner, _, work) = try Self.setup("validate-other")
        let page = try sandbox.write("<!DOCTYPE html><html><head><title>403 Forbidden</title></head><body>Access denied</body></html>", to: "ACPU.dmg")
        #expect(try await Self.error(inspector, page, work) == .notAnInstaller(.webPage))
        let empty = try sandbox.write("", to: "Empty.dmg")
        #expect(try await Self.error(inspector, empty, work) == .notAnInstaller(.empty))
        let pageAsPackage = try sandbox.write("<html><body>Not found</body></html>", to: "Setup.pkg")
        #expect(try await Self.error(inspector, pageAsPackage, work) == .notAnInstaller(.webPage))
        #expect(!runner.commands.contains { $0.executable.hasSuffix("hdiutil") }, "the bytes decided before any tool ran")
        // Bytes MacReplica does not know and hdiutil cannot open: not called damaged, because that is not proven.
        // An odd size: hdiutil takes any file whose size is a multiple of 512 bytes for a raw disk image.
        var noise = Data(count: 4097)
        for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: index &* 7919 &+ 13) }
        noise[0] = 0x13
        let unknown = sandbox.url.appendingPathComponent("Mystery.dmg")
        try noise.write(to: unknown)
        #expect(FileFormatEvidence.examine(unknown) == .unknown)
        #expect(try await Self.error(inspector, unknown, work) == .notRecognised)
        let text = TestEnvironment.english.installerProblemText(.notRecognised)
        #expect(text.contains("Whether it is damaged could not be determined"))
    }

    static func error(_ inspector: InstallerArchiveInspector, _ file: URL, _ work: URL) async throws -> InstallerInspectionError? {
        let selection = await inspector.select(file, workFolder: work, bundleStore: work.deletingLastPathComponent().appendingPathComponent("bundles"))
        if case .failure(let error) = selection.result {
            #expect(selection.note?.isEmpty == false, "every rejection says what was checked")
            return error
        }
        return nil
    }

    // MARK: Restore



    /// On the new Mac: an image the user confirmed although it was not inspected is opened in Finder if MacReplica
    /// cannot open it; an installer verified by its developer keeps MacReplica's own checks and is never handed over.
    @Test func confirmedImageThatDoesNotOpenGoesToFinderOnTheNewMac() async throws {
        let (sandbox, _, _, layout, _) = try Self.setup("validate-restore")
        let raw = sandbox.url.appendingPathComponent("blank-raw.dmg")
        let image = sandbox.url.appendingPathComponent("Blank.dmg")
        #expect(try await Self.hdiutil(["create", "-quiet", "-size", "2m", "-layout", "NONE", raw.path]).succeeded)
        #expect(try await Self.hdiutil(["convert", "-quiet", raw.path, "-format", "UDZO", "-o", image.path]).succeeded)
        var installer = DownloadInstaller(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]),
                                          macOSVersion: "14.8", architecture: .x86_64)
        installer.retryPause = 10_000_000
        var offer = DownloadOffer(id: "own:x", itemID: "manual:m", kind: .ownInstaller, url: image.absoluteString, trust: .checksum)
        offer.developerUnverified = true
        let prepared = try await installer.prepare(image, offer: offer, staging: sandbox.url.appendingPathComponent("staging"))
        guard case .openInFinder(let shown, _) = prepared else { Issue.record("expected Finder, got \(prepared)"); return }
        #expect(shown == image)
        offer.developerUnverified = nil
        await #expect(throws: DownloadError.self) { try await installer.prepare(image, offer: offer, staging: sandbox.url.appendingPathComponent("staging2")) }
        #expect(await !Self.isAttached(image))
    }

    /// On the new Mac, a zip the user confirmed goes to Finder when MacReplica cannot unpack it or finds no app in it;
    /// a verified own installer and every other kind of offer keep failing with the reason instead.
    @Test func confirmedZipThatMacReplicaCannotUseGoesToFinder() async throws {
        let (sandbox, _, _, layout, _) = try Self.setup("validate-restore-zip")
        let installer = DownloadInstaller(layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]),
                                          macOSVersion: "14.8", architecture: .x86_64)
        let manual = try sandbox.write("Read me", to: "manual/Manual.txt").deletingLastPathComponent()
        let noApp = sandbox.url.appendingPathComponent("Manual.zip")
        try OwnInstallerTests.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", manual.path, noApp.path])
        // Bytes ditto cannot unpack (a half zip still unpacks from its local headers).
        let cut = sandbox.url.appendingPathComponent("Cut.zip")
        try Data(repeating: 0x42, count: 4096).write(to: cut)
        func offer(_ kind: DownloadOffer.Kind, confirmed: Bool?, _ file: URL) -> DownloadOffer {
            var offer = DownloadOffer(id: "x", itemID: "manual:x", kind: kind, url: file.absoluteString, trust: .checksum)
            offer.developerUnverified = confirmed
            return offer
        }
        var step = 0
        func staging() -> URL { step += 1; return sandbox.url.appendingPathComponent("staging-\(step)") }
        let finder = try await installer.prepare(noApp, offer: offer(.ownInstaller, confirmed: true, noApp), staging: staging())
        #expect(finder == .openInFinder(noApp, reason: .noApplicationFound))
        let unpacked = try await installer.prepare(cut, offer: offer(.ownInstaller, confirmed: true, cut), staging: staging())
        guard case .openInFinder(let shown, .extractionFailed(let detail)) = unpacked else { Issue.record("expected Finder, got \(unpacked)"); return }
        #expect(shown == cut && detail.hasPrefix("ditto -x: exit"))
        for (kind, confirmed) in [(DownloadOffer.Kind.ownInstaller, nil), (.homebrewCask, true), (.vendorFeed, true)] as [(DownloadOffer.Kind, Bool?)] {
            await #expect(throws: DownloadError.noApplicationFound) { try await installer.prepare(noApp, offer: offer(kind, confirmed: confirmed, noApp), staging: staging()) }
            await #expect(throws: DownloadError.self) { try await installer.prepare(cut, offer: offer(kind, confirmed: confirmed, cut), staging: staging()) }
        }
    }
}

/// The parts of the validation that need no tool: the file's bytes, the record, the texts, `hdiutil info` and `pkgutil`
/// output. Separate from the slower suite above so mutation testing can run them for every change.
@Suite("Installer evidence")
struct InstallerEvidenceTests {
    static let app = InstallerValidationTests.app

    @Test func evidenceComesFromTheFileItself() {
        func trailer(dataOffset: UInt64 = 0, dataLength: UInt64, xmlOffset: UInt64, xmlLength: UInt64, checksumType: UInt32 = 2) -> Data {
            var data = Data(count: 512)
            data.replaceSubrange(0..<4, with: Array("koly".utf8))
            func put64(_ value: UInt64, _ at: Int) { for i in 0..<8 { data[at + i] = UInt8((value >> (56 - 8 * UInt64(i))) & 0xFF) } }
            func put32(_ value: UInt32, _ at: Int) { for i in 0..<4 { data[at + i] = UInt8((value >> (24 - 8 * UInt32(i))) & 0xFF) } }
            put64(dataOffset, 24); put64(dataLength, 32); put64(xmlOffset, 216); put64(xmlLength, 224); put32(checksumType, 80)
            return data
        }
        let zlib = Data([0x78, 0xDA] + [UInt8](repeating: 1, count: 100))
        #expect(FileFormatEvidence.classify(head: zlib, trailer: trailer(dataLength: 900, xmlOffset: 900, xmlLength: 100), size: 1512) == .udif(hasChecksum: true))
        #expect(FileFormatEvidence.classify(head: zlib, trailer: trailer(dataLength: 900, xmlOffset: 900, xmlLength: 100, checksumType: 0), size: 1512) == .udif(hasChecksum: false))
        #expect(FileFormatEvidence.classify(head: zlib, trailer: trailer(dataLength: 900, xmlOffset: 900, xmlLength: 101), size: 1512) == .udifTruncated,
                "the directory points one byte past the end")
        #expect(FileFormatEvidence.classify(head: zlib, trailer: trailer(dataLength: 2000, xmlOffset: 0, xmlLength: 0), size: 1512) == .udifTruncated)
        #expect(FileFormatEvidence.classify(head: zlib, trailer: trailer(dataOffset: .max, dataLength: 2, xmlOffset: 0, xmlLength: 0), size: 1512) == .udifTruncated,
                "an overflowing offset is not trusted")
        #expect(FileFormatEvidence.classify(head: zlib, trailer: Data(repeating: 7, count: 512), size: 60_000_000) == .compressedImageWithoutDirectory)
        #expect(FileFormatEvidence.classify(head: Data("encrcdsa".utf8) + Data(count: 100), trailer: Data(count: 512), size: 9000) == .encrypted)
        #expect(FileFormatEvidence.classify(head: Data(count: 100), trailer: Data(count: 504) + Data("cdsaencr".utf8), size: 9000) == .encrypted)
        #expect(FileFormatEvidence.classify(head: Data("  <!DOCTYPE html><html>".utf8), trailer: Data(), size: 95) == .otherFormat(.webPage))
        #expect(FileFormatEvidence.classify(head: Data("PK\u{03}\u{04}rest".utf8), trailer: Data(), size: 10) == .otherFormat(.zipArchive))
        #expect(FileFormatEvidence.classify(head: Data("xar!rest".utf8), trailer: Data(), size: 10) == .otherFormat(.installerPackage))
        #expect(FileFormatEvidence.classify(head: Data("%PDF-1.7".utf8), trailer: Data(), size: 10) == .otherFormat(.pdf))
        var gpt = Data(count: 2048)
        gpt.replaceSubrange(512..<520, with: Array("EFI PART".utf8))
        #expect(FileFormatEvidence.classify(head: gpt, trailer: Data(count: 512), size: 10_000_000) == .rawImage, "a read/write image has no directory")
        var hfs = Data(count: 2048)
        hfs.replaceSubrange(1024..<1026, with: Array("H+".utf8))
        #expect(FileFormatEvidence.classify(head: hfs, trailer: Data(count: 512), size: 10_000_000) == .rawImage)
        #expect(FileFormatEvidence.classify(head: Data(count: 100), trailer: Data(count: 512), size: 4096, sector16: Data("CD001".utf8)) == .rawImage)
        #expect(FileFormatEvidence.classify(head: Data([0x13, 0x37, 0x00, 0x42]), trailer: Data(count: 512), size: 4096) == .unknown)
        #expect(FileFormatEvidence.OtherFormat.allCasesProveNothingButOtherFormat)
        #expect(!FileFormatEvidence.unknown.provesNotADiskImage && !FileFormatEvidence.rawImage.provesNotADiskImage && !FileFormatEvidence.encrypted.provesNotADiskImage)
    }

    @Test func notesKeepTheToolsWordsWithoutWarningsOrTheHomeFolder() {
        let result = CommandResult(exitCode: 1, stdout: "", stderr: "hdiutil: WARNING: 'hdiutil attach' is deprecated.\nhdiutil: attach failed - Keine aktivierbaren Dateisysteme /Users/knut/x.dmg")
        let note = InstallerArchiveInspector.note("hdiutil attach", result) { $0.replacingOccurrences(of: "/Users/knut", with: "~") }
        #expect(note == "hdiutil attach: exit 1 – hdiutil: attach failed - Keine aktivierbaren Dateisysteme ~/x.dmg")
        #expect(InstallerArchiveInspector.note("hdiutil verify", CommandResult(exitCode: 15, stdout: "", stderr: "", timedOut: true)) { $0 } == "hdiutil verify: did not finish in time")
        #expect(InstallerArchiveInspector.note("pkgutil", CommandResult(exitCode: 1, stdout: "<?xml", stderr: "")) { $0 } == "pkgutil: exit 1")
    }

    @Test func reasonIsRecordedAndOlderAndNewerBackupsStillRead() throws {
        let archive = InstallerArchive(id: "a", fileName: "X.dmg", kind: .dmg, size: 1, sha256: "a", originalPath: "/Volumes/Backup/X.dmg",
                                       contentsLimit: .notMountable, inspectionNote: "hdiutil attach: exit 1")
        let decoded = try JSONDecoder().decode(InstallerArchive.self, from: JSONEncoder().encode(archive))
        #expect(decoded == archive && decoded.contentsUnknown)
        let older = #"{"id":"a","fileName":"X.dmg","kind":"dmg","size":1,"sha256":"a","originalPath":"/x"}"#
        let old = try JSONDecoder().decode(InstallerArchive.self, from: Data(older.utf8))
        #expect(old.contentsLimit == nil && old.inspectionNote == nil && !old.contentsUnknown)
        let newer = older.replacingOccurrences(of: "}", with: #","contentsLimit":"somethingNew"}"#)
        #expect(try JSONDecoder().decode(InstallerArchive.self, from: Data(newer.utf8)).contentsLimit == .notReadable, "an unknown reason still means unchecked")
    }

    @Test func everyReasonHasItsOwnTextInEveryLanguage() {
        for language in AppLanguage.allCases {
            let l = Localizer(language: language)
            for limit in InstallerArchive.ContentsLimit.allCases {
                for key in ["ownInstaller.contents.limit.\(limit.rawValue)", "ownInstaller.status.limit.\(limit.rawValue)"] {
                    #expect(l.t(key) != key, "\(language) \(key)")
                    if language != .english { #expect(l.t(key) != TestEnvironment.english.t(key), "\(language) \(key) is translated") }
                }
            }
            for key in ["ownInstaller.problem.truncated", "ownInstaller.problem.notAnInstaller", "ownInstaller.problem.notRecognised", "ownInstaller.next.finder",
                        "ownInstaller.format.webPage", "ownInstaller.format.empty", "ownInstaller.format.zipArchive", "ownInstaller.format.installerPackage",
                        "ownInstaller.format.pdf", "ownInstaller.details", "ownInstaller.problem.details"] {
                #expect(l.t(key) != key, "\(language) \(key)")
            }
        }
        let l = TestEnvironment.english
        #expect(l.installerProblemText(.damaged(.truncated)).contains("incomplete"))
        #expect(l.installerProblemText(.notAnInstaller(.webPage)).contains("a web page"))
        for limit in InstallerArchive.ContentsLimit.allCases {
            let archive = InstallerArchive(id: "a", fileName: "X.dmg", kind: .dmg, size: 1, sha256: "a", originalPath: "/x", contentsLimit: limit)
            let status = l.installerDescription(archive, for: Self.app).status
            #expect(!status.contains("is damaged") && (status.contains("not damaged") || status.contains("not found damaged")
                                                      || status.contains("is fine") || status.contains("Nothing was found damaged") || status.contains("is complete")),
                    "\(limit): \(status)")
        }
    }

    @Test func filesAreReadFromBothEnds() throws {
        let sandbox = try Sandbox("evidence-files")
        // A zip archive ends with its central directory; a comment may follow it (up to 64 KiB).
        let payload = try sandbox.write("hello", to: "payload/readme.txt")
        let zip = sandbox.url.appendingPathComponent("a.zip")
        try OwnInstallerTests.run("/usr/bin/ditto", ["-c", "-k", payload.path, zip.path])
        #expect(ZipEvidence.hasCentralDirectory(zip) == true)
        let data = try Data(contentsOf: zip)
        let commented = sandbox.url.appendingPathComponent("commented.zip")
        try (data + Data(repeating: 0x20, count: 60_000)).write(to: commented)
        #expect(ZipEvidence.hasCentralDirectory(commented) == true, "found before a long comment")
        let cut = sandbox.url.appendingPathComponent("cut.zip")
        try data.prefix(data.count - 22).write(to: cut)
        #expect(ZipEvidence.hasCentralDirectory(cut) == false)
        let tiny = try sandbox.write("PK", to: "tiny.zip")
        #expect(ZipEvidence.hasCentralDirectory(tiny) == false)
        #expect(ZipEvidence.hasCentralDirectory(sandbox.url.appendingPathComponent("missing.zip")) == nil)
        // Files shorter than a disk image's directory, and missing files.
        #expect(FileFormatEvidence.examine(try sandbox.write("hello", to: "small.dmg")) == .unknown)
        #expect(FileFormatEvidence.examine(try sandbox.write("", to: "empty.dmg")) == .otherFormat(.empty))
        #expect(FileFormatEvidence.examine(sandbox.url.appendingPathComponent("missing.dmg")) == nil)
        var iso = Data(count: 40_000)
        iso.replaceSubrange(32_769..<32_774, with: Array("CD001".utf8))
        let isoFile = sandbox.url.appendingPathComponent("disc.dmg")
        try iso.write(to: isoFile)
        #expect(FileFormatEvidence.examine(isoFile) == .rawImage, "ISO 9660 is found in sector 16")
        var udif = Data([0x78, 0x01]) + Data(count: 998)
        var trailer = Data(count: 512)
        trailer.replaceSubrange(0..<4, with: Array("koly".utf8))
        trailer[39] = 0xE8; trailer[38] = 0x03  // data fork length 1000
        trailer[83] = 2                          // CRC32
        udif += trailer
        let udifFile = sandbox.url.appendingPathComponent("image.dmg")
        try udif.write(to: udifFile)
        #expect(FileFormatEvidence.examine(udifFile) == .udif(hasChecksum: true))
        try (udif.prefix(900) + trailer).write(to: udifFile)
        #expect(FileFormatEvidence.examine(udifFile) == .udifTruncated)
    }

    /// Every signature, and files exactly as long as each check needs.
    @Test func everySignatureAndEveryMinimumLength() throws {
        func head(_ bytes: [UInt8], at offset: Int = 0, count: Int = 2048) -> Data {
            var data = Data(count: count)
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            return data
        }
        let trailer = Data(count: 512)
        func classify(_ data: Data) -> FileFormatEvidence { FileFormatEvidence.classify(head: data, trailer: trailer, size: 1_000_000) }
        #expect(classify(head(Array("sprs".utf8))) == .rawImage)
        #expect(classify(head(Array("ER".utf8)) + Data()) == .unknown, "ER alone is no Apple partition map")
        var apm = head(Array("ER".utf8))
        apm.replaceSubrange(512..<514, with: Array("PM".utf8))
        #expect(classify(apm) == .rawImage)
        #expect(classify(head(Array("PM".utf8), at: 512)) == .unknown, "PM alone neither")
        #expect(classify(head(Array("HX".utf8), at: 1024)) == .rawImage)
        #expect(classify(head(Array("NXSB".utf8), at: 32)) == .rawImage)
        for compressed in ["BZh9", "bvx2", "bvx-", "bvxn", "bvx1"] {
            #expect(classify(Data(compressed.utf8) + Data(count: 100)) == .compressedImageWithoutDirectory, "\(compressed)")
        }
        #expect(classify(Data([0x5D, 0x00, 0x00, 0x80])) == .compressedImageWithoutDirectory, "LZMA")
        #expect(classify(Data([0x5D, 0x00, 0x01])) == .unknown)
        #expect(classify(Data([0x5D, 0x01, 0x00])) == .unknown)
        #expect(classify(Data([0x78, 0x9C])) == .compressedImageWithoutDirectory, "two bytes are enough for zlib")
        #expect(classify(Data([0x78, 0x5E])) == .compressedImageWithoutDirectory)
        #expect(classify(Data([0x78, 0x02])) == .unknown)
        #expect(classify(Data([0x77, 0xDA])) == .unknown)
        #expect(classify(Data([0x5D, 0x00, 0x00])) == .compressedImageWithoutDirectory, "three bytes are enough for LZMA")
        #expect(classify(head([0x55, 0xAA], at: 510, count: 512)) == .rawImage, "an MBR in exactly 512 bytes")
        #expect(classify(head([0x55, 0xAB], at: 510, count: 512)) == .unknown)
        #expect(classify(head([0x54, 0xAA], at: 510, count: 512)) == .unknown)
        #expect(classify(Data("<HTML><body>".utf8)) == .otherFormat(.webPage))
        #expect(classify(Data("<?xml version=\"1.0\"?><html xmlns=\"x\">".utf8)) == .otherFormat(.webPage))
        #expect(classify(Data("<?xml version=\"1.0\"?><plist>".utf8)) == .unknown, "XML that is no web page")
        #expect(classify(Data("<html".utf8).dropFirst()) == .unknown)

        // The same at the edges of what `examine` reads from a file.
        let sandbox = try Sandbox("evidence-lengths")
        func file(_ data: Data, _ name: String) throws -> URL {
            let url = sandbox.url.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        var koly = Data(count: 512)
        koly.replaceSubrange(0..<4, with: Array("koly".utf8))
        #expect(FileFormatEvidence.examine(try file(koly, "only-directory.dmg")) == .udif(hasChecksum: false), "a 512-byte file is all directory")
        var iso = Data(count: 32_774)
        iso.replaceSubrange(32_769..<32_774, with: Array("CD001".utf8))
        #expect(FileFormatEvidence.examine(try file(iso, "iso-minimum.dmg")) == .rawImage, "exactly long enough for the ISO 9660 mark")
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        #expect(ZipEvidence.hasCentralDirectory(try file(emptyZip, "empty.zip")) == true, "an empty zip is just its 22-byte end record")
        #expect(ZipEvidence.hasCentralDirectory(try file(emptyZip.dropLast(), "short.zip")) == false)
    }

    @Test func aSignedInstallerWithUnknownContentsIsStillVerified() {
        let app = AppRecord(name: "Tool", bundleIdentifier: "com.example.tool", path: "/Applications/Tool.app")
        var archive = InstallerArchive(id: "a", fileName: "Tool.pkg", kind: .pkg, size: 1, sha256: "a", teamIdentifier: "TEAMID1234",
                                       trustedSignature: true, originalPath: "/x", contentsLimit: .timedOut)
        #expect(archive.contentsUnknown && archive.usability(for: app) == .verified, "the package's own Developer ID signature was checked")
        archive.trustedSignature = false
        #expect(archive.usability(for: app) == .unverified(.contentsNotInspected))
        archive.contentsLimit = nil
        #expect(!archive.contentsUnknown && archive.usability(for: app) == .unverified(.notSigned))
        let l = TestEnvironment.english
        let package = InstallerArchive(id: "b", fileName: "Tool.pkg", kind: .pkg, size: 1, sha256: "b", originalPath: "/x", containsPackage: true,
                                       contentsLimit: .notReadable, inspectionNote: "pkgutil --check-signature: exit 1")
        var approved = package
        approved.userApprovedUnverified = true
        #expect(l.installerDescription(approved, for: app).nextAction?.contains("shows it in Finder") == true, "a package is shown in Finder, not opened")
        // A package keeps the package texts; a licence agreement keeps its own text even with a reason recorded.
        let unapprovedPackage = l.installerDescription(package, for: app)
        #expect(unapprovedPackage.status.contains("could not read the installer's description") && unapprovedPackage.nextAction == nil)
        var licence = InstallerArchive(id: "d", fileName: "Tool.dmg", kind: .dmg, size: 1, sha256: "d", originalPath: "/x", hasLicenseAgreement: true,
                                       contentsLimit: .notMountable)
        #expect(l.installerDescription(licence, for: app).status.contains("asks to accept a licence agreement"))
        licence.userApprovedUnverified = true
        #expect(l.installerDescription(licence, for: app).nextAction?.contains("accept the licence") == true)
        // Contents read although a later step was limited (e.g. read from an image already open): app texts, not Finder.
        var read = InstallerArchive(id: "e", fileName: "Tool.dmg", kind: .dmg, size: 1, sha256: "e", originalPath: "/x",
                                    containedApps: [.init(name: "Tool", bundleIdentifier: "com.example.tool", version: "1", path: "Tool.app")],
                                    userApprovedUnverified: true, contentsLimit: .timedOut)
        #expect(l.installerDescription(read, for: app).nextAction?.contains("copies the app into Applications") == true)
        read.contentsLimit = nil
        read.containedApps = []
        #expect(l.installerDescription(read, for: app).nextAction?.contains("opens it in Finder") == false)
        let image = InstallerArchive(id: "c", fileName: "Tool.dmg", kind: .dmg, size: 1, sha256: "c", originalPath: "/x", contentsLimit: .encrypted)
        #expect(l.installerDescription(image, for: app).summary == "Disk image · protected by a password, contents not checked · not signed with a Developer ID")
    }

    @Test func ownInstallersSayWhatTheyAreCheckedAgainst() {
        let l = TestEnvironment.english
        var offer = DownloadOffer(id: "own:a", itemID: "manual:x", kind: .ownInstaller, url: "file:///x.dmg", trust: .checksum)
        #expect(l.offerChecksText(offer).contains("recorded on the old Mac") && !l.offerChecksText(offer).contains("Homebrew"))
        #expect(l.offerChecksText(offer).contains("developer"))
        offer.developerUnverified = true
        #expect(l.offerChecksText(offer).contains("recorded on the old Mac") && l.offerChecksText(offer).contains("cannot be verified"))
        let cask = DownloadOffer(id: "cask:a", itemID: "manual:x", kind: .homebrewCask, url: "https://example.com/x.dmg", trust: .checksum)
        #expect(l.offerChecksText(cask) == l.trustText(.checksum))
        for language in AppLanguage.allCases {
            let localized = Localizer(language: language)
            for key in ["trust.ownInstaller", "trust.ownInstaller.unverified"] { #expect(localized.t(key) != key, "\(language) \(key)") }
        }
    }

    /// An image that attaches without a volume (no file system macOS mounts) is detached again by its whole-disk
    /// device – listed after its slice by `hdiutil` – and a confirmed own installer then goes to Finder.
    @Test func imageAttachedWithoutVolumeIsDetachedByItsWholeDisk() async throws {
        final class Scripted: CommandRunning, @unchecked Sendable {
            let lock = NSLock()
            var detached: [[String]] = []
            func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
                switch command.arguments.first {
                case "imageinfo":
                    return CommandResult(exitCode: 0, stdout: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Format</key><string>UDZO</string></dict></plist>", stderr: "")
                case "attach":
                    return CommandResult(exitCode: 0, stdout: """
                    <?xml version="1.0"?><plist version="1.0"><dict><key>system-entities</key><array>
                    <dict><key>dev-entry</key><string>/dev/disk9s1</string></dict><dict><key>dev-entry</key><string>/dev/disk9</string></dict>
                    </array></dict></plist>
                    """, stderr: "")
                case "detach":
                    lock.withLock { detached.append(command.arguments) }
                    return CommandResult(exitCode: 0, stdout: "", stderr: "")
                default:
                    return CommandResult(exitCode: 0, stdout: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>images</key><array/></dict></plist>", stderr: "")
                }
            }
        }
        let sandbox = try Sandbox("evidence-novolume")
        let image = try sandbox.write("raw image bytes", to: "Blank.dmg")
        let runner = Scripted()
        var installer = DownloadInstaller(layout: toolchainLayout(sandbox), runner: runner, macOSVersion: "14.8", architecture: .arm64)
        installer.retryPause = 1_000
        var offer = DownloadOffer(id: "own:x", itemID: "manual:x", kind: .ownInstaller, url: image.absoluteString, trust: .checksum)
        offer.developerUnverified = true
        let prepared = try await installer.prepare(image, offer: offer, staging: sandbox.url.appendingPathComponent("staging"))
        guard case .openInFinder(let shown, _) = prepared else { Issue.record("expected Finder, got \(prepared)"); return }
        #expect(shown == image)
        #expect(runner.lock.withLock { runner.detached } == [["detach", "/dev/disk9", "-force"]])
        #expect(DownloadInstaller.devices(fromAttachOutput: "hdiutil: WARNING\n<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk3s2</string></dict><dict><key>dev-entry</key><string>/dev/disk3</string></dict></array></dict></plist>") == ["/dev/disk3", "/dev/disk3s2"])
    }

    @Test func attachmentListIsReadForThisImageOnly() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array>
        <dict><key>image-path</key><string>/Volumes/Backup/A.dmg</string><key>system-entities</key><array>
          <dict><key>dev-entry</key><string>/dev/disk5</string></dict>
          <dict><key>dev-entry</key><string>/dev/disk5s1</string><key>mount-point</key><string>/Volumes/A</string></dict></array></dict>
        <dict><key>image-path</key><string>/Volumes/Backup/B.dmg</string><key>system-entities</key><array>
          <dict><key>dev-entry</key><string>/dev/disk6</string></dict></array></dict>
        </array></dict></plist>
        """
        let found = DownloadInstaller.attachments(of: "/Volumes/Backup/A.dmg", infoPlist: "hdiutil: WARNING: deprecated\n" + plist)
        #expect(found.count == 1 && found[0].device == "/dev/disk5" && found[0].mountPoint?.path == "/Volumes/A")
        #expect(DownloadInstaller.attachments(of: "/Volumes/Backup/B.dmg", infoPlist: plist).map(\.device) == ["/dev/disk6"])
        #expect(DownloadInstaller.attachments(of: "/Volumes/Backup/C.dmg", infoPlist: plist).isEmpty)
        #expect(InstallerArchiveInspector.packageIsInvalid("Package \"x.pkg\":\n   Status: package is invalid (checksum did not verify)"))
        #expect(!InstallerArchiveInspector.packageIsInvalid("Package \"x.pkg\":\n   Status: no signature"))
    }
}

extension FileFormatEvidence.OtherFormat {
    /// Every "something else" proves the file is no disk image (used by `evidenceComesFromTheFileItself`).
    static var allCasesProveNothingButOtherFormat: Bool {
        [FileFormatEvidence.OtherFormat.empty, .webPage, .zipArchive, .installerPackage, .pdf].allSatisfy { FileFormatEvidence.otherFormat($0).provesNotADiskImage }
    }
}
