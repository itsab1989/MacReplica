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
| `Restore/PrivilegedExecutor` | Runs a fixed set of operations (`mkdir`, `install`, `ditto`, `mv`, `installer`) with one administrator authentication; paths are validated and quoted by AppleScript itself. |
| `Inventory/*` | Read-only scanning. Fonts and profiles carry their identity (`FontIdentity`, `ProfileIdentity`) and origin. |
| `Matching/*` | Conservative app → Homebrew cask matching (bundle ID, app name, vendor evidence); ambiguous cases need a user decision. |
| `Providers/*` | Catalog of application-data providers (`AppDataCatalog`), re-authentication / manual-migration guidance (`GuidanceCatalog`), generic detection. Knowledge about apps is data, not code. |
| `Credentials/*` | `CredentialProvider` protocol, SSH and file-based providers, `CredentialVault` (PBKDF2 + AES-256-GCM). |
| `Backup/*` | Writing the self-contained backup folder and verifying it (SHA-256 per file plus `SHA256SUMS`). |
| `Restore/RestorePlanner` | Turns a manifest and a `RestoreSelection` into an ordered plan; `continuation(of:)` continues an interrupted session with a reviewed selection. |
| `Restore/RestoreExecutor` + `Inspector` | Shared read-only checks (`predict`) for the selection screen, dry run and restore; the executor performs and verifies each step and never stops on a single failure. |
| `Restore/FileConflictAnalyzer` | Destination-aware decisions for fonts and ICC profiles (see [FONTS_AND_PROFILES.md](FONTS_AND_PROFILES.md)). |
| `Restore/SessionStore` | Restore sessions (selection, results) for resume and retry. |
| `Reports/*` | Localized HTML reports and restore instructions. |
| `Support/*` | Logging with redaction, startup diagnostics and safe mode, safe clean-up of owned folders, update check. |
| `Localization/*` | Own `.strings` loader with plural rules and English fallback (7 languages); user-facing descriptions of every enum case. |

## Manifest

`manifest.json` is versioned (`manifest_version`, currently 1), uses stable snake_case keys and is
decoded leniently (missing sections become empty, unknown keys are ignored, newer major versions
are refused with a clear message). It records the MacReplica version and build, macOS version and
architecture of the old Mac, and for each item what is needed to restore it — never secrets.
Fonts and profiles store original path, backup path, size, SHA-256, origin and identity; the
selection made on the old Mac is summarized in `backup_selection`. An example is in
[examples/manifest.json](examples/manifest.json).

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
