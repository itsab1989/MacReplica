# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private vulnerability
reporting (*Security → Report a vulnerability*) on
[github.com/itsab1989/MacReplica](https://github.com/itsab1989/MacReplica). Include the MacReplica
version (*MacReplica → About*), macOS version and steps to reproduce. You will get an answer within
a week; fixes are released as soon as possible and credited if you wish.

Supported versions: the latest release.

## Threat model and safeguards

| Risk | Safeguard |
|---|---|
| A manipulated backup tries to run commands | No shell is ever used. Only allow-listed executables are started by absolute path, with arguments passed verbatim. Package names from a backup are never interpreted. |
| A manipulated backup writes outside its target folders | Every path from a manifest is resolved with `PathSafety` and must stay inside the expected base folder; `..`, absolute paths, `~` and control characters are refused, and the scanners never follow symbolic links. |
| Damaged or altered backup files | SHA-256 for every file plus `SHA256SUMS`; damaged files are reported and never restored. |
| Untrusted downloads | MacReplica downloads only Homebrew's official installer package and verifies its signature (Developer ID Installer, Homebrew's team ID), notarization and SHA-256 before installing. Everything else is installed by Homebrew or the App Store. Third-party Homebrew taps must be allowed explicitly. |
| Privilege misuse | Administrator rights are requested only when needed, once, through the macOS dialog, for a fixed set of operations (`mkdir`, `install`, `ditto`, `mv`, `installer`); the password is entered in macOS's own authentication dialog. When Homebrew itself needs `sudo` (some casks), it asks through MacReplica's small askpass helper, which passes the password straight to `sudo` and never stores or logs it. |
| Leaking secrets | Passwords, tokens, cookies, browser data, Keychain contents and private keys are never collected by default. Opt-in credential providers encrypt with AES-256-GCM (key from PBKDF2-HMAC-SHA256, 600,000 iterations); the passphrase is never stored. Git configuration is sanitized. Logs and reports redact the home folder. |
| Deleting user data | Clean-up only removes folders carrying MacReplica's ownership marker; existing files are kept, renamed or moved to *Replaced Files*, never deleted. MacReplica never writes into `/System`. |
| Self-update attacks | There is no self-update. The update check only shows a link to the GitHub release page. |

## For maintainers

- Never commit certificates, private keys, provisioning profiles or `.env` files (`.gitignore`
  blocks the common ones; CI runs a secret scan).
- Signing and notarization credentials live only in GitHub Actions secrets (see
  [docs/BUILDING.md](docs/BUILDING.md)).
