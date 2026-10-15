# Passwords, keys and credentials

How MacReplica preserves credentials (since 1.0.7): what it backs up, how it encrypts it, how it restores it, and
what it deliberately leaves to the system, the browser or the password manager. Research date: 2026-10-14.

## What was wrong before (1.0.5 / 1.0.6)

Files that looked like secrets were left out of every backup and listed; **Include …** added one of them. That path had
four defects. The first is the reported "one key or database, then no more":

1. **A database outside the chosen folders** (for example one KeePassXC remembers) was included by creating a hidden
   one-file *own folder*, keyed by folder *and* file name. When the user later chose that folder as an own folder, a
   second folder with the same path existed. The next **Include …** found the wrong folder, hit
   `guard … !folder.files.contains … else { return }` and **returned without doing anything or saying anything**. The
   button seemed dead, and files could show as both included and left out.
2. Files in the **home folder itself, iCloud Drive (`~/Library/Mobile Documents`), `~/Library/CloudStorage` or another
   volume** could not be included at all. `scanPersonal` refuses those folders, and the include failed with "could not
   be included".
3. `removeApplicationData` removed **every backup issue below the folder's path**, including the issues of another
   chosen folder inside it and of databases an app remembers. Deselecting or rescanning one folder could make
   credential files silently disappear from "Not in this backup", so the backup looked more complete than it was.
4. Included files were **copied unchanged, unencrypted** into the backup folder (a key file next to its database, or a
   private key, in plain text). There was no way to choose individual files, only folders.

Fix: credentials are no longer files grafted into folders. Each one is an independent **credential item**
(`InventoryResult.credentialSelection`). Its identity comes from its real path, and duplicates are recognised by
device and inode. Items come from any readable place, through **Add Keys or Password Files …** (several files and
folders at once) or **Add Encrypted** on a found file. Every item is stored only encrypted. `removeApplicationData`
now removes only the folder's own issues and never a user decision or a remembered database.

## Policy by category

"Encrypted backup" means: encrypted, decrypted again and compared before it counts (`Encrypted and verified`).
"Restore check" is what MacReplica proves on the new Mac. Opening a database or using a key still needs what the
last column says, so MacReplica never reports more than it checked.

| Category | Examples | Encrypted backup | Restore check | Still needed / alternative |
|---|---|---|---|---|
| Private key | `id_ed25519`, `deploy_key` (header), `.pem`/`.key` with a private key, `.p12`/`.pfx` | yes | same bytes, same format (PEM/OpenSSH/PKCS #12 header) | its own passphrase, if any. Keychain-only identities: export as `.p12` in Keychain Access |
| Public key | `*.pub` next to its private key, OpenPGP public key | yes | same bytes and format | — |
| Certificate | `.crt`, `.cer`, `.der`, PEM certificate | yes | same bytes and format | the matching private key is a separate item |
| PGP key | `.asc`, `.gpg`, extension-less armored private keys | yes | same bytes and format | its passphrase; keys only in a GPG keyring must be exported first |
| Password database | KeePass/KeePassXC `.kdbx`/`.kdb`, Password Safe `.psafe3` | yes | same bytes, same KDBX version | master password (and key file, if used) |
| Key file of a database | `.keyx`, KeePass XML `.key` | yes | same bytes | keep another copy apart from the database |
| Password-manager export | 1Password `.1pux`/`.1pif` (unencrypted exports) | yes, after an extra confirmation | same bytes | import into the manager, then delete |
| Recovery material | `github-recovery-codes.txt`, "recovery key", "backup codes", "Emergency Kit" | yes, after an extra confirmation | same bytes | keep an offline copy as well |
| Command-line logins | SSH folder, AWS, Git credential store, npm, Kubernetes, Terraform (providers) | yes | same bytes | the service may have revoked the login |
| Secrets file / other | `.env`, `.netrc`, any file the user picks | yes | same bytes | — |

“After an extra confirmation” applies when such a file found in your folders is added with **Add Encrypted**; adding
all undecided files at once leaves these two kinds out. A file you pick yourself with **Add Keys or Password Files …**
is added without a further question – picking it is the decision.
| macOS keychain files | `*.keychain-db` | **no** – listed as "cannot be backed up as a file" | — | iCloud Keychain, Migration Assistant, Passwords › Export, Keychain Access export |
| Browser password/cookie stores | `Login Data`, `Cookies`, `Web Data` | **no** | — | the browser's sync or export (see below) |
| Passkeys | iCloud Keychain, password managers, security keys | **no** (never files) | — | sync with the account; security keys stay on the key |

Files are found by name and the first bytes only (KDBX signature, `PWS3`, PEM/OpenSSH/OpenPGP header). Their contents
are never interpreted, logged or stored.

## Encryption

Only primitives from CryptoKit and CommonCrypto are used; nothing is self-made.

```
credentials/keys.json              data key wrapped per unlock method (no secret in clear)
credentials/items/<id>.mrcred      one encrypted file per item
```

- **Data key:** 256 random bits (`SecRandomCopyBytes`), only ever in memory.
- **Passphrase slot:** PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP Password Storage Cheat Sheet), 16-byte salt.
  It wraps the data key with AES-256-GCM, and the associated data names the slot. Fewer than 100,000 iterations are
  refused when opening.
