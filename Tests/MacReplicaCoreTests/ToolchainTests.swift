import Foundation
import SQLite3
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// A layout rooted in a sandbox (home at `home/`, system paths below the sandbox).
func toolchainLayout(_ sandbox: Sandbox, architecture: CPUArchitecture = .arm64) -> SystemLayout {
    let root = sandbox.url
    let home = root.appendingPathComponent("home")
    var layout = SystemLayout(
        homeDirectory: home, applicationFolders: [root.appendingPathComponent("Applications")],
        userFonts: home.appendingPathComponent("Library/Fonts"), systemFonts: root.appendingPathComponent("Library/Fonts"),
        userColorProfiles: home.appendingPathComponent("Library/ColorSync/Profiles"),
        systemColorProfiles: root.appendingPathComponent("Library/ColorSync/Profiles"),
        homebrewPrefixes: [root.appendingPathComponent("opt/homebrew")], xcodeSelect: "/usr/bin/xcode-select", pkgutil: "/usr/sbin/pkgutil",
        mdls: "/usr/bin/mdls", osascript: "/usr/bin/osascript", installer: "/usr/sbin/installer", commandLineToolsMarkers: [],
        rosettaMarker: root.appendingPathComponent("rosetta").path, applicationSupport: home.appendingPathComponent("Library/Application Support/MacReplica"),
        caches: home.appendingPathComponent("Library/Caches/MacReplica"), logs: home.appendingPathComponent("Library/Logs/MacReplica"),
        isSimulation: true)
    layout.simulationRoot = root
    return layout
}

extension Sandbox {
    @discardableResult
    func file(_ path: String, _ text: String = "", executable: Bool = false) throws -> URL {
        let url = try write(text, to: path)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func symlink(_ path: String, to destination: String) throws {
        let url = self.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }
}

@Suite("Toolchain scanners")
struct ToolchainScannerTests {
    func context(_ sandbox: Sandbox) -> ToolchainContext {
        ToolchainContext(layout: toolchainLayout(sandbox), workFolder: sandbox.url.appendingPathComponent("home/Library/Caches/MacReplica/Work"),
                         architecture: .arm64)
    }

    @Test func nvmVersionsDefaultAndGlobalPackages() throws {
        let sandbox = try Sandbox("nvm")
        try sandbox.file("home/.nvm/nvm.sh", "# nvm")
        try sandbox.file("home/.nvm/alias/default", "20\n")
        for version in ["v18.20.4", "v20.11.1", "v20.9.0"] { try sandbox.file("home/.nvm/versions/node/\(version)/bin/node", executable: true) }
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/typescript/package.json", #"{"name":"typescript","version":"5.4.5"}"#)
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/@angular/cli/package.json", #"{"name":"@angular/cli","version":"17.3.0"}"#)
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/npm/package.json", #"{"name":"npm","version":"10.5.0"}"#)
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/corepack/package.json", #"{"name":"corepack","version":"0.25.0"}"#)
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/gitdep/package.json", #"{"name":"gitdep","version":"1.0.0"}"#)
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/.package-lock.json",
                         #"{"packages":{"node_modules/gitdep":{"resolved":"git+ssh://example.invalid/gitdep.git"}}}"#)
        let context = context(sandbox)

        let nvm = try #require(NVMProvider().scan(context))
        #expect(nvm.runtimes.map(\.version) == ["v18.20.4", "v20.9.0", "v20.11.1"])
        #expect(nvm.runtimes.filter(\.isDefault).map(\.version) == ["v20.11.1"], "alias 20 means the newest 20.x")
        #expect(NVMProvider().supportLevel(for: ToolchainAction(provider: .nvm, kind: .runtime, runtime: nvm.runtimes[2])) == .guided)
        #expect(NVMProvider().manualInstruction(for: ToolchainAction(provider: .nvm, kind: .runtime, runtime: nvm.runtimes[2]))
                == "nvm install v20.11.1\nnvm alias default v20.11.1")

