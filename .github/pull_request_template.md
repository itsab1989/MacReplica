## What and why

<!-- What does this change, and why is it needed? Link the issue if there is one. -->

## How it was tested

- [ ] `scripts/test.sh` passes
- [ ] New or changed behavior has tests (restore logic: also a dry-run expectation)
- [ ] Mutation tests run for changed critical modules (planner, executor, conflict analyzer, clean-up, credentials, verification), if applicable
- [ ] UI changes checked against a simulated Mac; screenshots attached (synthetic data only)

## Checklist

- [ ] New user-facing text added to all seven `Localizable.strings` files
- [ ] No real personal data, paths, keys or tokens in code, tests, fixtures or screenshots
- [ ] No shell commands built from strings; new tools added to the allow-list
- [ ] New app-data providers copy only documented, user-created data and include evidence and tests
- [ ] `CHANGELOG.md` (*Unreleased*) and documentation updated
