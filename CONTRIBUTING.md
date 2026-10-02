# Contributing to MacReplica

Thanks for helping! MacReplica changes other people's Macs, so correctness and safety come first.

## Ground rules

- **Never use real user data.** Tests, fixtures, screenshots and logs use synthetic data only
  (`MacReplicaTestSupport`, simulated Macs). No real names, email addresses, paths, serial numbers,
  tokens or keys — not even in examples.
- **No shell.** New external tools must be added to the allow-list in `SystemLayout` and run through
  `CommandRunner` with an argument array. Never build command lines from strings.
- **No secret collection.** Credential support only through an explicit `CredentialProvider` with a
  fixed file list, opt-in and encrypted. No generic scanning for secrets.
- **Never delete what MacReplica did not create.** Use `SafeCleaner`; replaced files are moved aside.
- **Every user-facing string in all languages.** Add keys to all seven `Localizable.strings` files;
  `LocalizationTests` fail otherwise.

## Development

```sh
scripts/test.sh                                 # all tests (needs only the Command Line Tools)
scripts/build-app.sh build                      # app bundle in ./build
.build/debug/MacReplicaSimulator create /tmp/sim source   # a simulated old Mac
open build/MacReplica.app --args --simulation-root /tmp/sim
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for driving the real app against simulated Macs.

## Pull requests

1. Add or update tests for every behavior change; for restore logic also a dry-run expectation.
2. Run `scripts/test.sh` and, for changes in critical modules, the mutation tests for that file:
   `python3 tools/mutation/mutate.py --files Restore/RestoreExecutor.swift` (run it in a copy of the
   repository; it edits the source temporarily).
3. Update `CHANGELOG.md` under *Unreleased* and the documentation.
4. Keep the code style of the surrounding code; comments explain *why*, not *what*.

By contributing you agree that your contribution is licensed under the GPL-3.0.