- **Recovery-key slot:** the recovery key is 28 random Crockford-Base32 characters (140 bits) plus a 4-character
  checksum, shown as `XXXX-XXXX-…` (8 groups). It is derived with HKDF-SHA256 (RFC 5869), because it is already
  uniformly random, and wraps the same data key. Typing is forgiving: case, spaces and dashes are ignored, O→0 and
  I/L→1. The checksum catches typos before anything is tried.
- **Items:** each item gets its own key, HKDF-SHA256(data key, 32-byte random salt, `macreplica-credential-item/2/<id>`).
  The contents are split into 64 KiB records sealed with AES-256-GCM. The nonce is the record counter: unique,
  because every item has its own key (NIST SP 800-38D §8). The associated data is SHA-256(header) ‖ counter ‖ final
  flag, the "STREAM" online-AE construction (Hoang, Reyhanitabar, Rogaway, Vizár 2015; the same idea as the C2SP
  `age` format). Records therefore cannot be reordered, dropped, truncated or extended. The final record holds size,
  SHA-256 and permissions, all inside the encryption.
- **Binding:** the header names the item ID and a fingerprint of the data key, so an item of another backup or
  another item never opens.
- **Manifest:** only non-secret facts. That is the encrypted file's SHA-256 and size (checked by `SHA256SUMS` and the
  verifier without any key) and an **HMAC-SHA256 of the contents keyed with the data key**. The HMAC lets a restore
  recognise an identical file without decrypting and reveals nothing without the key. A plain SHA-256 of a secret is
  never written anywhere.
- **Writing:** the source is read once, encrypting as it goes, into a new private file (`0600`) inside the backup.
  No plaintext temporary copy is made. Then every record is decrypted and checked again, and the source is hashed a
  second time. If it changed meanwhile, the item is `failed (changed during backup)`.
- **Memory:** passphrase and recovery key live in the app only until the store is written, and are never logged or
  saved. Derived key buffers are zeroed after use. Swift strings cannot be wiped reliably; that is a known limit.

### Why not the Mac's login password

