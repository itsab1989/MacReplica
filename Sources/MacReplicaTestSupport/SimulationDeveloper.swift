import CryptoKit
import Foundation
import SQLite3

extension SimulationBuilder {
    /// The synthetic vendor's signing key for update feeds. It only exists in simulations and tests.
    public static let vendorSigningKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x5A, count: 32))
    public static var vendorPublicKey: String { vendorSigningKey.publicKey.rawRepresentation.base64EncodedString() }
    public static let nightlyFeed = "https://updates.example.com/orbit-nightly/appcast.xml"

    /// Version managers, runtimes, global tools and other package managers on the old Mac, all synthetic.
    static func populateDeveloperEnvironments(_ root: SimulationRoot) throws {
        let home = root.url.appendingPathComponent("home")
        func file(_ path: String, _ text: String = "", base: URL? = nil, executable: Bool = false) throws {
            try write(text, to: (base ?? home).appendingPathComponent(path), executable: executable)
        }
        // Node.js with nvm and global npm packages.
        try file(".nvm/nvm.sh", "# synthetic nvm")
        try file(".nvm/alias/default", "20\n")
        for version in ["v18.20.4", "v20.11.1"] { try file(".nvm/versions/node/\(version)/bin/node", "node", executable: true) }
        try file(".nvm/versions/node/v20.11.1/lib/node_modules/typescript/package.json", #"{"name":"typescript","version":"5.4.5"}"#)
        try file(".nvm/versions/node/v20.11.1/lib/node_modules/@angular/cli/package.json", #"{"name":"@angular/cli","version":"17.3.0"}"#)
        try file(".nvm/versions/node/v20.11.1/lib/node_modules/npm/package.json", #"{"name":"npm","version":"10.5.0"}"#)
        // Python: pyenv versions, uv-managed Python and tools, pipx, Conda.
        try file(".pyenv/version", "3.12.4\n")
        for version in ["3.11.9", "3.12.4"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".pyenv/versions/\(version)/bin"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.url.appendingPathComponent("tools/python"),
                                             to: home.appendingPathComponent(".pyenv/versions/\(version)/bin/python3"))
        }
        try file(".local/share/uv/python/cpython-3.13.1-macos-aarch64-none/bin/python3.13", "python")
        try file(".local/share/uv/tools/ruff/uv-receipt.toml", "[tool]\nrequirements = [{ name = \"ruff\" }]\n")
        try file(".local/share/uv/tools/ruff/lib/python3.13/site-packages/ruff-0.6.9.dist-info/METADATA", "Name: ruff\nVersion: 0.6.9\n")
        try file(".local/share/uv/credentials/credentials.toml", "# synthetic, never read by MacReplica\n")
        try file(".local/pipx/venvs/black/pipx_metadata.json",
                 #"{"main_package":{"package":"black","package_or_url":"black","package_version":"24.4.2"}}"#)
        try file("miniforge3/bin/conda", "conda", executable: true)
        try file("miniforge3/conda-meta/history", "==> 2026-01-01 00:00:00 <==\n# update specs: ['python=3.13', 'conda']\n")
        try file("miniforge3/envs/datasci/conda-meta/history",
                 "==> 2026-01-02 00:00:00 <==\n# update specs: ['python=3.11', 'numpy', 'pandas']\n")
        try file("miniforge3/envs/datasci/conda-meta/python-3.11.9-h0.json",
                 #"{"name":"python","version":"3.11.9","channel":"https://conda.anaconda.org/conda-forge/osx-arm64"}"#)
        // A uv project whose environment is rebuilt from its lock file.
        let project = home.appendingPathComponent("Projects/api-service")
        try file(".venv/pyvenv.cfg", "home = \(home.path)/.pyenv/versions/3.12.4/bin\nuv = 0.12.22\nversion_info = 3.12.4\n", base: project)
        try file(".venv/lib/python3.12/site-packages/fastapi-0.115.0.dist-info/METADATA", "Name: fastapi\nVersion: 0.115.0\n", base: project)
        try file("pyproject.toml", "[project]\nname = \"api-service\"\nversion = \"0.1.0\"\n", base: project)
        try file("uv.lock", "version = 1\n\n[[package]]\nname = \"fastapi\"\nversion = \"0.115.0\"\n", base: project)
        // Ruby with rbenv and gems.
        try file(".rbenv/version", "3.3.5\n")
        try file(".rbenv/versions/3.3.5/bin/ruby", "ruby", executable: true)
        for gem in ["rails-7.1.3", "nokogiri-1.16.7-arm64-darwin"] {
            try file(".rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/\(gem).gemspec")
        }
        // Rust with rustup and Cargo.
        try file(".rustup/settings.toml", "version = \"12\"\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n")
        try file(".rustup/toolchains/stable-aarch64-apple-darwin/lib/rustlib/components",
                 "cargo-aarch64-apple-darwin\nrust-src\nrust-std-aarch64-apple-darwin\nrust-std-wasm32-unknown-unknown\nrustc-aarch64-apple-darwin\n")
        try file(".cargo/.crates2.json", #"{"installs":{"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)":{}}}"#)
        // Go programs.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("go/bin"), withIntermediateDirectories: true)
        try SyntheticGoBinary.data(path: "golang.org/x/tools/gopls", module: "golang.org/x/tools/gopls", version: "v0.16.2")
            .write(to: home.appendingPathComponent("go/bin/gopls"))
        // Java and .NET.
        try file("Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/release",
                 "JAVA_VERSION=\"21.0.4\"\nIMPLEMENTOR=\"Eclipse Adoptium\"\n", base: root.url)
        try file("usr/local/share/dotnet/sdk/8.0.404/dotnet.dll", base: root.url)
        try file(".dotnet/tools/.store/dotnet-ef/8.0.8/dotnet-ef.nuspec")
        // Other package managers: MacPorts, Nix, Pixi, mise.
        try makeMacPortsRegistry(root.url.appendingPathComponent("opt/local/var/macports/registry/registry.db"),
                                 ports: [("ffmpeg", "7.1", 2, "+gpl2", true), ("zlib", "1.3.1", 0, "", false)])
        try file("opt/local/bin/port", "port", base: root.url, executable: true)
        try file(".local/state/nix/profiles/profile/manifest.json", """
            {"version":3,"elements":{"hello":{"active":true,"attrPath":"legacyPackages.aarch64-darwin.hello","originalUrl":"flake:nixpkgs"}}}
            """)
        try file(".pixi/manifests/pixi-global.toml", "version = 1\n\n[envs.search]\nchannels = [\"conda-forge\"]\ndependencies = { ripgrep = \"*\" }\n")
        try file(".config/mise/config.toml", "[tools]\nnode = \"22\"\n")

        // An app from a nightly channel, updated through a signed vendor feed and not available from Homebrew.
        try makeSyntheticApp(name: "Orbit Browser Nightly", bundleID: "org.example.orbit.nightly", version: "130.0a1",
                             extraInfo: ["SUFeedURL": nightlyFeed, "SUPublicEDKey": vendorPublicKey],
                             in: root.url.appendingPathComponent("Applications"))
    }

    /// A registry with the same `ports` table columns MacReplica reads from MacPorts' `registry.db`.
    static func makeMacPortsRegistry(_ database: URL, ports: [(String, String, Int, String, Bool)]) throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(handle) }
        var sql = "CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT, version TEXT, revision INTEGER, variants TEXT, requested INTEGER, state TEXT);"
        for port in ports {
            sql += "INSERT INTO ports (name, version, revision, variants, requested, state) VALUES ('\(port.0)', '\(port.1)', \(port.2), '\(port.3)', \(port.4 ? 1 : 0), 'installed');"
        }
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// What the synthetic vendor publishes: a signed nightly and a signed beta of Orbit Browser Nightly.
    static func populateVendorDownloads(_ root: SimulationRoot) throws {
        let downloads = root.url.appendingPathComponent("downloads/updates.example.com/orbit-nightly")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var items: [String] = []
        for (version, short, channel) in [("13002", "130.0a2", "nightly"), ("12903", "129.0b3", "beta")] {
            let build = root.url.appendingPathComponent("state/vendor-build/\(short)")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            let app = try makeSyntheticApp(name: "Orbit Browser Nightly", bundleID: "org.example.orbit.nightly", version: short,
                                           extraInfo: ["SUFeedURL": nightlyFeed, "SUPublicEDKey": vendorPublicKey], in: build)
            let zip = downloads.appendingPathComponent("Orbit-\(short).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
            try process.run()
            process.waitUntilExit()
            let data = try Data(contentsOf: zip)
            let signature = try vendorSigningKey.signature(for: data).base64EncodedString()
            items.append("""
                <item><title>\(short)</title><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>\(short)</sparkle:shortVersionString>
                <sparkle:channel>\(channel)</sparkle:channel><sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
                <enclosure url="https://updates.example.com/orbit-nightly/Orbit-\(short).zip" length="\(data.count)" type="application/octet-stream"
                 sparkle:edSignature="\(signature)"/></item>
                """)
        }
        let appcast = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Orbit Browser Nightly</title>
            \(items.joined(separator: "\n"))
            </channel></rss>
            """
        try write(appcast, to: downloads.appendingPathComponent("appcast.xml"), executable: false)
    }
}
