import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Inventory, fonts and ICC profiles")
struct InventoryTests {
    @Test func machOThinFatAndGarbage() {
        #expect(MachO.architectures(fromHeader: SimulationBuilder.machOHeader([.arm64])) == [.arm64])
        #expect(MachO.architectures(fromHeader: SimulationBuilder.machOHeader([.x86_64])) == [.x86_64])
        #expect(MachO.architectures(fromHeader: SimulationBuilder.machOHeader([.x86_64, .arm64])) == [.x86_64, .arm64])
        #expect(MachO.architectures(fromHeader: Data("#!/bin/sh\necho hi\n".utf8)).isEmpty)
        #expect(MachO.architectures(fromHeader: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 200])).isEmpty, "absurd slice count is rejected")
        #expect(MachO.architectures(fromHeader: Data([1, 2])).isEmpty)
        #expect(MachO.architecture(forCPUType: 0x0100_000C) == .arm64)
        #expect(MachO.architecture(forCPUType: 7) == .unknown)
    }

    @Test func vendorFromSigningCertificate() {
        #expect(BundleInspection.vendor(fromCertificateSummary: "Developer ID Application: Example Software Ltd (ABCDE12345)") == "Example Software Ltd")
        #expect(BundleInspection.vendor(fromCertificateSummary: "Apple Mac OS Application Signing") == nil)
        #expect(BundleInspection.vendor(fromCertificateSummary: "Developer ID Application:  (ABCDE12345)") == nil)
    }

    @Test func vendorFromCopyright() {
        #expect(BundleInspection.vendor(fromCopyright: "Copyright © 2019–2024 Example Inc. All rights reserved.") == "Example Inc.")
        #expect(BundleInspection.vendor(fromCopyright: "© 2025 Nimbus Labs Ltd. All rights reserved.") == "Nimbus Labs Ltd.")
        #expect(BundleInspection.vendor(fromCopyright: "(c) 2020 Someone") == "Someone")
        #expect(BundleInspection.vendor(fromCopyright: "Copyright 2024") == nil)
        #expect(BundleInspection.vendor(fromCopyright: String(repeating: "x", count: 100)) == nil)
    }

    @Test func quarantineAttributeParsing() {
        #expect(BundleInspection.quarantineAgent(fromAttribute: "0083;65a1b2c3;Safari;0F2E") == "Safari")
        #expect(BundleInspection.quarantineAgent(fromAttribute: "0083;65a1b2c3;;0F2E") == nil)
        #expect(BundleInspection.quarantineAgent(fromAttribute: "garbage") == nil)
    }

    @Test func quarantineAttributeIsReadFromDisk() throws {
        let sandbox = try Sandbox("quarantine")
        let file = try sandbox.write("x", to: "Downloaded.app")
        let value = "0083;65a1b2c3;Firefox;ABC"
        _ = value.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        #expect(BundleInspection.quarantineAgent(of: file) == "Firefox")
        #expect(BundleInspection.quarantineAgent(of: try sandbox.write("y", to: "Other.app")) == nil)
    }

    @Test func pkgutilParsing() {
        #expect(InventoryService.parsePkgutilFileInfo("volume: /\npath: Applications/X.app\n\npkgid: com.example.x.pkg\npkg-version: 1.0") == "com.example.x.pkg")
        #expect(InventoryService.parsePkgutilFileInfo("volume: /\npath: Applications/X.app\n") == nil)
        #expect(InventoryService.parsePkgutilFileInfo("pkgid:   ") == nil)
    }

