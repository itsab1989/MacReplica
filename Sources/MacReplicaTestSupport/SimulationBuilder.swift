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

        try writeReleases(root)
        switch scenario {
        case .sourceMac: try populateSourceMac(root)
        case .freshMac: try populateFreshMac(root)
        }
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

        // Fonts: synthetic files with font extensions.
        let userFonts = url.appendingPathComponent("home/Library/Fonts")
        try FileManager.default.createDirectory(at: userFonts.appendingPathComponent("Example Sans"), withIntermediateDirectories: true)
        try write("synthetic font: Example Sans Regular", to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Regular.otf"), executable: false)
        try write("synthetic font: Example Sans Bold", to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Bold.otf"), executable: false)
        try write("synthetic font: Example Serif", to: userFonts.appendingPathComponent("ExampleSerif.ttf"), executable: false)
        try write("synthetic font: Example Mono", to: url.appendingPathComponent("Library/Fonts/ExampleMono.ttc"), executable: false)
        try write("not a font", to: userFonts.appendingPathComponent("readme.txt"), executable: false)

        try populatePython(root)
        try populateApplicationData(root)
        try populateDeveloperAndAppData(root)

        // ICC profiles: synthetic but structurally valid headers.
        let userProfiles = url.appendingPathComponent("home/Library/ColorSync/Profiles")
        try makeICCProfile(description: "Example Studio Display D65").write(to: userProfiles.appendingPathComponent("Example Studio Display.icc"))
        try makeICCProfile(description: "Example Fine Art Paper").write(to: userProfiles.appendingPathComponent("Example Fine Art Paper.icm"))
        try makeICCProfile(description: "Example Press Proof").write(to: url.appendingPathComponent("Library/ColorSync/Profiles/Example Press Proof.icc"))
    }

    private static func populateFreshMac(_ root: SimulationRoot) throws {
        // The user already copied their project folder; its environment is missing.
        try write("print('hello')\n", to: root.url.appendingPathComponent("home/Projects/demo-app/main.py"), executable: false)
        // A font that conflicts with the backup (same name, different content) and one that is identical.
        let userFonts = root.url.appendingPathComponent("home/Library/Fonts")
        try write("an older Example Serif", to: userFonts.appendingPathComponent("ExampleSerif.ttf"), executable: false)
        try FileManager.default.createDirectory(at: userFonts.appendingPathComponent("Example Sans"), withIntermediateDirectories: true)
        try write("synthetic font: Example Sans Regular", to: userFonts.appendingPathComponent("Example Sans/ExampleSans-Regular.otf"), executable: false)
        try root.setCommandLineToolsDelay(1)
    }

    static func bumped(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        if let last = parts.last, let number = Int(last) { parts[parts.count - 1] = String(number + 1) }
        return parts.joined(separator: ".")
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
    public static func makeICCProfile(description: String) -> Data {
        let text = Array(description.utf8) + [0]
        var desc = Array("desc".utf8) + [0, 0, 0, 0]
        desc += [UInt8(text.count >> 24 & 0xFF), UInt8(text.count >> 16 & 0xFF), UInt8(text.count >> 8 & 0xFF), UInt8(text.count & 0xFF)]
        desc += text
        desc += [UInt8](repeating: 0, count: 12 + 67) // empty Unicode and ScriptCode parts
        let tagOffset = 128 + 4 + 12
        let size = tagOffset + desc.count
        func be(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        var header = be(size) + Array("appl".utf8) + [2, 0x10, 0, 0] + Array("mntr".utf8) + Array("RGB ".utf8) + Array("XYZ ".utf8)
        header += [UInt8](repeating: 0, count: 12) // date
        header += Array("acsp".utf8)
        header += [UInt8](repeating: 0, count: 128 - header.count)
        let table = be(1) + Array("desc".utf8) + be(tagOffset) + be(desc.count)
        return Data(header + table + desc)
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
