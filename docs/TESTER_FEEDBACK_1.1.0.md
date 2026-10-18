# Tester feedback on MacReplica 1.1.0 (Intel Mac, macOS 14, clean reinstall)

Investigation record for two reports from the same beta tester (2026-10-17), consolidated in one inventory. The
tester backed up an Intel Mac with the T2 chip (macOS 14.8.4), erased it, installed macOS 14.8.9 from a USB installer,
brought the home folder back from **Time Machine** (without apps), and then restored with MacReplica 1.1.0 (12).

Sources (kept outside the repository, not changed):
- **Report 1** – email “Feedback after trying MacReplica”: text, 27 inline screenshots, logs `app-…log`,
  `restore-20261017-151019.log` (467 steps), `restore-20261017-164554.log` (retry, 68 steps), `startup.json`.
  The screenshots arrived as 194×320 thumbnails: headings and buttons are readable, body text and technical
  details are not; the logs were used for those.
- **Report 2** – email “MacReplica restore report”: two sentences and the restore summary
  (`MacReplica Restore Summary.html`, zipped). The body shows an image placeholder, but the message contains no
  image part – only the zip. Nothing else was missing.
- **Report 4** – email “Test of MacReplica 1.1.3” and a follow-up: text, 3 screenshots (Launchpad, summary, guided
  steps), `restore-20261018-002425.log`, an `lporg` export of the old Mac's layout (YAML, read as data), a how-to text and
  the `lporg` tool itself (archive not unpacked or run). Follow-up: Office had to be installed by hand.
- **Report 3** – email “Test of MacReplica 1.1.2” (same session resumed with 1.1.2 on the restored Mac, macOS 14.8.9):
  text, one screenshot of the summary (a higher-resolution copy supplied separately), `restore-20261017-222553.log`
  (467 steps, 460 already finished). All readable.

Status categories: **Verified** (real app on screen, simulated Mac) · **Tests** (automated, simulated Mac or
synthetic data) · **Not verified on real hardware** where the tester's environment (Intel + T2, real Homebrew,
real administrator prompt, network share) was not available. Baseline: `main` at 4bf9a7e (1.1.1).

## Inventory

