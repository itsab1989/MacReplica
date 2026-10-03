# Engineering research report

Date: 2026-10-02 · MacReplica 1.0.0

This report summarizes the research behind MacReplica's migration providers, credential handling and
font/profile handling, what was implemented, and what remains. Details and sources are in
[PROVIDERS.md](PROVIDERS.md), [FONTS_AND_PROFILES.md](FONTS_AND_PROFILES.md) and
[PROVIDER_AUDIT.md](PROVIDER_AUDIT.md) (the state before the provider expansion).

## Method

- Primary sources first: Apple Support and Developer documentation, SDK headers, ICC and OpenType
  specifications, vendors' own migration articles. Forums only as corroboration.
- Read-only local checks on a current Mac (no writes outside sandbox folders, no personal data
  recorded; only counts and file-name patterns).
- Every implemented behavior is covered by tests with synthetic data that mirrors the documented
  layout; the restore engine contains no application knowledge (providers are data).

## Findings

**Application data.** Most apps keep user-created configuration (settings, keymaps, snippets,
presets, styles, templates) in small, documented folders under `~/Library/Application Support` or
`~/Library/Preferences`, next to caches, databases and session state that must not be copied.
Classifying each location (safe, compatibility-sensitive, may contain secrets, cache, database,
temporary, log, credential) allows conservative defaults: safe configuration is pre-selected,
compatibility-sensitive data is offered but not pre-selected, everything else is never offered.
Several apps must be closed while their data is restored because they rewrite it on quit.

**Credentials.** Modern developer tools and cloud CLIs keep tokens in the Keychain or tie them to
the device (GitHub CLI, GitLab CLI, Docker credential helpers, gcloud, Azure CLI, AWS SSO). Copying
their configuration does not migrate the login and copying the Keychain is neither supported nor
safe. The secure and honest approach is: re-authentication guidance for those, and an explicit,
opt-in, encrypted path only for plain credential files the user owns (SSH keys, AWS static
credentials, Git credential store, npm, kubeconfig, Terraform). MacReplica never reports a login as
“restored” unless the credential file itself was migrated and verified.

**Fonts and ICC profiles.** macOS protects its own fonts and profiles (SIP, sealed system volume),
resolves duplicate fonts by domain order (user before local before system), does not de-duplicate
ICC profiles and substitutes its own profile for an identical copy. File names and profile
descriptions are not identity; the PostScript name plus version identifies a font face and the
computed ICC Profile ID identifies profile content. Display profiles in `Displays/` are generated per
display and Mac. This led to the destination-aware conflict policy and the two-stage selection.

**Python.** Virtual environments contain absolute paths and interpreter links and break when
copied; recreating them from package lists with the same Python minor version is the reliable path.

## Implemented

| Area | Result |
|---|---|
| Application data | 16 provider entries for 15 apps (VS Code, Cursor, Sublime Text, JetBrains IDEs, Xcode, BBEdit, iTerm2, Photoshop, Camera Raw/Lightroom, Capture One, DaVinci Resolve, Blender, After Effects, Keyboard Maestro, Alfred), plus user-chosen folders; data classification, version folders, running-app protection, version notes |
| Guidance | 16 re-authentication entries and 8 manual-migration entries, detected from installed apps and configuration folders |
| Credentials | SSH and file-based providers (AWS, Git credentials, npm, Kubernetes, Terraform); opt-in per provider, AES-256-GCM vault, passphrase never stored, excluded from logs, reports, manifest and fixtures |
| Fonts and profiles | identity in the manifest, backup-time selection, destination-aware restore selection, conflict policy, verification by Core Text and ColorSync, decision codes |
| Selection | two independent stages; restore selection stored in the session, reviewable before resuming |
| Verification status | every provider declares *researched*, *fixture-tested* or *verified* with evidence links; no provider claims *verified* without a real restore |

## Verification status

All application-data and credential providers are **fixture-tested**. Read-only detection was
confirmed for Capture One and Camera Raw on the development Mac. No provider is marked *verified*,
because no restore into real application folders was performed — by design, the development Mac's
real apps were never modified.

## Limitations

- App data formats can change between major app versions; MacReplica restores into the matching
  version folder and notes when that version is not installed, but cannot convert data.
- Accounts, licenses and cloud-synced settings require signing in again.
- Printer-driver profiles and app-installed profile aliases come back by reinstalling the driver or app.
- Downloadable macOS fonts are not copied; macOS downloads them on demand.

