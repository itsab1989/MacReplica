import Foundation
import MacReplicaCore

/// Creates sandboxed simulation roots filled with synthetic data.
///
/// All names, vendors, identifiers and files are invented; nothing is copied from
/// the Mac the tests run on.
public struct SimulationRoot {
    public let url: URL

    public var state: URL { url.appendingPathComponent("state") }
    public var environment: SimulationEnvironment { get throws { try SimulationEnvironment(root: url) } }

    public init(url: URL) {
        self.url = url
    }

    // MARK: Failure switches

    public func setFlag(_ relativePath: String, _ on: Bool, content: String = "") throws {
        let file = state.appendingPathComponent(relativePath)
        if on {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func setOffline(_ on: Bool) throws { try setFlag("offline", on) }
    public func setAppStoreSignedOut(_ on: Bool) throws { try setFlag("mas/signed-out", on) }
    public func setHomebrewBroken(_ on: Bool) throws { try setFlag("brew-broken", on) }
    public func setDelay(_ seconds: Double) throws { try setFlag("delay", seconds > 0, content: String(seconds)) }
    public func failOnce(_ package: String, message: String) throws { try setFlag("fail-once/\(package)", true, content: message) }
    public func failAlways(_ package: String, message: String) throws { try setFlag("fail/\(package)", true, content: message) }
    public func setCommandLineToolsDelay(_ seconds: Double) throws { try setFlag("clt-delay", true, content: String(seconds)) }
    /// The simulated Mac's displays and ColorSync assignments (`state/colorsync.json`).
    /// `profile` paths are relative to the simulation root.
    public func configureDisplays(platform: String?, displays: [(uuid: String, name: String, builtIn: Bool, connected: Bool, profile: String?)],
                                  refuseAssignments: Bool = false) throws {
        let state = SimulatedDisplayColorManager.State(
            platform: platform,
            displays: displays.map { .init(uuid: $0.uuid, name: $0.name, builtIn: $0.builtIn, connected: $0.connected,
                                           profile: $0.profile.map { url.appendingPathComponent($0).path }) },
            refuseAssignments: refuseAssignments)
        try FileManager.default.createDirectory(at: self.state, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: self.state.appendingPathComponent("colorsync.json"))
    }

    /// The profile currently assigned to a simulated display (relative to the root), if any.
    public func assignedProfile(display uuid: String) -> String? {
        let manager = SimulatedDisplayColorManager(file: state.appendingPathComponent("colorsync.json"))
        guard let path = manager.load()?.displays.first(where: { $0.uuid == uuid })?.profile else { return nil }
        for root in [url.path, url.resolvingSymlinksInPath().path] where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = url.resolvingSymlinksInPath().path
        return resolved.hasPrefix(base + "/") ? String(resolved.dropFirst(base.count + 1)) : path
    }

    /// The version the simulated `brew --version` reports (default 4.4.0).
    public func setHomebrewVersion(_ version: String) throws { try setFlag("brew-version", true, content: version) }

    /// Simulates the user installing one of the sample apps by hand (from the App Store or a vendor download).
    public func simulateUserInstall(appNamed name: String) throws {
        guard let app = SimulationBuilder.sampleApps.first(where: { $0.name == name }) else { throw CocoaError(.fileNoSuchFile) }
        try SimulationBuilder.makeAppBundle(app, in: url.appendingPathComponent("Applications"))
        if let id = app.appStoreID {
            // What `mas list` reports for an app installed from the App Store.
            try FileManager.default.createDirectory(at: state.appendingPathComponent("mas/installed"), withIntermediateDirectories: true)
            try Data("\(app.name)  (\(app.version))".utf8).write(to: state.appendingPathComponent("mas/installed/\(id)"))
        }
    }

    /// Commands the simulated tools received, one per line.
    public func calls() -> [String] {
        let text = (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func clearCalls() {
        try? FileManager.default.removeItem(at: state.appendingPathComponent("calls.log"))
    }
}

public enum SimulationBuilder {
    public enum Scenario: String, CaseIterable {
        /// A Mac with apps, Homebrew, App Store apps, fonts and profiles: the source of a backup.
        case sourceMac
        /// A freshly installed Mac: no Homebrew, no Command Line Tools, nothing installed.
        case freshMac
        /// A source Mac that also has developer environments (version managers, runtimes, global tools,
        /// other package managers) and an app from a nightly channel with a signed vendor update feed.
        case developerMac
    }

    /// Synthetic apps used across scenarios.
    struct SampleApp {
        var name: String
        var bundleID: String
        var version: String
        var vendor: String
        var architectures: [CPUArchitecture]
        var appStoreID: Int? = nil
        var cask: String? = nil
        var installedViaCask = false
    }

    static let sampleApps: [SampleApp] = [
        SampleApp(name: "Nimbus Notes", bundleID: "com.example.nimbusnotes", version: "3.2.1", vendor: "Nimbus Labs Ltd.",
                  architectures: [.arm64, .x86_64], cask: "nimbus-notes", installedViaCask: true),
        SampleApp(name: "Pixel Forge", bundleID: "com.example.pixelforge", version: "2.4.0", vendor: "Forgeworks Inc.",
                  architectures: [.arm64, .x86_64], cask: "pixel-forge"),
        SampleApp(name: "Orbit Browser", bundleID: "org.example.orbit", version: "128.0", vendor: "Orbit Foundation",
                  architectures: [.arm64, .x86_64]),
        SampleApp(name: "Terminal Plus", bundleID: "com.example.terminalplus", version: "1.9.3", vendor: "Shellcraft Software",
                  architectures: [.arm64], cask: "terminal-plus"),
        SampleApp(name: "Ledger Lite", bundleID: "com.example.ledgerlite", version: "5.1", vendor: "Example Finance AB",
                  architectures: [.arm64, .x86_64], appStoreID: 1_234_567_890),
        SampleApp(name: "Quill Writer", bundleID: "com.example.quillwriter", version: "7.0.2", vendor: "Quill Software GmbH",
                  architectures: [.arm64, .x86_64]),
        SampleApp(name: "Studio Mixer", bundleID: "com.example.studiomixer", version: "11.4", vendor: "Example Audio Co.",
                  architectures: [.x86_64]),
    ]

    /// Creates a simulation root at `url` (which must not exist yet).
    @discardableResult
    public static func create(at url: URL, scenario: Scenario) throws -> SimulationRoot {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try OwnershipMarker(kind: .simulation).write(into: url)
        let root = SimulationRoot(url: url)

        let folders = ["home/Desktop", "home/Library/Fonts", "home/Library/ColorSync/Profiles", "home/Applications", "Applications",
                       "Library/Fonts", "Library/ColorSync/Profiles", "bin", "tools", "catalog", "packages", "opt/homebrew/bin",
                       "state/brew/formulae", "state/brew/casks", "state/brew/taps", "state/brew/available/casks",
                       "state/brew/available/formulae", "state/mas/installed", "state/mas/available", "state/adam"]
        for folder in folders {
            try fm.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(url.appendingPathComponent("Applications").path.utf8).write(to: root.state.appendingPathComponent("appdir"))

        // Tools
        try write(FakeTools.library, to: url.appendingPathComponent("tools/lib.sh"), executable: false)
        try write(FakeTools.brew, to: url.appendingPathComponent("tools/brew"), executable: true)
        try write(FakeTools.mas, to: url.appendingPathComponent("tools/mas"), executable: true)
        try write(FakeTools.python, to: url.appendingPathComponent("tools/python"), executable: true)
        try write(FakeTools.toolchain, to: url.appendingPathComponent("tools/toolchain"), executable: true)
        try write(FakeTools.xcodeSelect, to: url.appendingPathComponent("bin/xcode-select"), executable: true)
        try write(FakeTools.pkgutil, to: url.appendingPathComponent("bin/pkgutil"), executable: true)
        try write(FakeTools.mdls, to: url.appendingPathComponent("bin/mdls"), executable: true)

        // Configuration
        let config = SimulationEnvironment.Config(
            home: "home",
            applicationFolders: ["Applications", "home/Applications"],
            userFonts: "home/Library/Fonts",
            systemFonts: "Library/Fonts",
            userColorProfiles: "home/Library/ColorSync/Profiles",
            systemColorProfiles: "Library/ColorSync/Profiles",
            homebrewPrefixes: ["opt/homebrew"],
            xcodeSelect: "bin/xcode-select",
            pkgutil: "bin/pkgutil",
            mdls: "bin/mdls",
            commandLineToolsMarkers: ["CommandLineTools/usr/bin/git", "CommandLineTools/usr/bin/clang"],
            caskCatalog: "catalog/cask.json",
            formulaCatalog: "catalog/formula.json",
            homebrewPackage: "packages/Homebrew.json",
            architecture: .arm64,
            macosVersion: "15.1.0")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url.appendingPathComponent(SimulationEnvironment.configFileName))

        try writeCatalog(into: url)
        try write(#"{"files": [{"source": "tools/brew", "destination": "opt/homebrew/bin/brew"}]}"#,
                  to: url.appendingPathComponent("packages/Homebrew.json"), executable: false)

        // What Homebrew and the App Store can install (both scenarios).
        for app in sampleApps {
            if let cask = app.cask {
                try write(#"{"version": "\#(bumped(app.version))", "app": "\#(app.name).app", "bundle_id": "\#(app.bundleID)"}"#,
                          to: root.state.appendingPathComponent("brew/available/casks/\(cask).json"), executable: false)
            }
            if let id = app.appStoreID {
                try write(#"{"name": "\#(app.name)", "version": "\#(app.version)", "bundle_id": "\#(app.bundleID)", "app": "\#(app.name).app"}"#,
                          to: root.state.appendingPathComponent("mas/available/\(id).json"), executable: false)
            }
        }
        for cask in ["orbit-browser", "orbit-browser@esr"] {
            try write(#"{"version": "129.0", "app": "Orbit Browser.app", "bundle_id": "org.example.orbit"}"#,
                      to: root.state.appendingPathComponent("brew/available/casks/\(cask).json"), executable: false)
        }
        try write(#"{"version": "1.0.0", "app": "", "bundle_id": ""}"#,
                  to: root.state.appendingPathComponent("brew/available/casks/font-example-mono.json"), executable: false)
        for (name, version) in [("git", "2.47.0"), ("wget", "1.25.0"), ("jq", "1.7.1"), ("mas", "1.8.7"), ("openssl@3", "3.4.0"),
                                ("example-tool", "0.9.0"), ("python@3.12", "3.12.7")] {
            try write(version, to: root.state.appendingPathComponent("brew/available/formulae/\(name)"), executable: false)
        }
        // Version and package managers Homebrew can install (see FakeTools.toolchain).
        for (name, version) in [("uv", "0.12.22"), ("pyenv", "2.6.10"), ("pipx", "1.8.0"), ("fnm", "1.38.1"), ("volta", "2.0.2"),
                                ("pnpm", "10.18.0"), ("yarn", "1.22.22"), ("rbenv", "1.3.2"), ("rustup", "1.28.2"), ("go", "1.25.1"),
                                ("pixi", "0.81.0"), ("mise", "2026.10.0"), ("node", "26.10.0"), ("ruby", "4.0.7")] {
            try write(version, to: root.state.appendingPathComponent("brew/available/formulae/\(name)"), executable: false)
        }
        for (cask, version) in [("miniforge", "26.7.2-0"), ("temurin@21", "21.0.8"), ("dotnet-sdk", "10.0.401")] {
            try write(#"{"version": "\#(version)", "app": "", "bundle_id": ""}"#,
                      to: root.state.appendingPathComponent("brew/available/casks/\(cask).json"), executable: false)
        }

        try writeReleases(root)
        try populateMacOSFiles(root)
        switch scenario {
        case .sourceMac: try populateSourceMac(root)
        case .freshMac: try populateFreshMac(root)
        case .developerMac:
            try populateSourceMac(root)
            try populateDeveloperEnvironments(root)
        }
        try populateVendorDownloads(root)
        return root
    }

    private static func populateSourceMac(_ root: SimulationRoot) throws {
        let url = root.url
        // Homebrew and Command Line Tools are installed.
        try FileManager.default.copyItem(at: url.appendingPathComponent("tools/brew"), to: url.appendingPathComponent("opt/homebrew/bin/brew"))
        try FileManager.default.copyItem(at: url.appendingPathComponent("tools/mas"), to: url.appendingPathComponent("opt/homebrew/bin/mas"))
        try FileManager.default.createDirectory(at: url.appendingPathComponent("CommandLineTools/usr/bin"), withIntermediateDirectories: true)
        try write("git", to: url.appendingPathComponent("CommandLineTools/usr/bin/git"), executable: false)
        try write("clang", to: url.appendingPathComponent("CommandLineTools/usr/bin/clang"), executable: false)

        for app in sampleApps {
            try makeAppBundle(app, in: url.appendingPathComponent("Applications"))
            if app.installedViaCask, let cask = app.cask {
                try write(app.version, to: root.state.appendingPathComponent("brew/casks/\(cask)"), executable: false)
            }
            if let id = app.appStoreID {
                try write("\(app.name)  (\(app.version))", to: root.state.appendingPathComponent("mas/installed/\(id)"), executable: false)
                try write(String(id), to: root.state.appendingPathComponent("adam/\(app.name).app"), executable: false)
            }
        }
        try write("1.0.0", to: root.state.appendingPathComponent("brew/casks/font-example-mono"), executable: false)
        for (name, version) in [("git", "2.46.0"), ("wget", "1.24.5"), ("jq", "1.7.1"), ("mas", "1.8.7"), ("openssl@3", "3.3.2"),
                                ("example-tool", "0.9.0")] {
            try write(version, to: root.state.appendingPathComponent("brew/formulae/\(name)"), executable: false)
        }
        try root.setFlag("brew/dependency/openssl@3", true)
        try root.setFlag("brew/formula-tap/example-tool", true, content: "example/tools")
        try write("https://github.com/example/homebrew-tools", to: root.state.appendingPathComponent("brew/taps/example__tools"), executable: false)

        // Fonts: synthetic TrueType fonts that Core Text can read (see SyntheticFont), plus files that
        // exercise the conflict rules on the fresh Mac.
        let userFonts = url.appendingPathComponent("home/Library/Fonts")
        try FileManager.default.createDirectory(at: userFonts.appendingPathComponent("Example Sans"), withIntermediateDirectories: true)
        try SyntheticFont.make(family: "Example Sans").write(to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Regular.otf"))
        try SyntheticFont.make(family: "Example Sans", style: "Bold", weight: 700).write(to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Bold.otf"))
        try SyntheticFont.make(family: "Example Serif", version: "2.000").write(to: userFonts.appendingPathComponent("ExampleSerif.ttf"))
        try SyntheticFont.make(family: "Example Mono").write(to: url.appendingPathComponent("Library/Fonts/ExampleMono.ttc"))
        try SyntheticFont.make(family: "Studio Grotesk").write(to: userFonts.appendingPathComponent("Studio Grotesk.ttf"))
        try SyntheticFont.make(family: "Example Script").write(to: userFonts.appendingPathComponent("Example Script.otf"))
        // The same PostScript name as a font that macOS itself provides on the fresh Mac.
        try SyntheticFont.make(family: "System Demo", version: "1.500").write(to: userFonts.appendingPathComponent("System Demo.ttf"))
        try write("synthetic PostScript Type 1 placeholder", to: userFonts.appendingPathComponent("OldFace.pfb"), executable: false)
        try write("not really a font", to: userFonts.appendingPathComponent("Broken.otf"), executable: false)
        try write("not a font", to: userFonts.appendingPathComponent("readme.txt"), executable: false)

        try populatePython(root)
        try populateApplicationData(root)
        try populateDeveloperAndAppData(root)

        // ICC profiles: synthetic but structurally valid headers.
        let userProfiles = url.appendingPathComponent("home/Library/ColorSync/Profiles")
        let sharedProfiles = url.appendingPathComponent("Library/ColorSync/Profiles")
        try makeICCProfile(description: "Example Studio Display D65").write(to: userProfiles.appendingPathComponent("Example Studio Display.icc"))
        try makeICCProfile(description: "Example Fine Art Paper", deviceClass: "prtr").write(to: userProfiles.appendingPathComponent("Example Fine Art Paper.icm"))
        try makeICCProfile(description: "Example Press Proof", deviceClass: "prtr", colorSpace: "CMYK").write(to: sharedProfiles.appendingPathComponent("Example Press Proof.icc"))
        try makeICCProfile(description: "Example Proof Flags", deviceClass: "prtr").write(to: userProfiles.appendingPathComponent("Example Proof Flags.icc"))
        // An old copy of a profile macOS provides, an Apple profile this macOS no longer ships and a
        // profile macOS generated for a display of the old Mac.
        try makeICCProfile(description: "sRGB IEC61966-2.1", copyright: "Synthetic older copy").write(to: userProfiles.appendingPathComponent("sRGB Copy.icc"))
        try makeICCProfile(description: "Example Legacy Filter", deviceClass: "abst", colorSpace: "Lab ", creator: "appl")
            .write(to: sharedProfiles.appendingPathComponent("Example Legacy Filter.icc"))
        try FileManager.default.createDirectory(at: sharedProfiles.appendingPathComponent("Displays"), withIntermediateDirectories: true)
        try makeICCProfile(description: "Example Display", creator: "appl")
            .write(to: sharedProfiles.appendingPathComponent("Displays/Example Display-00000000-0000-0000-0000-SYNTHETIC000.icc"))
    }

    /// Fonts and profiles that macOS itself provides on a simulated Mac (normally read-only).
    static func populateMacOSFiles(_ root: SimulationRoot) throws {
        let fonts = root.url.appendingPathComponent("System/Library/Fonts")
        let profiles = root.url.appendingPathComponent("System/Library/ColorSync/Profiles")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try SyntheticFont.make(family: "System Demo", version: "3.000").write(to: fonts.appendingPathComponent("SystemDemo.ttf"))
        try makeICCProfile(description: "sRGB IEC61966-2.1", copyright: "Synthetic system copy").write(to: profiles.appendingPathComponent("sRGB Profile.icc"))
    }

    private static func populateFreshMac(_ root: SimulationRoot) throws {
        // The user already copied their project folders; their environments are missing.
        try write("print('hello')\n", to: root.url.appendingPathComponent("home/Projects/demo-app/main.py"), executable: false)
        try write("[project]\nname = \"api-service\"\nversion = \"0.1.0\"\n",
                  to: root.url.appendingPathComponent("home/Projects/api-service/pyproject.toml"), executable: false)
        try write("version = 1\n\n[[package]]\nname = \"fastapi\"\nversion = \"0.115.0\"\n", to: root.url.appendingPathComponent("home/Projects/api-service/uv.lock"), executable: false)
        // Fonts already on the new Mac: an older version, an identical copy, a different font under the
        // same file name and the same font under another file name.
        let userFonts = root.url.appendingPathComponent("home/Library/Fonts")
        try SyntheticFont.make(family: "Example Serif", version: "1.000").write(to: userFonts.appendingPathComponent("ExampleSerif.ttf"))
        try FileManager.default.createDirectory(at: userFonts.appendingPathComponent("Example Sans"), withIntermediateDirectories: true)
        try SyntheticFont.make(family: "Example Sans").write(to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Regular.otf"))
        try SyntheticFont.make(family: "Other Grotesk").write(to: userFonts.appendingPathComponent("Studio Grotesk.ttf"))
        try SyntheticFont.make(family: "Example Script", weight: 410).write(to: userFonts.appendingPathComponent("ExampleScript-Copy.otf"))
        // Profiles already on the new Mac: same name with other content, an identical copy in the other
        // library, and the same profile (only header flags differ) under another name.
        let userProfiles = root.url.appendingPathComponent("home/Library/ColorSync/Profiles")
        try FileManager.default.createDirectory(at: userProfiles, withIntermediateDirectories: true)
        try makeICCProfile(description: "Example Fine Art Paper", deviceClass: "prtr", copyright: "Synthetic newer measurement")
            .write(to: userProfiles.appendingPathComponent("Example Fine Art Paper.icm"))
        try makeICCProfile(description: "Example Press Proof", deviceClass: "prtr", colorSpace: "CMYK").write(to: userProfiles.appendingPathComponent("Example Press Proof.icc"))
        try makeICCProfile(description: "Example Proof Flags", deviceClass: "prtr", flags: 1).write(to: userProfiles.appendingPathComponent("Proof Flags (installed).icc"))
        try root.setCommandLineToolsDelay(1)
    }

    static func bumped(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        if let last = parts.last, let number = Int(last) { parts[parts.count - 1] = String(number + 1) }
        return parts.joined(separator: ".")
    }

    /// A synthetic, unsigned application bundle (Info.plist and a Mach-O header only).
    @discardableResult
    public static func makeSyntheticApp(name: String, bundleID: String, version: String, architectures: [CPUArchitecture] = [.arm64, .x86_64],
                                        minimumSystemVersion: String = "13.0", extraInfo: [String: Any] = [:], in folder: URL) throws -> URL {
        try makeAppBundle(SampleApp(name: name, bundleID: bundleID, version: version, vendor: "Example Vendor", architectures: architectures), in: folder)
        let bundle = folder.appendingPathComponent("\(name).app")
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        var info = (NSDictionary(contentsOf: infoURL) as? [String: Any]) ?? [:]
        info["LSMinimumSystemVersion"] = minimumSystemVersion
        info.merge(extraInfo) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        return bundle
    }

    static func makeAppBundle(_ app: SampleApp, in folder: URL) throws {
        let bundle = folder.appendingPathComponent("\(app.name).app")
        let executable = app.name.replacingOccurrences(of: " ", with: "")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": app.bundleID,
            "CFBundleShortVersionString": app.version,
            "CFBundleVersion": app.version,
            "CFBundleExecutable": executable,
            "CFBundleName": app.name,
            "LSMinimumSystemVersion": "13.0",
            "NSHumanReadableCopyright": "© 2025 \(app.vendor) All rights reserved.",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try machOHeader(app.architectures).write(to: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
        if app.appStoreID != nil {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
            try Data("synthetic receipt".utf8).write(to: bundle.appendingPathComponent("Contents/_MASReceipt/receipt"))
        }
    }

    /// A Mach-O header (thin or fat) for the given architectures. Only the header is written.
    public static func machOHeader(_ architectures: [CPUArchitecture]) -> Data {
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func le(_ value: UInt32) -> [UInt8] { be(value).reversed() }
        func cpu(_ arch: CPUArchitecture) -> UInt32 { arch == .arm64 ? 0x0100_000C : 0x0100_0007 }
        if architectures.count == 1, let arch = architectures.first {
            return Data(le(0xFEED_FACF) + le(cpu(arch)) + [UInt8](repeating: 0, count: 24))
        }
        var bytes = be(0xCAFE_BABE) + be(UInt32(architectures.count))
        for (index, arch) in architectures.enumerated() {
            bytes += be(cpu(arch)) + be(0) + be(UInt32(4096 * (index + 1))) + be(4096) + be(12)
        }
        return Data(bytes)
    }

    /// A minimal ICC v2 profile with a valid header and a `desc` tag.
    /// A small but valid ICC profile. `copyright` changes the content without changing the description;
    /// `flags` and `renderingIntent` change the bytes but not the computed Profile ID.
    public static func makeICCProfile(description: String, deviceClass: String = "mntr", colorSpace: String = "RGB ",
                                      creator: String? = nil, copyright: String = "No copyright, synthetic test data",
                                      flags: UInt32 = 0, renderingIntent: UInt32 = 0) -> Data {
        func be(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func textDescription(_ text: String) -> [UInt8] {
            let bytes = Array(text.utf8) + [0]
            return MacReplicaTestSupport.bytes(Array("desc".utf8), [0, 0, 0, 0], be(bytes.count), bytes, [UInt8](repeating: 0, count: 12 + 67))
        }
        func padded(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4) }
        func s15(_ value: Double) -> [UInt8] { be(Int(Int32(value * 65536)) & 0xFFFF_FFFF) }
        func xyz(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] { MacReplicaTestSupport.bytes(Array("XYZ ".utf8), [0, 0, 0, 0], s15(x), s15(y), s15(z)) }
        let gamma = MacReplicaTestSupport.bytes(Array("curv".utf8), [0, 0, 0, 0], be(1), [2, 0x33, 0, 0]) // gamma 2.2, u8Fixed8
        // lut8Type with identity tables and a 2-point grid: enough for ColorSync to accept device profiles.
        func lut8(inputs: Int, outputs: Int) -> [UInt8] {
            var t = MacReplicaTestSupport.bytes(Array("mft1".utf8), [0, 0, 0, 0], [UInt8(inputs), UInt8(outputs), 2, 0])
            for row in 0..<3 { for column in 0..<3 { t += s15(row == column ? 1 : 0) } }
            for _ in 0..<inputs { t += (0..<256).map { UInt8($0) } }
            let points = 1 << inputs
            for point in 0..<points { for output in 0..<outputs { t += [((point >> (inputs - 1 - min(output, inputs - 1))) & 1) == 1 ? 255 : 0] } }
            for _ in 0..<outputs { t += (0..<256).map { UInt8($0) } }
            return t
        }
        let channels = colorSpace == "CMYK" ? 4 : (colorSpace == "GRAY" ? 1 : 3)
        var tags: [(String, [UInt8])] = [
            ("desc", padded(textDescription(description))),
            ("cprt", padded(MacReplicaTestSupport.bytes(Array("text".utf8), [0, 0, 0, 0], Array(copyright.utf8), [0]))),
            ("wtpt", xyz(0.9642, 1.0, 0.8249)),
        ]
        switch deviceClass {
        case "mntr" where channels == 3:
            tags += [("rXYZ", xyz(0.4361, 0.2225, 0.0139)), ("gXYZ", xyz(0.3851, 0.7169, 0.0971)), ("bXYZ", xyz(0.1431, 0.0606, 0.7141)),
                     ("rTRC", padded(gamma)), ("gTRC", padded(gamma)), ("bTRC", padded(gamma))]
        case "abst":
            tags += [("A2B0", padded(lut8(inputs: 3, outputs: 3)))]
        default:
            tags += [("A2B0", padded(lut8(inputs: channels, outputs: 3))), ("B2A0", padded(lut8(inputs: 3, outputs: channels)))]
            if deviceClass == "prtr" { tags += [("gamt", padded(lut8(inputs: 3, outputs: 1)))] }
        }
        var offset = 128 + 4 + tags.count * 12
        var table = be(tags.count)
        var body: [UInt8] = []
        for (signature, data) in tags {
            table += Array(signature.utf8) + be(offset) + be(data.count)
            body += data
            offset += data.count
        }
        var header = [UInt8](repeating: 0, count: 128)
        header.replaceSubrange(0..<4, with: be(offset))
        header.replaceSubrange(4..<8, with: Array("appl".utf8))
        header.replaceSubrange(8..<12, with: [2, 0x10, 0, 0])
        header.replaceSubrange(12..<16, with: Array(deviceClass.utf8.prefix(4)))
        header.replaceSubrange(16..<20, with: Array(colorSpace.utf8.prefix(4)))
        header.replaceSubrange(20..<24, with: Array((deviceClass == "abst" ? "Lab " : "XYZ ").utf8))
        header.replaceSubrange(68..<80, with: s15(0.9642) + s15(1.0) + s15(0.8249)) // PCS illuminant D50
        header.replaceSubrange(36..<40, with: Array("acsp".utf8))
        header.replaceSubrange(44..<48, with: be(Int(flags)))
        header.replaceSubrange(64..<68, with: be(Int(renderingIntent)))
        if let creator { header.replaceSubrange(80..<84, with: Array(creator.utf8.prefix(4))) }
        return Data(header + table + body)
    }

    private static func writeCatalog(into url: URL) throws {
        func cask(_ token: String, _ names: [String], app: String?, bundleID: String?, homepage: String) -> [String: Any] {
            var artifacts: [[String: Any]] = []
            if let app { artifacts.append(["app": [app]]) }
            if let bundleID {
                artifacts.append(["uninstall": [["quit": bundleID]]])
                artifacts.append(["zap": [["trash": ["~/Library/Preferences/\(bundleID).plist", "~/Library/Caches/\(bundleID)"]]]])
            }
            return ["token": token, "name": names, "desc": "Synthetic test cask", "homepage": homepage, "version": "1.0",
                    "artifacts": artifacts, "deprecated": false, "disabled": false]
        }
        let casks: [[String: Any]] = [
            cask("nimbus-notes", ["Nimbus Notes"], app: "Nimbus Notes.app", bundleID: "com.example.nimbusnotes", homepage: "https://nimbus.example.com/"),
            cask("pixel-forge", ["Pixel Forge"], app: "Pixel Forge.app", bundleID: "com.example.pixelforge", homepage: "https://pixelforge.example.com/"),
            cask("orbit-browser", ["Orbit Browser"], app: "Orbit Browser.app", bundleID: "org.example.orbit", homepage: "https://orbit.example.org/"),
            cask("orbit-browser@esr", ["Orbit Browser ESR"], app: "Orbit Browser.app", bundleID: "org.example.orbit", homepage: "https://orbit.example.org/"),
            cask("terminal-plus", ["Terminal Plus"], app: "Terminal Plus.app", bundleID: nil, homepage: "https://terminalplus.example.com/"),
            cask("quill-writer", ["Quill Writer"], app: "Quill Writer Pro.app", bundleID: nil, homepage: "https://quill.example.com/"),
            cask("font-example-mono", ["Example Mono"], app: nil, bundleID: nil, homepage: "https://fonts.example.com/"),
        ]
        try JSONSerialization.data(withJSONObject: casks, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathComponent("catalog/cask.json"))
        let formulae: [[String: Any]] = [
            ["name": "git", "aliases": [], "homepage": "https://git-scm.com"],
            ["name": "wget", "aliases": [], "homepage": "https://www.gnu.org/software/wget/"],
            ["name": "jq", "aliases": [], "homepage": "https://jqlang.github.io/jq/"],
        ]
        try JSONSerialization.data(withJSONObject: formulae, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathComponent("catalog/formula.json"))
    }

    static func write(_ text: String, to url: URL, executable: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
