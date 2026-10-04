# MacReplica – validation report

## Addendum 2026-10-04: MacReplica 1.0.2 (round 3)

Host: development Mac, macOS 27.0.1 (Apple silicon), Command Line Tools / Swift 6.4; GitHub-hosted macOS 14.8
and 15.7 runners for Launchpad. Evidence levels as below (**real**, **real app, simulated Mac**, **automated**,
**not verified**); in addition **CI real** = the real macOS on a GitHub-hosted runner.

### Requirements and results

| Requirement | Result | Evidence |
|---|---|---|
| Launchpad: pages, folders, folder names, order | Implemented for macOS 13–15; recorded with the backup, arranged as the last restore step, again when apps arrive later; report keeps it on macOS 26+ | **CI real** on macOS 14 and 15: Launchpad reset to Apple's default, layout rebuilt, Dock restarted twice, read back identical (MATCH), screenshot; a layout recorded on macOS 14 rebuilt on macOS 15: MATCH; automated (5 + 5 tests) |
| Krita, GIMP, Inkscape, Scribus | Providers with verified categories | **real** (see below) |
| Word, Excel, OneNote, Office shared settings | Templates incl. Normal.dotm, AutoCorrect, custom dictionary, Word/Excel start-up (code, not pre-selected), ribbons (experimental) | **real** for AutoCorrect (Word and Excel); templates checksum-identical. OneNote keeps its notebooks in OneDrive or SharePoint; they come back after signing in (Office sign-in guidance) |
| Apple Mail | Signatures, rules, smart mailboxes, VIPs; Full Disk Access; **experimental** | automated only — see *Apple Mail* below |
| Synology Drive | Guidance (no export; tasks are set up again on the existing folders) | automated (guidance detection) |
| Cryptomator | Vault list (`settings.json`), vaults found reported after restore | **real** |
| DisplayCAL, Calibrite Profiler, BenQ Palette Master Element | DisplayCAL/ArgyllCMS providers (verified); Calibrite: guidance (profiles come back as ICC profiles); BenQ: `benq_params` (experimental) + guidance | **real** for DisplayCAL; BenQ and Calibrite automated |
| XP-Pen Artist Pro 16 | `~/.XPPen/config.xml` (experimental, compatibility-sensitive) + driver guidance; driver installers via *Your installers* | automated |
| Installer archive / offline recovery (Office LTSC + activation pkg) | *Your installers*: `.pkg`/`.dmg`/`.zip` recorded, optionally in the backup, used offline only with matching checksum and developer; follow-up packages (activation) opened in Apple's Installer only when signed by the same developer | automated (5 tests incl. disk images, zip-in-dmg, unsigned packages) |
| Provider framework, confidence model, two-stage selection | Confidence per category shown in backup and restore selection; `containsCode` class; alternate paths, file patterns, `/Users/Shared` scope, home placeholders | **real app, simulated Mac** (screenshots of the backup selection); automated |
| More popular apps | Karabiner-Elements, Hammerspoon, Ghostty, kitty, WezTerm, Alacritty, Zed, Motion, Logic Pro | automated |
| Repeated password prompt | Root cause: without a terminal `sudo` caches per parent process, so every `brew` process asked again, and a rejected password made it ask three times. Fixed: one MacReplica dialog per restore, checked with `sudo -S -k -v`, handed to Homebrew's `sudo` through a token-protected socket | automated with a fake `brew` that emulates `sudo` per process (one dialog for two casks with five privileged steps, wrong password first) |
| Automatic `mas` handling | Asked for only when an App Store app cannot be identified otherwise; MacReplica offers to install it | automated |
| Duplicate Zoom entry | Copies of an app (same bundle ID) merged; the other locations recorded | automated |
| User data beyond application data | *Your own folders*: home folders outside `~/Library`, each on its own, no size limit; free-space check; iCloud placeholders left out | automated (3 tests) |

### Real-application validation (2026-10-04)

