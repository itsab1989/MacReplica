# Failure-mode review

How MacReplica behaves when something goes wrong. Each row is covered by automated tests
(`FailureModeTests`, `RestoreTests`, `SecurityTests`, `FontAndProfileConflictTests`, …) unless noted.
General principle: **one failing item never stops the restore**; it is recorded with a category,
items that depend on it are skipped with a reason, everything else continues, and the session is
saved after every step.

## Backup (old Mac)

| Failure | Behavior |
|---|---|
| Homebrew not installed or broken | Inventory continues; warning shown; apps are still matched via the cask catalog where possible. |
| Homebrew cask catalog unavailable (offline) | Cached copy used if recent; otherwise matching falls back to “install manually” and a warning is shown. |
| `mas` missing or App Store list fails | App Store apps are still detected from their receipts; warning shown. |
| A location is not readable (privacy protection) | Recorded as *No permission* with a button to the privacy settings. Full Disk Access is only needed for Mail and Microsoft Office data; those restore steps wait for it and continue once it is granted. |
| A selected file cannot be read or changes during the backup | Left out, listed in `backup_issues`, the backup is marked *partial*; refused secret files are listed separately and do not make a backup partial. |
| Destination not writable / disk full | Backup fails with an explanation; the incomplete folder carries MacReplica's marker and can be removed safely. |
| Font or profile unreadable on the old Mac | Still backed up as a file, without identity; on the new Mac it is shown as *Not compatible*. |

## Opening a backup (new Mac)

| Failure | Behavior |
|---|---|
| `manifest.json` missing or unreadable | “Backup cannot be read” with technical details; nothing is changed. |
| Manifest from a newer MacReplica major version | Refused with a request to update MacReplica. Newer minor versions load; unknown keys are ignored. |
| Checksum file mismatch | Backup marked damaged. |
| Individual files damaged or missing | Listed; those items are skipped as *Backup file damaged*, everything else restores. |
| Backup from another architecture | Notice; apps without a matching architecture are skipped with an explanation; Rosetta noted where needed. |

## Restore

| Failure | Category / behavior |
|---|---|
| Command Line Tools installation cancelled or too slow | `commandLineToolsUnavailable`; Homebrew and everything that needs it are skipped as dependent; files and app data still restore. |
| Homebrew download fails, signature/team ID/checksum wrong | `homebrewUnavailable`; nothing is installed from an unverified package. |
| Network offline | `network` with guidance; *Retry Failed Items* later. |
| Package not found / renamed | `packageNotFound`; the app is listed with its vendor website. |
| App already installed (outside Homebrew) | Detected before installing → *Already installed*, no reinstall. |
| Not signed in to the App Store | `appStoreNotSignedIn` with guidance; retry after signing in. |
| Administrator password cancelled | `adminRightsDenied` only for the items that needed it. |
| Disk full | `diskFull`. |
| Tool hangs | Timeout per command; the process is terminated → `timeout`. |
| Installed but verification fails | `verificationFailed` — a successful exit code alone never counts. |
| Third-party tap not allowed | Tap and its packages skipped with the reason. |
| Python version unavailable / packages missing | `pythonVersionUnavailable` / `pythonPackagesIncomplete` (environment created, missing packages named); pinned versions are retried one by one, then unpinned. |
| Existing different environment at the target path | `pythonEnvironmentConflict`; nothing is overwritten. |
| App whose data is restored is running | `applicationRunning`; quit the app and retry. |
| Credential vault with a wrong passphrase | `credentialCannotBeOpened`; without a passphrase credential steps are skipped (also after a resume — the passphrase is asked again, never stored). |
| Font or profile: identical / equivalent / provided by macOS | No copy, reported as already present (see [FONTS_AND_PROFILES.md](FONTS_AND_PROFILES.md)). |
| Font or profile: different file or version | Decision required; default never overwrites. Replaced files are moved to *Replaced Files*. |
| Font or profile unreadable by this macOS | Skipped as *Not compatible*. |
| Restored font/profile not accepted by macOS | `verificationFailed` (Core Text / ColorSync check after copying). |
| User clicks *Stop* | The running step is left unfinished (not marked failed) and runs again on resume. |
| App crash, power loss, forced quit | Session saved after every step; next launch offers *Continue* or *Review …*; finished steps are not repeated. |
| MacReplica crashed during startup | Next launch starts in safe mode (no automatic session loading, English UI) with logs and a diagnostic report. |
| Running the same restore twice | Second run reports everything as already present and installs nothing (idempotent). |

## Hostile input

| Attack | Behavior |
|---|---|
| Package names with shell metacharacters | Passed as single arguments, never through a shell (tested with `$(…)`, `;`, backticks). |
| Paths with `..`, absolute paths, `~` | Refused by `PathSafety`; the item is reported as damaged. |
| Executables outside the allow-list | `CommandPolicy` refuses to start them. |
| Clean-up of a folder without MacReplica's marker | Refused. |

## Known residual risks

- The App Store and Homebrew themselves can change behavior between versions; MacReplica classifies
  unexpected output as `unknown` and shows the technical detail.
- Data of apps that change their storage format between major versions may not be readable by a
  newer app version; such data is marked *compatibility-sensitive* and not pre-selected.
- Font activation in apps that are already running is not verified (they may need a relaunch).
