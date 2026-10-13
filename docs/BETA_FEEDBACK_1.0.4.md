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
