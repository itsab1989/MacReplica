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
   - **Backup location** — where the backup will be saved, with the drive's name, its free space and how large
     the backup will be. Click **Choose …** (or **Change …**) to pick a folder or an external drive; nothing is
     written until you click **Save Backup**. **Save Selection …** keeps your choices for next time (the selection
     is also saved next to the backup automatically) and **Load Selection …** applies saved choices; when you scan
     again and the location has a saved selection, MacReplica offers **Use It**;
   - how each app will come back (Homebrew, App Store, vendor website, manual);
   - **Possible matches found** — apps where several Homebrew packages could fit. Pick the right one
     or *None of these* (you can also decide later on the new Mac);
   - **Fonts and Color Profiles** — every font and ICC profile with name, version and format. Untick
     what you do not need. Display profiles macOS generated for this Mac's displays are not selected.
     **Keep display profile assignments** remembers which profile each display uses, so MacReplica can
     assign it again to the same display (on the same Mac, or an external display that is connected);
   - **Development Environments** — Python environments to rebuild, Python settings from your shell profile.
     For reinstalling macOS on the same Mac you can also tick **Also keep a complete copy of this
     environment**; on restore the copy is checked and run, and rebuilt from its packages if it does not fit;
   - **Developer Tools** — version managers, language versions, global tools and other package managers,
     each with how it comes back (*Restored automatically*, *Guided step* or both). Untick any you do
     not want ([details](DEVELOPER_ENVIRONMENTS.md));
   - **Developer Settings** — Git settings (your email only if you tick it);
   - **Application Data** — detected app settings and presets, per app and kind (for example Photoshop and
     the Photoshop beta separately, DaVinci Resolve LUTs, Krita resources, GIMP and Inkscape settings, Word
     templates and AutoCorrect, LibreOffice settings, templates and dictionaries, Mail signatures and rules, the Cryptomator vault list, DisplayCAL calibrations);
     items that may not work in another app version, may contain keys or contain code (plug-ins, scripts,
     add-ins) are not selected. Hold the pointer over an item to see what it contains and what it means. Each item shows how well it is supported: *Fully supported* (confirmed in the
     real app), *Check in the app* or *Experimental*. Mail and Office need **Full Disk Access** for MacReplica
     (System Settings › Privacy & Security). Add more with **Add Folder …**.
     *Application data* means the settings, presets, templates and resources you created in an app — never
     the whole `~/Library`, which also holds caches, licences, databases and the state of this particular Mac;
   - **Your own folders** — optional: add folders of your home folder (documents, pictures, projects), each
     on its own and without a size limit. Not the home folder as a whole or `~/Library`. Files that are only in
     iCloud are left out and listed. MacReplica checks that the destination has enough free space;
   - **Not in this backup** — every file that will not be in the backup: files that look like passwords or keys
     (not in the backup until you decide, each with what it appears to be and what to do; **Add Encrypted** adds it
     to the encrypted part), and files that could not be read. **Show in Finder** shows the file. Read this before you erase the Mac;
   - **Your installers (offline)** — installers you keep (for example Office LTSC with its activation package,
     or a tablet driver, on an external drive): choose them for the app (**Use my installer …**, also an `.app`)
     or add a folder. Each file shows what it is, what is inside, where it is, whether it will be used and what
     happens on the new Mac – or why it cannot be used. *Copy into backup* stores the installer itself in the
     backup; *Contains a licence or activation* marks licence files as private (no licence is read). Installers
     without a Developer ID (for example DisplayCAL) are used only after you tick *Use this unverified installer*;
     macOS then asks you to allow the app on its first start (System Settings › Privacy & Security › Open Anyway).
     A file is only called *damaged* or *incomplete* when that is proven (its own checksum does not match, or its end
     is missing). An intact installer MacReplica cannot look inside – password-protected, not opening on this Mac, or
     with an unusual layout – is kept with the reason and a **Details** line, used after you confirm it, and opened in
     Finder for you on the new Mac ([INSTALLER_VALIDATION.md](INSTALLER_VALIDATION.md));
   - **Printers & Scanners** — your printers and scanner drivers, with connection and driver;
   - **macOS settings** — Dock, Finder, keyboard, trackpad, language and more, by category, and what is not
     transferred and why;
   - **Passwords, keys and credentials** — **Add Keys or Password Files …** adds any number of key files, password
     databases and folders containing them, from any folder or drive (several at once). Files found in your chosen
     folders are listed with **Add Encrypted** / **Leave Out**. The first time, you set a passphrase and MacReplica
     shows a **recovery key** – store it away from this Mac; either one opens the credentials, losing both loses them.
     The contents are stored only encrypted and checked after encrypting (names and paths stay readable in the
     backup's list of contents). Keychains, passkeys and browser password
     stores cannot be moved as files: the section names the supported way for each (sync, export, sign-in). If
     credential files were found but not decided on, **Save Backup** asks once more. See
     [CREDENTIALS.md](CREDENTIALS.md);
   - **Sign in again** — services that need a new login on the new Mac;
   - locations macOS did not let MacReplica read;
   - under **Show apps**, every app with a checkbox (untick apps you do not want in the backup) and a
     badge for beta, nightly and other pre-release channels. An app found in several places is listed once.
   If the backup contains Homebrew packages and Homebrew does not fully support this Mac (an Intel Mac, or macOS 14
   or older on Apple silicon), a notice explains what to expect after a fresh installation of the same macOS —
   read it before you erase the Mac.
   The **Launchpad** layout (macOS 13–15: pages, folders with their names, the order of the apps) is
   recorded automatically. If App Store apps could not be identified, MacReplica says so and offers to install
   the helper tool `mas`, which can look them up.
3. Click **Save Backup** (or **Save Backup …** if no location is chosen yet). MacReplica creates a folder named
   `MacReplica-Backup-<date>-<time>`, verifies it and shows its size, location, contents and how complete it is.
   The folder also contains a copy of MacReplica itself and **REINSTALL_MACOS.html** – click **Reinstall Guide**
   and print it before you erase the Mac (it is also available later under **Check Backup**). It contains every
   step on paper, including how to create a USB installer with Apple's `createinstallmedia` and start up from
   it. On an Intel Mac with the T2 chip it tells you to allow external boot media in Startup Security Utility
   *before* erasing: that utility asks for an administrator of this Mac, and after erasing there is none.
4. Copy that folder to the new Mac (or keep it on the external drive).

## 2. Restore on the new Mac

1. Open MacReplica, click **Restore** and choose the backup folder. MacReplica checks the backup and
   then this Mac.
2. **What do you want to put onto this Mac?** — everything from the backup is selected except items that are not
   recommended on this Mac and the encrypted credentials (tick them and enter the passphrase or recovery key to
   include them). For each area you see what is ready, already installed, needs a decision or is not recommended.
   - Untick whole areas or click **Choose Individual Items …** to untick single items, see details
     (version on this Mac, format, origin) and decide conflicts.
   - Allow third-party Homebrew sources (taps) only if you trust them.
   - **Credentials** are restored only if you switch them on, with the passphrase or the recovery key from the old Mac
     (asked before the check, so files that differ from this Mac's get a decision: keep this Mac's version, keep both,
     replace, or skip).
3. Click **Preview (Dry Run)** to see exactly what will happen, or **Start Restore**.
4. If something already exists in a different version or with the same name, MacReplica asks:
   *Keep this Mac's version*, *Replace with backup*, *Keep both* (where safe) or *Skip*. For application
   data, the item shows how many files differ (ⓘ lists them with size and date) and lets you choose
   *Keep this Mac's files, add the rest* (default), *Replace with the backup* (the old files are kept in
   *Replaced Files*) or *Skip*. Presets of a Photoshop version that is not on this Mac go into the version
   that is (**Restore for:** lets you choose).
   Data that belongs to an app that is not installed yet (for example DaVinci Resolve's LUTs and presets)
   waits: install the app, then choose **Continue** — MacReplica restores it then. Resolve presets are never
   put into an older Resolve. Quit Photoshop and Resolve before restoring their settings.
5. If administrator rights are needed (Homebrew packages with installers, shared folders), MacReplica asks
   for your password **once per restore** in its own window and checks it right away; it is kept only in
   memory until the restore ends.
   Steps that need **Full Disk Access** (Mail, Office) wait: allow MacReplica in System Settings › Privacy &
   Security › Full Disk Access, then continue the restore.
   **Launchpad** is arranged last, once the apps are installed: apps you did not restore are left out (their
   folders keep the others), apps that were not in the layout follow on further pages. If apps of the restore
   still wait for you, Launchpad is arranged with what is there and again when you continue. macOS 26 and
   later have no Launchpad; the backup's report lists the layout for reference.
6. Keep MacReplica open and the Mac awake. You can **Stop** at any time; the restore can continue later.
7. The summary lists what worked, what failed (with what to do), what is **waiting for you**, and
   services to sign in to. **Retry Failed Items** runs the failed steps again (and steps that waited for them)
   in the same restore: everything that already worked stays in the summary, the guided steps stay, and the
   restore can still be continued after you quit or restart. If the backup drive is not connected, it says so
   first.
8. **Continue with Guided Steps** opens the guided installation (see below), including printers and scanners
   to set up in System Settings. After a restart, choose **Continue** on the start window to get back here.
   If Launchpad waits because the Dock has no Launchpad database, **Restart the Dock** next to it usually fixes
   that; MacReplica then arranges Launchpad. Apps whose identifier changed (for example GIMP 2.10 → GIMP 3) go into
   their old folder by name, and apps you left out of the backup keep their place if you install them anyway.
   Every waiting app and step has **Skip**; **Skip All** leaves out everything the guided installation still shows
   (after a confirmation – nothing on the Mac is changed).

If you chose **Use my installer …** for an app when making the backup, that installer is used on the new Mac in
the guided steps – also for apps that have a Homebrew cask (up to 1.1.1 the cask was used and your installer
was never offered). A match you choose on the restore screen still wins.

### Guided installation

Everything automatic runs first. Apps that need you — App Store apps, apps without a Homebrew package,
beta and nightly builds — and developer-tool steps MacReplica cannot run come last:

1. Click **Look Up Downloads**. MacReplica asks only official sources (the vendor's update feed
   declared in the app, the vendor download from Homebrew's catalog, the App Store, the vendor's
   website). Nothing is downloaded yet.
2. For each app, pick the **Source** if there are several; the one marked *recommended* matches the
   channel you used on the old Mac. The line below tells you what is verified before installing.
3. **Install Selected One by One** downloads, verifies and installs the ticked apps. Apps are copied
   into Applications; installer packages open in Apple's Installer; App Store and website sources
   open the page for you. When MacReplica waits for you, answer **Done** (it checks), **Skip**,
   **Later** or **Cancel Installation**. **Download Selected** only downloads; downloads can be
   paused, resumed, retried and cancelled.
4. Developer-tool steps show the exact command (with **Copy**) or the page to install from. Do it,
   then click **Check Again** — MacReplica verifies it and installs what depends on it (for example
   your npm packages after you installed Node.js with nvm).

Skipped apps stay skipped. Postponed, cancelled and waiting steps are offered again whenever you
continue the restore. Details: [DOWNLOADS.md](DOWNLOADS.md).

### Interrupted restores

If MacReplica was stopped, quit or crashed, the start screen offers:

- **Continue** — resume with the same choices; finished steps are not repeated, steps that wait for
  you are checked again. If only such steps are left, the start screen says how many are waiting.
- **Review …** — open the selection first; finished steps are locked with their results, everything
  else can still be changed.
- **Discard** — forget the unfinished restore (nothing that was installed is removed).

## 3. Tools

Click **Tools** on the start screen. Every tool first shows what it finds; nothing changes until you press a button
and confirm, and MacReplica checks the real result afterwards. The **?** buttons explain each part; **Limits and
details** lists what a tool cannot do. Changes appear under **Changes made with the tools**. Backups and restores
never use these tools. Background and research: [TOOLS.md](TOOLS.md).

**Gatekeeper and app security**
- The top shows whether macOS checks apps, and why not (for example a configuration profile you installed).
- **Choose an app …** checks one app: signature, notarisation, quarantine mark and Gatekeeper's verdict. If macOS
  blocks it, **Open the app and Privacy & Security** guides you through Apple's “Open Anyway”; afterwards click
  **I approved it – check again**.
- **Open app** starts it right away. **Remove quarantine …** lets this one app open without Gatekeeper's first
  check, including Apple's malware check; only do this for apps you trust. **Put quarantine back** undoes it.
- **Turn off app checking for this Mac …** (advanced): MacReplica prepares a profile; you install it in System
  Settings › General › Device Management, then click **Check again**. **Turn app checking back on …** guides you to
  remove exactly that profile.

**macOS updates**
- Shows your automatic-update switches and, with **Ask Apple about this version**, whether your version still gets
  security updates.
- **Set up recommended settings …** opens Software Update and tells you which switches to change; click **I changed
  it – check again** afterwards. **Restore previous settings …** goes back.
- A new major version is installed only when you click “Upgrade”. **Postpone major macOS upgrades** (30, 60 or 90
  days, Apple's maximum) is offered on macOS 13–15.7.4 and 26 via a profile you install in Device Management;
  on macOS 15.7.5 and later 15.x it would also hold back security updates, and macOS 27 no longer supports it.

**Window corners** (experimental, macOS 26.4 and later)
- By default one radius (10 pt like macOS 15, 7, 4, or any value from 2 to 24 pt) applies to everything you tick. Turn
  off **Same radius for everything** to give each surface its own radius; untick a surface to leave it as macOS draws
  it. **Apply …**, then quit and reopen apps.
- Without anything else: app windows (with sheets and alerts), utility panels and **classic menus** (the older style
  without glass, ≈6 pt).
- **Menus, popovers and Quick Look … (advanced)** shows, after a warning, the surfaces that need the corner plugin:
  menus with any radius, popovers, toolbar groups and capsule buttons in apps that allow it (not Safari/hardened apps; the Quick Look window does not change on current macOS). The plugin
  runs through Plugin Playground, a maintained tweak loader whose source is public (it has no licence, so MacReplica
  only downloads its pinned release and never bundles it). It works on Macs with Apple silicon only. Setup:
  1. **Once, by you – allow debugging.** Shut down the Mac. Press and hold the power button until “Loading startup
     options” appears, click **Options**, then **Continue**. Choose **Utilities > Terminal**, type
     `csrutil enable --without debug` and press Return. macOS confirms the change and warns that it is an unsupported
     configuration – that is expected. Choose **Apple menu > Restart**. Every other protection stays on; MacReplica
     cannot do this step for you.
  2. Back in macOS, open **Tools > Window corners > Menus, popovers and Quick Look …** again: “Debugging is allowed”
     is green.
  3. Click **Set up automatically …** and enter your administrator password once. MacReplica shows the exact steps
     first, then downloads Plugin Playground (fixed version, checksum verified), installs it with its plugin, turns on
     Playground's “Disable arm64e (PAC)” setting (needed for Apple's own apps) and starts Playground's background
     service. You do not need to open Plugin Playground.
  4. Every row except the last turns green. Quit and reopen apps (or restart the Mac). After reopening MacReplica, the
     last row – “The plugin is loaded in MacReplica” – confirms it works.
  5. Tick the surfaces you want and click **Apply …**; apps pick up a change when they are reopened.

  Each row shows the real state of your Mac (green = checked, empty = missing, question mark = could not be read), and
  **Next step** under the list says what to do. If a setup run is cancelled or fails, the steps marked ✓ stay done and
  running it again only repeats what is missing. If the background service is set up but does not run, restart the
  Mac. **Undo setup** removes the plugin and uninstalls the loader; the service keeps running until the next restart.
  Then turn System Integrity Protection fully back on: recoveryOS > Terminal > `csrutil enable`, restart. On a macOS
  version it was not tested on, the plugin still loads but asks you to accept the risk first.

  **Know what this costs before you turn it on.** To reach Apple's own apps the loader turns on “Disable arm64e (PAC)”,
  which runs **every** Apple-silicon app from an unsigned copy in `/tmp` and weakens code signing broadly while it is
  active. Most apps work, but some crash or misbehave (Microsoft AutoUpdate, for example, is blocked by default; you can
  add more). It can **not** change Safari and other protected Apple apps, the system UI, or the Quick Look window on
  current macOS. If an app starts crashing or complaining about its location, add it to the loader's blocklist, or use
  **Undo setup** and restart to return everything to normal. On recent macOS partial SIP may not be enough; if the
  “enabled” row stays red after setup, you may need full `csrutil disable` in recoveryOS.
- **Restore previous** returns every setting exactly to how it was; **Restore macOS default appearance …** removes
  them all. The picture area inside Quick Look keeps its own corners in any case.

**Create macOS Installer** (a bootable USB installer, with Apple's own tools)
- **Open …** lists the macOS versions Apple offers right now, newest first, grouped by major release. MacReplica
  reads them each time from Software Update (`softwareupdate --list-full-installers`, the full installers Apple offers
  this Mac) and from Apple's page “How to download and install macOS” (support.apple.com/102662). No version list is
  built into MacReplica, so a new macOS version appears without a MacReplica update. The top shows when each source
  was last read and what failed; **Check Again** reads both again.
- Versions from Software Update are downloaded by MacReplica (no password needed). For older releases MacReplica opens
  Apple's App Store page or Apple's disk image; download it there, then click **Check Again**. Macs with Apple silicon
  start up only from macOS 11 or later, so older releases are shown but cannot be chosen on them.
- **Installers on this Mac** (top of the first step) lists the macOS installers already in Applications, with version,
  build and size: **Use** continues with one without downloading, **Move to Trash…** frees its space (installers from
  Software Update belong to the system, so macOS asks for the administrator password). **Choose Installer…** takes one
  from anywhere else (Downloads, a drive); it is copied into Applications first, because Apple's tool runs only from
  there, after checking that there is enough free space. After a drive is created, **Move Installer to Trash…** offers
  the same; nothing is deleted without asking.
- MacReplica checks the installer: the macOS version inside, Apple's signature on the app and on its
  `createinstallmedia`, and the options that tool has. Installers without `createinstallmedia` (OS X Lion and Mountain
  Lion) cannot make a bootable drive.
- Choose an **external** drive or a card (also in the Mac's built-in SD reader) with enough space (32 GB is enough for
  every installer). The startup disk, internal disks, disk images, read-only drives and drives holding a Time Machine
  backup, a MacReplica backup, MacReplica itself or the installer are listed with the reason and cannot be chosen. If
  macOS asks whether MacReplica may access a removable volume, allow it; until then that drive is shown as protected.
- The confirmation lists the drive and every volume on it that will be erased; tick **I understand …** and click
  **Erase and Create Installer**. MacReplica reads the drive again and stops if it is not exactly the confirmed drive,
  erases it as one Mac OS Extended (Journaled) volume, asks macOS for the administrator password and runs Apple's
  `createinstallmedia` on exactly that volume. In the same administrator step MacReplica first makes the installer the
  system's own (as Software Update leaves it) and checks Apple's signature again, so nothing can change it in between. This often takes 10 to 30 minutes (longer with USB 2); the Mac does not
  sleep meanwhile. Nothing is retried by itself: after a failure, **Try Again** starts over with a new confirmation.
- Afterwards MacReplica checks the drive (installer volume on the chosen drive, Mac OS Extended, the installer app in
  the same version, startup files, startup folder, Apple's signature on the copy) and shows how to start up an
  Apple-silicon Mac (hold the power button) and an Intel Mac (hold Option) from it. Whether a particular Mac starts up
  from the drive is only shown by trying it.
- **Internal disk (expert):** tick **Show empty partitions of the internal disk** to use an empty, separate partition
  of the Mac's own disk instead of a USB drive. Only partitions that hold nothing and are not APFS are offered – APFS
  volumes share their space with macOS and your data, and macOS cannot turn one into the Mac OS Extended volume an
  installer needs. MacReplica never resizes a disk; to get such a partition, use Disk Utility › Partition and leave the
  new partition empty. The confirmation then asks twice more (a second checkbox and a final question), and only that
  partition is erased; afterwards MacReplica checks that every other partition is unchanged. Apple documents installers
  only on external drives; Macs with Apple silicon may not list an installer on an internal partition at startup.
- **Main Menu** leaves the tool from every step (it cancels a running download). While the drive is erased and
  written it is unavailable, because stopping Apple's tool halfway would leave the drive unusable.

## The backup folder

```
MacReplica-Backup-2026-10-02-1852/
├── README.txt                         what this folder is and how to use it
├── manifest.json (+ .sha256)          everything MacReplica needs to restore, no secrets
├── fonts/{user,system}/…              selected fonts
├── icc_profiles/{user,system}/…       selected ICC profiles
├── development/python/<env>/          requirements.txt and project files per environment
├── application-data/<id>/…            selected app data (one folder per data location)
├── credentials/keys.json, items/*.mrcred   only if you added credentials (encrypted per item)
├── restore/RESTORE_INSTRUCTIONS.html  step-by-step guide, also for manual restoring
├── reports/inventory.html, manual_installations.html
├── checksums/SHA256SUMS               checksum of every file
└── logs/                              the backup log (home folder written as ~)
```

Keep the folder complete. **Check Backup** verifies every checksum at any time, says whether files were
missing when the backup was made, and opens the **Reinstall Guide** for the Mac the backup came from (written
with your current MacReplica; the copy in the backup stays unchanged).

## Where MacReplica keeps its own files

| Location | Content |
|---|---|
| `~/Library/Logs/MacReplica/` | logs (*Help → Open Logs*), startup record |
| `~/Library/Application Support/MacReplica/Sessions/` | unfinished restore sessions |
| `~/Library/Application Support/MacReplica/Replaced Files/` | files MacReplica moved aside instead of overwriting them |
| `~/Library/Application Support/MacReplica/Reports/` | restore reports |
| `~/Library/Caches/MacReplica/Downloads/` | downloads of the guided installation (verified, quarantined) |
| `~/Library/Application Support/MacReplica/tools-history.json` | changes made with the tools (no paths, no passwords) |
| `~/Library/Application Support/MacReplica/Profiles/` | configuration profiles the tools prepared for you to install |

## Troubleshooting

| Problem | What to do |
|---|---|
| An App Store app is “waiting for you” | Open the guided installation, install it from the App Store page MacReplica opens (signed in with your Apple Account), click **Done**. |
| A developer tool failed with “Required tool is missing” | Install the manager (or select it for the restore), then **Retry Failed Items**. |
| A download is “not verified” | The file did not match the vendor's signature, checksum or developer and was deleted. Install the app from the vendor's website instead. |
| Network errors | Check the connection, then **Retry Failed Items**. |
| Command Line Tools did not install | Confirm Apple's installation dialog; on a slow connection it can take long. Retry afterwards. |
| An app's data was not restored because the app is running | Quit the app and retry. |
| Some Python packages are missing | The summary names them; they may need a newer version or came from a local folder. |
| A font or profile shows *Provided by macOS* | macOS already has it; keep macOS's version unless you need the old copy. |
| Fonts do not show up in an app | Quit and reopen the app. |
| MacReplica started in safe mode | It did not start completely last time. Use **Export Diagnostic Report …** and report the problem, then **Continue Normally**. |
| Something else | *Help → Export Diagnostic Report …* creates a report you can attach to an issue: logs and system information with your home folder written as `~`, no passwords and no file contents (it does name apps, files and folders outside your home folder – read it before sharing). |