| App (version) | Data | Negative control (files moved aside) | After the restore |
|---|---|---|---|
| Krita 5.3.4 | palette in the resource folder (indexed in `resourcecache.sqlite`), `kritarc` marker | palette not in the resource database, marker gone | palette active in the resource database, marker kept by Krita |
| GIMP 3.2.6 | palette, `gimprc` (`undo-levels 42`) | `gimp-console`: no palette, undo levels 5 | `gimp-console`: palette loaded, undo levels 42 |
| Inkscape 1.4.4 | `preferences.xml` group, template, palette | gone | kept by Inkscape after running it |
| Scribus 1.6.6 | `prefs150.xml` context, palette | gone | kept by Scribus after running it |
| Cryptomator 1.19.3 | vault entry in `settings.json` | vault list empty | vault listed in Cryptomator's window; MacReplica reported "1 vault registered and found" |
| DisplayCAL 3.9.19 | the maintainer's real calibrations and settings (29 files) | DisplayCAL hung at start-up | DisplayCAL started normally; its scripting interface reported the same calibration, profile, white point and luminance |
| Word / Excel 16.x | AutoCorrect entry created through Word | Word: 400 defaults, entry absent | Word and Excel return the entry |

Every restored file matched its checksum (282 + 29 + 2 files). The five apps installed for the test were removed
with every file they created (listing of the affected folders identical to before). DisplayCAL and Office were
put back to their state before the test (safety copies). Two defects were found only with the real apps and
fixed: GIMP 3.2 keeps a `cache` folder (2,275 files) inside its profile, and `tags.xml` stores absolute home
paths. During the run DisplayCAL reset one of its own settings (`testchart.file`) on start-up; that happened
before the backup and is not caused by MacReplica.

### Apple Mail

