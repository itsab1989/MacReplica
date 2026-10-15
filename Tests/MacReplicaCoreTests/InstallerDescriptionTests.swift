import Foundation
import Testing
@testable import MacReplicaCore

/// What the user reads for each installer they chose: what it is, whether it will be used and what happens next.
@Suite("Installer descriptions")
struct InstallerDescriptionTests {
    static let l = TestEnvironment.english
    static let app: AppRecord = {
        var app = AppRecord(name: "DisplayCAL", version: "3.9.19", bundleIdentifier: "net.displaycal.DisplayCAL", path: "/Applications/DisplayCAL/DisplayCAL.app")
        app.teamIdentifier = nil
        return app
    }()

    static func archive(kind: InstallerArchive.Kind = .dmg, trusted: Bool = false, team: String? = nil, apps: [String] = ["net.displaycal.DisplayCAL"],
                        licence: Bool = false, approved: Bool = false, package: Bool = false) -> InstallerArchive {
        InstallerArchive(id: "a", fileName: "DisplayCAL.dmg", kind: kind, size: 1, sha256: "a", teamIdentifier: team, signer: trusted ? "Developer ID Application: Example (TEAMID1234)" : nil,
                         trustedSignature: trusted, bundleIdentifier: apps.first, version: "3.9.19", architectures: [.x86_64],
                         originalPath: "/Volumes/USB/DisplayCAL.dmg",
                         containedApps: apps.enumerated().map { .init(name: $0.offset == 0 ? "DisplayCAL" : "Helper \($0.offset)", bundleIdentifier: $0.element, version: "3.9.19", path: "x") },
                         hasLicenseAgreement: licence, userApprovedUnverified: approved, containsPackage: package)
    }

    @Test func everyStateSaysWhatHappens() {
        let unverified = Self.l.installerDescription(Self.archive(), for: Self.app)
        #expect(unverified.style == .attention && unverified.canApproveUnverified && unverified.nextAction == nil)
        #expect(unverified.status.contains("cannot be verified") && unverified.status.contains("not used unless you confirm"))
        #expect(unverified.summary == "Disk image · contains DisplayCAL 3.9.19 · Intel · not signed with a Developer ID")

        let approved = Self.l.installerDescription(Self.archive(approved: true), for: Self.app)
        #expect(approved.status.contains("only its checksum is checked") && approved.nextAction?.contains("Open Anyway") == true)

        let verified = Self.l.installerDescription(Self.archive(trusted: true, team: "TEAMID1234"), for: Self.app)
        #expect(verified.style == .ok && !verified.canApproveUnverified && verified.nextAction == "MacReplica copies the app into Applications and checks that it is there.")
        #expect(verified.summary.hasSuffix("Developer ID Application: Example (TEAMID1234)"))

        var signedApp = Self.app
        signedApp.teamIdentifier = "OTHERTEAM1"
        let other = Self.l.installerDescription(Self.archive(trusted: true, team: "TEAMID1234"), for: signedApp)
        #expect(other.style == .blocked && other.status.contains("different developer") && other.nextAction == nil)

        let wrong = Self.l.installerDescription(Self.archive(apps: ["com.example.other"]), for: Self.app)
        #expect(wrong.style == .blocked && wrong.status.contains("com.example.other") && !wrong.canApproveUnverified)

        let suite = Self.l.installerDescription(Self.archive(trusted: true, apps: ["net.displaycal.DisplayCAL", "net.displaycal.DisplayCAL-3DLUT-maker", "net.displaycal.DisplayCAL-curve-viewer"]), for: Self.app)
        #expect(suite.summary.contains("contains DisplayCAL 3.9.19 and 2 more apps") && suite.nextAction?.contains("copies the folder with all its apps") == true)

        let licence = Self.l.installerDescription(Self.archive(apps: [], licence: true, approved: true), for: Self.app)
        #expect(licence.summary.contains("contents not checked (licence agreement)") && licence.nextAction?.contains("accept the licence") == true)

        let package = Self.l.installerDescription(Self.archive(kind: .pkg, trusted: true, apps: [], package: true), for: Self.app)
        #expect(package.summary.hasPrefix("Installer package · ") && package.nextAction?.contains("Apple's Installer") == true)
        let unsignedPackage = Self.l.installerDescription(Self.archive(kind: .pkg, apps: [], approved: true, package: true), for: Self.app)
        #expect(unsignedPackage.nextAction?.contains("shows it in Finder") == true)
        let packageInImage = Self.l.installerDescription(Self.archive(trusted: true, apps: [], package: true), for: Self.app)
        #expect(packageInImage.summary.contains("contains an installer package"))
        #expect(Self.l.installerKindText(.app) == "App (kept as a zip archive)")
        #expect(Self.l.architecturesText([.arm64, .x86_64]) == "Apple silicon and Intel" && Self.l.architecturesText([]) == nil)
    }

    @Test func problemsAreExplained() {
        for (error, text) in [(InstallerInspectionError.unsupportedType, "not an installer"), (.unreadable, "cannot be read"), (.damaged(.checksumMismatch), "damaged"),
                              (.nothingInside, "nothing MacReplica could install"), (.licenseAgreement, "licence agreement")] {
            #expect(Self.l.installerProblemText(error).contains(text), "\(error)")
        }
    }

    @Test func versionAndPrinterAndHomebrewTexts() {
        let printer = PrinterRecord(queue: "Office_Laser", deviceURI: "lpd://192.168.1.20/queue", manufacturer: "Brother", model: "HL-5250DN", driver: .vendor, vendorDriverFolders: ["Brother"])
        #expect(Self.l.printerSummary(printer) == "HL-5250DN · network (LPD) · driver from Brother – install it again on the new Mac")
        var item = RestoreItem(id: "scanner:x", kind: .printer, title: "EPSON Scanner", identifier: "x")
        item.scannerDriver = ScannerDriverRecord(name: "EPSON Scanner", bundleIdentifier: nil, version: "5.9")
        #expect(Self.l.printerInstruction(item)?.contains("EPSON Scanner") == true)
        #expect(Self.l.homebrewNoteText(HomebrewNote(token: "x", availability: CaskAvailability(state: .disabled, reason: "something_new", date: nil))).contains("(something_new)"),
                "an unknown reason is shown as Homebrew names it")
        #expect(Self.l.homebrewNoteText(HomebrewNote(token: "x", availability: CaskAvailability(state: .deprecated))).contains("deprecated"))
    }
}
