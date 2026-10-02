# Release process

Official releases are built, validated and published by GitHub Actions
([`.github/workflows/release.yml`](../.github/workflows/release.yml)). The maintainer's Mac is used
for development only; no local build, packaging or upload is part of a release.

## Making a release

1. Set the new version in `Sources/MacReplicaCore/System/SystemInfo.swift`
   (`MacReplicaVersion.current`, [Semantic Versioning](https://semver.org); pre-releases like
   `1.1.0-beta.1`).
2. In `CHANGELOG.md`, move the *Unreleased* entries into `## [X.Y.Z] - YYYY-MM-DD` and add the link
   reference at the bottom. A test checks that the changelog contains the current version.
3. Commit, then tag and push:
   ```sh
   git tag -a vX.Y.Z -m "MacReplica X.Y.Z"
   git push origin main vX.Y.Z
   ```

Everything else is automatic. To try the pipeline without publishing, run the *Release* workflow
manually (*Actions → Release → Run workflow*): it builds and validates, but does not create a release.

## What the pipeline does

| Job | Runner | Steps |
|---|---|---|
| **Build and package** | macOS 15 (Apple silicon) | checks that the tag matches `MacReplicaVersion.current` and that the changelog has the version · runs all tests · optional signing · builds the universal app (`scripts/build-app.sh`) and the disk image (`scripts/make-dmg.sh`) · optional notarization · writes and verifies SHA-256 files · generates the release notes (`scripts/release-notes.sh`) |
| **Validate** | macOS 14, 15 and 26 on Apple silicon; macOS 15 on Intel | verifies the checksum · `hdiutil verify` · mounts the disk image and checks bundle identifier, version, both architectures, the *Applications* link and the code signature · records the Gatekeeper assessment · copies the app out of the disk image (“install”) and launches it (`scripts/smoke-test.sh`, which waits until startup is complete) |
| **Publish** | Ubuntu | only for tags, only if build and all validations passed: creates the GitHub release with the disk image, its `.sha256` file and the notes |

Release notes consist of the changelog section for the version plus download, checksum,
first-launch, compatibility and support (Ko-fi) information. Tags with a suffix (`v1.1.0-beta.1`)
become pre-releases, which the in-app update check only offers when the user enabled pre-releases.

Mutation testing is not part of the release run (a full run takes hours); a sampled, report-only run happens weekly
in `tests.yml`, and full runs are documented in [MUTATION_TESTING.md](MUTATION_TESTING.md).

## Artifact strategy: one universal disk image

Options considered: (A) one universal app, (B) separate Apple silicon and Intel builds, (C) both.

MacReplica ships **one universal disk image** (option A), because:

- the universal app is small (about 5 MB as a disk image; one architecture would save roughly half),
  so there is no meaningful download cost;
- users do not have to know which processor their Mac has, and a backup made on one kind of Mac is
  usually restored on another — the same download works on both;
- both slices are validated from the same artifact: the validation job installs and launches that
  disk image on Apple silicon (macOS 14, 15, 26) and on Intel (macOS 15), and the complete test suite
  runs natively on Intel in `tests.yml`;
- one artifact keeps checksums, release notes and support simple.

Separate builds remain possible (`MACREPLICA_ARCHS=arm64` or `x86_64` for `build-app.sh`) if a
future reason appears.

## Signing and notarization (prepared, not active)

The project currently has **no Apple Developer Program membership**. Releases are therefore signed
ad hoc (the code signature is valid but not tied to an identity) and are **not notarized**; macOS
Gatekeeper blocks the first launch until the user allows it
([TROUBLESHOOTING.md](TROUBLESHOOTING.md#macos-says-macreplica-cannot-be-opened)). The release
notes say so automatically.

The pipeline is prepared so that signing needs configuration only, no redesign. Add these repository
secrets (*Settings → Secrets and variables → Actions*):

| Secret | Content | Used by |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | Base64 of the exported *Developer ID Application* certificate with its private key | *Import signing certificate* (temporary keychain) |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that `.p12` | same |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` | `build-app.sh` (hardened runtime, timestamp, entitlements) and `make-dmg.sh` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Apple ID, team ID and an app-specific password | `scripts/notarize.sh` (`notarytool submit --wait`, staple, validate) |

When `MACOS_CERTIFICATE_P12` is present the certificate is imported; when `APPLE_ID` and
`MACOS_SIGN_IDENTITY` are present the disk image is notarized and stapled, the checksum is written
after stapling and the release notes drop the first-launch warning. Expected after enabling signing:
the Gatekeeper assessment in the validation job changes from *rejected* to *accepted*; check that
before announcing the release. Certificates and passwords never go into the repository.

## After a release

- Check the release page: assets, checksum, notes.
- The README badges (latest release, downloads) update automatically.
- Start a new *Unreleased* section in `CHANGELOG.md` for the next changes.