| ID | Observation (source) | Kind | Severity | Root cause (confidence) | Disposition |
|---|---|---|---|---|---|
| F-01 | Backup took several tries; encryption passphrase entered every time; wish to *update* an existing backup instead of making a new one (R1 text) | Enhancement | Enhancement | By design: the passphrase and recovery key are never kept after a store is written; every backup is a new, separately verified folder. A saved selection (**Save/Load selection**) already keeps the choices. | **Deferred** – incremental backups and re-keying need a design (credential store, verification, gaps). |
| F-02 | “Partial: 2 selected files are missing Everything else …” – missing full stop (R1 §1) | Defect | Low | `ReinstallGuide` joined title and message with a space; the restore instructions too (confirmed). | **Fixed, verified** (backup on screen; guide/instructions files checked; test in all 7 languages). |
| F-03 | Guide said *Partial*, **Check Backup** said everything included and correct (R1 §1) | Defect | High | Both had a basis: the manifest recorded 2 gaps; Check Backup verifies only files *in* the backup and called it “complete and undamaged” without looking at the gaps (confirmed). | **Fixed, verified** – “The saved files are undamaged – but the backup is not complete”, completeness notice and the missing files listed (screenshot `gui-02`). |
| F-04 | Reinstall guide only reachable right after **Create Backup** (R1 §2) | Defect/UX | Medium | Button only on the “Backup saved” screen (confirmed). | **Fixed, verified** – **Reinstall Guide** on the Check Backup result; written fresh for the backup's Mac with the current MacReplica, the backup is not changed. |
| F-05 | Booting from the USB installer not explained; a link is useless on paper (R1 §3) | Defect (docs in app) | High | Guide had one line about USB boot and a link to Apple (confirmed). | **Fixed, tests** – new section *Install from a USB installer*: Apple's steps (support.apple.com/101578, /102662), the exact `createinstallmedia` command for the Mac's macOS, Option key (Intel) / power button (Apple silicon). Not verified on a real Intel Mac. |
| F-06 | Erased the disk, then Startup Security Utility could not authenticate (no user) → stuck; DFU restore needed (R1 “What happened”) | Defect (missing safeguard) | High | Startup Security Utility asks for an administrator of this Mac (Apple, support.apple.com/102522); after erasing there is none. The guide mentioned the setting only after the erase step (confirmed). | **Fixed, tests** – red warning in *Before you start* on T2 Macs, with the exact steps; repeated under the USB section. Not verified on a T2 Mac. |
| F-07 | Recovery download showed 11–13 hours (R1) | Platform | Info | Internet Recovery download speed. | **Addressed in guide** – USB installer recommended, to prepare *before* erasing. |
| F-08 | Home folder restored from Time Machine first; many items already present (R1) | Context | Info | MacReplica compared every file: identical ones are “already installed”, nothing overwritten (report 2 confirms). | **Not a defect.** It caused F-10 (old Homebrew came back). |
| F-09 | “Microsoft Teams.app is damaged and can't be opened … downloaded on an unknown date” during the restore; tester pressed Cancel (R1 screenshots 1–2) | Unclear | Medium | Preliminary: the dialog appeared while the Teams package was installing (screenshot 1: “Installing …”); the cask reported success 41 min later. MacReplica does not open apps; likely Microsoft's installer or a login item opening a half-installed app. Not reproducible here (no Intel Mac, no Teams). | **Requires clarification** – does Teams open now? MacReplica does not check the signature of cask-installed apps; a post-install `codesign` check is a possible follow-up. |
| F-10 | 13 casks failed as “Unexpected problem” (balenaEtcher, ChromIQ, GIMP, Keka, Microsoft Office, MonitorControl, OBS, Oracle JDK 21, Synology Drive, TeamViewer, VLC, VueScan, zoom) (R1 screenshots, both logs; R2 report) | Defect | High | Confirmed from the logs: Homebrew was “already present” (brought back by Time Machine) and too old for today's cask definitions (`Unexpected method 'postflight_steps' / 'command_wrapper' called on Cask`, “Do not report this issue until you've run `brew update`”). MacReplica always sets `HOMEBREW_NO_AUTO_UPDATE=1` and never updated it. | **Fixed, verified (simulated)** – on that evidence only, `brew update` once per restore and the package again (note in the summary); if it fails: **Homebrew is too old** with what to do. On screen: 1 update, all casks installed (`gui-04`). Not tested with the tester's real Homebrew. Office's `undefined method 'first' for nil` is not classified as outdated (no evidence); it follows the update made for an earlier cask. |
| F-11 | 52 colour profiles for all users failed (R1 screenshots, log; R2 report) | Defect | High | Confirmed: one administrator command chain installed every file with `install … <backup>/…` as root; root got `Operation not permitted` (exit 71, EX_OSERR – BSD `install` could not open the *source*) and `&&` stopped the rest. Why root may not read the backup volume (network share mounted by the user, or privacy protection) is not known (preliminary). | **Fixed, tests** – each file is copied to this Mac as the user, checked against its checksum, and only that copy is installed; after a failure, each file counts by what is on disk. Real administrator prompt and a network share not tested. |
| F-12 | After **Retry Failed Items** the same 52 profiles were “Damaged in the backup”, while Check Backup found no damage (R1 retry log) | Defect | High (false claim) | Confirmed in code: “damaged” was reported for any copy that could not be found **or read**, not only for a checksum mismatch. Why the copies were unreadable at retry time is unknown (hypothesis: backup volume not reachable). | **Fixed, tests** – **Backup copy could not be read** with the reason; damage only with a differing checksum; retry checks first that the backup is reachable. |
| F-13 | After retry the summary showed only the retried steps; “Install these apps yourself” listed MacReplica (R1 last screenshots) | Defect | High | Confirmed: retry created a new session with only the failed steps; results, guided steps and the manual list's “already installed” information were not part of it. | **Fixed, verified** – retry runs in the same session (log “39 steps, 34 already finished”), also retries steps skipped because of a failed one (`gui-05`). |
| F-14 | Question: after quitting and updating MacReplica, can the failed items still be retried? (R1) | Question | – | The restore with open guided steps stays unfinished and is offered on the start window (**Continue**); failed steps are retried from its summary. Session files only gained new, additive values. | **Answered and verified** – quit, relaunch, **Continue** → summary with **Retry Failed Items** and guided steps (`gui-06`, `gui-07`). Documented (USER_GUIDE, TROUBLESHOOTING). Opening a 1.1.0 session file in the new build was not tested separately. |
| F-15 | “For most of these apps I specified a stored installation file … which obviously did not work” (R1 end) | Defect | High | Confirmed: an app installed from a cask was always planned as that cask; its own installers (saved in the backup, shown as “Will be used on the new Mac”) were never offered – not even after the cask failed. | **Fixed, tests** – an app with a usable own installer is restored from it in the guided steps; a match chosen on the restore screen still wins. Not driven on screen (file panels). |
| F-16 | DisplayCAL and MacDown: “No automatic source was found …” although installers were chosen (R1 last screenshot; R2 report) | Defect | Medium | Confirmed: the hint ignored own installers. | **Fixed, tests** – “Your own installer is used: choose Continue with Guided Steps …”. |
| RESTORE-001 | After a restart and **Continue**: several apps “Waiting for you – see the guided steps”, but the guided steps cannot be found (R2 text) | Defect | High | Confirmed contributing cause: the guided-steps card named the 5 waiting **scanners** “5 developer tool steps with the exact commands to run” (R1 screenshot 3; no developer tool was open), and the HTML report says “see the guided steps” without saying they are in MacReplica. It is not known whether the tester looked in the app or in the report. | **Fixed, verified** – card: “2 steps for displays, printers and scanners, set up in System Settings” (`gui-08`); report: count + where the steps are. Relates to F-13/F-14. **Clarification asked**: where was the tester looking? |
| RESTORE-002 | Report lists MacReplica under “Apps to Install Manually” although its row says “Already installed” (R2 report) | Defect | Medium | Confirmed: `restoreSummaryReport` listed `plan.manualApps` without the results. Corroborates F-13 (same symptom in the window after retry). | **Fixed, tests** + checked in a written report. |
| RESTORE-003 | Report shows 387 / 65 / 0 skipped – the 15 waiting steps are not counted (R2 report) | Defect | Medium | Confirmed: no “waiting” card in the report. | **Fixed, tests** + checked in a written report. |
| RESTORE-004 | Report: casks and profiles as “Unexpected problem” (R2) | Corroborating | – | F-10, F-11. | See F-10, F-11. |
| RESTORE-005 | Report: 9 guided installations, 5 scanners waiting; Launchpad waits for 9 apps (R2) | Corroborating | – | Matches the 15 waiting steps of R1 screenshot 3; Launchpad waiting is intended. | See RESTORE-001. |
| RESTORE-006 | The report after the restart is the *original* session (387/65), not the retry (3/65) (R2) | Corroborating | – | Confirms F-13's cause: the original session stayed unfinished and is what **Continue** resumes; the retry was a separate, completed session. | – |
| RESTORE-007 | Backup made on macOS 14.8.4, restored on 14.8.9, Intel (R2 header) | Context | Info | Same major version: settings are offered as usual. | Not applicable. |
| TEST112-001 | With 1.1.2 the restore completed and “guided steps were possible to click and reach” (R3 text, screenshot: “4 steps for displays, printers and scanners”) | Confirmation | – | – | **RESTORE-001 and F-13/F-14 verified by the tester on his real Mac.** |
| TEST112-002 | “The reinstall guide includes all the things I had problems with” (R3 text) | Confirmation | – | – | **F-05/F-06 confirmed by the tester** (content; he did not repeat the reinstall). |
| TEST112-003 | “The restore window falsely claims that Launchpad does not exist on this macOS, which is Sonoma … restoring the Launchpad was skipped” (R3 text; screenshot: *Launchpad – Launchpad does not exist on this macOS (replaced by the Apps view)* under “4 items skipped”) | New defect (not a regression of 1.1.2's changes: the Launchpad code was not touched) | Medium (misleading status; the arrangement is lost silently) | **Confirmed in code:** `predictLaunchpad` returned `launchpadNotAvailable` for three different causes – macOS 26 or later (correct), *and* a Launchpad database that was not found or no store – and that result was final, so it was never checked again. On 14.8.9 the version check passes, so the database file (`$(getconf DARWIN_USER_DIR)/com.apple.dock.launchpad/db/db`) was not found when the step ran. **Why it was missing is not known** (same Mac arranged Launchpad with 1.1.0, R1 log; the step ran in an earlier 1.1.2 run of the session, not in the attached log). | **Fixed, tests + on screen (simulated)** – a missing database on a macOS with Launchpad is now *“Not arranged yet: Launchpad's list of apps was not found … Open Launchpad once, then choose Continue”*, the step waits and is checked again; a session saved by 1.1.2 with the false result is reopened on Continue (the tester's own session included). Not verified on a real macOS 14 (none here): whether opening Launchpad recreates a missing database. **Clarification asked:** output of `ls "$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/"` on his Mac. |
| TEST112-004 | Cakebrew, Get It, iClue “Skipped as you chose” (R3 screenshot) | Informational | – | The tester skipped them in the guided steps. | Not applicable. |
| TEST112-005 | 4 scanner steps still waiting (R3 screenshot, log) | Informational | – | Set up in System Settings by the user; the restore stays open for them. | Not applicable. |

## Changes

| Area | Files |
|---|---|
| Outdated Homebrew | `Homebrew/HomebrewClient.swift` (`isOutdatedHomebrewOutput`, `update`), `Restore/RestoreExecutor.swift` (`brewInstall`), `Restore/ErrorClassifier.swift`, `Restore/RestoreModel.swift` (`homebrewOutdated`, `homebrewUpdated`) |
| Administrator copy, damage only with proof | `Restore/RestoreExecutor.swift` (`runPrivilegedFileBatch`, `sourceProblem`, `backupUnreachable`) |
| Retry in the same session | `Restore/SessionStore.swift` (`retryableItemIDs`, `preparedForRetry`), `App/AppModel.swift` (`retryFailed`) |
| Own installers before casks | `Restore/RestorePlanner.swift` (`usesOwnInstaller`), `Localization/Descriptions.swift` (`manualHint`) |
| Check Backup, guide | `Views/VerifyViews.swift`, `App/AppModel.swift` (`openReinstallGuide`), `Reports/ReinstallGuide.swift`, `Reports/RestoreInstructions.swift`, `Localization/InstallerDescriptions.swift` (`completenessSentence`) |
| Guided steps, report | `Views/DeveloperToolsViews.swift`, `Reports/ReportBuilder.swift` |
| Texts | 32 new or changed keys in all 7 languages |
| Tests | `TesterFeedback110Tests` (15 tests), `ReinstallAndBootstrapEdgeTests` (new section numbering); simulated `brew` knows `update` and an outdated state |

## Verification

- `scripts/test.sh`: **672 tests in 110 suites passed** (before: 657).
- On screen, real app (arm64 build) against simulated Macs (`/Users/Shared/MacReplica-Staging/test-data/knut110`),
  driven by accessibility: partial backup made by removing two selected fonts after the scan (the tester's state);
  Check Backup; Reinstall Guide from Check Backup (file checked on disk); restore with an outdated pre-installed
  Homebrew and one cask failing once; Retry Failed Items; quit, relaunch, **Continue**, guided steps; a second restore
  with two synthetic scanner drivers. Screenshots in `~/Desktop/MacReplica-Staging/knut-feedback/`.
- Not available here: an Intel Mac with T2, macOS 14, the tester's real Homebrew, a real administrator prompt for
  `/Library`, a backup on a network share, Microsoft Teams.
- Mutation testing of the changed lines: 42 of 44 valid mutants killed (95.5 %), two pre-existing planner survivors
  documented in [MUTATION_TESTING.md](MUTATION_TESTING.md).
- Incident during on-screen testing: the **Reinstall Guide** button opened the page in the maintainer's Safari; a window
  screenshot of it was deleted at once (it showed private tabs) and the closed browser window was reopened. HTML pages
  are now checked as files on disk.

### Report 3 (TEST112-003, Launchpad)

- Code: `Restore/RestoreModel.swift` (`launchpadDatabaseMissing`, open), `Restore/LaunchpadRestore.swift`,
  `Restore/SessionStore.swift` (`reopeningStaleLaunchpadResult`, applied at the start of every run),
  `Localization/Descriptions.swift`, one new text in 7 languages.
- Tests: `LaunchpadRestoreTests` +2 (missing database waits and is arranged on Continue; a 1.1.2 session with the
  false result is reopened on macOS 14 and left alone on macOS 26). Full suite: **674 tests passed**. Mutation of the
  changed lines: 1 of 1 valid mutant killed (the guard changes produce no mutants with this tool).
- On screen (simulated macOS 15.1, real app): restore onto a Mac without Launchpad database → *Waiting for apps or
  permissions: Launchpad – Not arranged yet …* (`gui-09`); database created, **Continue** → “Launchpad arranged
  (1 pages, 1 folders)” (`gui-10`). Not verified on a real macOS 14.

### Report 4 (1.1.3) and reproduction on GitHub's macOS runners

Reproduced on real runners with a throw-away workflow (`repro/knut-1.1.3`, not merged): macOS 14.8.9 (23J631, the
tester's version, Apple silicon) for Launchpad, macOS 15 Intel for Homebrew. Artifacts in
`~/Desktop/MacReplica-Staging/knut-feedback/repro-*`.

| ID | Observation (source) | Kind | Severity | Root cause (confidence) | Disposition |
|---|---|---|---|---|---|
| TEST113-001 | Launchpad still “not found” after opening Launchpad and Continue; Full Disk Access did not help; Launchpad shows the arranged folders (R4 text, screenshots 1–2, log) | **Contradicts** TEST112-003's assumption (database missing) | Medium | The screenshot shows the 12 folders 1.1.0 arranged on this Mac, so the database exists. On macOS 14.8.9 the runner proved: MacReplica's exact code finds and rewrites it, also from an app started by LaunchServices; **a deleted database is recreated by the Dock at once** – so “open Launchpad once” could never help. What makes MacReplica's check fail on the tester's Mac is **not reproduced and not known**; hypothesis: macOS refuses access (privacy protection – each ad-hoc-signed release counts as a new app; Full Disk Access applies only after reopening). The runner's unapproved probe app could read it, which weakens that hypothesis. | **Fix of the message + diagnostics (tests, on screen):** the advice is gone; *access refused* (`EPERM`/`EACCES`) is reported as such with the Full Disk Access button and “quit and reopen”; the log records `stat`'s answer for each level of the path. **Requires the tester's log** of the next run. |
| TEST113-002 | “There should be a choice to skip / ignore each one of them, or all” (R4 text, screenshot 3) | Enhancement (UX) | Medium | Device steps and waiting data had no Skip. | **Implemented, on screen (simulated):** Skip on every device step and every “Waiting for apps or permissions” row, **Skip All** with a confirmation (`gui-11`–`gui-15`). |
| TEST113-003 | Office had to be installed by hand; the Homebrew cask did not work (follow-up) | Corroborates F-10/F-17 | High (closed) | **Reproduced:** Homebrew 4.2.0 crashes while loading the current `microsoft-office` cask (stack trace in `cask_loader.rb`, nothing installed); after `brew update` the same command installs Office 16.114 correctly on Intel. 1.1.2's update-and-retry covers it; the tester's manual install was most likely made after the 1.1.0 failure (no 1.1.2 log of that step). | **Root cause confirmed, fix (1.1.2) verified with real Homebrew on Intel.** |
| TEST113-004 | (found while reproducing TEST113-003) | **New defect** | High (false success, app that cannot run) | **Reproduced:** Homebrew 4.2.0 fails on `gimp` (`Unexpected method 'command_wrapper'`, exit 1) but still moves the **arm64-only** GIMP into Applications on the Intel Mac and records the cask; after `brew update`, `brew install` says “already installed” and MacReplica reported it as *already installed*. | **Fixed, tests:** a cask whose app has no code for this Mac's processor is reinstalled once with Homebrew and checked again; still wrong → *Built for another processor*; an app not installed by Homebrew is never replaced. The tester's GIMP (and other casks the old Homebrew touched) may be affected: check with `lipo -archs`. |
| TEST113-005 | `lporg` export and how-to supplied “for reference” (R4 attachments) | Informational | – | The export (old Mac, before the reinstall) confirms the layout MacReplica recorded (same folder names). MacReplica does not read `lporg` files. | Not applicable. |

### Report 5 (1.1.4): the Launchpad diagnostic

| ID | Observation (source) | Kind | Severity | Root cause (confidence) | Disposition |
|---|---|---|---|---|---|
| TEST114-001 | Continue in 1.1.4 still skips Launchpad; both logs: *user folder: ok; com.apple.dock.launchpad: No such file or directory* (R5 logs `restore-20261018-020328/020513`, screenshot) | More specific (TEST113-001) | Medium | **Established:** not refused access (the user folder is readable, no `EPERM`) – the folder MacReplica gets from `confstr(_CS_DARWIN_USER_DIR)` has no Launchpad data, while the Dock evidently has a database (Launchpad works, and the Dock recreates a missing one at once). So on this Mac the Dock's database is **in another place**. **Why** the two differ is still not known. The access-refused hypothesis of TEST113-001 is ruled out. | **Fixed, partially verified:** the database the user's own Dock has open (`lsof -a -c Dock -u <uid> -Fn`, read-only) is used when the user's folder has none; the log names both locations. On a real macOS 14.8.9 runner (repro branch): the Dock keeps it open across restarts, and with the user's folder emptied MacReplica's code found and chose the Dock's file. The arrangement itself in that state could only be verified on the tester's Mac. |

### Report 6 (1.1.5)

| ID | Observation (source) | Kind | Severity | Root cause (confidence) | Disposition |
|---|---|---|---|---|---|
| TEST115-001 | Launchpad still not arranged; both logs: *com.apple.dock.launchpad: No such file or directory … the Dock has open: none* (R6 logs `restore-20261018-083254/083538`, screenshot) | More specific (TEST114-001) | Medium | Neither MacReplica's user folder nor a Dock of MacReplica's user has Launchpad. **Reproduced exactly on macOS 14.8.9 by starting MacReplica with `sudo`** (with and without `-H`): root's folder (`/var/folders/zz/…`) has no Launchpad and root has no Dock; started normally by the same user, both are found. **Likely cause: MacReplica runs as another user than the logged-in one on the tester's Mac** (confidence high, not yet confirmed – how he starts MacReplica is not known). Alternative causes (lsof failing, a Dock without its database open) are not excluded. | **Diagnosed and handled (tests, real macOS 14.8.9):** new reason *runs as a different user* with what to do; a warning at the start of every restore; the log now names the user IDs of MacReplica and of the logged-in user, the running Docks, and lsof's exit status and counts. **Question to the tester:** how is MacReplica started (Finder, Launchpad, Terminal, `sudo`)? |