    @Test func appScannerReadsBundlesAndSkipsAppleApps() throws {
        let sandbox = try Sandbox("apps")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        let layout = try root.environment.layout
        let apps = layout.applicationFolders[0]
        // An Apple system app without receipt must be ignored; with receipt it counts.
        for (name, receipt) in [("Safari", false), ("Pages", true)] {
            let bundle = apps.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.apple.\(name.lowercased())", "CFBundleShortVersionString": "1.0"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
            if receipt {
                try FileManager.default.createDirectory(at: bundle.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
                try Data("r".utf8).write(to: bundle.appendingPathComponent("_MASReceipt/receipt"))
            }
        }
        // Broken bundle without Info.plist, a symlinked app and a nested app in a subfolder.
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Broken.app"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Link.app"), withDestinationURL: apps.appendingPathComponent("Pixel Forge.app"))
        let utilities = apps.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.appendingPathComponent("Pixel Forge.app"), to: utilities.appendingPathComponent("Nested Tool.app"))

        let scanner = AppScanner(layout: layout)
        let urls = scanner.bundleURLs()
        #expect(!urls.contains { $0.lastPathComponent == "Link.app" })
        #expect(urls.contains { $0.lastPathComponent == "Nested Tool.app" })
        let records = urls.compactMap(scanner.read)
        let names = records.map(\.name)
        #expect(!names.contains("Safari"))
        #expect(names.contains("Pages"))
        #expect(!names.contains("Broken"))
        let pages = try #require(records.first { $0.name == "Pages" })
        #expect(pages.source == .appStore)
        let ledger = try #require(records.first { $0.name == "Ledger Lite" })
        #expect(ledger.source == .appStore)
        #expect(ledger.minimumSystemVersion == "13.0")
        #expect(ledger.vendor == "Example Finance AB")
        #expect(AppScanner.isBuiltInAppleApp(bundleIdentifier: "com.apple.Safari", hasAppStoreReceipt: false))
        #expect(!AppScanner.isBuiltInAppleApp(bundleIdentifier: "com.apple.Pages", hasAppStoreReceipt: true))
        #expect(!AppScanner.isBuiltInAppleApp(bundleIdentifier: nil, hasAppStoreReceipt: false))
    }

    @Test func inventoryWarnsWithoutHomebrewAndCatalog() async throws {
        let sandbox = try Sandbox("inventory-warn")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("opt/homebrew/bin/brew"))
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("opt/homebrew/bin/mas"))
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("catalog/cask.json"))
        let simulation = try root.environment
        let result = try await TestEnvironment.inventory(simulation).run()
        #expect(result.warnings.contains(.homebrewNotInstalled))
        #expect(result.warnings.contains(.catalogUnavailable))
        #expect(result.manifest.homebrew == nil)
        // Without Homebrew data the App Store app is still identified through Spotlight, so mas is not needed.
        #expect(result.manifest.applications.first { $0.name == "Ledger Lite" }?.restoreMethod == .appStore(id: 1_234_567_890))
        #expect(!result.warnings.contains { if case .masNeeded = $0 { return true }; return false })
    }

    @Test func masIsOnlyAskedForWhenAnAppStoreAppCannotBeIdentified() async throws {
        let sandbox = try Sandbox("inventory-mas")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("opt/homebrew/bin/mas"))
        for name in try FileManager.default.contentsOfDirectory(atPath: root.state.appendingPathComponent("adam").path) {
            try FileManager.default.removeItem(at: root.state.appendingPathComponent("adam/\(name)"))
        }
        let result = try await TestEnvironment.inventory(try root.environment).run()
        #expect(result.warnings.contains(.masNeeded(unidentifiedApps: 1, homebrewAvailable: true)))
        #expect(TestEnvironment.english.inventoryWarningText(.masNeeded(unidentifiedApps: 1, homebrewAvailable: true)).contains("1 App Store app"))
    }

    @Test func inventoryReportsBrokenHomebrew() async throws {
        let sandbox = try Sandbox("inventory-broken")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        try root.setHomebrewBroken(true)
        let result = try await TestEnvironment.inventory(try root.environment).run()
        #expect(result.warnings.contains { if case .homebrewBroken = $0 { return true }; return false })
        #expect(result.manifest.brewFormulae.isEmpty)
    }

    @Test func inventoryDetectsInstallerPackages() async throws {
        let sandbox = try Sandbox("inventory-pkg")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        try root.setFlag("pkg/Studio Mixer.app", true, content: "com.example.studiomixer.pkg")
        let result = try await TestEnvironment.inventory(try root.environment).run()
        #expect(result.manifest.applications.first { $0.name == "Studio Mixer" }?.source == .package(identifier: "com.example.studiomixer.pkg"))
    }

    @Test func inventoryReportsProgressInOrder() async throws {
        let sandbox = try Sandbox("inventory-progress")
        let (_, simulation) = try TestEnvironment.sourceMac(sandbox)
        final class Box: @unchecked Sendable { var values: [InventoryProgress] = []; let lock = NSLock() }
        let box = Box()
        _ = try await TestEnvironment.inventory(simulation).run { progress in box.lock.withLock { box.values.append(progress) } }
        let fractions = box.values.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(Set(box.values.map(\.phase)) == Set(InventoryPhase.allCases))
    }

    @Test func fontScannerAcceptsFontsAndRecordsMetadata() throws {
        let sandbox = try Sandbox("fonts")
        let (_, simulation) = try TestEnvironment.sourceMac(sandbox)
        let fonts = FileScanner(layout: simulation.layout).scan(.font)
        #expect(fonts.map(\.record.relativePath).sorted() == ["Broken.otf", "Example Sans/ExampleSans-Bold.otf", "Example Sans/ExampleSans-Regular.otf",
                                                              "Example Script.otf", "ExampleMono.ttc", "ExampleSerif.ttf", "OldFace.pfb",
                                                              "Studio Grotesk.ttf", "System Demo.ttf"])
        let serif = try #require(fonts.first { $0.record.fileName == "ExampleSerif.ttf" }).record
        #expect(serif.domain == .user)
        #expect(serif.originalPath == "~/Library/Fonts/ExampleSerif.ttf")
        #expect(serif.backupPath == "fonts/user/ExampleSerif.ttf")
        let expected = SyntheticFont.make(family: "Example Serif", version: "2.000")
        #expect(serif.sha256 == Hashing.sha256Hex(of: expected))
        #expect(serif.size == Int64(expected.count))
        // Identity comes from the font itself, not from the file name.
        #expect(serif.font == FontIdentity(postScriptNames: ["ExampleSerif-Regular"], families: ["Example Serif"], styles: ["Regular"],
                                           version: "Version 2.000", format: "TrueType"))
        #expect(serif.origin == .userInstalled)
        #expect(fonts.first { $0.record.fileName == "ExampleMono.ttc" }?.record.origin == .sharedInstalled)
        // Legacy formats are recorded but never opened; unreadable files have no identity.
        #expect(fonts.first { $0.record.fileName == "OldFace.pfb" }?.record.font == nil)
        #expect(fonts.first { $0.record.fileName == "Broken.otf" }?.record.font == nil)
        #expect(fonts.first { $0.record.fileName == "ExampleMono.ttc" }?.record.backupPath == "fonts/system/ExampleMono.ttc")
    }

    @Test func realFontMetadataIsRead() throws {
        // Uses a font that ships with every macOS, read-only, only to check metadata extraction.
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let metadata = FileScanner.fontMetadata(url)
        #expect(metadata["family"] == "Arial")
        #expect(metadata["postscript_names"]?.contains("ArialMT") == true)
        #expect(FileScanner.fontMetadata(URL(fileURLWithPath: "/nonexistent.ttf")).isEmpty)
    }

    @Test func iccScannerAcceptsOnlyRealProfiles() throws {
        let sandbox = try Sandbox("icc")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        try Data("not a profile at all, but long enough to have forty bytes........".utf8)
            .write(to: root.url.appendingPathComponent("home/Library/ColorSync/Profiles/Fake.icc"))
        let profiles = FileScanner(layout: simulation.layout).scan(.colorProfile)
        #expect(profiles.map(\.record.fileName).sorted() == ["Example Display-00000000-0000-0000-0000-SYNTHETIC000.icc", "Example Fine Art Paper.icm",
                                                            "Example Legacy Filter.icc", "Example Press Proof.icc", "Example Proof Flags.icc",
                                                            "Example Studio Display.icc", "sRGB Copy.icc"])
        #expect(profiles.first { $0.record.fileName.hasPrefix("Example Display-") }?.record.origin == .displayGenerated)
        #expect(profiles.first { $0.record.fileName == "Example Legacy Filter.icc" }?.record.origin == .appleCreated)
        #expect(profiles.first { $0.record.fileName == "Example Studio Display.icc" }?.record.origin == .userInstalled)
        let display = try #require(profiles.first { $0.record.fileName == "Example Studio Display.icc" }).record
        #expect(display.metadata["description"] == "Example Studio Display D65")
        #expect(display.metadata["device_class"] == "mntr")
        #expect(display.metadata["color_space"] == "RGB")
        #expect(display.metadata["icc_version"] == "2.1.0")
    }

    @Test func iccHeaderParserHandlesEdgeCases() {
        let profile = SimulationBuilder.makeICCProfile(description: "Proof")
        let header = ICCProfileHeader.parse(profile)
        #expect(header?.description == "Proof")
        #expect(header?.connectionSpace == "XYZ")
        #expect(header?.size == UInt32(profile.count))
        #expect(ICCProfileHeader.parse(Data(count: 50)) == nil)
        var broken = profile
        broken[36] = 0x41
        #expect(!ICCProfileHeader.isProfile(broken))
        // Truncated tag table: the header is still valid, the description just missing.
        #expect(ICCProfileHeader.parse(profile.prefix(140))?.description == nil)
    }

    @Test func iccMlucDescription() {
        var data = SimulationBuilder.makeICCProfile(description: "x")
        // Replace the desc tag with an mluc tag holding UTF-16 text.
        let text = Array("Ünïcode".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let tag = bytes(Array("mluc".utf8), [0, 0, 0, 0], [0, 0, 0, 1], [0, 0, 0, 12], Array("enUS".utf8),
                        [0, 0, 0, UInt8(text.count)], [0, 0, 0, 28], text)
        data = data.prefix(144) + Data(tag)
        data.replaceSubrange(128..<132, with: [0, 0, 0, 1])
        data.replaceSubrange(136..<140, with: [0, 0, 0, 144])
        data.replaceSubrange(140..<144, with: [0, 0, 0, UInt8(tag.count)])
        #expect(ICCProfileHeader.parse(data)?.description == "Ünïcode")
    }

    @Test func relativePathStaysInsideBase() {
        let base = URL(fileURLWithPath: "/tmp/base")
        #expect(FileScanner.relativePath(of: URL(fileURLWithPath: "/tmp/base/a/b.otf"), below: base) == "a/b.otf")
        #expect(FileScanner.relativePath(of: URL(fileURLWithPath: "/tmp/basement/x.otf"), below: base) == nil)
        #expect(FileScanner.relativePath(of: base, below: base) == nil)
    }

    @Test func hashingFileMatchesData() throws {
        let sandbox = try Sandbox("hash")
        let big = Data(repeating: 7, count: 3 * 1024 * 1024 + 5)
        let file = sandbox.url.appendingPathComponent("big.bin")
        try big.write(to: file)
        #expect(try Hashing.sha256Hex(ofFile: file) == Hashing.sha256Hex(of: big))
        #expect(Hashing.sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

@Suite("Duplicate applications")
struct DuplicateAppTests {
    static func app(_ name: String, _ id: String?, _ path: String, _ version: String) -> AppRecord {
        AppRecord(name: name, version: version, bundleIdentifier: id, path: path, architectures: [.arm64], source: .unknown, restoreMethod: .manual)
    }

    @Test func copiesWithTheSameBundleIdentifierAreListedOnce() {
        let folders = ["/Applications", "~/Applications"]
        let apps = [Self.app("zoom.us", "us.zoom.xos", "~/Applications/zoom.us.app", "6.4.1"),
                    Self.app("zoom.us", "us.zoom.xos", "/Applications/zoom.us.app", "6.3.0"),
                    Self.app("Zoom", "US.ZOOM.XOS", "/Applications/Old/zoom.us.app", "5.0.0"),
                    Self.app("Tool", nil, "/Applications/Tool.app", "1"),
                    Self.app("Tool", nil, "~/Applications/Tool.app", "1"),
                    Self.app("Other", "com.example.other", "/Applications/Other.app", "2")]
        let merged = InventoryService.mergeCopies(apps, applicationFolders: folders)
        #expect(merged.map(\.path) == ["/Applications/zoom.us.app", "/Applications/Tool.app", "~/Applications/Tool.app", "/Applications/Other.app"])
        let zoom = merged[0]
        #expect(zoom.version == "6.3.0", "the copy in /Applications is kept, even if the one in ~/Applications is newer")
        #expect(Set(zoom.otherCopies ?? []) == [AppRecord.OtherCopy(path: "~/Applications/zoom.us.app", version: "6.4.1"),
                                                AppRecord.OtherCopy(path: "/Applications/Old/zoom.us.app", version: "5.0.0")])
        #expect(Set(merged.map(\.id)).count == merged.count, "every listed app has its own id")
    }

    @Test func theScanListsAnAppInstalledTwiceOnce() async throws {
        let sandbox = try Sandbox("duplicate-apps")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .sourceMac)
        try SimulationBuilder.makeSyntheticApp(name: "zoom.us", bundleID: "us.zoom.xos", version: "6.3.0", in: root.url.appendingPathComponent("Applications"))
        try SimulationBuilder.makeSyntheticApp(name: "zoom.us", bundleID: "us.zoom.xos", version: "6.4.1", in: root.url.appendingPathComponent("home/Applications"))
        let manifest = try await TestEnvironment.inventory(try root.environment).run().manifest
        let zoom = manifest.applications.filter { $0.bundleIdentifier == "us.zoom.xos" }
        #expect(zoom.count == 1)
        #expect(zoom.first?.path == "/Applications/zoom.us.app")
        #expect(zoom.first?.otherCopies == [AppRecord.OtherCopy(path: "~/Applications/zoom.us.app", version: "6.4.1")])
    }
}
