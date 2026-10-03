# MacReplica – validation report

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

### Mutation testing

Display profile and Python preservation modules: 100 % (were 52–77 %). Application data modules after the
provider extension: see [MUTATION_TESTING.md](MUTATION_TESTING.md).

### Found and fixed during validation

- Photoshop beta not detected at all (real Mac). Resolve presets looked for in the wrong (stale) folder.
- App-data conflicts had no user choice; now keep / replace / skip with a file comparison.
- Data waiting for an app was counted as “waiting” but not listed in the summary; now listed.
- Status text cut off in the restore selection; short status added. “1 files differ” plural fixed.
- The mutation docs claimed a manual check of the live display manager that had not happened; corrected and
  the check performed (`MacReplicaSimulator display-check-live`).
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
