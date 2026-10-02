# Changelog

All notable changes to MacReplica are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and MacReplica uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The backup format has its own version
(`manifest_version`), independent of the app version.

## [Unreleased]

## [1.0.0] - 2026-10-02

First public release.

### Added
- **Create Backup (inventory):** applications in `/Applications` and `~/Applications` with name, version, bundle
  identifier, vendor, architecture and installation source; Homebrew formulae, casks, taps and version; Mac App Store
  apps; fonts and ICC profiles from the personal and shared libraries with their identity (PostScript names and
  version; ICC description, class and computed Profile ID).
- **Two-stage selection:** choose fonts, profiles, Python environments, app data and credentials for the backup on the
  old Mac, then choose again on the new Mac what is actually restored — without making the backup again. The restore
  selection shows the state of the new Mac for every item and is kept when a restore is interrupted; it can be
  reviewed before continuing.
- **Destination-aware font and ICC profile restore:** identical or equivalent files are recognized (also under other
  names), fonts and profiles that macOS provides are kept, different versions and same-name files need a decision
  (*Keep this Mac's version*, *Replace with backup*, *Keep both*, *Skip*), display profiles of the old Mac are never
  restored, legacy and unreadable formats are not pre-selected. Restored files are verified by Core Text and
  ColorSync. Based on documented and tested macOS behavior (docs/FONTS_AND_PROFILES.md).
- **Homebrew matching** for apps installed by hand, with conservative automatic matching and a choice when several
  packages could fit.
- **Python environments:** interpreters (Homebrew, pyenv, python.org) and virtual environments are recorded and rebuilt
  on the new Mac from their package lists instead of being copied.
- **Application data:** providers for 15 apps (Visual Studio Code, Cursor, Sublime Text, JetBrains IDEs, Xcode, BBEdit,
  iTerm2, Adobe Photoshop, Camera Raw, Capture One, DaVinci Resolve, Blender, After Effects, Keyboard Maestro, Alfred)
  with data classification, evidence and verification status, plus folders chosen by the user. Caches, databases and
  credential stores are never copied; apps that rewrite their data must be closed while restoring.
- **Sign-in guidance:** detects tools and services that need a new login (GitHub CLI, Docker, cloud CLIs, Adobe Creative
  Cloud, Microsoft 365, Dropbox, Slack, …) or a manual export, and explains what to do.
- **Developer settings:** sanitized Git configuration; the email address only on request.
- **Encrypted credentials (opt-in):** providers for SSH keys, AWS credentials, Git credentials, npm, Kubernetes and
  Terraform, each selectable on its own, encrypted with AES-256-GCM using a key derived from a user-chosen passphrase
  (PBKDF2-HMAC-SHA256, 600,000 iterations). Passwords, tokens, cookies, browser data and the Keychain are never backed
  up, and there is no generic scan for secrets.
- **Self-contained backup package** with manifest, checksums for every file, localized restore instructions, reports and
  logs; partial backups are clearly marked.
- **Restore** with automatic installation of the Command Line Tools and Homebrew (verified, signed package), Homebrew
  casks and formulae, App Store apps, Python environments, app data, Git settings, fonts and profiles.
- **Dry Run** with the same decisions as the restore, **resume** after interruptions (the credential passphrase is
  asked again), **retry** of failed items, verification of every step and language-independent decision codes in
  the logs.
- **Check Backup** to verify a backup's integrity at any time.
- **Permission-aware inventory** that reports locations macOS did not allow MacReplica to read.
- **Check for Updates** via GitHub Releases (information only, no automatic installation).
- **Diagnostics:** component-tagged, privacy-redacted logs, a startup record with safe mode after a failed launch, and an
  exportable diagnostic report.
- Seven languages: English, German, Norwegian Bokmål, French, Spanish, Italian and Dutch.
- Universal app for Apple silicon and Intel, macOS 13 or later.

[Unreleased]: https://github.com/itsab1989/MacReplica/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/itsab1989/MacReplica/releases/tag/v1.0.0
