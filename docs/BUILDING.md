# Building, signing and releasing

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`) with Swift 6.1 or later. Xcode itself is not needed.

## Build and test

```sh
scripts/test.sh                  # all tests; adds the Swift Testing plug-in path when only the CLT are installed
swift build                      # debug build of all targets
scripts/build-app.sh build       # release build → build/MacReplica.app (universal, ad-hoc signed)
scripts/make-dmg.sh build        # build/MacReplica-<version>.dmg and .dmg.sha256
```

`build-app.sh` reads the version from `MacReplicaVersion.current` in
`Sources/MacReplicaCore/System/SystemInfo.swift` (the single source of the version) and the build
number from `MACREPLICA_BUILD_NUMBER` or the number of Git commits. It only ever replaces an
earlier MacReplica build in the output folder. `MACREPLICA_ARCHS` limits the architectures (default
`arm64 x86_64`).

## Signing and notarization

Without `MACREPLICA_SIGN_IDENTITY` the app is signed ad hoc, which is fine for local use. For
distribution:

```sh
export MACREPLICA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
scripts/build-app.sh build      # hardened runtime, secure timestamp, Packaging/MacReplica.entitlements
scripts/make-dmg.sh build       # signs the disk image as well

export APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=…   # app-specific password
scripts/notarize.sh build/MacReplica-1.0.0.dmg            # notarytool submit --wait, staple, validate
```

Certificates and passwords are never stored in the repository.

## Releasing

1. Update `MacReplicaVersion.current` (Semantic Versioning; pre-releases like `1.1.0-beta.1`).
2. Move the *Unreleased* entries in `CHANGELOG.md` to a section `## [x.y.z] - YYYY-MM-DD`.
   `AddendumTests` check that the changelog contains the current version.
3. Commit, tag `vX.Y.Z` and push the tag. `.github/workflows/release.yml` then
   - checks that the tag matches the app version and the changelog,
   - runs the tests,
   - imports the signing certificate if the secrets are configured,
   - builds the app and the disk image, notarizes and staples it (if configured),
   - publishes a GitHub release with the DMG, its SHA-256 and the changelog section
     (tags with a `-` suffix are marked as pre-release, which the in-app update check only offers
     when the user enabled pre-releases).

### Repository secrets for signed releases

| Secret | Content |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64 of the exported *Developer ID Application* certificate with private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that `.p12` |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | For `notarytool` |

Without these secrets the workflow still publishes an ad-hoc-signed build; the README explains how
users open it (*Privacy & Security → Open Anyway*).

## Continuous integration

`.github/workflows/tests.yml` runs on every push and pull request: localization lint, all tests,
the universal app build and a packaging check; a separate job runs gitleaks and checks that no
personal paths or certificates are committed. A sampled mutation test of the critical modules runs
weekly and on demand.
