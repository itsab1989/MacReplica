# MacReplica user guide

## Before you start

- Use MacReplica on the old Mac **before** you erase it or hand it over.
- Have a place for the backup: an external drive, a USB stick or a cloud folder. The backup is
  usually small (apps are reinstalled, not copied); fonts, profiles and app data make up most of it.
- On the new Mac, finish the macOS setup assistant and sign in to the App Store if you want App
  Store apps reinstalled.

## 1. Create a backup on the old Mac

1. Open MacReplica and click **Create Backup**. The scan only reads; nothing on the Mac changes.
2. The results screen, **What do you want to take with you?**, shows:
   - how each app will come back (Homebrew, App Store, vendor website, manual);
   - **Possible matches found** — apps where several Homebrew packages could fit. Pick the right one
     or *None of these* (you can also decide later on the new Mac);
   - **Fonts and Color Profiles** — every font and ICC profile with name, version and format. Untick
     what you do not need. Display profiles macOS generated for this Mac's displays are not selected;
   - **Development Environments** — Python environments to rebuild, Python settings from your shell profile;
   - **Developer Settings** — Git settings (your email only if you tick it);
   - **Application Data** — detected app settings and presets; add more with **Add Folder …**;
   - **Credentials** — off unless you choose a provider and set a passphrase;
   - **Sign in again** — services that need a new login on the new Mac;
   - locations macOS did not let MacReplica read.
3. Click **Save Backup …** and choose the destination folder. MacReplica creates a folder named
   `MacReplica-Backup-<date>-<time>`, verifies it and shows its size, location and contents.
4. Copy that folder to the new Mac (or keep it on the external drive).

## 2. Restore on the new Mac

1. Open MacReplica, click **Restore** and choose the backup folder. MacReplica checks the backup and
   then this Mac.
2. **What do you want to put onto this Mac?** — everything from the backup is selected. For each
   area you see what is ready, already installed, needs a decision or is not recommended.
   - Untick whole areas or click **Choose Individual Items …** to untick single items, see details
     (version on this Mac, format, origin) and decide conflicts.
   - Allow third-party Homebrew sources (taps) only if you trust them.
   - **Credentials** can only be restored with the passphrase you set on the old Mac.
3. Click **Preview (Dry Run)** to see exactly what will happen, or **Start Restore**.
4. If something already exists in a different version or with the same name, MacReplica asks:
   *Keep this Mac's version*, *Replace with backup*, *Keep both* (where safe) or *Skip*.
5. If administrator rights are needed (Homebrew, shared folders), MacReplica explains why and macOS
   asks for your password once.
6. Keep MacReplica open and the Mac awake. You can **Stop** at any time; the restore can continue later.
7. The summary lists what worked, what failed (with what to do), apps to install yourself, and
   services to sign in to. **Retry Failed Items** runs only the failed steps again.

### Interrupted restores

If MacReplica was stopped, quit or crashed, the start screen offers:

- **Continue** — resume with the same choices; finished steps are not repeated.
- **Review …** — open the selection first; finished steps are locked with their results, everything
  else can still be changed.
- **Discard** — forget the unfinished restore (nothing that was installed is removed).

## The backup folder

```
MacReplica-Backup-2026-10-02-1852/
├── README.txt                         what this folder is and how to use it
├── manifest.json (+ .sha256)          everything MacReplica needs to restore, no secrets
├── fonts/{user,system}/…              selected fonts
├── icc_profiles/{user,system}/…       selected ICC profiles
├── development/python/<env>/          requirements.txt and project files per environment
├── application-data/<id>/…            selected app data (one folder per data location)
├── credentials/<provider>.macreplica-vault   only if you opted in (encrypted)
├── restore/RESTORE_INSTRUCTIONS.html  step-by-step guide, also for manual restoring
├── reports/inventory.html, manual_installations.html
├── checksums/SHA256SUMS               checksum of every file
└── logs/                              the backup log (home folder written as ~)
```

Keep the folder complete. **Check Backup** verifies every checksum at any time.

## Where MacReplica keeps its own files

| Location | Content |
|---|---|
| `~/Library/Logs/MacReplica/` | logs (*Help → Open Logs*), startup record |
| `~/Library/Application Support/MacReplica/Sessions/` | unfinished restore sessions |
| `~/Library/Application Support/MacReplica/Replaced Files/` | files MacReplica moved aside instead of overwriting them |
| `~/Library/Application Support/MacReplica/Reports/` | restore reports |

## Troubleshooting

| Problem | What to do |
|---|---|
| “Not signed in to the App Store” | Open the App Store, sign in, then **Retry Failed Items**. |
| Network errors | Check the connection, then **Retry Failed Items**. |
| Command Line Tools did not install | Confirm Apple's installation dialog; on a slow connection it can take long. Retry afterwards. |
| An app's data was not restored because the app is running | Quit the app and retry. |
| Some Python packages are missing | The summary names them; they may need a newer version or came from a local folder. |
| A font or profile shows *Provided by macOS* | macOS already has it; keep macOS's version unless you need the old copy. |
| Fonts do not show up in an app | Quit and reopen the app. |
| MacReplica started in safe mode | It did not start completely last time. Use **Export Diagnostic Report …** and report the problem, then **Continue Normally**. |
| Something else | *Help → Export Diagnostic Report …* creates a report without personal data that you can attach to an issue. |
