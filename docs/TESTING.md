# Testing MacReplica

All tests use [Swift Testing](https://developer.apple.com/documentation/testing) and run with the
Xcode Command Line Tools alone.

```sh
scripts/test.sh                                  # everything (~300 tests, about half a minute)
scripts/test.sh --filter FontConflictTests       # one suite (struct name)
scripts/test.sh --filter "Restore|DryRun"        # suites matching a pattern
```

`scripts/test.sh` is a thin wrapper around `swift test`. When only the Command Line Tools are
installed it sets `MACREPLICA_CLT_TESTING=1`, which adds the plug-in path the Swift Testing macros
need there; with Xcode installed it is not needed.

## No real data, no real system changes

Tests never read or change your own apps, fonts, profiles, Homebrew or settings:

- **Simulated Macs** (`MacReplicaTestSupport.SimulationBuilder`) are sandbox folders that stand in
  for `/`, with synthetic app bundles, a home folder and stand-in versions of `brew`, `mas`,
  `xcode-select`, `pkgutil`, `mdls` and Homebrew's Python that behave like the real tools but only
  change files inside the sandbox. Failure switches simulate offline networks, an App Store that is
  not signed in, broken Homebrew, missing Python packages and slow installs.
- **Synthetic fonts and profiles** are generated in code: `SyntheticFont` writes minimal TrueType
  fonts that Core Text can read; `SimulationBuilder.makeICCProfile` writes ICC profiles that
  ColorSync accepts.
- **Sandboxes clean up after themselves** through MacReplica's own `SafeCleaner`.

## What the suites cover

| Area | Suites (examples) |
|---|---|
| Manifest format, compatibility, migration | `ManifestTests` |
| Inventory: apps, Homebrew, App Store, fonts, profiles | `InventoryTests`, `HomebrewTests`, `MatchingTests` |
| ICC and Git configuration parsers | `ICCHeaderTests`, `ICCComputedIDBoundaryTests`, `GitConfigSanitizerTests` |
| Python environments | `PythonTests` |
| Application data and providers | `ApplicationDataTests`, `ProviderCatalogTests`, `ProviderTests`, `AppDataScannerEdgeTests` |
| Credentials (vault, providers, opt-in) | `CredentialTests`, `FileCredentialProviderTests`, `CredentialEdgeTests` |
| Restore planning and selection | `RestorePlannerTests`, `SelectionPlannerTests`, `TwoStageSelectionTests` |
| Restore execution, dry run, resume | `RestoreExecutionTests`, `DryRunTests`, `ResumeTests`, `ExecutorPredictionTests`, `ExecutorEdgeTests` |
| Font and profile conflict decisions | `FontConflictTests`, `ProfileConflictTests`, `FileDecisionRestoreTests`, `DestinationIndexTests` |
| End-to-end: backup → verify → restore → second restore | `EndToEndTests` |
| Failure modes (offline, signed out, denied rights, damaged backups, …) | `FailureModeTests`, `ClassifierAndProgressTests` |
| Security: no shell, path traversal, redaction, privileged operations | `SecurityTests`, `CommandRunnerEdgeTests`, `PathResolutionTests` |
| Verification and clean-up | `VerificationTests`, `VerificationEdgeTests`, `CleanupTests`, `CleanupEdgeTests` |
| Versions, updates, permissions, diagnostics | `VersionAndUpdateTests`, `VersionEdgeTests`, `PermissionTests`, `PackageAndDiagnosticsTests` |
| Localization (all seven languages complete, placeholders match) | `LocalizationTests` |
| Reports | `ReportTests` |

## What automated tests cannot cover

- Real administrator prompts (`osascript … with administrator privileges`) and writing into the real
  `/Library` — the tests use a privileged executor that performs the same operations in the sandbox.
- The real Mac App Store, Homebrew's servers and Apple's Command Line Tools installer.
- The SwiftUI interface. It is validated on screen against simulated Macs
  ([VALIDATION.md](VALIDATION.md)).

## Mutation testing

[`tools/mutation/mutate.py`](../tools/mutation/mutate.py) mutates the critical modules one change at
a time and checks that the covering tests fail. Method, current results (85.5 % of 712 mutants
killed, every module at or above its threshold) and the list of remaining mutants are in
[MUTATION_TESTING.md](MUTATION_TESTING.md). Run it in a copy of the repository — it edits source
files temporarily.

## Continuous integration

`.github/workflows/tests.yml` runs on every push and pull request: the full suite on Apple silicon
(macOS 15) and natively on Intel (macOS 15), the universal app and disk image build with a checksum
check and a launch test, and a secret scan (gitleaks over the full history). A sampled mutation test
runs weekly. The release workflow additionally installs and launches the release disk image on
macOS 14, 15 and 26 and on Intel before publishing ([RELEASE_PROCESS.md](RELEASE_PROCESS.md)).

The Command Line Tools ship Swift Testing for arm64 only, so on an Apple silicon Mac the suite cannot
be built for x86_64 locally; the Intel app can still be launched under Rosetta with
`SMOKE_ARCH=x86_64 scripts/smoke-test.sh build/MacReplica.app`.
