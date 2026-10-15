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
        return (sandbox, InstallerArchiveInspector(layout: layout, runner: runner), runner, layout, sandbox.url.appendingPathComponent("work"))
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

    // MARK: The file's own bytes

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

    // MARK: Intact images that cannot be inspected are kept

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

    @Test func changedImageIsDamagedByItsOwnChecksum() async throws {
        let (sandbox, inspector, _, _, work) = try Self.setup("validate-bitflip")
        let dmg = try await OwnInstallerTests.diskImage(app: "Pen Driver", bundleID: "com.example.pen", version: "4.0.14", in: sandbox, name: "PenFlip")
        let handle = try FileHandle(forUpdating: dmg)
        try handle.seek(toOffset: 600)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 16))
        try handle.close()
        let selection = await inspector.select(dmg, workFolder: work, bundleStore: sandbox.url.appendingPathComponent("b"))
        guard case .failure(let error) = selection.result else { Issue.record("a changed image was accepted"); return }
        #expect(error == .damaged(.checksumMismatch))
        #expect(selection.note?.contains("hdiutil verify: exit") == true)
        #expect(await !Self.isAttached(dmg))
        #expect(TestEnvironment.english.installerProblemText(error).contains("damaged"))
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

    // MARK: Record, texts, restore

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
