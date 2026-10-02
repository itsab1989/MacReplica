# Contributing to MacReplica

Thank you for helping! MacReplica changes other people's Macs, so correctness, honesty about
limitations and safety come before features.

## Ways to help

- **Report a bug** – use the *Bug report* issue template. Attach the diagnostic report
  (*Help → Export Diagnostic Report …*) if you can; please check it first and never attach
  passwords, keys or private files.
- **Ask for support of an app** – use the *Application support request* template and describe which
  data you create in the app and where it lives, ideally with the vendor's documentation.
- **Translate** – improve one of the seven languages or add a new one (see below).
- **Code** – fix a bug or implement an issue; please open or comment on an issue first for larger changes.

## Getting started

1. Fork the repository on GitHub and clone your fork:
   ```sh
   git clone https://github.com/<your-account>/MacReplica.git
   cd MacReplica
   ```
2. Install the Xcode Command Line Tools if needed (`xcode-select --install`); Xcode is optional.
3. Build and test:
   ```sh
   scripts/test.sh                 # all tests
   scripts/build-app.sh build      # build/MacReplica.app
   ```
4. Try the app against a **simulated Mac** instead of your own:
   ```sh
   swift build --product MacReplicaSimulator
   .build/debug/MacReplicaSimulator create /tmp/macreplica-old source
   .build/debug/MacReplicaSimulator create /tmp/macreplica-new fresh
   open build/MacReplica.app --args --simulation-root /tmp/macreplica-old
   .build/debug/MacReplicaSimulator remove /tmp/macreplica-old      # clean up
   ```
   See [docs/VALIDATION.md](docs/VALIDATION.md) for failure switches and UI automation helpers, and
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the code structure.

## Ground rules

- **Synthetic data only.** Tests, fixtures, screenshots and logs must never contain real names, email
  addresses, paths, serial numbers, tokens or keys — not even in examples.
- **No shell.** External tools are added to the allow-list in `SystemLayout` and run through
  `CommandRunner` with an argument array. Never build command lines from strings.
- **No secret collection.** Credentials only through an explicit `CredentialProvider` with a fixed
  file list, opt-in and encrypted. No generic scanning for secrets.
- **Never delete what MacReplica did not create.** Use `SafeCleaner`; files that would be replaced are
  moved aside.
- **Every user-facing string in all languages.** Add new keys to all seven `Localizable.strings`
  files; `LocalizationTests` fail otherwise.
- **Code style:** follow the surrounding code (Swift 6 strict concurrency, small types, comments that
  explain *why*). New behavior needs tests.

## Adding an application-data provider

Providers are data, not code: add an `AppDataProvider` entry to
`Sources/MacReplicaCore/Providers/AppDataCatalog.swift`.

1. **Research first.** Use the vendor's documentation (preferably an official article about moving
   settings or presets). Record it as `Evidence` with title and URL.
2. **Only user-created data.** Select the specific folders or files with settings, presets, styles,
   templates, keymaps and similar. Never add caches, databases, logs, session state, licence files or
   whole Library folders.
3. **Classify every category** (`safe`, `compatibilitySensitive`, `mayContainSecrets`, …). Only `safe`
   data is pre-selected; anything that can contain secrets must be classified so.
4. Set `mustBeClosed` when the app rewrites its data on quit, version-folder patterns for versioned
   apps, and the bundle identifiers.
5. **Test it:** add a synthetic fixture mirroring the documented layout in `MacReplicaTestSupport`
   and tests for detection, backup and restore (see `ProviderCatalogTests`). Status stays
   `fixtureTested` unless a restore into the real app was confirmed.
6. Document the provider in [docs/PROVIDERS.md](docs/PROVIDERS.md).

Apps whose logins live in the Keychain belong in `GuidanceCatalog` (“sign in again”), not in a provider.

## Adding a language

1. Copy `Sources/MacReplicaCore/Resources/Localization/en.lproj` to `<code>.lproj` and translate
   every value. Keep placeholders (`%1$@`, `%1$d`) and use the same number of each.
2. Add a case to `AppLanguage` in `Sources/MacReplicaCore/Localization/Localizer.swift` and the code
   to `CFBundleLocalizations` in `Packaging/Info.plist`.
3. Run `scripts/test.sh --filter LocalizationTests` (completeness and placeholders) and check the
   app in the new language against a simulated Mac — longer words must not be cut off.

## Pull requests

- One topic per pull request; describe what changed and why, and how you tested it.
- `scripts/test.sh` must pass. For changes in critical modules (planner, executor, conflict
  analyzer, clean-up, credentials, verification) also run the mutation tests for that file in a copy
  of the repository: `python3 tools/mutation/mutate.py --files Restore/RestoreExecutor.swift`.
- UI changes: include before/after screenshots made with synthetic data.
- Update `CHANGELOG.md` (*Unreleased*) and the documentation.
- Security issues are not discussed in pull requests or issues — see [SECURITY.md](SECURITY.md).

By contributing you agree that your contribution is licensed under the GPL-3.0.
