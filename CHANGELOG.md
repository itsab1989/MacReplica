# Changelog

All notable changes to MacReplica are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and MacReplica uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The backup format has its own version
(`manifest_version`), independent of the app version.

## [Unreleased]

### Added
- **Installers already on this Mac.** Tools › Create macOS Installer lists the macOS installers in Applications with
  version and size; use one without downloading, or move it to the Trash to free its space (also offered after a drive
  was created – never automatic). **Choose Installer…** takes one from Downloads or a drive and copies it into
  Applications first (on the same disk that is a clone and takes no extra space; from another drive the free space is
  checked). If an installer of that name is already there, MacReplica asks: use that one, or replace it.
- **Progress while the installer is written.** A bar shows how much is already on the drive (Apple's tool reports its
  own progress only when it has finished).

- **The Mac stays awake while MacReplica works.** Reading the Mac for a backup, saving and checking a backup,
  restoring, and downloading, copying or writing a macOS installer now keep the Mac from going to sleep when idle
  (the display may still turn off; closing the lid still sleeps). It shows in Activity Monitor › Energy with what
  MacReplica is doing, and ends with the operation. Until now only writing an installer drive did this.

### Fixed
- **No false “another user” warning.** MacReplica read the logged-in user from `/dev/console`, which on macOS 27 stays
  root's after the screen was locked and unlocked again. It now asks the system who is logged in at the screen.
- **An installer whose options could not be read was called one that “cannot run without questions in Terminal”.**
  The reason (did not start, did not answer) is now shown with **Check Again**, and the tool gets 120 s to answer.

### Security
- **The installer is locked before it runs as administrator.** An installer that belongs to the user could be changed
  between MacReplica's signature check and Apple's `createinstallmedia` starting as root. In the same administrator
  step MacReplica now first makes it the system's own (as Software Update leaves it) and checks Apple's signature again
  as root; only then does the tool run.

## [1.1.9] - 2026-10-20

### Added
- **Tools › Create macOS Installer**: a bootable USB installer for a macOS version Apple offers, made with Apple's
  own `createinstallmedia`. The versions are read live on the Mac – Software Update's full installers for this Mac and
  Apple's page “How to download and install macOS” – so new macOS versions appear without a MacReplica update; grouped
  by major release, newest first, with the time each source was read. MacReplica downloads Software Update's
  installers itself and opens Apple's App Store page or download for older ones. It checks Apple's signature on the
  installer and its `createinstallmedia`, offers only external drives (never the startup disk, internal disks, disk
  images or drives with a backup), reads the drive again right before erasing and stops if it changed, erases it,
  then runs `createinstallmedia` with one administrator password on exactly the volume it erased. Afterwards it checks
  the drive and shows how to start up Macs with Apple silicon and Intel Macs from it. Nothing destructive is retried by
  itself. Cards in the Mac's built-in SD reader can be used too.
- **Expert option: an empty partition of the internal disk.** Only empty, separate, non-APFS partitions are offered;
  MacReplica never resizes a disk. It asks twice more before erasing, erases only that partition (found by its
  partition identifier) in the same administrator step as `createinstallmedia`, and checks afterwards that every other
  partition is unchanged.