        let npm = try #require(NPMProvider().scan(context))
        #expect(npm.packages.map(\.name) == ["@angular/cli", "gitdep", "typescript"], "npm and corepack come with Node.js")
        #expect(npm.packages.first { $0.name == "gitdep" }?.origin == .vcs)
        #expect(npm.packages.first { $0.name == "typescript" }?.runtime == RuntimeReference(source: .manager, provider: .nvm, version: "v20.11.1"))
        #expect(NPMProvider().restoreActions(for: npm).count == 2, "git packages are not reinstalled automatically")
    }

    @Test func npmCommandUsesTheRuntimesOwnNpmWithoutAShell() throws {
        let sandbox = try Sandbox("npm-command")
        let context = context(sandbox)
        let package = ToolchainPackage(name: "@angular/cli", version: "17.3.0", runtime: RuntimeReference(source: .manager, provider: .nvm, version: "v20.11.1"))
        let action = ToolchainAction(provider: .npm, kind: .package, package: package)
        #expect(NPMProvider().commands(for: action, context: context) == nil, "no npm yet")
        let npm = try sandbox.file("home/.nvm/versions/node/v20.11.1/bin/npm", "#!/bin/sh", executable: true)
        let command = try #require(NPMProvider().commands(for: action, context: context)?.first)
        #expect(command.executable == npm.path)
        #expect(command.arguments == ["install", "--global", "--no-fund", "--no-audit", "@angular/cli@17.3.0"])
        #expect(command.environment["PATH"]?.hasPrefix(npm.deletingLastPathComponent().path + ":") == true)
        #expect(!NPMProvider().isSatisfied(action, context: context))
        try sandbox.file("home/.nvm/versions/node/v20.11.1/lib/node_modules/@angular/cli/package.json", "{}")
        #expect(NPMProvider().isSatisfied(action, context: context))
    }