On the development Mac (macOS 27) Mail no longer keeps signatures and rules in `~/Library/Mail/V10/MailData`,
and signatures or rules created by script are not saved. On GitHub's macOS 14 and 15 runners Mail has no
account and stops answering scripts for signatures and rules. The provider therefore follows Apple's
documented layout up to macOS 15 (Knut's Sonoma) with synthetic files and is marked **experimental**: after
restoring, check signatures and rules in Mail.

### Launchpad findings

The Dock rebuilds its first page if a page has no row in `groups`; MacReplica now creates that row like the Dock.
The Dock keeps the arrangement in memory and writes it back on quit, so it is paused while the database is
written and ended without saving. Copies of an app with the same bundle identifier (several Xcode versions)
each keep their place.

### Regression check

457 automated tests pass (451 before the mutation follow-up tests). Backups of 1.0.0 (format 1) and 1.0.1
(format 2) are read and migrated; 1.0.1 refuses format-3 backups. Existing providers keep their behaviour;
verified categories were only added where a real-app check exists (enforced by `ProviderCatalogTests`).

### On-screen run (real app, simulated Mac)

The real MacReplica.app (1.0.2 build) was driven end to end against a simulated old Mac with the new app data, a
Launchpad and an own folder, and a simulated fresh Mac, through accessibility actions only (`tools/ui/ax-press`;
the macOS file panels are bypassed in simulation mode by `stagingSkipPanels`, which uses the remembered folders):

1. Inventory → backup selection with confidence badges, code and Full Disk Access notes (screenshots), *Your own
   folders* → **Add Folder …** → `~/Documents/Novel` listed with size and total.
2. **Save Backup** → *The backup is complete and was checked* (70 files, format 3, Launchpad layout and the own
   folder in the manifest).
3. Fresh Mac → **Restore** → selection with *Your own folders* and *Launchpad layout* → conflict sheet (3 font/profile
   decisions) → *Before the restore starts* → restore: **53 successful, 0 failed, 3 skipped, 5 waiting**; Launchpad
   *arranged with the apps installed so far*, waiting for 4 guided apps.
4. The 4 apps installed (simulated) → **Continue** → **Restore complete, 58 successful, 0 failed**; Launchpad
   arranged again (Dock paused and reloaded twice), the own folder's file and Krita's settings (home path filled
   in) on the new Mac, Launchpad database in the recorded order.

Found and fixed during the run: Krita's Python plug-ins were restored with the resource folder although their
own category was not selected; the note before the restore still described the old password dialog; the summary
listed apps to install that were installed by then. Evidence: `~/Desktop/MacReplica-Staging/validation/round3-gui/`.

### Mutation testing of the new modules

Run on 2026-10-04 (6 shards; then only the survivors again after adding tests — `AdminPasswordTests`,
`OwnInstallerTests`, `LaunchpadTests`, `LaunchpadRestoreTests`, `AppDataScannerEdgeTests` gained cases). Overall
**84.7 %** (177 of 209 counted mutants killed); equivalent mutants of the password channel are
excluded with their reasons in `tools/mutation/config.json`.

| Module | Killed | Survived | Invalid | Excluded | Score |
|---|---:|---:|---:|---:|---:|
| `Downloads/InstallerArchive.swift` | 18 | 9 | 0 | 0 | 66.7 % |
| `Inventory/AppDataScanner.swift` | 44 | 8 | 5 | 5 | 84.6 % |
| `Launchpad/LaunchpadLayout.swift` | 65 | 11 | 3 | 0 | 85.5 % |
| `Providers/AppDataProviders.swift` | 22 | 3 | 2 | 1 | 88.0 % |
| `Restore/LaunchpadRestore.swift` | 10 | 1 | 0 | 2 | 90.9 % |
| `System/AdminPasswordBroker.swift` | 18 | 0 | 1 | 8 | 100.0 % |

Remaining survivors: in `InstallerArchive.swift` the paths that need an installer signed with a real Developer ID
(`pkgutil` reports a trusted signature, a signed app inside a disk image) or `hdiutil detach` failing, plus the
nesting limits for zip/disk-image containers; in `AppDataScanner.swift` partly the home-path check that was
rewritten during the run (the new version is covered by `homePathPlaceholderOnlyReplacesTheHomeFolderItself`).

### Limitations and what is not supported

- Launchpad: macOS 13 not tested (14 and 15 on CI); macOS 26 and later have no Launchpad.
- Apple Mail: experimental (see above); accounts and passwords are never copied.
- Office: OneNote notebooks, licences and sign-ins are not copied; ribbon customizations are experimental.
- Calibration: the monitor's own hardware calibration (BenQ) stays in the monitor; Calibrite presets are
  exported in the app; instrument licences are not copied.
- XP-Pen and BenQ data: experimental (community sources); install the vendor driver first.
- Synology Drive: guidance only.
- Your own folders: no deduplication, no incremental backups — MacReplica is not a replacement for Time Machine.
- No test ran on a freshly installed macOS or a second physical Mac.

### Legal note on the reseller's installation guide

The PDF guide that came with Knut's Office LTSC licence was only read to learn the file names of the installer
and activation packages. Nothing from it is included in MacReplica, its documentation or its tests. Installers
and activation packages a user adds stay in that user's own backup and are never shared.

## Addendum 2026-10-03: display profiles, Python preservation, Photoshop and DaVinci Resolve

Host: development Mac, macOS 27.0.1 (Apple silicon), Command Line Tools / Swift 6.4. Evidence levels used below:
**real** = the user's real data and the real third-party app on the development Mac (not a freshly installed
macOS); **real app, simulated Mac** = the real MacReplica.app against a simulated Mac with synthetic data;
**automated** = unit/integration tests; **not verified** = not exercised. *No test ran on a freshly installed
macOS or a second physical Mac.*

### Baseline before the changes

- Display profiles: profiles were restored as files; display assignments were never recorded or restored.
- Python: environments were rebuilt from interpreter version and exact package versions (kept as the default).
- Application data: Photoshop presets for year-named versions only (beta not detected — it uses separate
  `(Beta)` folders but the same bundle ID), Photoshop panel files off by default, Resolve only Fusion
  templates/macros/fuses; LUTs and Resolve presets were guidance only. Conflicting app-data files were always
  kept without a per-item choice. The provider docs said “No provider is verified”.

### Regression checklist

| Feature | Result | Evidence |
|---|---|---|
| Inventory, app detection, Homebrew, App Store, manual/guided apps | unchanged | 411 automated tests; real app, simulated Mac (run 1: 52 items, 44 successful, 5 guided, 3 skipped as expected) |
| Fonts and ICC profiles incl. conflicts | unchanged | real app, simulated Mac: decision sheet for a same-name profile with different content (default *Keep both*), screenshot F1 |
| Application data (existing providers) | unchanged except the documented corrections below | existing provider tests pass unchanged; Capture One / Camera Raw *already present* on the real Mac |
| Python rebuild | unchanged, still the default | automated; real app runs B, D, E |
| Backup creation, manifest, checksums, verification | unchanged; new optional manifest fields read as before by older backups | automated (`sharedLocationsAreLimitedToAppFoldersAndOlderBackupsStillRead`, session/manifest compatibility tests); real backup “complete and checked” |
| Restore selection, dry run, resume, logging, localization | extended | real app runs; 7 languages for every new text |

