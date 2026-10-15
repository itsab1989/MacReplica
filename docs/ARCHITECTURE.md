# Architecture

MacReplica is a Swift package (SwiftPM, Swift 6 language mode with strict concurrency) that builds
with the Xcode Command Line Tools alone.

```
Sources/
├── MacReplicaCore/        all logic, no UI — testable without the app
├── MacReplica/            SwiftUI app (AppModel + views)
├── MacReplicaAskpass/     tiny helper shown by sudo/Homebrew to ask for the administrator password
├── MacReplicaTestSupport/ simulated Macs, stand-in tools, synthetic fonts/profiles (tests and validation only)
└── MacReplicaSimulator/   command-line tool to create and control simulated Macs
Tests/MacReplicaCoreTests/ Swift Testing suites
tools/                     mutation testing, icon generator, UI validation helpers
scripts/                   test, app bundle, DMG, notarization
```

## Data flow

```
 old Mac                                                    new Mac
 ───────                                                    ───────
 InventoryService ──► InventoryResult ──► BackupWriter ──►  backup folder ──► BackupVerifier
   AppScanner            (manifest +       (copies files,        │                  │
   HomebrewClient         scanned files)    checksums,           ▼                  ▼
   MASClient                                reports,        ManifestIO.read     VerificationReport
   Matcher/CaskCatalog                      instructions)        │
   FileScanner (fonts, ICC)                                       ▼
   PythonScanner                                           RestorePlanner ──► RestorePlan (ordered items
   AppDataScanner + AppDataProviders                              │           with dependencies)
   DeveloperSettingsScanner                                       ▼
   ToolchainCatalog (providers)                                    │
   CredentialProviders (opt-in)                            RestoreExecutor
   GuidanceDetector                                          ├─ dryRun(plan)   — read-only predictions
   AccessProbe                                               └─ run(plan)      — installs, copies, verifies,
                                                                                 saves the session after each step
```

The app layer (`AppModel`) only orchestrates: it keeps the user's selections, starts the core
services on background tasks and turns their results into screens.

## Key modules

| Module | Responsibility |
|---|---|
| `System/SystemLayout` | Every path MacReplica reads or writes, and the allow-list of executables. The live layout points at the real Mac; a simulation layout points into a sandbox folder. Home paths are always displayed as `~`. |
| `System/CommandRunner` | Runs allow-listed executables by absolute path with an explicit environment — never a shell. Output is drained on dedicated reader threads. |
| `Restore/PrivilegedExecutor` | Runs a fixed set of operations (`mkdir`, `install`, `ditto`, `mv`, `installer`, and `rm` only for an allow-list of the corner plugin's and its loader's own files) with one administrator authentication through AppleScript `do shell script … with administrator privileges`; paths are validated and every argument is quoted by AppleScript (`quoted form of`). |
| `System/AdminPasswordBroker` + `MacReplicaAskpass` | The Homebrew `sudo` password for one restore: asked in MacReplica's window, checked with `sudo -S -k -v`, kept in memory and handed to the askpass helper over a socket only the user can open, with a one-time token. |
| `Inventory/*` | Read-only scanning. Fonts and profiles carry their identity (`FontIdentity`, `ProfileIdentity`) and origin. |
| `Matching/*` | Conservative app → Homebrew cask matching (bundle ID, app name, vendor evidence); ambiguous cases need a user decision. |
| `Providers/*` | Catalog of application-data providers (`AppDataCatalog`), re-authentication / manual-migration guidance (`GuidanceCatalog`), generic detection. Knowledge about apps is data, not code. |
| `Credentials/*` | `CredentialProvider` protocol, SSH and file-based providers, credential items and `CredentialStore` (per-item AES-256-GCM in 64 KiB records; data key wrapped by PBKDF2 passphrase and recovery key). `CredentialVault` is kept only to restore 1.0.0–1.0.6 backups. See [CREDENTIALS.md](CREDENTIALS.md). |
| `Backup/*` | Writing the self-contained backup folder and verifying it (SHA-256 per file plus `SHA256SUMS`), the encrypted credential store, the bootstrap copy of MacReplica and the reinstall guide. |
| `Downloads/InstallerArchive`, `FileFormatEvidence` | The user's own installers: inspection without running anything; damage only on proof from the file's bytes or its own checksum ([INSTALLER_VALIDATION.md](INSTALLER_VALIDATION.md)). |
| `Settings/*`, `Launchpad/*`, `ColorProfiles/*`, `Inventory/Printers` | macOS settings by category, the Launchpad layout (macOS 13–15), display profile assignments, printers and scanner drivers. |
| `Tools/*` | The three Tools on the start screen: Gatekeeper and app security, macOS updates (configuration profiles), window corners and the optional corner plugin ([TOOLS.md](TOOLS.md)). |
| `Restore/RestorePlanner` | Turns a manifest and a `RestoreSelection` into an ordered plan; `continuation(of:)` continues an interrupted session with a reviewed selection. |
| `Restore/RestoreExecutor` + `Inspector` | Shared read-only checks (`predict`) for the selection screen, dry run and restore; the executor performs and verifies each step and never stops on a single failure. |
| `Restore/FileConflictAnalyzer` | Destination-aware decisions for fonts and ICC profiles (see [FONTS_AND_PROFILES.md](FONTS_AND_PROFILES.md)). |
| `Restore/SessionStore` | Restore sessions (selection, results) for resume and retry. |
| `Reports/*` | Localized HTML reports and restore instructions. |
| `Support/*` | Logging with redaction, startup diagnostics and safe mode, safe clean-up of owned folders, update check. |
| `Localization/*` | Own `.strings` loader with plural rules and English fallback (7 languages); user-facing descriptions of every enum case. |

