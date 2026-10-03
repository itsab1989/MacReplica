# Mutation testing

Mutation testing checks whether the tests would notice if the code were wrong: the source is changed
in small ways (*mutants*) and the covering tests run against each change. A failing test *kills* the
mutant; if all tests still pass, the mutant *survived* and shows a gap.

Swift has no mutation tool that works with plain SwiftPM and the Command Line Tools, so MacReplica
ships a small, dependency-free runner: [`tools/mutation/mutate.py`](../tools/mutation/mutate.py).

## Method

- **Operators:** relational (`==`↔`!=`, `<`↔`<=`, `>`↔`>=`), logical (`&&`↔`||`, removing `!`),
  boolean literals, `contains` negation, `isEmpty` negation, `+ 1`/`- 1`, `+=`→`-=`, removing
  `continue`, `first`→`last`, `min`↔`max`. Strings, comments and test expectations are never mutated.
- **One mutant at a time:** the file is changed, the package rebuilt (mutants that do not compile are
  *invalid* and do not count), the module's covering test suites run (`config.json`), and the file is
  always restored — also on Ctrl-C or errors.
- **Hangs count as killed:** each test run has a timeout; the whole process group is stopped, so a
  mutant that loops forever cannot leave test processes behind.
- **Isolation:** tests run against mutants use their own temporary folder (`.build/mutation-tmp`),
  because a mutant can break the clean-up code itself.
- **Safety:** the runner refuses suites that do not exist (a filter that matches nothing would let
  every mutant survive) and checks that the covering tests pass on the unmodified code first.
- **Parallel shards:** `--shard K --shards N` processes every N-th mutant; run each shard in its own
  copy of the repository and combine the results with `--merge`.
- **Thresholds:** 80 % by default, lower where documented in `config.json`.

```sh
# in a copy of the repository (the runner edits files temporarily)
python3 tools/mutation/mutate.py --files Restore/FileConflictAnalyzer.swift --report mutation-report
python3 tools/mutation/mutate.py --shard 0 --shards 6 --report r0   # … shards 1–5 in other copies
python3 tools/mutation/mutate.py --merge r0 r1 r2 r3 r4 r5 --report merged --check
```

## Results

Run on 2026-10-02 (macOS 27, Swift 6.4, 6 shards). First full run: **68.5 %** (488 of 712 valid
mutants killed, 6 of 18 modules at threshold). The surviving mutants were analysed one by one; where
they showed a real gap, tests were added (suites `SelectionPlannerTests`, `DestinationIndexTests`,
`ExecutorPredictionTests`, `ExecutorEdgeTests`, `GitConfigSanitizerTests`, `ICCHeaderTests`,
`ICCComputedIDBoundaryTests`, `VersionEdgeTests`, `VerificationEdgeTests`, `CleanupEdgeTests`,
`SessionAndPrivilegeEdgeTests`, `CredentialEdgeTests`, `AppDataScannerEdgeTests`,
`CommandRunnerEdgeTests`) and only the survivors were tested again (`--only-survivors`; added tests
can only kill more mutants).

Overall mutation score: **85.5 %** (609 of 712 valid mutants killed)