Verified corrections of earlier behaviour: Photoshop's Adobe-listed panel files are now selected by default
(Adobe documents them as copyable between installations; verified with the real Photoshop beta); presets of a
Photoshop version that is not on the new Mac go into the installed version instead of an unused folder.

### Scenarios

| Scenario | Result | Evidence level |
|---|---|---|
| A – standard migration | passed: run 1 (52 items) | real app, simulated Mac |
| B – same-Mac reinstall (display assignments, Python saved copy, app data) | passed (earlier run); Photoshop beta and Resolve with the user's real data: passed | real app, simulated Mac; **real** for Photoshop beta / Resolve |
| C – different Mac | passed (earlier run): built-in display assignment of the other Mac skipped | real app, simulated Mac |
| D – Intel vs Apple silicon | passed: Apple-silicon-only app skipped on the Intel Mac; saved Python copy not used (home folder check fired first), rebuild attempted | real app, simulated Mac; processor check of saved copies automated |
| E – saved Python copy fails | passed: damaged archive detected (“1 file in this backup is damaged”), *saved copy not used (archive damaged)*, environment rebuilt and verified by running it | real app, simulated Mac |
| F – profile conflict | passed: explicit decision, no overwrite | real app, simulated Mac |
| G – interrupted restore | passed: app killed at step 12/52, relaunch → resume banner → continued; every install ran exactly once (tool call log) | real app, simulated Mac |
| Photoshop/Resolve real restore | passed (see below) | **real** |

### Real-application verification (Photoshop beta 27.12, DaVinci Resolve Studio 21.1)

