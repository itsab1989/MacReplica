# Validation

MacReplica changes real Macs, so it is validated in two ways: automated tests against **simulated
Macs**, and the **real app** driven on screen against the same simulations. Nothing in this process
touches the developer's own apps, fonts, profiles, Homebrew or settings.

## Simulated Macs

A simulation root is a folder that stands in for `/`:

```
<root>/simulation.json          maps every SystemLayout location into the root
<root>/home/…                   the simulated home folder (~)
<root>/Applications, Library/…  apps, shared fonts and profiles
<root>/System/Library/…         fonts and profiles "provided by macOS" (read-only by convention)
<root>/opt/homebrew/bin/brew …  stand-in tools (brew, mas, xcode-select, pkgutil, mdls, python3.x)
<root>/state/…                  state and failure switches of the stand-in tools
```

The stand-in tools behave like the real ones (output format, exit codes, timing) but only change
files inside the root. The app enters this mode only when launched with
`--simulation-root <folder>`; paths are displayed as on a real Mac, so screenshots and reports
never show the sandbox location.

```sh
.build/debug/MacReplicaSimulator create /tmp/sim-old source   # old Mac with synthetic apps, fonts, profiles, Python, app data
.build/debug/MacReplicaSimulator create /tmp/sim-new fresh    # new Mac with some conflicting files
.build/debug/MacReplicaSimulator set /tmp/sim-new signed-out on   # App Store not signed in
.build/debug/MacReplicaSimulator set /tmp/sim-new offline on      # network errors
.build/debug/MacReplicaSimulator set /tmp/sim-new delay 1.5       # slow installs (progress, ETA, interruption)
.build/debug/MacReplicaSimulator fail-once /tmp/sim-new example-tool "simulated failure"
open build/MacReplica.app --args --simulation-root /tmp/sim-new
```

All test data is synthetic: app bundles with fake executables, TrueType fonts generated in code
(`SyntheticFont`), ICC profiles generated in code with the tags ColorSync requires, fake SSH keys
assembled at runtime so secret scanners do not flag the repository.

## Driving the real app

`tools/ui/` contains small helpers used for on-screen validation:

| Tool | Purpose |
|---|---|
| `launch.sh <root> [lang] [-] [w h]` | quits MacReplica, sets the language, launches the built app against a simulation root and sizes the window |
| `ax.sh click/list/choose/scroll/key` | operates controls through their accessibility identifiers (System Events) |
| `shot.sh <file>` | captures only MacReplica's window (`screencapture -l`), never the desktop |

Dark mode is validated by switching the system appearance temporarily and switching it back.

## On-device validation performed for 1.0.0

Real `MacReplica.app` (release build, universal), macOS 27 developer build, simulated Macs only.

| Scenario | Result |
|---|---|
| Start screen in light and dark mode, English/German/Norwegian, narrow window | Layout correct; with macOS *Keyboard navigation* enabled, Tab reaches the language menu, the three actions and the Ko-fi link (focus ring visible) |
| Scan of the old Mac with progress | 7 apps, Homebrew, App Store app, 9 fonts, 7 profiles, 2 Python environments, app data, guidance |
| Backup selection of fonts and profiles | Individual items with name, version, format, size; *All/None* per group; display profile not pre-selected; one font deselected |
| Backup written and verified | Manifest contains exactly the 8 selected fonts and 6 profiles, `backup_selection` recorded, no absolute home paths |
| Opening the backup on a fresh Mac | Destination check: “37 items in the backup · 35 selected · 6 already on this Mac”; per-component status (ready / already installed / needs a decision / not recommended) |
| Fonts on the destination | identical file → *Already present*; same font under another name → *Already installed*; macOS font → *Provided by macOS*; older version → *Different version*; other font with the same file name → *Keep both*; Type 1 → *Legacy format*, not selected |
| Profiles on the destination | same Profile ID under another name → *Already present*; macOS profile → *Provided by macOS*; same name, other content → *Keep both*; Apple profile no longer shipped → not selected |
| Changing decisions and deselecting | Serif set to *Replace with backup*, Example Mono deselected; conflict sheet asked only about undecided items |
| Dry run | Same decisions as the restore, with explanations per item |
| Restore | 35 successful, 0 failed, 2 skipped; replaced font kept in *Replaced Files*; backup copies installed as `… (MacReplica).ttf/.icm`; nothing written to the simulated `/System`; decision codes in the log |
| Interruption and resume | App killed at step 9 of 38; relaunch shows the resume banner with *Review …*; finished steps locked with their results, saved decisions kept; one pending profile deselected; restore continued in the same session (9 finished, 28 remaining) and the deselected profile was not installed |
| Resume of a restore with credentials | Passphrase asked again (never stored); without it credential steps are marked as skipped |
| App Store not signed in, Python package missing | Clear failure entries with guidance; *Retry Failed Items* succeeded after fixing the cause |
| Check Backup | “The backup is complete and undamaged”, contents per category (Python, app data and developer settings were added to the list after this check) |
| Settings, About, update available (German) | Correct; version and build shown from the single version source |
| Failed previous launch (incomplete startup record) | Safe mode banner names the stage, offers logs, diagnostic report and *Continue Normally* |

Screenshots of these runs (synthetic data only) are in [images/](images/). The final report with the
answers for the font/ICC requirements is [VALIDATION_REPORT.md](VALIDATION_REPORT.md).

## Distribution validation (1.0.0)

| Check | Where | Result |
|---|---|---|
| Fresh clone builds, tests, packages and launches as documented in BUILD.md | developer's Mac (macOS 27, Apple silicon) | passed (298 tests, universal app, disk image, launch) |
| Release built only by GitHub Actions from tag `v1.0.0` | release workflow | passed; assets `MacReplica-1.0.0.dmg` and `.sha256` |
| Checksum of the downloaded disk image | developer's Mac and every validation runner | matches |
| Disk image mounts, contains `MacReplica.app` and an *Applications* link; bundle ID, version, `arm64` + `x86_64`, valid code signature | macOS 14.8, 15.7, 26.6 (Apple silicon), 15.7 (Intel) | passed |
| Install (copy out of the disk image) and launch until startup completes | same four runners | passed |
| Full test suite natively on Intel (x86_64) | GitHub `macos-15-intel` | passed (after making one test architecture-aware) |
| Intel slice under Rosetta: launch and a complete scan in the real app | developer's Mac | passed |
| Download with Safari (quarantine attribute set), install into `/Applications`, launch | developer's Mac | passed — but Gatekeeper is turned off on this Mac (`spctl --status`: assessments disabled), so no warning appeared |
| Gatekeeper assessment of the unsigned app | GitHub runners (Gatekeeper on) | `rejected`, as expected for an unsigned, not notarized app |
| First-launch instructions | Apple Support and Apple Developer documentation | Privacy & Security → *Open Anyway* + login password; Control-click no longer overrides since macOS 15 |
| README badges, links, screenshots, rendering on github.com | browser | checked; all badges resolve to live data |

Not verified: macOS 13 (no machine available), a physical Intel Mac, and the Gatekeeper dialogs on
a Mac with Gatekeeper enabled.

## Automated tests

`scripts/test.sh` runs 296 tests in 43 suites, including end-to-end backup → verify → restore →
second (idempotent) restore on simulated Macs, interruption and resume, failure injection,
privilege denial, path traversal and shell-injection attempts, and localization completeness for
all seven languages.
