# MacReplica – validation report

## Addendum 2026-10-17 (1.1.2): restore after a clean reinstall with a Time Machine home folder

Two reports from the beta tester (1.1.0, Intel Mac with T2, macOS 14): 13 casks and 52 shared colour profiles failed,
the retry called intact profiles damaged and lost the rest of the restore, own installers were ignored for cask apps,
Check Backup and the reinstall guide disagreed, the guide lacked the USB-installer steps (the tester got locked out by
Startup Security Utility after erasing), and the waiting scanners could not be found. Every finding, its root cause,
fix and verification level: [TESTER_FEEDBACK_1.1.0.md](TESTER_FEEDBACK_1.1.0.md).

- Tests: 672 in 110 suites passing. Mutation of the changed lines: 95.5 % ([MUTATION_TESTING.md](MUTATION_TESTING.md)).
- Real app on screen (simulated Macs): partial backup → Check Backup (gaps listed, Reinstall Guide written), restore
  with an outdated pre-installed Homebrew (one `brew update`, casks installed), Retry Failed Items in the same session,
  quit/relaunch/Continue → guided steps, scanners named as such in the guided-steps card, report on disk.
- Not verified on real hardware: Intel + T2, the tester's Homebrew, a real administrator copy into `/Library`, a backup
  on a network share.

## Addendum 2026-10-15 (1.1.0): working disk images reported as damaged

Report (beta tester, 1.0.7, Intel MacBook Pro, macOS Sonoma, installers on an external drive): DisplayCAL 3.9.19 – which
he had just installed from –, AppPolice and Adobe Color Printer Utility showed *“The file cannot be opened: it is
damaged, incomplete (an interrupted download?) or encrypted”*; Brackets from the same folder worked. Model, sources and
the step table: [INSTALLER_VALIDATION.md](INSTALLER_VALIDATION.md).

