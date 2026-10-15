# Security Policy

## Supported versions

Security fixes are made for the latest release. Please update before reporting.

## Reporting a vulnerability

Please **do not open a public issue, discussion or pull request** for security problems. Report them
privately through GitHub: on the repository page open **Security → Report a vulnerability**
([direct link](https://github.com/itsab1989/MacReplica/security/advisories/new)). Only the
maintainer can see the report.

Please include:

- the MacReplica version (*MacReplica → About MacReplica*), macOS version and Mac type;
- what an attacker could achieve and under which conditions (for example a crafted backup folder);
- steps or a minimal, **synthetic** example to reproduce it.

Never include real passwords, keys, tokens, backups of your own Mac or other personal data in a
report — describe them or use made-up values. Do not publish details of an unfixed vulnerability.

You will get an answer as soon as possible, usually within a week. Once a fix is released, the
advisory is published and you are credited if you wish.

## Threat model and safeguards

| Risk | Safeguard |
|---|---|
| A manipulated backup tries to run commands | Tools are started without a shell: only allow-listed executables, by absolute path, with arguments passed verbatim. Package names from a backup are never interpreted. The only shell is the one macOS uses for administrator steps (AppleScript `do shell script … with administrator privileges`): those are limited to a fixed set of operations, every argument is quoted with `quoted form of`, and paths are validated first (no `..`, no control characters; removals only for an allow-list of the corner plugin's and its loader's own files). |
| A manipulated backup writes outside its target folders | Every path from a manifest is resolved with `PathSafety` and must stay inside the expected base folder; `..`, absolute paths, `~` and control characters are refused, and the scanners never follow symbolic links. |
| Damaged or altered backup files | SHA-256 for every file plus `SHA256SUMS`; damaged files are reported and never restored. |
| Untrusted downloads | MacReplica downloads three kinds of files itself. **Homebrew's installer package:** Developer ID Installer signature with Homebrew's team ID, a notarization status if `pkgutil` reports one, and the SHA-256 GitHub publishes for it (when present). **Vendor downloads in the guided installation** ([DOWNLOADS.md](docs/DOWNLOADS.md)): only from the vendor's own update feed or the download Homebrew's catalog names; verified by the vendor's EdDSA signature or Homebrew's checksum, then the app's bundle identifier, developer team, code signature, architecture and minimum macOS; quarantine is kept. **The window-corner plugin's loader package** (Tools, on request): pinned version and SHA-256. Everything else is installed by Homebrew, the App Store or the user. Third-party Homebrew taps must be allowed explicitly. |
| Privilege misuse | Administrator rights are requested only when a step needs them, for a fixed set of operations (`mkdir`, `install`, `ditto`, `mv`, `installer`, and `rm` limited to the corner plugin's and its loader's own files); the password for these is entered in macOS's own authentication dialog. When Homebrew itself needs `sudo` (some casks), MacReplica asks once per restore in **its own window**, checks the password with `sudo -k -v`, and keeps it in memory only; Homebrew's `sudo` gets it from MacReplica's askpass helper over a socket only the user can open, with a one-time token. Programs Homebrew starts during that restore (for example a cask's installer script) could request it as well; this is why third-party taps are only used after the user allows them. The password is never stored or logged. |
| Leaking secrets | Passwords, tokens, cookies, browser data, Keychain contents and private keys are never collected by default. The contents of credentials the user adds are encrypted per file (AES-256-GCM, random data key wrapped with PBKDF2-HMAC-SHA256 600,000 iterations and with a recovery key, STREAM-style 64 KiB records), verified after encrypting and never written in plain text; their names, original paths, sizes and formats stay readable in the manifest, which holds no contents and no plain hashes (see [docs/CREDENTIALS.md](docs/CREDENTIALS.md)). The rest of the backup is not encrypted. Git configuration is sanitized. Logs and reports redact the home folder. |
| Deleting user data | Clean-up only removes folders carrying MacReplica's ownership marker; existing files are kept, renamed or moved to *Replaced Files*, never deleted. MacReplica never writes into `/System`. |
| Self-update attacks | There is no self-update. The update check only shows a link to the GitHub release page. |

## For maintainers

- Never commit certificates, private keys, provisioning profiles or `.env` files (`.gitignore`
  blocks the common ones; CI runs a secret scan).
- Signing and notarization credentials live only in GitHub Actions secrets (see
  [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md)). Releases are currently built without them (ad-hoc signed, not
  notarized).
