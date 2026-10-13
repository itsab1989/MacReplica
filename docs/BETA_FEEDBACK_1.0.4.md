# Beta feedback on MacReplica 1.0.4 (Intel MacBook Pro 2019, preparing a macOS reinstall)

Investigation log and checklist for the issues reported by the beta tester on 1.0.4, plus the Cakebrew follow-up.
Each item records what the code actually did (baseline), the root cause, the fix and how it was verified.

Status categories: **Verified** (tested in the real relevant environment) · **Partially verified** · **Simulated**
(mocks / synthetic data) · **Not verified** · **Unsupported**.

Baseline: `main` at 5f29144 (MacReplica 1.0.4, manifest version 3), SwiftPM app, Swift Testing suites,
7 languages (en, de, es, fr, it, nb, nl).

## Findings while establishing the baseline

| # | Area | Baseline behaviour (read from code, reproduced where noted) | Root cause | Severity |
|---|---|---|---|---|
| B1 | Own installers | Installers chosen with “Use my installer” and copied into the backup were **not written to `manifest.json`**; on the new Mac they were never offered. Reproduced: encoding a manifest dropped `own_installers` (test fails without the fix). | `AppRecord.CodingKeys` lists the stored keys explicitly and missed `ownInstallers` and `otherCopies` (added in 1.0.2). The existing test used the in-memory manifest, not the file. | Critical (silent loss of the offline route after erasing) |
| B2 | Own installers | Choosing a `.app`, an unsupported file, a disk image with a licence agreement or a damaged file produced **no visible reaction**; the reason was only logged. | `inspectOwnInstallers` caught every inspection error and only wrote a log line; `.app` was not a supported type. | High |
| B3 | Own installers | Installers whose app is not signed with a Developer ID (ad-hoc signed DisplayCAL 3.9.19, ChromIQ) were marked “Not signed by the app's developer: MacReplica will not open it” and could never be used. | `InstallerArchive.matchesDeveloper` requires a trusted Developer ID signature; there was no informed-consent path. | High |
| B4 | Sensitive files | “1 file was left out because it looks like a password, key or cookie file” with no way to see which file, where, or why. | `BackupIssue(.refusedSensitive)` paths were stored but never listed in the UI or reports; the backup counted as “complete”. | High |
| B5 | Sensitive files | The name rules also refused encrypted KeePass databases (`.kdbx`), public certificates (`.cer`, `.crt`), `.asc` files and any file with “token”, “secret”, “credential” or “password” in its name, without classification. | Single regex list, no classes, no opt-in. | Medium |
| B6 | Help | Hover-only help (`.help`) on a handful of controls; “In backup”, the installer status, the source picker, taps, conflicts and most restore options had none. Nothing visible tells the user that help exists. | No visible help affordance; hover tooltips require pointer rest and an active window. | Medium |
| B7 | Homebrew matching | Apps whose cask was **disabled** (DisplayCAL: “does not pass the macOS Gatekeeper check”, disabled 2026-09-01) were shown as plain “install yourself” without explanation. | `Matcher` and `DownloadSourceFinder` drop disabled casks silently. | Medium |
| B8 | Homebrew matching | Apps distributed through a vendor's own tap (ChromIQ: `itsab1989/chromiq`) were never matched when installed from the DMG. | Matching uses only the public catalog (`formulae.brew.sh`). | Medium |
| B9 | Homebrew restore | Casks from third-party taps are skipped unless the tap is ticked; the tap list did not say which apps need it. Apps *matched* to a tap cask got no tap dependency. | `TapSection` lists tap names only; `RestorePlanner` adds tap dependencies only for installed casks/formulae. | Medium |
| B10 | Companion apps | DisplayCAL's seven companion apps (`/Applications/DisplayCAL/*.app`, bundle IDs `net.displaycal.DisplayCAL-*`) were listed as seven independent apps to install. | No relationship model between apps. | Low/Medium |

(Continued below as the work proceeds.)

### Additional findings from the tester's logs (2026-10-13)