| Module | Killed | Survived | Invalid | Excluded | Score | Threshold | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| `Model/ManifestIO.swift` | 4 | 0 | 0 | 0 | 100.0 % | 80 % | ✅ |
| `Matching/Matcher.swift` | 41 | 10 | 4 | 0 | 80.4 % | 80 % | ✅ |
| `Restore/RestorePlanner.swift` | 60 | 11 | 12 | 0 | 84.5 % | 80 % | ✅ |
| `Restore/FileConflictAnalyzer.swift` | 67 | 12 | 5 | 0 | 84.8 % | 80 % | ✅ |
| `Restore/RestoreExecutor.swift` | 96 | 25 | 9 | 1 | 79.3 % | 75 % | ✅ |
| `Restore/SessionStore.swift` | 8 | 1 | 0 | 0 | 88.9 % | 80 % | ✅ |
| `Backup/BackupVerifier.swift` | 24 | 1 | 4 | 0 | 96.0 % | 80 % | ✅ |
| `Support/SafeCleaner.swift` | 36 | 2 | 1 | 0 | 94.7 % | 80 % | ✅ |
| `System/CommandRunner.swift` | 24 | 0 | 0 | 2 | 100.0 % | 70 % | ✅ |
| `Restore/PrivilegedExecutor.swift` | 8 | 1 | 1 | 0 | 88.9 % | 80 % | ✅ |
| `Restore/ErrorClassifier.swift` | 12 | 0 | 0 | 0 | 100.0 % | 80 % | ✅ |
| `Credentials/Credentials.swift` | 28 | 1 | 1 | 0 | 96.6 % | 80 % | ✅ |
| `Inventory/DeveloperSettings.swift` | 38 | 3 | 2 | 0 | 92.7 % | 80 % | ✅ |
| `Support/UpdateChecker.swift` | 38 | 5 | 3 | 0 | 88.4 % | 80 % | ✅ |
| `Restore/PythonAndDataRestore.swift` | 63 | 17 | 1 | 1 | 78.8 % | 75 % | ✅ |
| `Providers/AppDataProviders.swift` | 14 | 2 | 2 | 0 | 87.5 % | 80 % | ✅ |
| `Inventory/AppDataScanner.swift` | 21 | 3 | 4 | 0 | 87.5 % | 80 % | ✅ |
| `Inventory/ICCProfile.swift` | 27 | 9 | 1 | 0 | 75.0 % | 75 % | ✅ |

### Display profiles and Python saved copies (2026-10-03)

Run on 2026-10-03 (macOS 27, Swift 6.4, 6 shards) for the display-profile and saved-copy modules
and the Python/app-data restore, after the first run left them below threshold
(`PythonAndDataRestore.swift` 70.5 %, `DisplayProfiles.swift` 52.2 %, `DisplayProfileRestore.swift`
76.9 %, `PythonPreservation.swift` 59.1 %). Tests were added (suites `PythonRestoreEdgeTests`,
`PythonPreservationEdgeTests`, `DataRestoreEdgeTests`, and a simulated-manager test in
`DisplayProfileTests`), then the four modules were run again in full.

| Module | Killed | Survived | Invalid | Excluded | Score | Threshold | Result |
|---|---:|---:|---:|---:|---:|---:|---|
| `Restore/PythonAndDataRestore.swift` | 102 | 0 | 3 | 4 | 100.0 % | 75 % | ✅ |
| `ColorProfiles/DisplayProfiles.swift` | 14 | 0 | 2 | 2 | 100.0 % | 80 % | ✅ |
| `Restore/DisplayProfileRestore.swift` | 10 | 0 | 0 | 3 | 100.0 % | 80 % | ✅ |
| `Python/PythonPreservation.swift` | 20 | 0 | 2 | 2 | 100.0 % | 80 % | ✅ |

Gaps these survivors showed (now covered): the uv Python download's architecture (`aarch64` vs
`x86_64`), the preference for the exact pyenv version over Homebrew's Python and for Homebrew's uv,
the uv lock-file path and its notes, predictions for existing environments (other version, missing
packages, complete), the "project folders are never created" rule, nested folders of tool-managed
environments, no per-package retry after disk-full or timeout, the pip output shown after the last
attempt, the minimum macOS of a saved copy (including the exact boundary), the highest minimum of
all native files and `.dylib` files, local and editable packages, import-name validation and
de-duplication, app-data conflict/identical/damaged predictions, damaged backup files never being
copied, apps running under a secondary bundle identifier, credential permissions (`0` → `0o600`,
public files staying readable), one moved-aside note per credential folder, and the simulated
display manager refusing disconnected displays and failed writes.

