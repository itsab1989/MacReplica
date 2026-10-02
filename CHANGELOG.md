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
  apps; fonts and ICC profiles from the personal and shared libraries.
- **Homebrew matching** for apps installed by hand, with conservative automatic matching and a choice when several
  packages could fit.
- **Python environments:** interpreters (Homebrew, pyenv, python.org) and virtual environments are recorded and rebuilt
  on the new Mac from their package lists instead of being copied.
- **Application data:** folders chosen by the user, plus profiles for Adobe Photoshop presets, Capture One styles and
  presets, and DaVinci Resolve LUTs and Fusion templates. Credential files are always left out.
- **Developer settings:** sanitized Git configuration; the email address only on request.
- **Encrypted credentials (opt-in):** SSH keys can be included, encrypted with AES-256-GCM using a key derived from a
  user-chosen passphrase (PBKDF2-HMAC-SHA256). Passwords, tokens, cookies and the Keychain are never backed up.
- **Self-contained backup package** with manifest, checksums for every file, localized restore instructions, reports and
  logs; partial backups are clearly marked.
- **Restore** with automatic installation of the Command Line Tools and Homebrew (verified, signed package), Homebrew
  casks and formulae, App Store apps, fonts and profiles with Keep / Replace / Skip for conflicts.
- **Dry Run**, **resume** after interruptions, **retry** of failed items and verification of every step.
- **Check Backup** to verify a backup's integrity at any time.
- **Permission-aware inventory** that reports locations macOS did not allow MacReplica to read.
- **Check for Updates** via GitHub Releases (information only, no automatic installation).
- **Diagnostics:** component-tagged, privacy-redacted logs, a startup record with safe mode after a failed launch, and an
  exportable diagnostic report.
- Seven languages: English, German, Norwegian Bokmål, French, Spanish, Italian and Dutch.
- Universal app for Apple silicon and Intel, macOS 13 or later.

[Unreleased]: https://github.com/itsab1989/MacReplica/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/itsab1989/MacReplica/releases/tag/v1.0.0