**Root cause.** `InstallerArchiveInspector` mapped every failure of `hdiutil imageinfo` and `hdiutil attach` to
`.damaged`. `hdiutil` exits with 1 for every failure and prints its reason in the user's language (also with
`LANG=en_US`), so nothing distinguished damage from an image that is open, a mount folder that vanished, an image
without a mountable file system, or an encrypted one. Reproduced on this Mac with real files: an intact image
(`hdiutil verify`: VALID) without a mountable file system shows the tester's exact message in the 1.0.7 inspection
on screen; `hdiutil attach` into a removed folder fails with the same “no mountable file systems”; an
encrypted image makes `imageinfo` wait for a password dialog until the 120-second limit; an image already open made
the retry force-eject the user's volume. The tester's own trigger could not be determined (his drive and log were not
available; 1.0.7 did not log `hdiutil`'s message): his three files, downloaded from their official sources (DisplayCAL
from GitHub, SHA-256 matching the published digest; ACPU from Adobe's help page; AppPolice from GitHub) are intact, and
1.0.7's exact commands succeed on them on macOS 14.8, 15.7 (Apple silicon, Intel), 26.6 and 27.0 with Gatekeeper on, with
and without the quarantine flag (CI run 38729271450), and from APFS, HFS+, exFAT, FAT32 and read-only volumes on
macOS 27. Not tested: a physical USB drive (none attached here).

**Fix.** Damage needs proof (the file's bytes – directory missing or past the end, zip without end record – or the
image's own checksum via `hdiutil verify`, or `pkgutil`'s “package is invalid”); everything else keeps the intact file
with a `contentsLimit` and the tools' words (`inspectionNote`), used after the user confirms it and opened in Finder on
the new Mac if needed. Images already open are read in place and never ejected; attachments of others are never
detached; every inspection has its own folder; encrypted images are never handed to `hdiutil`. Not weakened:
checksums, developer checks and the user's confirmation for unverified installers are unchanged; truncated packages,
accepted as “not signed” before, are now rejected.

| Evidence | Result |
|---|---|
| Unit and integration tests (`InstallerEvidenceTests`, `InstallerValidationTests`, real `hdiutil`/`pkgutil`/`ditto`) | all pass; full suite 636+ tests pass locally, CI macOS + Intel green (PR #13) |
| Mutation testing ([MUTATION_TESTING.md](MUTATION_TESTING.md#results)) | `FileFormatEvidence` 100 %, `InstallerDescriptions` 100 %, `InstallerArchive` 90.7 % (was 87.2 %), `DownloadInstaller` changed lines 89.5 % |
| Real installers, this Mac (macOS 27.0.1, `MacReplicaSimulator inspect-installer`) | 14 official files (DisplayCAL, ACPU, AppPolice, Brackets [UDBZ], Karabiner-Elements [ULMO, dmg with pkg], macFUSE, IINA, Rectangle dmg+pkg, Stats, XQuartz pkg, SwiftBar zip, KeepingYouAwake zip, a copy named with spaces and non-ASCII letters) all kept and inspected; digests verified where published; independent `hdiutil verify` VALID, `pkgutil` signed, `unzip -t` OK |
| Negative files | bit-flipped DisplayCAL → damaged (checksum); cut at 60 MB → incomplete; web page as .dmg → not an installer; empty → not an installer; cut-short pkg → damaged; encrypted → kept, no `hdiutil`; raw UDRW and LZFSE images → kept |
| Real installers workflow (CI run 38737472965) | macOS 14.8, 15.7, 26.6, 15.7 Intel: every expected verdict, DisplayCAL already open stays open, nothing left attached |
| On screen, 1.0.7 vs 1.1.0 (simulated Mac, files on an exFAT “Backup” volume) | 1.0.7: intact image, interrupted download and saved error page all “damaged, incomplete … or encrypted”; 1.1.0: kept with reason and details / incomplete / not an installer; DisplayCAL read while open in Finder (volume stays), ACPU inspected, encrypted image kept without a password dialog |
| Backup and restore | installers recorded with reasons, copies match SHA-256; on a fresh simulated Mac DisplayCAL's own installer verified by checksum → without Rosetta “Not compatible with this Mac”, with Rosetta the DisplayCAL suite 3.9.19 installed, quarantined, nothing left attached |

Found on the way: the guided installation said “Homebrew's checksum of the file” for the user's own installer; it now
names the checksum recorded on the old Mac (and, for a confirmed unverified installer, that its developer cannot be
verified). Known, not changed here: in macFUSE's image MacReplica identifies the bundled uninstaller app instead of
the package.

## Addendum 2026-10-14 (1.0.7): passwords, keys and credentials

Request: multi-selection of keys and password databases was broken in 1.0.5, credential files were treated as
something to skip, and nothing should give a false impression that credentials are safe. Policy, design and sources:
[CREDENTIALS.md](CREDENTIALS.md).

**Root cause (reproduced in a test before the fix).** *Include …* on a file outside the chosen folders created a hidden
one-file own folder. Choosing that folder later produced a second folder with the same path, and the next *Include …*
returned silently at a `guard … else { return }`. Files in the home folder itself, iCloud Drive and other volumes could
not be included at all, and `removeApplicationData` dropped other folders' credential issues. Included files were
copied unencrypted. Fixed by independent, encrypted credential items (details in CREDENTIALS.md).

| Area | What was checked | How | Result |
|---|---|---|---|
| Several items from one folder (the reported bug) | `Work.kdbx`, then `Family.kdbx` and its key file from `~/Sync` | **real app, simulated Mac** (screenshots 01–03) + `severalItemsFromOneFolderAndFromAnywhereCanBeAdded` | all three selected, "3 encrypted · 1 needs a decision" |
| Items from several places at once | picker with the `Keys` and `Certs` folders and a database on a simulated external volume; iCloud Drive and home-folder databases | real app + `pickerAddsFilesAndFoldersWithoutDuplicatesLoopsOrUnrelatedFiles` | 12 items; key files named without `id_` recognised; `.pub` companions added; nothing unrelated added |
| Duplicates, same contents, links, loops | same file twice and through a link; two identical keys in different folders; a link back to the folder | automated | one item per file; identical contents kept as two items and reported; no loop |
| Refusals are explained | keychain chosen directly, file already selected, missing, unreadable (mode 000), browser `Login Data`, folder without credentials | real app (German, screenshot 13) + automated | each listed with its reason; nothing silently dropped |
| Decisions are recorded | *Leave Out*, *Undo*, *Remove* | real app (Norwegian, screenshot 14) + automated | "left out by you" in the UI, report and manifest |
| Warning before an unsafe save | an undecided iCloud database | real app (screenshot 04) | sheet lists it; *Review* / *Save Without Them* |
| Encryption | round trip 0 B…3 × 64 KiB + 17; tamper at magic, header, records, tag and final record; truncation at and between records; appended byte; other item ID; other backup's key; zero-length and oversized header; oversized record | automated (`CredentialPreservationTests`) | every change refused (`itemDamaged`) |
| Key handling | passphrase and recovery-key unlock, wrong passphrase, wrong or malformed key, weakened iteration count, changed key fingerprint, 11- vs 12-character passphrase | automated + real app (wrong passphrase refused in the sheet, screenshot 06; recovery key typed in lower case with spaces, screenshot 07) | as designed |
| No secrets outside the encryption | every file of the backup, manifest, reports and logs on both Macs, for passphrase, recovery key, PEM/PGP markers, entry passwords, recovery codes, plain SHA-256 of every source file | scripted scan of the real backup + automated | no hits (the only PEM-marker hits are string constants inside the copied MacReplica binary) |
| Failure is never success | source deleted before saving; no encryption set up | automated | item `failed (missing)` / `noEncryptionKey`, backup *partial*, other items still preserved |
| Restore into an empty Mac | 13 and 17 items | real app ×3 (passphrase, and recovery key) + automated | all files byte-identical; secret files `0600`, public `0644`, new folders `0700`; no partial files |
| Conflicts | a different `~/Sync/Work.kdbx` already on the new Mac; an identical key | real app: decision sheet (screenshot 08), *keep this Mac's version* (first run) and *keep both* (second run) + automated (*replace*: old file kept in *Replaced Files*) | identical → already present; different → only with the chosen decision; existing file never changed without it |
| Idempotent and interrupted restores | second run; leftover partial file from an interrupted run | real app + automated | second run changes nothing; leftover replaced; damaged item fails alone |
| Missing volume | database from a volume that is not connected | real app + automated | restored to `~/MacReplica Restored Credentials/<id>/`, result says so |
| **Real applications** | restored files opened with **KeePassXC 2.7.12** (`keepassxc-cli ls/db-info`: with password, with password + key file, refused without key file or with a wrong password), **OpenSSH** (`ssh-keygen -y`: unencrypted key, key with its own passphrase, wrong passphrase refused; both match their `.pub`), **LibreSSL** (`x509`, key ↔ certificate modulus, PKCS #12 with its password), **GnuPG** (secret key imports, fingerprint equals the original) | real tools, synthetic credentials | all open as on the old Mac (`validation/credentials/real-app-verification.txt`) |
| Localization | new texts in en, de, nb, es, fr, it, nl | automated (completeness, placeholders, every case) + real app in en, de, nb | complete |
| Regression | full suite | `scripts/test.sh` | 621 tests in 106 suites pass |

**Simulated, not real:** the old and new Macs are simulated home folders (MacReplica's simulation mode); the "external
volume" is a folder outside the home folder that was removed before the restore. Keychain items, passkeys and browser
password stores are not moved by MacReplica by design, so there is nothing to test beyond the guidance texts and
detection (`~/Library/Keychains`, installed apps). Browsers and password managers other than KeePassXC were not
installed. KeePassXC was installed with Homebrew into a scratch folder and removed afterwards (snapshot compared).

**Mutation testing:** 6 modules. The four new ones (`CredentialStore`, `CredentialItems`, `CredentialBackup`, `CredentialRestore`) reach **100 %** (154 of 154 valid mutants killed, 10 equivalent mutants excluded with reasons). The changed `Credentials.swift` and `SensitiveFiles.swift` also reach 100 %. Three rounds: round 2 left CredentialItems at 76 %, CredentialBackup at 52.9 % and CredentialRestore at 77.8 %. The fixes: an unused field and an unused equality were removed, the error→reason mappings became testable functions, and tests were added (1PUX format, undoing one of two decisions, unclassified issues, a remembered database not offered again, a file chosen by hand and through its provider, absolute restore locations, passphrase and header-length boundaries, a tighter record bound).

**Found and fixed during validation** (beyond the reported bug): credential conflicts were never shown because the
pre-restore check ran before the passphrase was known (now asked first); SSH keys saved without an `id_` name were
not recognised; `.pub` files were labelled as private keys; a stale "outside the chosen folders" note; a blank line
for guidance rows; "key file file" and a key file said to need "its key file".

Evidence: `~/Desktop/MacReplica-Staging/screenshots/credentials/` (01–16), `~/Desktop/MacReplica-Staging/validation/credentials/`.

## Addendum 2026-10-04 (after 1.0.3): Homebrew support notice, disk-image retry

- **Homebrew support tiers** (docs.brew.sh/Support-Tiers, as of 2026-10-04): Tier 1 = Apple silicon with macOS 15,
  26, 27; Tier 3 = Apple silicon with macOS 11–14 and every Intel Mac; unsupported = macOS 10.15 and older; Intel
  expected unsupported from September 2027. **Real app, simulated Mac** (macOS 14.8.4 on Intel, like Knut's): the
  notice appears on the old Mac's selection screen before the backup (H1), is in the backup's `inventory.html` and
  `RESTORE_INSTRUCTIONS.html`, appears in the new Mac's restore selection (H2), and the restore ran through (33
  successful, 0 failed, 4 guided). Negative check: Apple silicon with macOS 15.1 shows no notice (H4). Automated:
  tiers, texts, reports. Mutation: `HomebrewSupport.swift` 100 %. Evidence:
  `~/Desktop/MacReplica-Staging/validation/round5-homebrew/`.
- **Disk image after a busy retry** (PR #5): before each retry, attachments of the image a failed attempt may have
  left are detached. 5 runs of the disk-image suites and full runs: no image left attached.

## Addendum 2026-10-04 (round 4): Knut's test on an Intel Mac, LibreOffice, location, selection, explanations

| Request | Result | Evidence |
|---|---|---|
| Homebrew "installed but does not respond" on Knut's Intel MacBook Pro (Sonoma, MacReplica 1.0.2) | Cause: Homebrew could not read its version from git and printed `Homebrew >=4.3.0 (shallow or no git repository)` (Homebrew's `brew.sh`/`utils/git.sh`: without git — no Command Line Tools — or with a repository owned by another administrator, and no describe cache). MacReplica only accepted a number after "Homebrew ", so it treated a working Homebrew as broken. Fixed; the log now names the reason and every inventory warning | automated (`homebrewWithoutGitIsUsed` with that exact output, parser cases); Homebrew's source read on this Mac |
| LibreOffice settings like Office's Normal.dotm | Provider for the user profile | **real** (LibreOffice 26.8, see PROVIDERS.md); fixture test incl. everything that is never copied |
| Choose where to save the backup before starting | *Backup location* card with path, drive, free space and backup size; *Save Backup* saves there; "Nothing is written until you click Save Backup" | **real app, simulated Mac** (screenshot G1) |
| Save and load the selection, next to the backup | *Save Selection … / Load Selection …*; saved automatically next to the backup; offered at the next scan (*Use It*) | **real app, simulated Mac**: two choices changed, backup saved (selection file next to it), new scan → offered → applied → both choices back; *Load Selection …* likewise; automated (format, defaults for new items, newer format refused) |
| Explain the options | Hover text for every kind of application data (104 kinds × 7 languages): what it is, contents with example names, origin, support level, notes | **real app**: hover texts read through accessibility (AXHelp) for LibreOffice settings and macros and Krita; automated (every kind explained in every language) |

Complete on-screen run (real app, simulated Macs, accessibility actions only): backup with the location card, an own
folder and LibreOffice's macros switched on → *Save Backup* (format 3, selection file next to it) → restore on the new
Mac: 62 successful, 0 failed, 5 guided; all 10 LibreOffice files identical, settings filled in with the new home folder,
scripts not restored (not selected), own folder back → apps installed, *Continue* → **67 successful, 0 failed**.
Screenshots E1–E5 in `~/Desktop/MacReplica-Staging/validation/round4-gui/`.

Mutation testing of the new code: `BackupSelectionPreset.swift` 100 % (8 of 8), `HomebrewClient.swift` 100 % (22 of 22;
3 equivalent sort mutants excluded), after adding tests for the defaults, version lists, tap trust, name length and a
dangling `brew` link.

Disk images: two full runs of the test suites showed that on macOS 27 parallel attaches fail with "resource temporarily
unavailable" and can leave images attached — also with 1.0.2 (4 of 6 runs of the disk-image suites failed, up to 7
images left attached). MacReplica now queues `hdiutil`, retries attaches and detaches and detaches every attachment of
an image after a final failure: 8 of 8 runs passed with nothing left attached. Mutation score of the changed code:
`DownloadInstaller.swift` 92.6 % (50 of 54, before the new tests 69.1 %), `DiskImageCommands.swift` 100 %.

Found during the on-screen run and fixed: the *Use It* button could not be pressed through accessibility because
its row carried an identifier that hid the button's own.

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