**Outside the scope on purpose:** `LiveDisplayColorManager` (ColorSync and IOKit) is in its own file,
`ColorProfiles/LiveDisplayColorManager.swift`, which is not a mutation module. It is the only code
that reads and changes the real Mac's display settings; a test would change the user's display
profile assignments. Tests and the simulation use `SimulatedDisplayColorManager`, and the live
manager is checked by hand in the real app (assign a profile, compare with System Settings ›
Displays).

Exclusions (`config.json`; an exclusion can now name one `operator`, so other mutants on the same
line still count): parameter defaults that every caller overrides (`isConnected`,
`referencesLocalPaths`), `first` → `last` where at most one element can match (profile records by
original path, displays by their unique ColorSync ID) or any match is correct (identical profile
copies, which running bundle identifier the message names), sorting a set, the credential folder
whose parent is always the home folder, and the moved-aside check's fallback value that is never
read.

### Gaps the first run revealed (now covered)

- Deselected Python environments and app-data folders, and credentials without opt-in, could have
  been planned — nothing would have noticed (`SelectionPlannerTests`).
- Homebrew prerequisites, duplicate plan entries and plan order were unchecked.
- The destination index was not checked for files installed during the same run, nor for being
  re-read on every check (so a second copy of a font in the backup could have been installed twice).
- The replace target for same-name profiles, equivalent fonts at the same path, macOS-provided
  overrides and the quick check of the restore selection were untested.
- App Store apps without bundle information, installed apps found by bundle identifier, the exact
  administrator reason text and keeping replaced shared files were untested.
- The new ICC identity fields (creator, manufacturer, model, creation date, stored and computed Profile
  ID) and the Git configuration sanitizer had no exact-output tests.
- Semantic-version edge cases (numeric vs alphanumeric pre-release identifiers, empty components),
  verification of files outside the manifest, clean-up of links to protected folders and dangling
  links, and the "most recent unfinished session" rule were untested.

### Remaining surviving mutants (103)

The survivors of the restore planner, conflict analyzer, restore executor and ICC parser were
reviewed one by one; those of the other modules (mainly the matcher and the Python/app-data restore,
which met their thresholds in the first run) were reviewed from the list. They fall into these groups:

| Group | Examples | Why no test kills them |
|---|---|---|
| Equivalent: choice between equally valid matches | `first` → `last` when IDs, tokens or PostScript names are unique | the result is the same element |
| Equivalent: repeated bounds checks | ICC `offset + 4 <= count` → `<`, `count > 0` → `>= 0` | a later check or the empty-text rule gives the same result |
| Equivalent: values that are always overwritten | `checkPackages` default (the dry run always sets it), `privilegedBatchDone` (every item already has a batch result) | the mutated value is never read |
| Equivalent: sort ties | `>` → `>=` in comparisons of distinct dates or names | no ties occur |
| Not testable without real system services | administrator dialog parsing inside the AppleScript, HTTP status of the live GitHub API, Command Line Tools timeout at the exact deadline | would need real admin rights, network or timing |
| Low value | error category for a disk-full copy outside the administrator path, cosmetic progress values | documented, not worth a dedicated test |

Per module: `BackupVerifier.swift` 1, `Credentials.swift` 1, `AppDataScanner.swift` 3, `DeveloperSettings.swift` 3, `ICCProfile.swift` 9, `Matcher.swift` 10, `AppDataProviders.swift` 2, `FileConflictAnalyzer.swift` 12, `PrivilegedExecutor.swift` 1, `PythonAndDataRestore.swift` 17 (0 since the run of 2026-10-03, see above), `RestoreExecutor.swift` 25, `RestorePlanner.swift` 11, `SessionStore.swift` 1, `SafeCleaner.swift` 2, `UpdateChecker.swift` 5.

The complete list of every remaining mutant (file, line, operator, original and mutated line) is in
[mutation-survivors.md](mutation-survivors.md); re-run the runner as described above to reproduce it.

