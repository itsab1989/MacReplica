import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Beta feedback 1.0.4: “will the drivers and setup of my older laser printer be restored?” Printers are recorded (name,
/// connection, model, driver, PPD for reference) and set up again by the user, guided and checked – never by copying
/// drivers or system files.
@Suite("Printers and scanners")
struct PrinterTests {
    @Test func lpstatAndPPDAreRead() {
        let devices = PrinterScanner.parseDevices("""
        device for Office_Laser: lpd://192.168.1.20/queue
        device for Canon_PRO_300_: dnssd://Canon%20PRO-300%20series._ipps._tcp.local./?uuid=00000000-0000-1000-8000-00189f100fb4
        no system default destination
        """)
        #expect(devices == ["Office_Laser": "lpd://192.168.1.20/queue",
                            "Canon_PRO_300_": "dnssd://Canon%20PRO-300%20series._ipps._tcp.local./?uuid=00000000-0000-1000-8000-00189f100fb4"])
        // From the real Canon PRO-300 PPD on the maintainer's Mac (the relevant lines).
        let canon = PrinterScanner.parsePPD("""
        *Manufacturer: "Canon"
        *NickName: "Canon PRO-300 series"
        *cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/Canon/BJPrinter/Filters/Raster2CanonIJ/Raster2CanonIJ2S.bundle/Contents/MacOS/Raster2CanonIJ2S"
        *APPrinterUtilityPath: "/Library/Printers/Canon/BJPrinter/Utilities/CanonIJPrinterUtility2.app"
        """)
        #expect(canon == PrinterScanner.PPDInfo(manufacturer: "Canon", nickName: "Canon PRO-300 series", driver: .vendor, vendorFolders: ["Canon"]))
        #expect(PrinterScanner.parsePPD("*NickName: \"HP LaserJet-AirPrint\"\n*APAirPrint: True").driver == .driverless)
        #expect(PrinterScanner.parsePPD("*NickName: \"Generic PostScript Printer\"").driver == .builtIn)
        #expect(PrinterScanner.withoutCredentials("smb://anna:secret@server/Printer") == "smb://server/Printer", "no passwords in the backup")
        #expect(!PrinterScanner.isSafeQueueName("../x") && PrinterScanner.isSafeQueueName("Office_Laser"))
    }

    @Test func printersAreBackedUpAndSetUpAgainWithTheUser() async throws {
        let sandbox = try Sandbox("printers")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addPrinters()
        let result = try await TestEnvironment.inventory(source).run()
        let laser = try #require(result.manifest.printers.first { $0.queue == "Office_Laser" })
        #expect(laser.driver == .vendor && laser.vendorDriverFolders == ["Brother"] && laser.manufacturer == "Brother" && laser.connection == "lpd")
        #expect(result.manifest.printers.first { $0.queue == "HP_Color_LaserJet_MFP" }?.driver == .driverless)
        #expect(result.manifest.scannerDrivers.map(\.name) == ["EPSON Scanner"])
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("backups"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory))
        let manifest = try ManifestIO.read(from: outcome.url)
        #expect(manifest.printers.first { $0.queue == "Office_Laser" }?.ppd?.backupPath == "printers/Office_Laser.ppd")
        #expect(manifest.printers == result.manifest.printers, "everything survives manifest.json, the device URI too")
        #expect(FileManager.default.fileExists(atPath: outcome.url.appendingPathComponent("printers/Office_Laser.ppd").path))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact, "the PPD files are checksummed")

        // The new Mac: guided steps, nothing set up by MacReplica; once the queue exists, the step is done.
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.printers])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(Set(plan.items.map(\.id)) == ["printer:Office_Laser", "printer:HP_Color_LaserJet_MFP", "scanner:com.epson.scanner.ICA"])
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: outcome.url, sessionStore: nil)
        var session = await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["printer:Office_Laser"]?.outcome == .skipped(.manualStepRequired))
        #expect(!FileManager.default.fileExists(atPath: target.layout.cupsPPDFolder.appendingPathComponent("Office_Laser.ppd").path), "never set up by MacReplica")
        let l = TestEnvironment.english
        let laserItem = try #require(plan.items.first { $0.id == "printer:Office_Laser" })
        let text = try #require(l.printerInstruction(laserItem))
        #expect(text.contains("First install the Brother driver") && text.contains("lpd://192.168.1.20/queue") && text.contains("whether it prints can only be tested"))
        // The user adds the printer (macOS writes its PPD); checking again finds it.
        try FileManager.default.createDirectory(at: target.layout.cupsPPDFolder, withIntermediateDirectories: true)
        try Data("*NickName: \"Brother HL-5250DN\"".utf8).write(to: target.layout.cupsPPDFolder.appendingPathComponent("Office_Laser.ppd"))
        session = await executor.run(plan: plan, session: session, onEvent: { _ in })
        #expect(session.results["printer:Office_Laser"]?.outcome == .alreadyPresent)
        #expect(session.results["printer:HP_Color_LaserJet_MFP"]?.outcome == .skipped(.manualStepRequired))
        _ = fresh
    }

    @Test func printersCanBeLeftOut() async throws {
        let sandbox = try Sandbox("printers-excluded")
        let (root, source) = try TestEnvironment.sourceMac(sandbox)
        try root.addPrinters()
        var result = try await TestEnvironment.inventory(source).run()
        result.excludePrinters()
        #expect(result.manifest.printers.isEmpty && result.manifest.scannerDrivers.isEmpty)
        #expect(!result.extraFiles.contains { $0.record.backupPath.hasPrefix("printers/") })
        var preset = BackupSelectionPreset()
        preset.includePrinters = false
        let read = try JSONDecoder().decode(BackupSelectionPreset.self, from: try JSONEncoder().encode(preset))
        #expect(read.includePrinters == false, "the choice is kept in the saved selection")
    }
}
