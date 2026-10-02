# MacReplica 1.0.0 – final validation report

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
