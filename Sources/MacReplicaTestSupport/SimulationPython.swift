import Foundation
import MacReplicaCore

extension SimulationBuilder {
    /// A Homebrew Python, a project with a virtual environment and a virtualenvwrapper environment.
    static func populatePython(_ root: SimulationRoot) throws {
        let url = root.url
        let prefix = url.appendingPathComponent("opt/homebrew")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("opt/python@3.12/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Cellar/python@3.12/3.12.7_1"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url.appendingPathComponent("tools/python"), to: prefix.appendingPathComponent("opt/python@3.12/bin/python3.12"))
        try write("3.12.7", to: root.state.appendingPathComponent("brew/formulae/python@3.12"), executable: false)
        try root.setFlag("brew/dependency/python@3.12", true)

        func environment(_ path: String, packages: [(String, String, String?)]) throws {
            let env = url.appendingPathComponent(path)
            let site = env.appendingPathComponent("lib/python3.12/site-packages")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try write("home = \(prefix.path)/opt/python@3.12/bin\ninclude-system-site-packages = false\nversion = 3.12.7\n",
                      to: env.appendingPathComponent("pyvenv.cfg"), executable: false)
            try FileManager.default.createDirectory(at: env.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try machOHeader([.arm64]).write(to: env.appendingPathComponent("bin/python"))
            for (name, version, directURL) in packages {
                let info = site.appendingPathComponent("\(name.replacingOccurrences(of: "-", with: "_"))-\(version).dist-info")
                try write("Metadata-Version: 2.1\nName: \(name)\nVersion: \(version)\nSummary: synthetic\n\nDescription body\nName: ignored\n",
                          to: info.appendingPathComponent("METADATA"), executable: false)
                if let directURL { try write(directURL, to: info.appendingPathComponent("direct_url.json"), executable: false) }
            }
        }

        let project = url.appendingPathComponent("home/Projects/demo-app")
        try environment("home/Projects/demo-app/.venv", packages: [
            ("requests", "2.32.3", nil), ("urllib3", "2.2.3", nil), ("rich", "13.9.2", nil), ("pip", "24.2", nil),
            ("demo-app", "0.1.0", #"{"url": "file:///synthetic/demo-app", "dir_info": {"editable": true}}"#),
            ("private-lib", "1.0", #"{"url": "https://git.example.internal/private-lib.git", "vcs_info": {"vcs": "git"}}"#),
        ])
        try write("requests==2.32.3\nrich>=13\n", to: project.appendingPathComponent("requirements.txt"), executable: false)
        try write("[project]\nname = \"demo-app\"\nversion = \"0.1.0\"\n", to: project.appendingPathComponent("pyproject.toml"), executable: false)
        try write("print('hello')\n", to: project.appendingPathComponent("main.py"), executable: false)
        try environment("home/.virtualenvs/tools", packages: [("black", "24.10.0", nil), ("httpie", "3.2.4", nil)])

        let profile = [
            "# synthetic shell profile",
            "export PIP_REQUIRE_VIRTUALENV=true",
            "export WORKON_HOME=\"$HOME/.virtualenvs\"",
            "export OPENAI_API_KEY=sk-synthetic-secret-value",
            "export PIP_INDEX_URL=https://user:pass@pypi.example.internal/simple",
            "export PATH=\"/opt/homebrew/bin:$PATH\"",
        ]
        try write(profile.joined(separator: "\n") + "\n", to: url.appendingPathComponent("home/.zshrc"), executable: false)
    }

    /// Application data with harmless files and files that look like secrets.
    static func populateApplicationData(_ root: SimulationRoot) throws {
        let folder = root.url.appendingPathComponent("home/Library/Application Support/Example Editor")
        try write("synthetic template", to: folder.appendingPathComponent("Templates/Letter.tmpl"), executable: false)
        try write(#"{"theme": "dark"}"#, to: folder.appendingPathComponent("settings.json"), executable: false)
        try write("synthetic-token", to: folder.appendingPathComponent("token.json"), executable: false)
        try write("synthetic-key", to: folder.appendingPathComponent("license.key"), executable: false)
    }
}

extension SimulationBuilder {
    /// Supported-app data, Git settings with things that must be removed, synthetic SSH keys.
    static func populateDeveloperAndAppData(_ root: SimulationRoot) throws {
        let home = root.url.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support")
        try write("synthetic action set", to: support.appendingPathComponent("Adobe/Adobe Photoshop 2025/Presets/Actions/My Actions.atn"), executable: false)
        try write("synthetic brush", to: support.appendingPathComponent("Adobe/Adobe Photoshop 2025/Presets/Brushes/Ink.abr"), executable: false)
        try write("synthetic prefs", to: support.appendingPathComponent("Adobe/Adobe Photoshop 2025/Adobe Photoshop 2025 Settings/prefs.psp"), executable: false)
        try write("TITLE \"Synthetic\"\nLUT_3D_SIZE 2\n", to: support.appendingPathComponent("Blackmagic Design/DaVinci Resolve/LUT/Synthetic Film.cube"), executable: false)
        let gitconfig = [
            "[user]", "\tname = Example Person", "\temail = person@example.com", "\tsigningkey = ABCDEF0123456789",
            "[alias]", "\tco = checkout", "\tst = status -sb",
            "[init]", "\tdefaultBranch = main",
            "[core]", "\texcludesfile = \(home.path)/.gitignore_global",
            "[credential]", "\thelper = osxkeychain",
            "[credential \"https://git.example.internal\"]", "\tusername = person",
            "[url \"https://x-token:ghp_syntheticTOKEN@github.com/\"]", "\tinsteadOf = https://github.com/",
            "[http]", "\tproxy = http://user:secret@proxy.example.internal:8080",
            "[github]", "\ttoken = ghp_syntheticTOKEN2",
        ]
        try write(gitconfig.joined(separator: "\n") + "\n", to: home.appendingPathComponent(".gitconfig"), executable: false)
        let ssh = home.appendingPathComponent(".ssh")
        // Synthetic content; the marker is assembled so secret scanners do not mistake it for a real key.
        let marker = "OPENSSH " + "PRIVATE KEY"
        try write("-----BEGIN \(marker)-----\nsynthetic-test-key-not-real\n-----END \(marker)-----\n",
                  to: ssh.appendingPathComponent("id_ed25519"), executable: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ssh.appendingPathComponent("id_ed25519").path)
        try write("ssh-ed25519 AAAAsynthetic example@example.com\n", to: ssh.appendingPathComponent("id_ed25519.pub"), executable: false)
        try write("Host example\n  HostName example.com\n", to: ssh.appendingPathComponent("config"), executable: false)
        try write("example.com ssh-ed25519 AAAAsynthetic\n", to: ssh.appendingPathComponent("known_hosts"), executable: false)
        try write("not a key", to: ssh.appendingPathComponent("authorized_keys"), executable: false)
    }

    /// Controlled release metadata for the update check (never fetched from GitHub in tests).
    static func writeReleases(_ root: SimulationRoot) throws {
        let releases: [[String: Any]] = [
            ["tag_name": "v1.2.0-beta.1", "prerelease": true, "draft": false,
             "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.2.0-beta.1"],
            ["tag_name": "v1.1.0", "prerelease": false, "draft": false,
             "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.1.0"],
            ["tag_name": "v9.0.0", "prerelease": false, "draft": true,
             "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v9.0.0"],
            ["tag_name": "v1.0.0", "prerelease": false, "draft": false,
             "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.0.0"],
        ]
        let url = root.url.appendingPathComponent("releases/releases.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: releases, options: [.prettyPrinted]).write(to: url)
    }
}