### Fixed
- **Launchpad: the result names apps the backup has no place for.** Apps on the new Mac that the backup's arrangement
  does not contain end up after the arranged pages; the result said only “succeeded”. It now names them and explains
  why: backups made before 1.1.7 left out the apps deselected for the backup – a new backup of the old Mac keeps their
  places (tester's report on 1.1.8).
- **Progress of external tools arrives while they run.** MacReplica read a tool's output in 64 KB blocks, so lines
  reached it only at the end (found when the installer download's percentage stayed empty). Progress redrawn with a
  carriage return now counts as a line, too.

## [1.1.8] - 2026-10-19

### Fixed
- **Intact installers could be called damaged when macOS was busy with disk images.** MacReplica counted every failed
  `hdiutil verify` as a checksum mismatch – also “Resource temporarily unavailable”, which only means the disk-image
  service was busy (seen in a release run of 1.1.7). Damage now needs proof: `verify`'s own report of two different
  checksums (read as data, so independent of the user's language), or a list of contents inside the image that
  MacReplica cannot read as a property list. Any other failure is tried again three times; if it stays, the installer
  is kept with *checksum not checked* and the tool's own words, as for other installers MacReplica cannot look into.
- The details of such an installer no longer say *“checksum verified”* when the check could not run.

## [1.1.7] - 2026-10-18

### Fixed
- **Launchpad: apps whose identifier changed are placed in their folder.** A tester's GIMP 2.10 (`org.gimp.gimp-2.10`)
  became GIMP 3 (`org.gimp.gimp`) on the new Mac and ended up after his pages. When an app of the arrangement is not on
  the new Mac under its identifier, the app with the same name takes its place (never one that has its own place).
  Backups now record the names Launchpad shows; older backups use the names from their app list. The result is
  checked against the app that took the place, and repeating the restore changes nothing.
- **Launchpad: apps left out of the backup keep their place.** Until now they were removed from the recorded
  arrangement, so apps installed anyway on the new Mac (the tester's Microsoft Defender, OneDrive and DisplayCAL tools)
  ended up after the arranged pages. Only their identifier and name stay in the backup; if they are not installed, they
  are left out as before.

### Added
- **Restart the Dock** for Launchpad: when this Mac has Launchpad but its Dock has no Launchpad database, the waiting
  step offers to restart the Dock (a normal quit; macOS starts it again at once). That made the tester's Mac create
  the database again; MacReplica then checks again and arranges Launchpad.
- **Select All** and **Deselect All** above the parts of the restore (tester's suggestion).

## [1.1.6] - 2026-10-18

### Fixed
- **Launchpad: more diagnostics, and a clear message when MacReplica runs as another user.** A tester's 1.1.5 log
  showed neither a Launchpad folder in MacReplica's user folder nor a Dock with Launchpad open for MacReplica's user.
  One way this happens was reproduced on macOS 14.8.9: MacReplica started as another user (e.g. with `sudo`) looks in
  that user's folder and for that user's Dock. Whether that applies to the tester is not known. In that case the
  Launchpad step now says so, and every restore logs a warning. When Launchpad's database cannot be used, the log names
  MacReplica's and the logged-in user's IDs, the running Docks, what `lsof` returned, which processes of this user have
  a Launchpad file open, and whether `getconf` reports the same user folder (IDs, counts and system folders only).

## [1.1.5] - 2026-10-18

### Fixed
- **Launchpad was not arranged on a tester's macOS 14 Mac although Launchpad worked.** The 1.1.4 log showed that
  the folder macOS names for the user (`DARWIN_USER_DIR`) had no Launchpad data at all – access was not refused, the
  Dock simply keeps its database somewhere else on that Mac. The running Dock keeps its database open (checked on
  macOS 14.8.9), so MacReplica now uses the database the Dock has open when the user's folder has none, and the log
  names both locations. If neither is found, the log also says what the Dock has open.

## [1.1.4] - 2026-10-17

### Fixed
- **Apps an outdated Homebrew installed for the wrong processor were reported as already installed.** Reproduced with
  Homebrew 4.2.0 on Intel: it fails on GIMP's current cask but still puts the Apple-silicon-only GIMP into
  Applications; after `brew update` Homebrew calls it installed. MacReplica now checks that the app has code for this
  Mac's processor, reinstalls Homebrew's copy once if not, and otherwise reports *Built for another processor*. An app
  not installed by Homebrew is never replaced.
- **Launchpad:** the advice “open Launchpad once” is gone (on macOS 14 the Dock recreates a missing database at once,
  so it never helped). When macOS refuses access, the step says so and offers Full Disk Access (quit and reopen
  MacReplica afterwards); the restore log records what macOS reports for each folder of the database path.

### Added
- **Skip** on every guided step for displays, printers and scanners and on every item waiting for apps or permissions,
  and **Skip All** (with a confirmation) in the guided installation.

## [1.1.3] - 2026-10-17

### Fixed
- **“Launchpad does not exist on this macOS” on macOS 14.** A tester's restore on Sonoma skipped Launchpad with that
  message. MacReplica gave the same reason when the macOS has no Launchpad (macOS 26 and later) and when Launchpad's
  database was simply not found, and never checked again. On a macOS with Launchpad the step now says it is *not
  arranged yet* because Launchpad's list was not found, waits, and arranges Launchpad when you choose **Continue**.
  A restore saved by 1.1.2 with the wrong result is checked again when you continue it.

## [1.1.2] - 2026-10-17

Fixes from a tester's restore with 1.1.0 on an Intel Mac (macOS 14) after a clean reinstall, where the home folder
had first been brought back from Time Machine. Details: [docs/TESTER_FEEDBACK_1.1.0.md](docs/TESTER_FEEDBACK_1.1.0.md).

### Fixed
- **An old Homebrew made 13 casks fail as “Unexpected problem”.** Homebrew restored by Time Machine was too old for
  today's package definitions (“Unexpected method 'postflight_steps' called on Cask …”). When Homebrew itself says
  so, MacReplica now runs `brew update` once and tries the package again; the summary notes it. A working Homebrew is
  never updated. If the update fails, the items say **Homebrew is too old** with what to do, instead of
  “Unexpected problem”.
- **52 colour profiles for all users failed with “Operation not permitted”.** The administrator copy read each file
  straight from the backup drive, which macOS can refuse (network share, user-mounted drive), and the first refusal
  stopped every remaining file. Each file is now copied to this Mac as you first and checked against its checksum;
  only that copy is installed. After a failure, files that are in place count as restored – checked on disk.
- **“Damaged in the backup” for intact files.** A backup copy that could not be found or read (for example a
  disconnected backup drive) was reported as damaged. It is now **Backup copy could not be read**, with the reason;
  only a checksum that differs counts as damage. **Retry Failed Items** checks first that the backup is reachable.
- **Retry Failed Items lost the rest of the restore.** It ran the failed steps in a new session, so the summary
  afterwards showed only those steps, the guided steps disappeared and apps already present (even MacReplica) were
  listed as “Install these apps yourself”. Retry now runs in the same restore, also retries steps that waited for a
  failed one, and keeps every other result.
- **Your own installers were ignored for apps with a Homebrew cask.** Installers chosen with **Use my installer …**
  were saved in the backup and said “Will be used on the new Mac”, but the cask was used and the installer was never
  offered, not even when the cask failed. Such apps now come back from your installer in the guided steps, and the
  list of apps to install says so instead of “No automatic source was found”.
- **Check Backup said “complete” for a partial backup.** It now says the saved files are undamaged but the backup is
  not complete, and lists the files that could not be saved – matching the reinstall guide.
- **Scanners were counted as “developer tool steps”.** The summary's guided-steps card now names displays, printers
  and scanners separately, so the steps that say “Waiting for you – see the guided steps” can be found.
- The restore report shows how many steps wait for you and where the guided steps are (in MacReplica, not in the
  report), and no longer lists apps that are already installed as apps to install.
- Missing full stop in “Partial: 2 selected files are missing. Everything else …” (reinstall guide and restore
  instructions).

### Changed
- **The reinstall guide is complete on paper.** New section *Install from a USB installer*: Apple's steps to
  download the full installer, the exact `createinstallmedia` command for this Mac's macOS, and how to start up from
  the USB drive on Intel and Apple silicon. On Intel Macs with the T2 chip a warning *before* the erase step says to
  allow external boot media in Startup Security Utility first – it needs an administrator of this Mac, and after
  erasing there is none.
- **The reinstall guide is also available from Check Backup**, written for the backup's Mac with the current
  MacReplica (the copy in the backup is not changed).

## [1.1.1] - 2026-10-16

### Fixed
- **Window corners: the corner-plugin setup now finishes by itself.** In 1.1.0, “Set up automatically” installed
  Plugin Playground and the plugin, then opened Playground's window and asked you to “enable it” – but that window has
  no such switch, so “Plugin Playground is enabled” stayed grey with no clear next step. The setup now also turns on
  Playground's “Disable arm64e (PAC)” setting and sets up and starts its background service (exactly what
  Playground's own *Install* button does), in the same single password prompt. You no longer need to open Plugin
  Playground.
- Every requirement is read from the real system: the service file, whether launchd has it loaded, whether the injector
  runs, the PAC setting, the plugin files, and – new – whether the plugin is actually loaded in MacReplica itself.
  Rows that cannot be read show a question mark instead of a guess. The panel refreshes when you come back to
  MacReplica and says the **next step** in one sentence.
- Running the setup again only does what is still missing. A cancelled or failed run lists each step with ✓/✗, says
  what is already done and that retrying is safe; a service that does not start shows launchd's exit code and asks for
  a restart. Each run is logged with an operation id and a path-free state line.
- **Undo setup** no longer implies the loader stops at once: its injector keeps running until the next restart
  (stopping it from outside can crash the Mac), and the panel says so. Undo now also forgets the loader's installer
  receipt.
- Clear, numbered setup steps in the app, the user guide and docs/TOOLS.md, including what to expect in recoveryOS.
  Intel Macs are shown as unsupported (Plugin Playground exists for Apple silicon only).
- The corner plugin **no longer goes inert on untested macOS builds**. It loads everywhere; on a build MacReplica did
  not verify it shows an orange warning and requires an "at my own risk" checkbox before setup. The per-method class
  checks remain the safety net.

### Changed – honesty about the corner plugin's real scope and cost
On-device testing on macOS 27.0.1 showed the feature is far more invasive than 1.1.0 implied, and reaches fewer apps.
1.1.1 says so plainly in the app, help text, user guide and docs/TOOLS.md:
- **"Disable arm64e (PAC)" runs your Apple-silicon apps from unsigned copies in `/tmp`.** This is how the loader reaches
  Apple's own apps, and it affects *all* arm64e GUI apps, not just the ones the plugin targets. Most work; some crash or
  misbehave. A new orange warning in the panel and in the setup confirmation spells this out.
- **Some apps crash** when the plugin is injected (strict code-signing → `CODESIGNING, Invalid Page`). **Microsoft
  AutoUpdate** is confirmed and is now in the shipped blacklist; you can add your own fragile apps. The blacklist stops
  our plugin from loading into an app, but not the loader's `/tmp` stripping.
- **Safari and other hardened Apple apps cannot be changed** (they refuse injection). The "Buttons in all apps" wording
  is corrected to "apps that allow it".
- **The Quick Look window is a no-op on current macOS** — its Liquid Glass frame keeps its own corners. The option and
  its preview now say so.
- **Partial SIP may not be enough on recent macOS.** `csrutil enable --without debug` lets the loader install but the
  injector can be killed by AMFI on 27; full `csrutil disable` may be required. The steps keep the smaller change but
  warn, and the injector-running check shows red when injection does not actually work. A compatibility issue was filed
  with Plugin Playground.

### Documentation
- Checked against the 1.1.0 code: the README and SECURITY.md now list every server MacReplica contacts, say that the
  backup is not encrypted apart from the contents of credentials, describe the administrator steps and the Homebrew
  password exactly, and name which app-data categories were confirmed in the real apps. Corrected: Full Disk Access
  (Troubleshooting), the restore defaults, the Tools' quarantine and plugin details (Apple silicon only), the
  architecture overview, credential permissions, and the 1.0.5 changelog entry (it shipped with Ammonia; Plugin
  Playground came in 1.0.6). New screenshots from 1.1.0, including Tools and your own installers.

## [1.1.0] - 2026-10-15

### Fixed
- **Working disk images were reported as damaged.** Installers chosen with **Use my installer …** – among them the
  DisplayCAL installer a tester had just installed from – showed *“The file cannot be opened: it is damaged,
  incomplete (an interrupted download?) or encrypted”*. MacReplica treated every failed `hdiutil` step as damage,
  although `hdiutil` fails the same way (exit status 1, a translated message) when an image is already open, when
  its mount folder disappears, when it has no file system macOS mounts, or when it is password-protected. Now only
  proof counts: a file cut short, or an image whose own checksum `hdiutil verify` rejects. An intact installer that
  MacReplica cannot open or recognise is **kept**, with the reason and the tools' own words under **Details**. It is
  used after you confirm it, and on the new Mac it is opened in Finder for you if MacReplica cannot open it there.
  See [docs/INSTALLER_VALIDATION.md](docs/INSTALLER_VALIDATION.md).
- A disk image that was **already open** (for example in Finder after installing from it) was ejected without
  asking. It is now read where it is open and left open; attachments of other programs are never detached.
- Choosing an **encrypted** disk image made macOS ask for its password in a dialog behind MacReplica, and after two
  minutes the image was called damaged. Encrypted images are recognised from the file itself and kept unopened.
- Two inspections at the same time shared a work folder; the first one to finish removed it, and the other image
  could no longer be mounted. Every inspection now has a folder of its own.
- An installer package that `pkgutil` reports as **invalid** (cut short or changed) was accepted as “not signed”.
  It is now reported as damaged.
- The guided installation said *“Homebrew's checksum of the file”* for your own installer. It now says that the
  checksum recorded on the old Mac is checked.

### Added
- Clear reasons when an installer is not used: **incomplete** (its end is missing), **damaged** (its checksum does
  not match), **not an installer** (for example a web page saved instead of the download, or an empty file), **not
  recognised** (damage not proven, with what to try next) – each with a **Checked:** line naming the tool and its
  result. English, German, Norwegian Bokmål, French, Spanish, Italian and Dutch.
- Kept installers whose contents MacReplica could not check say why: protected by a password, could not be opened on
  this Mac, description could not be read, check did not finish, no app found where MacReplica looks, or could not be
  unpacked here.
- **Real installers** workflow: MacReplica's inspection on real, officially published installers (DisplayCAL,
  AppPolice, Brackets, Karabiner-Elements, Rectangle, Stats, KeepingYouAwake) and damaged copies of them on macOS 14,
  15, 26 and Intel. `MacReplicaSimulator inspect-installer` runs it locally.

## [1.0.7] - 2026-10-15

### Fixed
- **Keys and password databases: any number, from anywhere.** After one key or database had been included, further
  ones could not be added: including a file outside the chosen folders created a hidden one-file folder, and a later
  **Include …** into that folder silently did nothing. Files in the home folder itself, in iCloud Drive or on another
  drive could not be included at all, and deselecting one folder could make another folder's credential files
  disappear from "Not in this backup". Credentials are now independent items. Add any number from any place, with
  duplicates (also through links) recognised. Nothing a user chose or decided ever disappears from the lists.
- Credential files that were included used to be copied into the backup **unencrypted**. They are now always
  encrypted.

### Added
- **Passwords, keys and credentials** section: **Add Keys or Password Files …** (several files and folders at once),
  **Add Encrypted** / **Leave Out** for every credential file found, and what cannot be copied as a file (keychains,
  browser password stores). **Needs a step by you** shows the supported route for passkeys, iCloud Keychain, Chrome,
  Edge, Brave, Firefox, 1Password and Bitwarden. Before saving, credential files nobody decided on are shown once
  more.
- **Encrypted credential store** (manifest version 4): every item encrypted on its own (AES-256-GCM in 64 KiB
  records). The key is protected by your passphrase (PBKDF2-HMAC-SHA256, 600,000 iterations) **and a recovery key**
  shown once. Each item is decrypted and compared before it counts as preserved. The manifest records every item's
  status, format, prerequisites and the reason when it could not be preserved, never contents or plain hashes.
  Backups without credentials stay version 3.
- **Credential restore**: passphrase or recovery key, checked in the sheet. Asked before the pre-restore check, so a
  credential that differs from this Mac's file gets a decision (keep this Mac's version, keep both, replace, skip).
  Each item is verified after writing (same bytes, same format), and the result says what you still need (master
  password, key passphrase). A file whose drive is not connected goes to `~/MacReplica Restored Credentials`.
- Recognises more credential files: SSH/PGP private keys saved under any name without an extension (from the first
  line), Password Safe `.psafe3`, 1Password exports (`.1pux`, `.1pif`) and recovery codes or emergency kits.
- Reports and restore instructions include a **Passwords, keys and credentials** readiness section.
- [docs/CREDENTIALS.md](docs/CREDENTIALS.md): policy per category, encryption format, recovery, sources.

### Changed
- The SSH, AWS, Git, npm, Kubernetes and Terraform providers now write into the same encrypted store (one passphrase
  and recovery key for everything). Version 1 vaults of older backups are still restored.

## [1.0.6] - 2026-10-14

### Added
- **Window corners:** an example preview (the eye next to each surface) shows the element at the default vs. the
  reduced corner, so you see what a change does before applying it.
- **Window corners – one-click plugin setup.** The advanced plugin (menus, popovers, Quick Look, toolbar groups and
  capsule buttons) now uses **Plugin Playground**, a maintained tweak loader with public source (no licence; MacReplica
  downloads its pinned release and never bundles it), instead of the archived
  Ammonia. It needs System Integrity Protection only partly off (debugging allowed) — still your step, MacReplica
  never changes SIP — and no boot argument. **Set up automatically** downloads the pinned, checksum-verified loader,
  installs it and the plugin with one administrator prompt and opens Plugin Playground to enable; **Undo setup**
  removes the plugin and uninstalls the loader. It falls back to the manual steps if the download or checksum fails.
- **Gatekeeper:** the single-app check can now open the app or remove and restore its quarantine mark (one app, after
  a warning, with the exact mark kept for an exact undo).

### Changed
- **ChromIQ (and other developer taps MacReplica documents) restore through Homebrew automatically:** the tap now
  starts enabled in the restore selection — but only when the backup names it with its known address — so the app is
  installed without the tap being left switched off. Verified end to end against the real Homebrew.
- Rewrote the Gatekeeper and macOS-update help so it describes the profile, quarantine and deferral options MacReplica
  now offers, instead of saying it never touches them.

## [1.0.5] - 2026-10-13

### Added
- **Tools** – a fourth option on the start screen with three tools for this Mac. Each tool shows what it finds,
  asks before changing anything, checks the real result afterwards and keeps a short history (docs/TOOLS.md).
  - **Gatekeeper and app security:**
    - Shows whether macOS checks apps and why not (for example a profile).
    - Checks a single app: signature, notarisation, quarantine and Gatekeeper's verdict. It guides you through
      Apple's “Open Anyway”, or opens the app or removes its quarantine mark at your request (with a way back).
    - On request and after a warning, it prepares a profile that turns app checking off for the whole Mac, and
      helps you remove exactly that profile again.
  - **macOS updates:**
    - Shows the automatic-update switches and whether this macOS version still gets security updates.
    - Guides you to a setup that keeps this version current without upgrading.
    - Where Apple still allows it without device management (macOS 13–15.7.4 and 26), it can postpone major
      upgrades by up to 90 days with a profile. On macOS 27 this is no longer possible, and the tool says so.
  - **Window corners (experimental, macOS 26.4 and later):**
    - Less rounded app windows and utility panels (2–24 pt) and classic menus, through undocumented AppKit
      settings, with an exact way back.
    - One radius for everything by default, or one per surface, and every surface can be left out.
    - Advanced, behind warnings: a corner plugin for the Ammonia tweak loader that also changes menus, popovers,
      the Quick Look window, toolbar groups and capsule buttons in all apps. It needs System Integrity Protection
      off, which only you can do, and does nothing on untested macOS builds. (Replaced by Plugin Playground and a
      one-click setup in 1.0.6.)

### Fixed
- **A backup could be removed completely** when Word (or another Office app) was open: its temporary lock file
  `~$Normal.dotm` made the final check fail. Office lock files are skipped now, and a file whose name a backup
  cannot hold is left out with a reason instead of failing the backup.
- **Installers you chose with “Use my installer …” were not written into the backup's manifest** (since 1.0.2):
  copied into the backup, they were still not offered on the new Mac. They are now, and every new field of a backup is
  checked to survive writing and reading.
- Disk images with a licence agreement (OnyX, SuperDuper!, Krita, Murus …) were reported as unreadable; they are
  recognised and opened in Finder on the new Mac so you can accept the licence.
- Casks from third-party taps (for example ChromIQ's) were reported as failed after a successful installation.
- Cakebrew and other apps whose Homebrew cask was **removed or disabled** were promised as “restorable with Homebrew”
  and failed on the new Mac. They now get the developer's download or your installer, with Homebrew's reason
  (DisplayCAL: disabled on 2026-09-01 because it does not pass Apple's Gatekeeper check).
- Files removed between scanning and saving are reported as “no longer there” instead of “unreadable”.
- Keynote presentations (`.key`) were left out as if they were keys.
- The restore screen called every backup “complete”.

### Added
- **What is not in the backup, and why**: every file left out is listed with its path, what it appears to be (an
  encrypted KeePass database, a key file, a private key, a certificate …, from its name and format only – contents are
  never read) and what to do – on the selection screen, after saving, on the new Mac and in the reports. A file that
  looks like a secret can be included on request (keychains and browser logins never). Backups are *complete*,
  *complete except files left out on purpose* or *partial*.
- **KeePassXC**: its settings, and the databases KeePassXC remembers are listed so you can include them (they stay
  encrypted; key files are never included without a warning that this removes their protection).
- **MacReplica in every backup**: a verified, universal copy of MacReplica is put next to the README, so the restore
  can start on a freshly installed Mac without a download.
- **Printable macOS reinstall guide** for the Mac the backup was made on: Intel (with or without T2) or Apple silicon,
  the right startup keys or options, erase and install steps, first start, Apple's support pages.
- **macOS settings**: Dock and hot corners, Finder, keyboard, trackpad and mouse, language and region, appearance,
  screenshots, menu bar clock, and (optionally) keyboard shortcuts and input sources – applied through macOS and read
  back on the new Mac; settings from an older macOS only where their meaning is stable. What is never transferred
  (Accessibility, privacy permissions, wallpaper …) is listed with the reason.
- **Printers and scanners**: each printer's name, connection, model and driver (and its PPD for reference) and the
  scanner drivers; on the new Mac MacReplica guides you to add them (manufacturer's driver first where needed) and
  checks that they are there.
- **Your installers**: every chosen file shows what it is, what is inside (app, version, processors, signature), where
  it is, whether it will be used and what happens on the new Mac – or why it cannot be used. Apps (`.app`) can be
  chosen directly. Installers without a Developer ID (DisplayCAL, ChromIQ …) can be used after you confirm it; the
  checksum is still checked and macOS still asks you to approve the app. Suites such as DisplayCAL with its companion
  apps are installed as their folder.
- **Homebrew**: casks of the taps on the old Mac and the developer's own tap (ChromIQ) are found; the restore screen
  says which apps need each tap. Companion apps (DisplayCAL's 3D LUT Maker …) are installed with their main app.
  Cakebrew and Applite are shown as Homebrew front ends – restoring them restores no packages.
- **Versions**: each source says which version it installs compared with the old Mac; a beta is never switched to
  stable (or the other way round) without your choice.
- **Microsoft Office**: whether Office used a volume licence (Office LTSC) or a sign-in, and what that means on the
  new Mac; the Office packages in the match choice are explained.
- **VueScan**: settings and saved option sets in `~/Pictures/VueScan`.
- **Keychain passwords**: Apple's supported ways to move them (iCloud Keychain, the Passwords app, `.p12` for
  certificates) – nothing is copied.
- Visible help (**?** buttons with an explanation) next to the options; hover help alone was easy to miss.
- New choices are kept in the saved selection.

## [1.0.4] - 2026-10-04

### Added
- Before you erase your Mac: when the backup includes Homebrew packages, MacReplica says how well Homebrew supports
  this Mac's macOS and processor (Homebrew's support tiers, dated, with the source). On Tier 3 systems — Intel Macs
  and Apple silicon with macOS 14 or older — some command-line tools may be built from source or fail after a fresh
  installation; Homebrew expects to end Intel support from September 2027. The notice is also in the backup's report
  and restore instructions, and on the new Mac in the restore selection.

### Fixed
- A disk image that macOS attached during an attempt it reported as failed is detached before the next attempt,
  so no second copy stays attached until logout.

## [1.0.3] - 2026-10-04

### Added
- LibreOffice: settings (Tools › Options, your name, paths with the home folder adjusted), templates, AutoCorrect,
  AutoText, custom dictionaries, menus, toolbars and keyboard shortcuts, colour palettes and Gallery themes; Basic
  macros and your scripts are offered but not selected automatically. Automatic document backups, temporary files,
  crash data and extensions are never copied. Settings, templates, dictionaries and toolbars were confirmed inside
  LibreOffice 26.8.
- Backup location on the selection screen: where the backup goes (with the drive's name), its free space and how
  large the backup will be, before anything is written; **Save Backup** saves there.
- Save and load your selection: **Save Selection …** / **Load Selection …**, and the selection is saved next to the
  backup automatically (`MacReplica Selection.json`). At the next backup MacReplica offers to use it. New apps and
  data keep their usual setting; passphrases are never saved.
- Explanations on every kind of application data (hover): what it is, what the backup contains with example file
  names, where it comes from, what the support level means and any notes.

### Fixed
- Homebrew that cannot read its version from git (for example without the Command Line Tools, or installed by
  another administrator) was reported as "does not respond" and its packages were not recorded. It is used now,
  and the log names the reason whenever Homebrew is not used.
- Disk images (downloads and your own installers) are attached and detached one at a time and retried when macOS
  reports them as busy; an image is never left attached after a failed attempt.

## [1.0.2] - 2026-10-04

### Added
- Launchpad layout (macOS 13–15): pages, folders with their names and the order of the apps are recorded
  with the backup and arranged again as the last step of the restore, once the apps are installed. Apps
  that are not restored are left out (their folders keep the others); apps that were not in the layout
  follow on further pages; while apps of the restore still wait to be installed, Launchpad is arranged
  with what is there and again when the restore continues. Validated on real macOS 14 and 15, including
  a macOS 14 layout on macOS 15. macOS 26 and later have no Launchpad: the backup's report keeps the
  layout as a reference.
- Application data for Krita, GIMP, Inkscape, Scribus, Microsoft Word/Excel/PowerPoint (templates incl.
  Normal.dotm, AutoCorrect, custom dictionary; start-up add-ins offered separately), Apple Mail
  (signatures, rules, smart mailboxes, VIPs – needs Full Disk Access), Cryptomator (the vault list; vaults
  stay where they are), DisplayCAL and ArgyllCMS (calibrations, settings, instrument corrections), BenQ
  Palette Master Element and XP-Pen (experimental), Karabiner-Elements, Hammerspoon, Ghostty, kitty,
  WezTerm, Alacritty, Zed, Motion templates and Logic Pro patches. Paths that contain the home folder are
  stored as a placeholder and filled in with the new Mac's home folder.
- Confidence levels for every kind of application data (*verified*, *check in the app*, *experimental*),
  shown in the backup and restore selection. Data that contains code (plug-ins, scripts, add-ins) is
  offered but never selected automatically.
- Your own installers (offline): installer packages, disk images and zip archives kept for an app (for
  example Microsoft Office LTSC with its activation package, or a tablet driver) can be recorded and
  optionally copied into the backup. On the new Mac they are used without internet, only if checksum and
  developer still match; packages open in Apple's Installer, nothing in them is run by MacReplica.
- Guidance for Synology Drive, calibration software, BenQ Palette Master, XP-Pen, mail accounts and Office
  activation (what MacReplica cannot carry over and why).
- Restore: steps that need Full Disk Access wait for it and continue after it is granted.
- Your own folders: folders of the home folder (documents, pictures, projects) can be added to the backup,
  each on its own and without a size limit, and are restored as their own group. The home folder as a whole
  and `~/Library` are not offered; files that are only in iCloud are left out and listed.
- The backup checks the free space of the destination before writing and stops with a clear message if
  it does not fit.

### Changed
- Confidence levels from real-app checks: Krita, GIMP, Inkscape, Scribus, Cryptomator, DisplayCAL and Word's
  AutoCorrect were confirmed in the apps themselves (*verified*); Apple Mail is *experimental* (its files
  follow Apple's layout up to macOS 15, but Mail itself could not be checked).
- Backup format version 3. MacReplica 1.0.1 refuses these backups instead of restoring them wrongly.

### Fixed
- The administrator password is asked for once per restore instead of once per package (Homebrew's
  `sudo` gets it from MacReplica through a private, token-protected channel; a wrong password is asked
  for again, never stored).
- `mas` is only asked for when an App Store app cannot be identified otherwise, and MacReplica offers to
  install it.
- An app found in several places (for example Zoom in `/Applications` and `~/Applications`) is listed once.
- GIMP 3: thumbnails, font caches and crash reports are no longer backed up; resource tags stay valid
  under another user name.
- Inspecting a disk image no longer leaves it mounted.
- Krita's Python plug-ins are only restored when chosen (they were also part of the resource folder).
- The restore summary no longer lists apps to install yourself that are installed by then.
- The note before a restore describes how the administrator password is now asked for.
- Home-folder paths in settings files are replaced only as a whole path component (another user's folder
  with a longer name stays as it is).

## [1.0.1] - 2026-10-03

### Added
- Developer tools and package managers: pyenv, uv, pipx, Conda, nvm, fnm, Volta, npm/pnpm/Yarn global
  packages, rbenv, RVM, gems, rustup, Cargo, Go, JDKs, SDKMAN, .NET, MacPorts, Nix, Pixi, mise, asdf
  (pkgx and Fink listed only). Scans read files only; restores run the managers' own commands without
  a shell; steps MacReplica cannot run are guided and verified.
- Python: environments are rebuilt with exactly the recorded pyenv or uv Python; uv projects from
  `uv.lock` with `uv sync --frozen`; `uv.lock`, `pylock.toml`, `environment.yml` and `hatch.toml` are kept.
- Release channels (beta, nightly, insider, preview) with their evidence, the vendor's update feed and
  the developer Team ID are recorded per app; casks keep their channel on restore.
- Guided installation: official download sources (vendor update feed, Homebrew's vendor URL, App Store
  page, vendor website), verification before installing (vendor signature or checksum, bundle
  identifier, Team ID, code signature, architecture, macOS version), download queue with pause,
  resume, retry and cancel, installation one after another, quarantine kept for Gatekeeper.
- Steps that wait for the user, and steps skipped, postponed or cancelled by the user, are recorded as
  such (not as failures) and offered again when the restore continues, also after quitting.
- Backup selection for individual apps and for each developer tool.
- Homebrew development builds (`--HEAD`) are reproduced unless the stable release is chosen.
- Display profile assignments: the profile each display uses is recorded (displays and the Mac only as
  salted hashes) and assigned again to the same display, verified by reading it back; displays that are not
  connected wait; the built-in display of another Mac is left alone.
- Python: optional complete copy of a virtual environment for reinstalling on the same Mac; used only after
  checks and a run of the environment, otherwise rebuilt from its packages (the default stays the rebuild).
- Photoshop (Beta) as its own provider; more Photoshop presets and settings (the Adobe-listed panel files,
  colour settings, workspaces, document presets, preferences for the same version); Adobe colour settings;
  Camera Raw defaults. Presets go into the Photoshop version installed on the new Mac, or the original one.
- DaVinci Resolve: user LUTs from the shared LUT folder (without the LUTs Resolve installs), ACES transforms,
  Fairlight presets, keyboard, layout and user-preference presets, smart bins, metadata presets. Data that
  needs its app waits until the app is installed and is never restored into an older version.
- Application data conflicts: keep this Mac's files, replace with the backup or skip, with a list of the
  files that differ.

### Fixed
- Command timeouts could fire late, or not at all, while many commands ran at the same time (blocking
  output readers used GCD's limited global worker threads); readers now have their own threads and
  timeouts their own queue.
- Photoshop beta data was not detected. Resolve's keyboard and layout presets live in
  `~/Library/Preferences/Blackmagic Design/DaVinci Resolve/`, not in Application Support.
- Mac App Store apps could not be reinstalled with current `mas` (7.0 requires root for `mas install`).
  App Store apps are now installed from the App Store page MacReplica opens, and verified.
- Third-party taps are trusted after the user allows them (`brew trust --tap`), as Homebrew 6 and
  later require before loading their packages.

### Changed
- Backup format version 2 (`manifest_version`): backups of 1.0.0 are read as before; MacReplica 1.0.0
  refuses version 2 backups with a clear message instead of restoring new kinds of data (such as
  DaVinci Resolve LUTs in `/Library`) to the wrong place. Update MacReplica on the new Mac first.
- Release pipeline: every release is built, installed and launched on macOS 14, 15 and 26 (Apple
  silicon) and macOS 15 (Intel) before it is published; release notes include download, checksum,
  first-launch and compatibility information.
- The full test suite also runs natively on Intel in CI.
- Documentation: build guide, release process, troubleshooting, testing guide, code of conduct,
  issue forms and screenshots of the current app.

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

[Unreleased]: https://github.com/itsab1989/MacReplica/compare/v1.1.9...HEAD
[1.1.9]: https://github.com/itsab1989/MacReplica/compare/v1.1.8...v1.1.9
[1.1.8]: https://github.com/itsab1989/MacReplica/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/itsab1989/MacReplica/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/itsab1989/MacReplica/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/itsab1989/MacReplica/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/itsab1989/MacReplica/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/itsab1989/MacReplica/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/itsab1989/MacReplica/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/itsab1989/MacReplica/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/itsab1989/MacReplica/compare/v1.0.7...v1.1.0
[1.0.7]: https://github.com/itsab1989/MacReplica/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/itsab1989/MacReplica/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/itsab1989/MacReplica/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/itsab1989/MacReplica/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/itsab1989/MacReplica/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/itsab1989/MacReplica/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/itsab1989/MacReplica/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/itsab1989/MacReplica/releases/tag/v1.0.0
