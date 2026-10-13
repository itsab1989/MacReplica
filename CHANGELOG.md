# Changelog

All notable changes to MacReplica are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and MacReplica uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The backup format has its own version
(`manifest_version`), independent of the app version.

## [Unreleased]

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
      off, which only you can do, and does nothing on untested macOS builds.

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

[Unreleased]: https://github.com/itsab1989/MacReplica/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/itsab1989/MacReplica/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/itsab1989/MacReplica/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/itsab1989/MacReplica/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/itsab1989/MacReplica/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/itsab1989/MacReplica/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/itsab1989/MacReplica/releases/tag/v1.0.0
