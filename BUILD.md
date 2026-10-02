# Building MacReplica

MacReplica is a Swift package. It builds with the Xcode Command Line Tools alone; Xcode is optional.
Every command on this page was run from a fresh clone and works as shown.

## Requirements

- A Mac with the **Xcode Command Line Tools** (`xcode-select --install`) or Xcode, providing
  **Swift 6.1 or later** (Xcode 16.3 or later). Check with `swift --version`.
- Git.
- The resulting app runs on **macOS 13 or later** (deployment target in `Package.swift`) and is a
  universal binary for Apple silicon and Intel.

There are no third-party dependencies: the package uses only Apple frameworks (SwiftUI, AppKit,
Foundation, CryptoKit, CommonCrypto, Core Text, ColorSync, Security, os).

## Build, test, package

```sh
git clone https://github.com/itsab1989/MacReplica.git
cd MacReplica
scripts/test.sh                  # build and run all tests (Swift Testing)
scripts/build-app.sh build       # release build → build/MacReplica.app (universal, ad-hoc signed)
scripts/make-dmg.sh build        # → build/MacReplica-<version>.dmg and MacReplica-<version>.dmg.sha256
open build/MacReplica.app
```

| Command | Output |
|---|---|
| `swift build` | debug build of all targets in `.build/` |
| `scripts/test.sh` | runs ~300 tests; adds the Swift Testing plug-in path when only the Command Line Tools are installed |
| `scripts/build-app.sh [folder]` | `MacReplica.app` in `folder` (default `build/`); only an earlier MacReplica build there is ever replaced |
| `scripts/make-dmg.sh [folder]` | compressed disk image with an *Applications* link, plus its SHA-256 file |
| `scripts/smoke-test.sh <app> [version] [simulation-root]` | launches the app and checks that it starts completely |

Options for `build-app.sh` (environment variables):

- `MACREPLICA_ARCHS` — default `arm64 x86_64` (universal); e.g. `MACREPLICA_ARCHS=arm64`.
- `MACREPLICA_BUILD_NUMBER` — default: number of Git commits.
- `MACREPLICA_SIGN_IDENTITY` — a *Developer ID Application* identity; without it the app is signed
  ad hoc (fine for local use, see [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)).

The version comes from `MacReplicaVersion.current` in `Sources/MacReplicaCore/System/SystemInfo.swift`,
the single source of the version number.

## Trying it without touching your own Mac

MacReplica can run against a **simulated Mac** — a folder with synthetic apps, fonts, profiles and
stand-in tools:

```sh
swift build --product MacReplicaSimulator
.build/debug/MacReplicaSimulator create /tmp/macreplica-old source
.build/debug/MacReplicaSimulator create /tmp/macreplica-new fresh
open build/MacReplica.app --args --simulation-root /tmp/macreplica-old
.build/debug/MacReplicaSimulator remove /tmp/macreplica-old
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for failure switches and UI automation helpers.

## Notes

- Testing the Intel build: the Command Line Tools ship Swift Testing for arm64 only, so the test
  suite cannot be built for x86_64 on an Apple silicon Mac. CI runs it natively on an Intel runner.
  The Intel slice of the app can be launched under Rosetta with
  `SMOKE_ARCH=x86_64 scripts/smoke-test.sh build/MacReplica.app`.
- Opening `Package.swift` in Xcode is possible but not used by the maintainer; the scripts above are
  the reference.
- Releases are built by GitHub Actions, not locally — see [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md).