| # | Area | Baseline behaviour | Root cause | Severity |
|---|---|---|---|---|
| B11 | Backup | The whole backup was removed with `verificationFailed(unsafePath("application-data/appdata-dfa452475bc3/~$Normal.dotm"))`. Reproduced exactly (same folder ID) in a test and on screen with the released 1.0.4. | Word's owner file `~$Normal.dotm` (exists while Word is open) was copied; the verifier refuses relative paths starting with `~`, so verification of the finished backup failed. | Critical |
| B12 | Backup | Files of a folder deleted between scan and save were reported as “unreadable”. | `BackupWriter.copy` had only one reason for every failure. | Low |
| B13 | Own installers | OnyX, SuperDuper!, Krita, Murus images reported as “unreadable”. Reproduced with the real OnyX and SuperDuper! images: `hdiutil attach` ends with “attach canceled”. | `hdiutil imageinfo -plist` reports the licence agreement under `Properties`; MacReplica only looked at the top level, so the attach waited for an answer and was cancelled. The same bug made the restore fail instead of opening such an image in Finder. | High |
| B14 | Restore screen | “The backup is complete and stays unchanged” was shown for every backup, also partial ones. | Fixed sentence. | Medium |
| B15 | Sensitive files | Keynote presentations (`.key`, zip format) were refused as “key” files. | Name-only rule. | Medium |

## Validation log

### V1 – Tester's failed backup (B11, B12) — **Verified** (real app, simulated Mac)
Simulated Mac `knut-src` (Office templates with `~$Normal.dotm`, own folder `~/displaycal-py3` deleted after adding it).
- Released 1.0.4 (`/Applications/MacReplica.app`): “The backup could not be saved”; log identical to the tester's
  (`Not included (unreadable): ~/displaycal-py3/…`, `verificationFailed(unsafePath(".../~$Normal.dotm"))`).
  Screenshot `knut-before-1.0.4-backup-failed.png`.
- New build: “Backup saved with gaps”, the four files listed as “no longer there – deleted or moved after the scan”,
  71 files verified; `shasum -c checksums/SHA256SUMS` passes for every file; `Normal.dotm` in the backup, no `~$` file.
- Restore onto a fresh simulated Mac: 61 succeeded, 0 failed, 4 waiting (apps to install by hand); `Normal.dotm`
  byte-identical to the backup.
- Tests: `BackupRobustnessTests` (fail without the fix with the tester's exact error), `VerificationAndCleanupTests`.

### V2 – Installer selection feedback, licence images, unverified installers (B2, B3, B13) — **Verified** (selection, real app) / **Simulated** (restore of a licence image)
Chosen for “Quill Writer” in the real app: a disk image with a licence agreement, a damaged `.dmg`, a `.txt`, and
`Pixel Forge.app` (a different app). Every file showed a result: “contents not checked (licence agreement) … not
used unless you confirm it”, “damaged, incomplete … or encrypted”, “not an installer MacReplica can use”,
“contains a different app (com.example.pixelforge)”. After confirming the licence image, the status names exactly
what is checked (“only its checksum … proves it is the same file – not that it is safe”) and the next action
(opened in Finder for the user). Manifest: `own_installers` with `user_approved_unverified: true`,
`has_license_agreement: true`, the file in `installers/…`, checksums pass.
The restore of a licence image is covered by `OwnInstallerTests.imagesWithALicenceAgreementAreRecognised`
(hdiutil with a synthetic licence agreement); it was not opened on screen, because that would mount an image in the
real Finder.

### V3 – Files not in the backup, completeness, KeePassXC, VueScan (B4, B5, B14, B15) — **Verified** (real app, simulated Mac, synthetic files)
Synthetic KDBX 4.1 header files (no real database), a `.keyx` key file, a Keynote-format `.key`, a KeePassXC cache
file remembering `~/Sync/Passwords.kdbx`, VueScan `.ini` files.
- Selection screen: “Not in this backup: 3 files” with name, path, “Looks like: encrypted KeePass password database
  (KDBX 4.1) · recognised by its file format”, advice, Include …/Show in Finder; help popover opened by click.
- `Family.kdbx` included on request; completion screen: “Complete, except 2 files left out on purpose”, both listed,
  the included database listed separately; reports list the same.
- Restore: 64 succeeded, 0 failed; `Family.kdbx` byte-identical, the key file not restored, `Talk.key` restored,
  VueScan `vuescan.ini` and `Film negatives.ini` restored (not the log), KeePassXC settings restored.
