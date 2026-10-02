# Package managers, developer environments and guided recovery – report

Status of the enhancement "Package Managers, Developer Environments, Manual Installations and Guided
Recovery" (October 2026). Everything listed as supported is covered by automated tests; what was
validated on screen is stated separately. Details: [DEVELOPER_ENVIRONMENTS.md](DEVELOPER_ENVIRONMENTS.md),
[DOWNLOADS.md](DOWNLOADS.md), research in [RESEARCH_REPORT.md](RESEARCH_REPORT.md).

## 1. Audit of the state before this work (v1.0.0)

| Area | Before | Gap |
|---|---|---|
| Homebrew formulae, casks, taps | inventory and restore | `--HEAD` builds restored as stable; third-party taps fail on Homebrew 6+ (tap trust) |
| Mac App Store | `mas list` / `mas install` | **broken with mas 7.0**: `mas install` requires root |
| MacPorts, Nix, Conda, Pixi, uv, pkgx, Fink, mise, asdf | not supported | – |
| Python | Homebrew/pyenv/python.org interpreters detected; venvs rebuilt with Homebrew's Python of the same minor version and pip | no exact versions, no pyenv/uv/pipx/Conda restore, lock files not used |
| Node.js, Ruby, Rust, Go, Java, .NET | not supported | – |
| Distribution channel | not recorded | nightly/beta builds restored as stable or not at all |
| Installation source | App Store receipt, cask, pkg receipt, quarantine agent | not used for restore |
| Apps without automatic installation | static list with homepage link in the summary and report | no downloads, no tracking, not part of the restore session |
| Cancellation / postponing | not distinguished from technical failures | – |
| Resume | finished steps skipped | manual apps not part of the session |

## 2. Package managers

| Supported | Partially supported | Listed only / planned |
|---|---|---|
| Homebrew formulae, casks, taps (tap trust, `--HEAD`); Pixi global environments; Conda environments (Miniconda, Anaconda, Miniforge); uv; pipx | Mac App Store (guided: App Store page + verification); MacPorts (inventory automatic, restore guided); Nix (installing Nix guided, Nixpkgs packages automatic, other flakes listed); mise (registry tools automatic, other backends guided); asdf (guided) | pkgx/pkgm and Fink (listed); nix-darwin/home-manager and micromamba (planned) |

## 3. Developer environments

| Supported | Partially supported | Planned |
|---|---|---|
| Python: pyenv versions, uv Pythons and tools, pipx, Conda environments, virtual environments with exact interpreter, uv projects via `uv.lock`. Node.js: fnm, Volta, npm/pnpm/Yarn 1 global packages. Ruby: rbenv, gems. Rust: rustup toolchains with components and targets, Cargo programs. Go: Go via Homebrew, `go install` programs. Java: JDKs from Temurin, Zulu, Corretto, Oracle, Microsoft as casks. .NET: global tools | Node.js: nvm (guided). Ruby: RVM (guided). Java: SDKMAN and JDKs from other vendors (guided). .NET: SDK versions (guided: download page) | Poetry/Hatch environment recreation with their own tools; npm custom prefixes |

## 4. Download recovery

| Supported | Partially supported | Planned |
|---|---|---|
| Official sources: vendor update feed (Sparkle, per channel), vendor URL from Homebrew's cask, App Store page, vendor website. Verification: EdDSA signature, SHA-256, bundle identifier, Team ID, code signature, architecture, minimum macOS. Download queue with progress, pause, resume, retry, cancel. Quarantine kept | Casks without checksum: only offered when the original Team ID can be compared; casks needing browser-like requests: website only | Version-specific downloads of older releases; Sparkle 1 DSA-only feeds |

## 5. Installation assistance

| Supported | Partially supported | Planned |
|---|---|---|
| ZIP unpacking, read-only disk image mounting, copying apps into Applications (no administrator rights, never over existing apps), signed packages opened in Installer, sequential installation, Done/Skip/Later/Cancel, resume across launches | Disk images with license agreements are handed to Finder (the user accepts there); packages complete in Installer (MacReplica verifies afterwards) | – |

## 6. Validation

### Tests executed

`scripts/test.sh`: **343 tests in 54 suites, all passing** (Command Line Tools, Swift 6, macOS 27). New suites:
`ToolchainScannerTests`, `ToolchainDetailTests`, `ToolchainSecurityTests`, `SmallParserTests`,
`DeveloperEnvironmentTests`, `ChannelTests`, `DownloadSourceTests`, `DownloadQueueTests`,
`DownloadInstallerTests`, `GuidedInstallationTests`; updated: planner, executor, failure-mode and
end-to-end tests for guided App Store installs and manual apps.

### Mutation tests executed

See [MUTATION_TESTING.md](MUTATION_TESTING.md#developer-tools-downloads-and-guided-installation).

### Simulation results

End-to-end with realistic synthetic data (`developerMac` → `freshMac` simulations, simulated tools,
signed synthetic vendor feed):

- **Backup and manifest:** 17 providers recorded; no credentials (uv credential store not read, no
  secrets from shell profiles); no sandbox paths; the nightly app recorded with channel, evidence,
  update feed and vendor key; uv project with `uv.lock`.
- **Restore selection:** *Developer Tools* (27 steps) and *Other Package Managers* (8) as components;
  managers ordered before their steps.
- **Restore:** 61 steps succeeded, 0 failed, 14 waiting for the user (App Store app, 4 apps without
  automatic installation, nvm versions, npm packages waiting for nvm, MacPorts, Nix, .NET SDK).
  Commands ran without a shell through the simulated tools.
- **Download generation and installation:** the nightly app's feed offered *Nightly 130.0a2
  (recommended)* and *Beta 129.0b3*; installing downloaded, verified the vendor signature and
  installed 130.0a2 with MacReplica's quarantine flag.
- **Resume:** after relaunching, the start screen showed "13 steps … waiting"; after Node.js was
  installed with nvm and the App Store app was installed by the user, *Continue* verified both and
  installed the npm packages automatically (66 succeeded).
- **Cancellation and postponing:** *Skip*, *Later* and *Done* (only accepted once the app was really
  installed) were saved as `skipped_by_user`, `postponed_by_user` and `succeeded`; the session stayed
  open for the postponed app.
- **Reporting:** summary with *Waiting for you*, guided steps card; restore instructions list
  developer tools with the guided commands.
- The guided screen was also checked in German.

## 7. Limitations (verified)

- `mas install` needs root since mas 7, so App Store apps are installed by the user from the App Store
  page MacReplica opens.
- nvm, RVM and SDKMAN are shell functions and MacPorts installs need administrator rights; these are
  guided. MacReplica never runs a shell.
- Installing Nix, .NET SDK versions, asdf versions and mise tools from third-party backends are guided.
- pkgx and Fink are listed, not restored.
- Downloads without a vendor signature, a Homebrew checksum or the original Team ID are not offered;
  the vendor's website is opened instead.
- Disk images with a license agreement are opened in Finder, not mounted by MacReplica.
- npm packages under a custom `prefix` (from `~/.npmrc`) are not found, because `.npmrc` is never read.
- Real installations of MacPorts, Nix, rbenv, rustup, SDKMAN and .NET SDKs were not available for
  testing; their parsers follow the projects' documentation and are tested with synthetic files.
  Formats of uv, Pixi, Conda and Homebrew were checked against the real tools in an isolated folder.