    @Test func fnmVoltaPnpmAndYarn() throws {
        let sandbox = try Sandbox("node-managers")
        try sandbox.file("home/.local/share/fnm/node-versions/v22.3.0/installation/bin/node", executable: true)
        try sandbox.file("home/.local/share/fnm/node-versions/v20.15.0/installation/bin/node", executable: true)
        try sandbox.symlink("home/.local/share/fnm/aliases/default", to: "../node-versions/v22.3.0/installation")
        try sandbox.file("home/.volta/tools/image/node/18.19.0/bin/node")
        try sandbox.file("home/.volta/tools/user/platform.json", #"{"node":{"runtime":"18.19.0","npm":null}}"#)
        try sandbox.file("home/.volta/tools/user/packages/typescript.json", #"{"name":"typescript","version":"5.3.3"}"#)
        try sandbox.file("home/Library/pnpm/global/5/package.json", #"{"dependencies":{"vercel":"^33.0.0"}}"#)
        try sandbox.file("home/Library/pnpm/global/5/node_modules/vercel/package.json", #"{"version":"33.5.1"}"#)
        try sandbox.file("home/.config/yarn/global/package.json", #"{"dependencies":{"serve":"^14.0.0"}}"#)
        try sandbox.file("home/.config/yarn/global/node_modules/serve/package.json", #"{"version":"14.2.1"}"#)
        let context = context(sandbox)

        let fnm = try #require(FNMProvider().scan(context))
        #expect(fnm.runtimes.map(\.version) == ["v20.15.0", "v22.3.0"])
        #expect(fnm.runtimes.first { $0.isDefault }?.version == "v22.3.0")
        let fnmBinary = try sandbox.file("opt/homebrew/bin/fnm", executable: true)
        let commands = try #require(FNMProvider().commands(for: ToolchainAction(provider: .fnm, kind: .runtime, runtime: fnm.runtimes[1]), context: context))
        #expect(commands.map(\.arguments) == [["install", "v22.3.0"], ["default", "v22.3.0"]])
        #expect(commands.allSatisfy { $0.executable == fnmBinary.path })
        #expect(commands[0].environment["FNM_DIR"]?.hasSuffix("home/.local/share/fnm") == true)

        let volta = try #require(VoltaProvider().scan(context))
        #expect(volta.runtimes == [ToolchainRuntime(version: "18.19.0", isDefault: true)])
        #expect(volta.packages.map(\.name) == ["typescript"])
        #expect(try #require(PNPMProvider().scan(context)).packages == [ToolchainPackage(name: "vercel", version: "33.5.1")])
        #expect(try #require(YarnProvider().scan(context)).packages == [ToolchainPackage(name: "serve", version: "14.2.1")])
    }

    @Test func pyenvUvPipxAndConda() throws {
        let sandbox = try Sandbox("python-tools")
        try sandbox.file("home/.pyenv/version", "3.12.4\n3.11.9\n")
        try sandbox.file("home/.pyenv/versions/3.12.4/bin/python", executable: true)
        try sandbox.file("home/.pyenv/versions/3.11.9/bin/python", executable: true)
        try sandbox.file("home/.pyenv/versions/3.12.4/envs/web/pyvenv.cfg", "version = 3.12.4")
        try sandbox.symlink("home/.pyenv/versions/web", to: "3.12.4/envs/web")
        try sandbox.file("home/.local/share/uv/python/cpython-3.13.1-macos-aarch64-none/bin/python3.13")
        try sandbox.symlink("home/.local/share/uv/python/cpython-3.13-macos-aarch64-none", to: "cpython-3.13.1-macos-aarch64-none")
        try sandbox.file("home/.local/share/uv/tools/httpie/uv-receipt.toml", """
            [tool]
            requirements = [
                { name = "httpie", specifier = ">=3" },
                { name = "requests" },
            ]
            entrypoints = [ { name = "http", install-path = "/x/bin/http", from = "httpie" } ]
            """)
        try sandbox.file("home/.local/share/uv/tools/httpie/lib/python3.13/site-packages/httpie-3.2.4.dist-info/METADATA", "Name: httpie\nVersion: 3.2.4\n")
        try sandbox.file("home/.local/share/uv/tools/black/uv-receipt.toml", "[tool]\nrequirements = [{ name = \"black\", extras = [\"d\"] }]\npython = \"3.13\"\n")
        try sandbox.file("home/.local/share/uv/credentials/credentials.toml", "token = \"synthetic-never-read\"")
        try sandbox.file("home/.local/pipx/venvs/black/pipx_metadata.json",
                         #"{"main_package":{"package":"black","package_or_url":"black","package_version":"24.4.2"},"injected_packages":{"black-plugin":{}}}"#)
        try sandbox.file("home/.local/pipx/venvs/mytool/pipx_metadata.json",
                         #"{"main_package":{"package":"mytool","package_or_url":"git+https://example.invalid/mytool.git","package_version":"0.1"}}"#)
        try sandbox.file("home/miniforge3/bin/conda", executable: true)
        try sandbox.file("home/miniforge3/conda-meta/history", "==> 2026-01-01 <==\n# update specs: ['python=3.12', 'conda']\n==> 2026-01-02 <==\n# update specs: ['jupyterlab']\n")
        try sandbox.file("home/miniforge3/envs/datasci/conda-meta/history", """
            ==> 2026-01-03 <==
            # cmd: conda create -n datasci python=3.11 numpy
            # update specs: ['python=3.11', 'numpy']
            ==> 2026-01-04 <==
            # update specs: ["pandas[version='<3']", 'scipy']
            ==> 2026-01-05 <==
            # remove specs: ['scipy']
            """)
        try sandbox.file("home/miniforge3/envs/datasci/conda-meta/python-3.11.9-h0.json",
                         #"{"name":"python","version":"3.11.9","channel":"https://conda.anaconda.org/conda-forge/osx-arm64"}"#)
        try sandbox.file("home/miniforge3/envs/datasci/conda-meta/numpy-1.26.4-h0.json",
                         #"{"name":"numpy","version":"1.26.4","channel":"https://user:secret@conda.anaconda.org/t/abc/private/osx-arm64"}"#)
        let context = context(sandbox)

        let pyenv = try #require(PyenvProvider().scan(context))
        #expect(pyenv.runtimes.map(\.version) == ["3.11.9", "3.12.4"], "the pyenv-virtualenv link is an environment")
        #expect(pyenv.runtimes.first { $0.isDefault }?.version == "3.12.4")

        let uv = try #require(UVProvider().scan(context))
        #expect(uv.runtimes.map(\.version) == ["3.13.1"])
        #expect(uv.packages.map(\.name) == ["black", "httpie"])
        #expect(uv.packages.first { $0.name == "httpie" } == ToolchainPackage(name: "httpie", version: "3.2.4", extras: ["with=requests"]))
        #expect(uv.packages.first { $0.name == "black" }?.extras == ["extra=d", "python=3.13"])
        let uvBinary = try sandbox.file("opt/homebrew/bin/uv", executable: true)
        let toolCommand = try #require(UVProvider().commands(for: ToolchainAction(provider: .uv, kind: .package, package: uv.packages[0]), context: context)?.first)
        #expect(toolCommand.executable == uvBinary.path)
        #expect(toolCommand.arguments == ["tool", "install", "black[d]", "--python", "3.13"])

        let pipx = try #require(PipxProvider().scan(context))
        #expect(pipx.packages.map(\.name) == ["black", "mytool"])
        #expect(pipx.packages[0].extras == ["inject=black-plugin"])
        #expect(pipx.packages[1].origin == .vcs)

        let conda = try #require(CondaProvider().scan(context))
        #expect(conda.environments.map(\.name) == ["base", "datasci"])
        #expect(conda.environments[0].requestedPackages == ["jupyterlab"], "installer specs of base are left out")
        let datasci = conda.environments[1]
        #expect(datasci.requestedPackages == ["python=3.11", "numpy", "pandas[version='<3']"])
        #expect(datasci.channels == ["conda-forge"], "token channel URLs are dropped")
        #expect(datasci.pythonVersion == "3.11.9")
        #expect(CondaProvider.environmentFile(datasci) == """
            name: datasci
            channels:
              - conda-forge
            dependencies:
              - "python=3.11"
              - "numpy"
              - "pandas[version='<3']"

            """)
        let create = try #require(CondaProvider().commands(for: ToolchainAction(provider: .conda, kind: .environment, environment: datasci), context: context)?.first)
        #expect(create.arguments.prefix(5) == ["env", "create", "--yes", "--name", "datasci"])
        #expect(create.environment["CI"] == nil, "Anaconda's terms are never accepted on the user's behalf")
        #expect(create.inputFiles.values.first == CondaProvider.environmentFile(datasci))
        #expect(CondaProvider().managerPackage(for: conda) == .cask("miniforge"))
    }

    @Test func rubyRustGoJavaDotnet() throws {
        let sandbox = try Sandbox("languages")
        try sandbox.file("home/.rbenv/version", "3.3.5\n")
        try sandbox.file("home/.rbenv/versions/3.3.5/bin/ruby", executable: true)
        try sandbox.file("home/.rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/rails-7.1.3.gemspec")
        try sandbox.file("home/.rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/nokogiri-1.16.7-arm64-darwin.gemspec")
        try sandbox.file("home/.rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/rake-13.1.0.gemspec")
        try sandbox.file("home/.rbenv/versions/3.3.5/lib/ruby/gems/3.3.0/specifications/default/json-2.7.1.gemspec")
        try sandbox.file("home/.rustup/settings.toml", "version = \"12\"\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\nprofile = \"default\"\n")
        try sandbox.file("home/.rustup/toolchains/stable-aarch64-apple-darwin/lib/rustlib/components",
                         "cargo-aarch64-apple-darwin\nclippy-preview-aarch64-apple-darwin\nrust-src\nrust-std-aarch64-apple-darwin\nrust-std-wasm32-unknown-unknown\nrustc-aarch64-apple-darwin\n")
        try sandbox.file("home/.rustup/toolchains/nightly-2024-05-01-aarch64-apple-darwin/lib/rustlib/components", "rustc-aarch64-apple-darwin\n")
        try sandbox.symlink("home/.rustup/toolchains/local", to: "/nonexistent/build")
        try sandbox.file("home/.cargo/.crates2.json", """
            {"installs":{"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)":{"features":["pcre2"],"all_features":false,"no_default_features":false},
            "mytool 0.1.0 (git+https://example.invalid/mytool?branch=main#abc)":{},
            "localtool 0.1.0 (path+file:///private/src/localtool)":{}}}
            """)
        let gopls = sandbox.url.appendingPathComponent("home/go/bin/gopls")
        try FileManager.default.createDirectory(at: gopls.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticGoBinary.data(path: "golang.org/x/tools/gopls", module: "golang.org/x/tools/gopls", version: "v0.16.2").write(to: gopls)
        try SyntheticGoBinary.data(path: "example.invalid/local", module: "example.invalid/local", version: "(devel)")
            .write(to: gopls.deletingLastPathComponent().appendingPathComponent("local"))
        try sandbox.file("home/go/bin/notes.txt", "not a program")
        try sandbox.file("Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/release", "JAVA_VERSION=\"21.0.4\"\nIMPLEMENTOR=\"Eclipse Adoptium\"\n")
        try sandbox.file("Library/Java/JavaVirtualMachines/custom-17.jdk/Contents/Home/release", "JAVA_VERSION=\"17.0.2\"\nIMPLEMENTOR=\"Example Vendor\"\n")
        try sandbox.file("usr/local/share/dotnet/sdk/8.0.404/dotnet.dll")
        try sandbox.file("home/.dotnet/tools/.store/dotnet-ef/8.0.8/dotnet-ef.nuspec")
        let context = context(sandbox)

        #expect(try #require(RbenvProvider().scan(context)).runtimes == [ToolchainRuntime(version: "3.3.5", isDefault: true, path: "~/.rbenv/versions/3.3.5")])
        let gems = try #require(GemProvider().scan(context)).packages
        #expect(gems.map(\.name) == ["nokogiri", "rails"], "bundled gems (rake) and default gems (json) are left out")
        #expect(gems.first?.version == "1.16.7")

        let rustup = try #require(RustupProvider().scan(context))
        #expect(rustup.runtimes.map(\.version) == ["nightly-2024-05-01", "stable"], "linked local toolchains are skipped")
        let stable = try #require(rustup.runtimes.first { $0.version == "stable" })
        #expect(stable.isDefault)
        #expect(stable.components == ["rust-src"])
        #expect(stable.targets == ["wasm32-unknown-unknown"])
        let rustupBinary = try sandbox.file("home/.cargo/bin/rustup", executable: true)
        let rustupCommands = try #require(RustupProvider().commands(for: ToolchainAction(provider: .rustup, kind: .runtime, runtime: stable), context: context))
        #expect(rustupCommands[0].executable == rustupBinary.path)
        #expect(rustupCommands.map(\.arguments) == [["toolchain", "install", "stable", "--profile", "default", "--no-self-update",
                                                     "--component", "rust-src", "--target", "wasm32-unknown-unknown"], ["default", "stable"]])

        let cargo = try #require(CargoProvider().scan(context))
        #expect(cargo.packages.map(\.origin) == [.local, .vcs, .index])
        #expect(cargo.packages.last == ToolchainPackage(name: "ripgrep", version: "14.1.0", extras: ["features=pcre2"]))

        let go = try #require(GoProvider().scan(context))
        #expect(go.packages == [ToolchainPackage(name: "golang.org/x/tools/gopls", version: "v0.16.2"),
                                ToolchainPackage(name: "example.invalid/local", version: nil, origin: .local)], "local builds are not reinstallable")
        #expect(GoProvider.binaryName("example.com/tool/v2") == "tool")

        let jdk = try #require(JDKProvider().scan(context))
        #expect(jdk.runtimes.map(\.version) == ["17.0.2", "21.0.4"])
        #expect(JDKProvider().homebrewPackage(for: jdk.runtimes[1]) == .cask("temurin@21"))
        #expect(JDKProvider().homebrewPackage(for: jdk.runtimes[0]) == nil)
        #expect(JDKProvider().restoreActions(for: jdk).map { $0.runtime?.version } == ["17.0.2"], "only JDKs without a cask are guided steps")
        #expect(JDKProvider.major("1.8.0_412") == "8")

        let dotnet = try #require(DotnetProvider().scan(context))
        #expect(dotnet.runtimes.map(\.version) == ["8.0.404"])
        #expect(dotnet.packages == [ToolchainPackage(name: "dotnet-ef", version: "8.0.8")])
        #expect(DotnetProvider().manualInstruction(for: ToolchainAction(provider: .dotnet, kind: .runtime, runtime: dotnet.runtimes[0]))
                == "https://dotnet.microsoft.com/download/dotnet/8.0")
    }

    @Test func packageManagers() throws {
        let sandbox = try Sandbox("package-managers")
        // MacPorts registry (synthetic, same table and columns as MacPorts' registry.db).
        let database = sandbox.url.appendingPathComponent("opt/local/var/macports/registry/registry.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, """
            CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT, version TEXT, revision INTEGER, variants TEXT, requested INTEGER, state TEXT);
            INSERT INTO ports (name, version, revision, variants, requested, state) VALUES
              ('ffmpeg', '7.1', 2, '+gpl2+nonfree', 1, 'installed'),
              ('zlib', '1.3.1', 0, '', 0, 'installed'),
              ('wget', '1.24.5', 0, '', 1, 'imaged');
            """, nil, nil, nil)
        sqlite3_close(handle)
        try sandbox.file("home/.nix-profile/manifest.json", """
            {"version":3,"elements":{"hello":{"active":true,"attrPath":"legacyPackages.aarch64-darwin.hello","originalUrl":"flake:nixpkgs","url":"github:NixOS/nixpkgs/abc"},
            "tool":{"active":true,"attrPath":"packages.aarch64-darwin.default","originalUrl":"github:example/tool"}}}
            """)
        try sandbox.file("home/.pixi/manifests/pixi-global.toml", """
            version = 1

            [envs.demo]
            channels = ["conda-forge"]
            dependencies = { ripgrep = "*", python = "3.12.*" }
            exposed = { rg = "rg", py = "python" }
            """)
        try sandbox.file("home/.config/mise/config.toml", "[tools]\nnode = \"22\"\npython = [\"3.12\", \"3.11\"]\n\"ubi:example/tool\" = \"1.0\"\n[env]\nSECRET = \"synthetic\"\n")
        try sandbox.file("home/.asdf/plugins/nodejs/README")
        try sandbox.file("home/.tool-versions", "nodejs 20.11.0 system\nruby 3.3.0 # comment\n")
        try sandbox.file("sw/bin/fink", executable: true)
        try sandbox.file("sw/var/lib/dpkg/status", "Package: wget\nStatus: install ok installed\nVersion: 1.21\n\nPackage: old\nStatus: deinstall ok config-files\nVersion: 1\n")
        let context = context(sandbox)

        let ports = try #require(MacPortsProvider().scan(context))
        #expect(ports.packages == [ToolchainPackage(name: "ffmpeg", version: "7.1_2", extras: ["+gpl2", "+nonfree"])])
        #expect(MacPortsProvider().manualInstruction(for: ToolchainAction(provider: .macports, kind: .package, package: ports.packages[0]))
                == "sudo port -N install ffmpeg +gpl2 +nonfree")
        #expect(MacPortsProvider().restoreActions(for: ports).first?.kind == .manager)

        let nix = try #require(NixProvider().scan(context))
        #expect(nix.packages == [ToolchainPackage(name: "hello"), ToolchainPackage(name: "default", origin: .vcs)])
        #expect(NixProvider().restoreActions(for: nix).map(\.kind) == [.manager, .package], "only Nixpkgs packages are reinstalled")

        let pixi = try #require(PixiProvider().scan(context))
        #expect(pixi.environments.first?.requestedPackages == ["python=3.12.*", "ripgrep", "expose=py=python"])
        try sandbox.file("opt/homebrew/bin/pixi", executable: true)
        let pixiCommand = try #require(PixiProvider().commands(for: ToolchainAction(provider: .pixi, kind: .environment, environment: pixi.environments[0]), context: context)?.first)
        #expect(pixiCommand.arguments == ["global", "install", "--environment", "demo", "--channel", "conda-forge", "--expose", "py=python",
                                          "python=3.12.*", "ripgrep"])

        let mise = try #require(MiseProvider().scan(context))
        #expect(mise.runtimes.map(\.version) == ["node@22", "python@3.12", "python@3.11", "ubi:example/tool@1.0"])
        #expect(MiseProvider().supportLevel(for: ToolchainAction(provider: .mise, kind: .runtime, runtime: mise.runtimes[0])) == .automatic)
        #expect(MiseProvider().supportLevel(for: ToolchainAction(provider: .mise, kind: .runtime, runtime: mise.runtimes[3])) == .guided,
                "tools from third-party backends are guided")

        let asdf = try #require(AsdfProvider().scan(context))
        #expect(asdf.runtimes.map(\.version) == ["nodejs/20.11.0", "ruby/3.3.0"])

        let fink = try #require(FinkProvider().scan(context))
        #expect(fink.packages == [ToolchainPackage(name: "wget", version: "1.21")])
        #expect(FinkProvider().restoreActions(for: fink).isEmpty)
    }

    @Test func catalogScanFindsEverythingAndNothingOnAnEmptyMac() throws {
        let sandbox = try Sandbox("catalog-empty")
        #expect(ToolchainCatalog.scan(context(sandbox)).isEmpty)
        #expect(Set(ToolchainCatalog.providers.map(\.id)) == Set(ToolchainProviderID.allCases), "every provider is registered exactly once")
        #expect(ToolchainCatalog.providers.count == ToolchainProviderID.allCases.count)
    }
}

@Suite("Toolchain validation and security")
struct ToolchainSecurityTests {
    @Test(arguments: ["--global", "-g", "a b", "x;rm", "$(id)", "`id`", "../x", "a\nb", ""])
    func unsafeNamesAreRefused(_ value: String) {
        #expect(!ToolchainValidation.isSafePackageName(value))
        #expect(!ToolchainValidation.isSafeVersion(value))
    }

    @Test func safeNamesAreAccepted() {
        for name in ["@angular/cli", "golang.org/x/tools/gopls", "ripgrep", "ruamel.yaml"] { #expect(ToolchainValidation.isSafePackageName(name)) }
        for version in ["v20.11.1", "3.12.4", "nightly-2024-05-01", "8.0.404", "1.0.0+build.1"] { #expect(ToolchainValidation.isSafeVersion(version)) }
        #expect(ToolchainValidation.isSafeCondaSpec("numpy[version='<3']"))
        #expect(!ToolchainValidation.isSafeCondaSpec("numpy\"; rm"))
        #expect(!ToolchainValidation.isSafeChannel("https://user:token@example.invalid/channel"))
    }

    @Test func policyExtensionNeverAddsShells() {
        let policy = CommandPolicy(allowedExecutables: []).adding(["/bin/zsh", "/opt/homebrew/bin/bash", "/usr/bin/env", "/usr/bin/sudo",
                                                                    "relative/uv", "/x/../bin/uv", "/opt/homebrew/bin/uv"])
        #expect(policy.allowedExecutables == ["/opt/homebrew/bin/uv"])
    }

    @Test func everyToolchainExecutableIsAnAllowedAbsolutePath() throws {
        let sandbox = try Sandbox("toolchain-executables")
        let context = ToolchainContext(layout: toolchainLayout(sandbox), architecture: .arm64)
        var actions: [ToolchainAction] = []
        for provider in ToolchainCatalog.providers {
            for kind in [ToolchainAction.Kind.manager, .runtime, .package, .environment] {
                actions.append(ToolchainAction(provider: provider.id, kind: kind, runtime: ToolchainRuntime(version: "1.0"),
                                               package: ToolchainPackage(name: "tool", version: "1.0",
                                                                         runtime: RuntimeReference(source: .manager, provider: .nvm, version: "v1")),
                                               environment: ToolchainEnvironment(name: "env", path: "~/env", requestedPackages: ["x"])))
            }
        }
        let executables = ToolchainCatalog.executables(for: actions, context: context)
        #expect(!executables.isEmpty)
        for path in executables {
            #expect(path.hasPrefix("/"))
            #expect(!CommandPolicy.forbiddenNames.contains((path as NSString).lastPathComponent))
        }
        #expect(CommandPolicy(allowedExecutables: []).adding(executables).allowedExecutables == executables)
    }
}

@Suite("Small parsers")
struct SmallParserTests {
    @Test func miniTOML() {
        let document = MiniTOML.parse("""
            # comment
            title = "x" # trailing
            count = 3
            flag = true
            list = ["a", 'b',
              "c", ]
            [envs.demo]
            dependencies = { ripgrep = "*", "python-dateutil" = ">=2" }
            [[array.table]]
            ignored = 1
            [tool]
            requirements = [
                { name = "httpie", specifier = ">=3" },
                { name = "requests" },
            ]
            escaped = "a\\"b"
            """)
        #expect(document["title"] as? String == "x")
        #expect(document["count"] as? Int == 3)
        #expect(document["flag"] as? Bool == true)
        #expect(document["list"] as? [String] == ["a", "b", "c"])
        #expect(MiniTOML.value(document, ["envs", "demo", "dependencies", "python-dateutil"]) as? String == ">=2")
        #expect((MiniTOML.value(document, ["tool", "requirements"]) as? [[String: Any]])?.count == 2)
        #expect(MiniTOML.value(document, ["tool", "escaped"]) as? String == "a\"b")
        #expect(MiniTOML.value(document, ["array"]) == nil)
    }

    @Test func goBuildInfo() throws {
        let info = try #require(GoBuildInfo.parse("path\tgolang.org/x/tools/gopls\nmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:x\ndep\tgolang.org/x/mod\tv0.20.0\n"))
        #expect(info == GoBuildInfo.Info(path: "golang.org/x/tools/gopls", module: "golang.org/x/tools/gopls", version: "v0.16.2", replaced: false))
        #expect(GoBuildInfo.parse("path\tx\nmod\tx\tv1\n=>\t../local\t\n")?.replaced == true)
        #expect(GoBuildInfo.parse("garbage") == nil)
    }

    @Test func condaHistoryAndSpecs() {
        #expect(CondaProvider.parsePythonList(#" ['a', "b[version='<3']", 'c=1']"#) == ["a", "b[version='<3']", "c=1"])
        #expect(CondaProvider.packageName(ofSpec: "conda-forge::xarray>=2024") == "xarray")
        #expect(CondaProvider.channels(["https://repo.anaconda.com/pkgs/main/osx-arm64", "pkgs/r", "bioconda"]) == ["defaults", "bioconda"])
    }

    @Test func gemspecNames() {
        #expect(GemProvider.parseGemspecName("aws-sdk-core-3.1.0.gemspec")! == ("aws-sdk-core", "3.1.0"))
        #expect(GemProvider.parseGemspecName("nokogiri-1.16.7-x86_64-darwin.gemspec")! == ("nokogiri", "1.16.7"))
        #expect(GemProvider.parseGemspecName("README") == nil)
    }
}
