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