An app cannot read the login password: LocalAuthentication and Authorization Services only report whether a password
was right ([LocalAuthentication](https://developer.apple.com/documentation/localauthentication),
[Authorization Services](https://developer.apple.com/documentation/security/authorization-services)). Asking for it
in MacReplica's own window would train exactly the habit phishing relies on. The password can also change, and the
new Mac may use another one, so a backup keyed to it could become unreadable. MacReplica therefore uses a separate
passphrase plus a recovery key, and explains this in the setup sheet. Storing the passphrase in this Mac's keychain
would not help once this Mac is erased. iCloud Keychain (synchronizable items) needs a provisioning profile, which an
app distributed outside the App Store with ad-hoc or Developer ID signing does not have.

### Recovery

- Either the **passphrase** or the **recovery key** opens the credentials. Both are needed only in the sense that
  you must keep at least one.
- **Both lost = credentials lost.** MacReplica says this before the backup (a confirmation box) and on the restore
  sheet. Everything else in the backup restores normally.
- A wrong passphrase or key is reported in the sheet, and nothing starts.

## Restore

- Credentials are a component of their own: off by default, offered only for items whose backup was verified.
- The passphrase or recovery key is asked **before** the pre-restore check. Only then can the check see which items
  differ from files already on this Mac, and each such conflict appears in the decision sheet with **keep this Mac's
  version** (default), **keep both** (`Name (MacReplica).ext`), **replace** (the existing file moves to
  `~/Library/Application Support/MacReplica/Replaced Files/<session>/credentials/…`) or **skip**.
- Each item is decrypted into a new private file in the destination folder, checked against the SHA-256 inside the
  encryption, moved into place, then hashed again and checked for its recorded format. New folders are created
  `0700`. A restored file keeps its original permissions, limited to the owner (at most `0700`) for secrets and to at
most `0755` for public keys, certificates and `known_hosts`, and never less than `0600`.
- An item whose original folder does not exist (a drive that is not connected) goes to
  `~/MacReplica Restored Credentials/<id>/`, and the result says so.
- Running the restore again finds identical files (keyed HMAC) and changes nothing. A damaged item fails on its own,
  leaves no partial file, and does not affect the others. The backup is only read.

## What needs a step by the user

Detected and listed under **Needs a step by you**, with the supported route:

| Item | Why MacReplica does not copy it | Supported route | Source |
|---|---|---|---|
| Passwords in the keychain | Local Items/iCloud Keychain items cannot be copied; a copied keychain file needs its old password | iCloud Keychain, Migration Assistant, Passwords › File › Export All Passwords (unencrypted CSV, delete after import); certificates with keys: Keychain Access export | [Copy keychains](https://support.apple.com/guide/keychain-access/copy-keychains-kyca1121/mac), [Export passwords](https://support.apple.com/guide/passwords/mchl35b12625/mac), [Import/export items](https://support.apple.com/guide/keychain-access/import-and-export-keychain-items-kyca35961/mac), [iCloud Keychain](https://support.apple.com/109016) |
| Passkeys | not files; synced, provider-bound or device-bound | same Apple Account + iCloud Keychain; the manager's sync; security keys stay on the key. macOS 26 adds app-to-app transfer (`ASCredentialExportManager`) | [Passkeys on Mac](https://support.apple.com/guide/passwords/passkeys-mchl4af65d1a/mac), [Passkey security](https://support.apple.com/en-us/102195), [FIDO passkeys](https://fidoalliance.org/passkeys/), [ASCredentialExportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager) |
| Chrome | passwords encrypted with the "Chrome Safe Storage" key in this Mac's keychain | Google Password Manager sync or export/import | [Chrome help](https://support.google.com/chrome/answer/13068232), [Chromium source](https://chromium.googlesource.com/chromium/src/+/HEAD/components/os_crypt/common/keychain_password_mac.mm) |
| Edge | same Chromium design | sync or Settings › Passwords › Export (CSV "not protected") | [Microsoft](https://support.microsoft.com/en-us/edge/export-passwords-in-microsoft-edge) |
| Brave | same Chromium design | Brave Sync or password export | [Brave help](https://support.brave.app/hc/en-us/articles/360018185951-How-do-I-use-the-built-in-password-manager) (page returned 403 to automated checks; content confirmed from search excerpts only) |
| Firefox | `logins.json` only works together with its `key4.db` | Firefox Sync, export, or copy both files together into the new profile with Firefox closed | [Mozilla](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data) (site blocks automated fetches; confirmed from search excerpts) |
| 1Password | vaults live in the account | sign in with account password + Secret Key (Emergency Kit). 1PUX exports are unencrypted | [Emergency Kit](https://support.1password.com/emergency-kit/), [Export](https://support.1password.com/export/) |
| Bitwarden | vault lives in the account | sign in; if a file is wanted, use the password-protected encrypted export | [Bitwarden export](https://bitwarden.com/help/export-your-data/) |

## Manifest and statuses

`manifest_version` 4 marks a backup with encrypted credential items: 1.0.6 refuses it rather than hiding the
credentials. A backup without credential items is still written as version 3, which 1.0.6 reads as before.

- `credential_store`: format, version, keys path, algorithm, unlock methods, key fingerprint.
- `credential_items[]`: `id`, `category`, `kind`, `provider`, `file_name`, `original_path`, `home_relative_path` or
  `absolute_path`, `format`, `size`, `status`, `problem`, `encrypted_path`, `encrypted_size`, `encrypted_sha256`,
  `content_hmac`, `restore_strategy`, `prerequisites`, `manual_action_required`. Plus `macos_version` and
  `architecture` of the manifest itself.
- `backup_issues[]` with `refused_sensitive`: found but not in the backup. With `detail = left_out_by_user` it was a
  decision of the user; without, it is still undecided (and the user was warned before saving).

How the requested statuses map:

| Requested status | Where |
|---|---|
| Encrypted Backup Verified | item `status = encryptedBackupVerified` |
| Failed | item `status = failed` + `problem`, and a backup gap (backup = partial) |
| Skipped by User | issue `detail = leftOutByUser` |
| Requires Manual Export / Requires Reauthentication | guidance records (`manualMigration` / `reauthenticationRequired`) |
| Unsupported | issue of kind `keychain` / `browserData` ("cannot be backed up as a file") |
| Verified / Partially Verified (restore) | result note `credentialVerified(format:)` (bytes + format) plus `credentialNeeds(...)` for what MacReplica could not check |
| Restore Verification Failed | result `failed(verificationFailed)` |

## Verification done (2026-10-14)

See the 1.0.7 addendum in [VALIDATION_REPORT.md](VALIDATION_REPORT.md): unit tests, mutation testing, and an
on-screen run of the real app against simulated Macs. Restored files were opened with the real KeePassXC 2.7.12
(`keepassxc-cli`), OpenSSH `ssh-keygen`, LibreSSL `openssl` and GnuPG.

## Known limits

- MacReplica proves bytes and format. It cannot prove that you still know a master password or a key's passphrase.
- Passkeys, keychain items and browser password stores are guidance only, by design (see above).
- Directory-shaped vaults (1Password `.opvault`, Cryptomator vault folders) are not credential items. Inside a chosen
  folder their already-encrypted files are backed up like other files.
- The passphrase is a Swift `String` while the sheet is open and cannot be wiped from memory reliably.
