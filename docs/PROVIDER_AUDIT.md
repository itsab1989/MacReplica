# Provider audit (before the provider expansion)

Date: 2026-10-02 · Code state: commit `2ce7ba5` plus uncommitted addendum work (versioning, updates, permissions,
first credential and application-data providers). This document records what existed *before* the provider research and
expansion, so later claims can be checked against it.

## Architecture as found

| Area | Implementation | Assessment |
|---|---|---|
| Credential providers | `CredentialProvider` protocol (`Sources/MacReplicaCore/Credentials/Credentials.swift`): `detect`, `export`, `destination`, description/risk keys, `isPortable`. Registry `CredentialProviders.all`. | Sound, but only one provider. No `verify()` step beyond byte/permission comparison in the executor, no explicit "re-authentication required" catalogue. |
| Credential types supported | **SSH keys only** (`~/.ssh/id_*`, `config`, `known_hosts`), opt-in, encrypted (AES-256-GCM, PBKDF2-HMAC-SHA256). | Not Git-centric in the architecture. Git is handled as *configuration* (sanitized `~/.gitconfig`), not as a credential. Other ecosystems (AWS, Docker, npm, Kubernetes, gh, cloud CLIs) were not covered at all — neither migrated nor flagged for re-authentication. |
| Application-data providers | `AppDataProfile` list in `AppDataProviders.swift`: Photoshop presets (6 categories), Capture One (Styles, Presets60, KeyboardShortcuts), DaVinci Resolve (LUT, Fusion Templates/Macros). Detection = folder exists and is non-empty. | Profiles are data, the restore engine has no app knowledge (good). Missing: bundle IDs, category classification, compatibility rules, "app must be closed", evidence and verification status. Capture One and Resolve paths were **based on recall, not verified sources**. |
| Generic application data | User-chosen folders (`AppDataScanner`), refuses credential stores and broad folders, skips secret-looking files. | Works; tested end-to-end with synthetic data. |
| Discovery | Read-only, filesystem-based; no dependency on installed tools for detection except Homebrew/mas listing. | Tests use synthetic simulation roots; nothing depends on software installed on the development Mac. |
| Selection UI | Detected provider folders were *added automatically* and could only be removed (minus button). No select-all/none, no grouping by app, no credential choice per provider. | Insufficient for the requested per-item scope selection. |
| Restore | Generic copy with hash comparison, Keep/Replace/Skip, replaced files moved aside, verification by SHA-256, dry run, resume, idempotency. | Solid for file-based data. No check whether the target app is running. Version handling limited to a note when the versioned folder is missing. |
| Logging / security | Component-tagged, redacted logs; secrets never logged; credential vault separate. | OK. |
| Localization | All provider strings localized in 7 languages. | OK. |
| Tests | Provider tests: detection of 3 profiles with synthetic folders, restore into version folder, Git sanitizing, SSH vault round trip, opt-in/opt-out. | Fixture-level only. **No provider was verified at application level** (the apps are not installed on the development Mac and cannot run in CI). |
| Mutation testing | Covers Credentials.swift, DeveloperSettings.swift, PythonAndDataRestore.swift among the critical modules. | Did not yet cover provider selection/compatibility logic (it did not exist). |

## Provider status as found

| Provider | Kind | Status |
|---|---|---|
| SSH keys | Credential (opt-in, encrypted) | Implemented, fixture-tested end to end |
| Git configuration | Configuration | Implemented, fixture-tested end to end |
| Python environments | Development environment | Implemented, fixture-tested with simulated Homebrew Python and pip |
| Adobe Photoshop presets | Application data | Implemented, fixture-tested; path from general knowledge, not yet backed by a cited source |
| Capture One | Application data | Implemented; **paths unverified** |
| DaVinci Resolve | Application data | Implemented; **paths unverified** (LUT location may be system-wide) |
| User-chosen folders | Application data | Implemented, fixture-tested end to end |
| Everything else (VS Code, JetBrains, AWS, Docker, …) | — | Not supported, not flagged |

## What depended on the development Mac

Nothing in detection or tests. The concern was product scope: the first providers were chosen as examples, not from
research. The expansion that follows is research-driven (see `docs/PROVIDERS.md`).