## Manifest

`manifest.json` is versioned (`manifest_version`, currently 4 for backups with encrypted credential items and 3
otherwise; backups of MacReplica 1.0.0 (version 1) and 1.0.1 (version 2) are migrated on reading, and any version
higher than the app knows is refused with a clear message instead of being restored wrongly), uses stable snake_case
keys and is decoded leniently (missing sections become empty, unknown keys are ignored). Fields added without a
version change are optional, for example `contents_limit` and `inspection_note` of an own installer (1.1.0): an older
MacReplica ignores them and treats such an installer as unverified (used only if the user confirmed it); if it cannot
open the installer, that step fails with the reason instead of opening it in Finder. It records the MacReplica version and build, macOS version and
architecture of the old Mac, and for each item what is needed to restore it — never secrets.
Fonts and profiles store original path, backup path, size, SHA-256, origin and identity; the
selection made on the old Mac is summarized in `backup_selection`. [examples/manifest.json](examples/manifest.json)
is an older example (MacReplica 1.0.0, format version 2) that shows the basic structure; current backups have more
sections (Launchpad, settings, printers, own installers, credential items).

## Restore selection

`RestoreSelection` holds everything the user decided on the new Mac: components, individually
excluded items, allowed taps, cask choices for ambiguous apps and per-item conflict decisions. It is
stored in the restore session, so it survives a restart. Only items in the backup can be planned.

## Extending MacReplica

- **New application-data provider:** add an `AppDataProvider` entry to `AppDataCatalog` with
  categories, data classification, `mustBeClosed`, verification status and evidence URLs; add a
  fixture in `MacReplicaTestSupport` and a test.
- **New credential provider:** implement `CredentialProvider` (explicit file list, destination
  mapping, risk text), register it in `CredentialProviders.all`. Never add a generic secret scanner.
- **New restore step kind:** extend `RestoreItemKind`, `RestorePlanner`, `Inspector.predict` and
  `RestoreExecutor.perform`, plus descriptions in all languages (tests enforce translations).
- **New language:** add a `.lproj` folder and an `AppLanguage` case; `LocalizationTests` check
  completeness and placeholders.

## Developer tools: provider architecture

`Sources/MacReplicaCore/Toolchains/` holds one `ToolchainProvider` per package or version manager
(pyenv, uv, Conda, nvm, rustup, MacPorts, …), registered in `ToolchainCatalog.providers`. Adding a
provider means adding one type and one catalog entry; scanning, backup and restore selection, the
plan, the dry run and the reports work from the catalog. A provider

- **scans** by reading files (`scan(_:) -> ToolchainRecord?`), never by starting a tool;
- describes its **restore steps** (`restoreActions(for:)`: manager, runtime, package, environment) and
  the **Homebrew package** that installs the manager or a runtime (`managerPackage`, `homebrewPackage`);
- builds **commands** from validated names and versions (`commands(for:context:)`), lists the exact
  executables it may start (`executableCandidates`) and **verifies** results through files
  (`isSatisfied`);
- states its **support level** per step (automatic, guided, listed) and the instruction for guided steps.

`RestorePlanner` turns records into `toolchainStep` items with dependencies (manager → runtime →
packages; Cargo programs → rustup's default toolchain; Python environments → the exact pyenv/uv
runtime). `RestoreExecutor` extends the command policy for one run by exactly the executables of the
plan's steps (`CommandPolicy.adding`, which always refuses shells and similar programs).

## Guided steps and resume

Steps that wait for the user end with an *open* outcome (`manualStepRequired`,
`waitingForManualStep`, `postponedByUser`, `cancelledByUser`). Open steps are not part of
`RestoreSession.finishedItemIDs`, so continuing a session checks them again; a session whose only
remaining steps are open is shown as "waiting for you".

## Downloads

`Sources/MacReplicaCore/Distribution/` derives release channels and reads update feeds;
`Sources/MacReplicaCore/Downloads/` contains `DownloadSourceFinder` (official sources only),
`DownloadQueue` (pause, resume, retry, cancel; `URLSessionDownloadTransport` in the app,
`LocalDownloadTransport` in tests and the simulation), `DownloadInstaller` (verification, unpacking,
installation without administrator rights) and `GuidedInstallation` (one-after-another installation
with user decisions). See [DOWNLOADS.md](DOWNLOADS.md).