1. Safety copy and checksums of the real folders; baseline through scripting (Photoshop: 4 user action sets,
   preset lists; Resolve: keyboard preset list with the user's preset active, `SetLUT` with two user LUTs).
2. Backup with the real MacReplica app (backup selection screenshots R1–R3): 13 Photoshop-beta/Resolve items,
   24 user LUTs (124 Resolve-installed LUTs left out), no machine state, database list, licence, caches or logs.
3. Exactly the 47 backed-up files moved aside; both apps opened: Photoshop showed only Adobe's default action
   sets, Resolve had no custom keyboard preset and refused the user's LUTs (negative control). Both apps wrote
   their defaults back, so the restore met real conflicts.
4. Restore with the real app: per-item conflict choice and file comparison (R5–R6), dry run (R7), *Replace with
   the backup*, 18 successful / 0 failed (R8); all 47 files byte-identical to the originals; replaced defaults
   kept in *Replaced Files*.
5. After relaunching: Photoshop's probe output identical to the baseline; Resolve lists and uses the custom
   keyboard preset again; both LUTs apply (a non-existent LUT is still refused); temporary project deleted.

Evidence: `~/Desktop/MacReplica-Staging/validation/real-apps/` (probes, hashes, safety copy),
`screenshots/R*.png`, `logs/R-real-apps-restore.log`.

### Support status

| | Items |
|---|---|
| **Verified (real)** | Photoshop beta: panel contents, changed workspaces, workspace selection, document presets, preferences (restore + app reads them; the probe covers action sets and preset lists). Resolve: user LUTs (shared folder, receipt exclusion), keyboard presets, user preferences (active preset). Live ColorSync reading and re-assigning the current profile on the built-in display. |
| **Partially verified (real, checksum only)** | Resolve layout presets, user-preference presets, smart bins, metadata/HDR presets, Fairlight presets (no read API in Resolve). |
| **Real app, simulated Mac** | Photoshop release presets/settings incl. moving into the installed version; Resolve waiting until installed and continuing; never into an older Resolve; display assignment on same/different Mac; Python saved copy and fallbacks; scenarios A–G. |
| **Automated only** | Saved-copy processor and macOS checks; permission denied on the shared LUT folder. |
| **Requires manual action** | Resolve PowerGrades, render presets, project presets and project libraries (Project Manager *Back Up/Restore*, Gallery DRX export); Photoshop plug-ins and scripts (reinstall); display profiles of displays that are not connected (assigned when connected or in System Settings). |
| **Not verified** | Photoshop release (not installed on the development Mac); Photoshop actions *loaded from* `Presets/Actions` files (only listed in the panel menu by Photoshop); assigning a *different* profile and external displays on real hardware; a freshly installed macOS or a second physical Mac. |
| **Unsupported on purpose** | Machine preferences (Photoshop `MachinePrefs.psp`, Resolve `config.dat`), caches, logs, licences, Resolve database list and project databases, credentials inside any of these. |

### Backup format compatibility (1.0.1)

- Backups are now `manifest_version` 2. The released MacReplica 1.0.0 (downloaded from the v1.0.0 release,
  checksum verified) refuses a version 2 backup with “This backup needs a newer MacReplica” (screenshot V1)
  instead of restoring shared-library data into the home folder.
- A backup made with the released 1.0.0 opens and restores in 1.0.1 (34 successful, 0 failed, guided steps
  as expected; screenshot V2). Guidance shows the current service names and wording for older backups.

### Mutation testing

Display profile and Python preservation modules: 100 % (were 52–77 %). Application data modules after the
provider extension: `PythonAndDataRestore` 95.5 → 100 %, `AppDataProviders` 89.5 → 100 %, `AppDataScanner`
81.1 → 100 % (equivalent mutants excluded one operator at a time; details in [MUTATION_TESTING.md](MUTATION_TESTING.md)).

### Found and fixed during validation

- Photoshop beta not detected at all (real Mac). Resolve presets looked for in the wrong (stale) folder.
- App-data conflicts had no user choice; now keep / replace / skip with a file comparison.
- Data waiting for an app was counted as “waiting” but not listed in the summary; now listed.
- Status text cut off in the restore selection; short status added. “1 files differ” plural fixed.
- The mutation docs claimed a manual check of the live display manager that had not happened; corrected and
  the check performed (`MacReplicaSimulator display-check-live`).
- CI (both runners) showed a command timeout firing late under load: the output readers blocked GCD's global
  worker threads. Readers now run on their own threads, timeouts and results on their own queues; a test that
  blocks the global queues fails with the old code and passes with the fix.
- Development builds are signed ad hoc, so macOS asks again for Desktop access after every rebuild; app-facing
  test data moved to `/Users/Shared/MacReplica-Staging/test-data` (linked from the staging folder).

---

## MacReplica 1.0.0 – final validation report

Date: 2026-10-02 · Host: macOS 27.0.1 (Apple silicon), Command Line Tools / Swift 6.4 · All validation on simulated Macs with synthetic data.

## Existing implementation (audit before the last two addenda)

- Providers: 3 application-data examples (Photoshop presets, Capture One, DaVinci Resolve), SSH keys as the only credential provider, Git-centric credential thinking (documented in `docs/PROVIDER_AUDIT.md`).
- Fonts and ICC profiles: everything from `~/Library` and `/Library` was backed up without a choice; restore selection allowed unticking items but showed nothing about the destination; conflicts were detected only by checksum at the same path; macOS's own fonts/profiles were not considered.

## New research

- Providers: Apple, vendor and tool documentation for 40+ candidates (`docs/PROVIDERS.md`, `docs/RESEARCH_REPORT.md`).
- Fonts/ICC (`docs/FONTS_AND_PROFILES.md`): SIP/sealed system volume protect macOS's fonts and profiles; font duplicates resolve user → local → system; ColorSync has no precedence between profile folders, lists duplicates and substitutes its own profile for an identical copy (tested); the ICC Profile ID is an MD5 with flags/intent/ID zeroed (ICC.1:2022 §7.2.18) and usually not stored, so it is computed; display profiles in `Displays/` are generated per display and Mac; Font Book calls suitcase/Type 1 fonts “might work but not recommended”; a reported crash risk when reading resource-fork fonts on macOS 26.x led to never opening them.

## New implementations

- 16 application-data provider entries (15 apps), 16 re-authentication and 8 manual-migration guidance entries, 6 opt-in credential providers with an encrypted vault; data classification, evidence and verification status per provider.
- Two-stage selection: backup selection of individual fonts/profiles (manifest records what was selected and copied); destination-aware restore selection for every item, pre-selected except items not recommended on this Mac; review and change of remaining choices when resuming; the credential passphrase is asked again after a restart.
- `FileConflictAnalyzer`: identical/equivalent detection by checksum, PostScript name + version and computed Profile ID; macOS-provided items kept by default; decisions Keep this Mac's version / Replace with backup / Keep both / Skip; display profiles never restored; legacy formats not opened; verification by Core Text and ColorSync; decision codes in logs.
- Main-window Ko-fi link (single URL source `MacReplicaLinks.kofi`), keyboard accessible.

## Re-authentication / manual

Detected and explained, never migrated: GitHub CLI, GitLab CLI, Docker, gcloud, Azure CLI, AWS SSO, GitHub Desktop, Adobe Creative Cloud, Microsoft 365, Dropbox, OneDrive, Google Drive, Slack, Teams, Zoom, Things. Manual export recommended: Raycast, BetterTouchTool, Hazel, Rectangle, Terminal profiles, Affinity, Premiere Pro, DaVinci Resolve project libraries.

## Answers for the font/ICC addendum

**Backup selection.** Individual fonts: yes. Individual ICC profiles: yes (generated display profiles start deselected). Application data individually: yes. Credential providers independently: yes, each opt-in.

**Restore selection.** Independent of the backup selection: yes, without re-creating the backup. Backed-up items pre-selected: yes, except incompatible, legacy, obsolete-Apple and display profiles. Individual deselection: yes. Persists through resume: yes (stored in the session; tested in code and in the real app).

**Fonts.** Duplicates: identical checksum anywhere on the Mac, or same PostScript names and version (also under another file name). Version conflicts: decision with “keep this Mac's version” as default; replace moves the old file to *Replaced Files*; only files in the restore folder are ever moved. System fonts: a font whose PostScript name macOS provides (system folders and downloadable font assets) is kept by default; MacReplica never writes to `/System`. Verification: SHA-256 plus Core Text parse of the installed file.

**ICC.** Duplicates: identical checksum or same computed Profile ID. System vs user: by location (macOS folder vs user/shared library) and creator; generated display profiles by the `Displays/` location. Equivalent profile on the destination: kept, nothing copied. Different profile with the same name: installed next to it by default (“Keep both”), or keep/replace/skip. Obsolete Apple profiles: not pre-selected, explained. Research/testing: ColorSync lists duplicates and substitutes its own profile for an identical copy; copying old Apple profiles is pointless or harmful.

## Verification

- Tests: 296 in 43 suites, all passing, stable across repeated runs (including under heavy CPU load).
- Mutation testing: 18 critical modules, 712 valid mutants. First run 68.5 %; after adding tests for the gaps it revealed, **85.5 %**, every module at or above its threshold (`docs/MUTATION_TESTING.md`, remaining survivors classified and listed). Selection and conflict logic: planner 84.5 %, conflict analyzer 84.8 %, executor 79.3 %.
- Dry run: tested in code (dry run equals restore for every font/profile) and in the real app.
- Resume: tested in code and in the real app (kill at step 9/38, review, change, continue in the same session).
- Real application UI: start, scan, backup selection, backup, check backup, restore selection, item details and decisions, dry run, conflict sheet, progress, summary, resume, safe mode, settings, about, update notice — English, German, Norwegian, light and dark, normal and narrow windows; release build and DMG launched by double-click.
- Privacy: manifests, logs, reports and screenshots free of personal paths, names, email addresses and secrets; repository scan clean.

## Remaining limitations

- No provider is marked *verified*: no restore into real application folders was performed on the development Mac, by design.
- Developer ID signing and notarization prepared but not performed (no certificate available).
- Font activation in apps that are already running is not verified.
- Printer-driver profiles and application-installed profile aliases come back by reinstalling the driver/app.
- An unwritable personal font folder is handled through the administrator copy (rare; reported if it fails).
- Remaining surviving mutants are listed and classified in `docs/MUTATION_TESTING.md`.