## Roadmap

1. *Verified* status for the most used providers through documented manual test runs on disposable
   Macs or virtual machines.
2. More application-data providers (candidates: Final Cut Pro libraries’ custom effects folder,
   Logic Pro patches, Figma local fonts helper, Raycast export file import, Sketch templates) — each
   only with vendor documentation.
3. Optional restore of display calibration profiles with an assignment step when the same display
   model is detected.
4. Homebrew bundle import/export for users who already maintain a `Brewfile`.
5. Signed and notarized releases via the release workflow once a Developer ID is configured.

## Package managers, developer environments and downloads (October 2026)

Research for the developer-tools and guided-installation work, from the projects' documentation and
source code; where possible, formats were checked against the real tools in an isolated folder
(uv 0.12.22, Pixi 0.81.0, Miniforge/conda 26.7.2, Homebrew 7.0.7, mas 7.0.0).

| Manager | Status (Oct 2026) | Machine-readable state | Decision |
|---|---|---|---|
| Homebrew | 7.0.7; Intel is Tier 3; tap trust since 6.0 | `brew info --json=v2 --installed`, `brew trust` | automatic; taps trusted after the user allows them |
| mas | 7.0.0; `install`/`get` require root | `mas list` | App Store page + verification instead of `mas install` |
| MacPorts | 2.12.6, active; reinstall per macOS major version; installs need root | registry database `registry.db` (`ports` table) | guided |
| Nix | 2.35; Determinate installer installs Determinate Nix only; no Homebrew package | profile `manifest.json` (version 3: elements keyed by name) | installing Nix guided, Nixpkgs packages automatic |
| Conda family | conda 26.9; Miniforge 26.7; Anaconda ToS plugin blocks non-interactive installs from `defaults` | `conda-meta/history` (`# update specs:`), `conda-meta/*.json` | automatic per environment; ToS never accepted for the user |
| Pixi | 0.81, very active, pre-1.0 | `~/.pixi/manifests/pixi-global.toml` | automatic |
| uv | 0.12.22, very active, pre-1.0; no JSON for `uv tool list` | `uv-receipt.toml`, managed-Python folders; plaintext credentials store (never read) | automatic |
| pkgx v2 / pkgm | runs tools on demand; pkgm cannot tell requested packages from dependencies | `~/.local/pkgs` | listed |
| Fink | last release 2022 | dpkg `status` | listed |
| mise / asdf | both active | `config.toml` `[tools]` / `.tool-versions` | mise automatic for registry tools; asdf guided (plugins are Git repositories with scripts) |
| nvm, RVM, SDKMAN | shell functions | version folders, alias files | guided (no shell is ever run) |
| fnm, Volta, rbenv, pyenv, rustup | real binaries; Volta unmaintained upstream | version folders and default markers | automatic |
| npm/pnpm/Yarn, gems, Cargo, Go, .NET tools | — | `package.json`, gemspecs, `.crates2.json`, Go build information, `.store` folders | automatic |

Downloads: Sparkle's EdDSA signature covers the raw bytes of the downloaded file and can be checked
with CryptoKit (`Curve25519.Signing`); feed URLs are often set at runtime, so only `Info.plist` values
are used. About a third of Homebrew casks publish no checksum (`no_check`); for those only the code
signature and Team ID can be compared. Files downloaded with `URLSession` are not quarantined
automatically, so MacReplica sets the quarantine attribute itself. `hdiutil attach` still works on
macOS 27 with a deprecation notice; disk images with a license agreement are handed to Finder.

Sources: brew.sh release notes and `brew help trust`; github.com/mas-cli/mas; guide.macports.org,
man.macports.org; nix.dev manual and NixOS/nix `profile.cc`; docs.conda.io, anaconda.com ToS plugin
documentation; pixi.prefix.dev; docs.astral.sh/uv; github.com/pkgxdev; finkproject.org;
mise.jdx.dev; asdf-vm.com; github.com/nvm-sh/nvm; github.com/Schniz/fnm (`directories.rs`);
github.com/volta-cli/volta; rust-lang.github.io/rustup; doc.rust-lang.org/cargo; pkg.go.dev/cmd/go and
golang/go `modload/build.go`; learn.microsoft.com (.NET); sparkle-project.org and the Sparkle source
(`SUConstants.m`, `SUSignatureVerifier.m`); formulae.brew.sh API; Apple documentation for code signing
services and `quarantineProperties`.
