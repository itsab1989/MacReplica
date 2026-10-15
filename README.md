<p align="center">
  <img src="docs/images/icon.png" alt="MacReplica app icon" width="112" height="112">
</p>

<h1 align="center">MacReplica</h1>

<p align="center">
  <strong>Bring your apps, settings and development environments to a freshly installed Mac.</strong>
</p>

<p align="center">
  <a href="https://github.com/itsab1989/MacReplica/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/itsab1989/MacReplica?label=release&color=4c6ef5"></a>
  <a href="https://github.com/itsab1989/MacReplica/actions/workflows/tests.yml"><img alt="Tests" src="https://github.com/itsab1989/MacReplica/actions/workflows/tests.yml/badge.svg"></a>
  <a href="https://github.com/itsab1989/MacReplica/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/itsab1989/MacReplica/total?color=2a9d8f"></a>
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-555">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/github/license/itsab1989/MacReplica?color=blue"></a>
</p>

<p align="center">
  <strong><a href="https://github.com/itsab1989/MacReplica/releases/latest">⬇️ Download</a></strong>
  &nbsp;·&nbsp;
  <a href="docs/USER_GUIDE.md">User guide</a>
  &nbsp;·&nbsp;
  <a href="#known-limitations">Limitations</a>
  &nbsp;·&nbsp;
  <a href="#support-the-developer">Support</a>
</p>

<p align="center">
  <img src="docs/images/macreplica-start.png" alt="MacReplica start screen with Create Backup, Restore, Check Backup and Tools" width="720">
</p>

Setting up a Mac from scratch is a good way to leave old clutter behind — but then you spend days
reinstalling apps, hunting for fonts and colour profiles, and rebuilding Python environments.
Migration Assistant avoids that, but copies everything, including what you wanted to leave behind.

**MacReplica sits in between.** On the old Mac it records what you have and saves what you choose
into one backup folder. On the new Mac it reinstalls your apps from reliable sources, recreates
your Python environments and puts back the fonts, colour profiles and app settings you selected —
checking every step and telling you clearly what still needs your attention.

MacReplica is a native macOS app. You do not need the Terminal.

---

## Contents

- [What MacReplica can preserve](#what-macreplica-can-preserve)
- [How it works](#how-it-works)
- [Screenshots](#screenshots)
- [Installation](#installation) · [Requirements and compatibility](#requirements-and-compatibility)
- [Using MacReplica](#using-macreplica) · [Tools](docs/TOOLS.md)
- [Details](#details): apps · guided installation · developer tools · app data · Python · fonts and ICC profiles · dry run and resume
- [Permissions, security and privacy](#permissions-security-and-privacy)
- [Logs and troubleshooting](#logs-and-troubleshooting)
- [Known limitations](#known-limitations)
- [Building from source](#building-from-source) · [Testing](#testing) · [Contributing](#contributing)
- [Support the developer](#support-the-developer) · [License](#license)

## What MacReplica can preserve

| | What is recorded on the old Mac | What happens on the new Mac |
|---|---|---|
| **Apps** | Apps in `/Applications` and `~/Applications` with version, vendor, architecture, release channel (beta, nightly …) and update feed | Reinstalled with Homebrew where a reliable package exists; everything else in a guided installation with verified official downloads |
| **Homebrew** | Formulae (including `--HEAD` builds), casks and taps | Xcode Command Line Tools and Homebrew are installed if needed, then your packages |
| **Mac App Store** | Apps installed from the App Store | MacReplica opens each app's App Store page; you click *Get* and MacReplica checks the result |
| **Developer tools** | Version managers, language versions, global tools and other package managers: pyenv, uv, pipx, Conda, nvm, fnm, Volta, npm/pnpm/Yarn, rbenv, RVM, gems, rustup, Cargo, Go, JDKs, SDKMAN, .NET, MacPorts, Nix, Pixi, mise, asdf | Managers from Homebrew, then versions, tools and environments — automatically where possible, as guided steps where not ([details](docs/DEVELOPER_ENVIRONMENTS.md)) |
| **Python** | Environments, Python versions, packages, lock files and project settings | Environments are rebuilt with the same Python version (exactly from pyenv or uv when available) and packages; uv projects from `uv.lock` — not copied |
| **App data** | Settings, presets, templates and resources of supported apps, each marked *Fully supported*, *Check in the app* or *Experimental* | Copied back after checks, into the right app version; caches, databases, licences and passwords are never included |
| **Your own folders** *(optional)* | Folders of your home folder you add (documents, pictures, projects), each on its own, no size limit | Copied back to the same place; existing files are kept unless you choose otherwise |
| **Launchpad** | Pages, folders with their names and the order of the apps (macOS 13–15) | Arranged last, once the apps are installed (macOS 13–15; a reference in the report on macOS 26 and later) |
| **Your installers** *(optional)* | Installers you keep (`.pkg`, `.dmg`, `.zip`, or the `.app` itself, e.g. Office LTSC with its activation package) — each shown with what is inside and whether it will be used; a file is only called damaged when that is proven, intact installers MacReplica cannot look inside are kept with the reason ([details](docs/INSTALLER_VALIDATION.md)); optionally copied into the backup | Used offline, only if the checksum matches and the developer is verified – or, for apps without a Developer ID or with contents MacReplica could not check, after you confirmed it (such an installer is opened in Finder for you if MacReplica cannot open it) |
| **macOS settings** | Dock and hot corners, Finder, keyboard, trackpad and mouse, language and region, appearance, screenshots, menu bar clock; optionally keyboard shortcuts and input sources | Applied through macOS and read back; from an older macOS only where the meaning is stable |
| **Printers and scanners** | Each printer's name, connection, model and driver (PPD for reference), scanner drivers | Guided: you add each printer (with the manufacturer's driver where needed), MacReplica checks it is there |
| **MacReplica itself** | A verified copy of MacReplica (Apple silicon and Intel) in the backup when it can be copied and checked (otherwise the backup says so), plus a printable reinstall guide for this Mac | Start the restore from the backup – no download needed |
| **Fonts and ICC profiles** | Each file individually selectable, with its identity; which colour profile each display used | Compared with what the new Mac already has before anything is copied; a display's profile is assigned again to the same display once it is connected (a built-in display only on the same Mac) |
| **Git settings** | Name, aliases and preferences (email only if you choose) | Written to `~/.gitconfig` |
| **Passwords, keys and credentials** *(optional)* | Any number of key files, password databases and credential files you add, from anywhere — the contents of each are encrypted and verified (names and paths stay readable) | Restored only with your passphrase or recovery key, with a decision for every conflict |

MacReplica does **not** clone your disk, copy whole Library folders or preference files, copy drivers or system
databases, or migrate logins stored in the Keychain. Everything it leaves out is listed with the reason – check that
list (“Not in this backup”) and run **Check Backup** before you erase the old Mac. Apart from the credentials you add,
the backup is **not encrypted**: store it where only you can read it (for example an encrypted external drive).

## How it works

```
 old Mac                                   new Mac
 ───────                                   ───────
 1. Scan (read-only)                       5. Open the backup – it is checked first
 2. Choose what to take with you           6. Choose what to put onto this Mac
 3. Save the backup folder                 7. Preview (Dry Run) if you like
 4. Check it, copy it to the new Mac       8. Restore – every step is verified
```

The selection happens **twice**: on the old Mac you decide what goes into the backup; on the new
Mac you decide what is actually restored, with each item showing what it would mean on that Mac
(*ready*, *already installed*, *provided by macOS*, *different version*, …). You never have to make
a new backup to restore less.

## Screenshots

All screenshots show MacReplica 1.1.0 with a simulated Mac and synthetic test data.

| | |
|:---:|:---:|
| <img src="docs/images/macreplica-inventory.png" alt="Scan results: how each app will be restored, what else is included, the backup location and your installers" width="420"> | <img src="docs/images/macreplica-app-data.png" alt="Application data grouped by app, each with its support label, path and warnings for data that may contain secrets or depend on the app version" width="420"> |
| **Scan results** – how each app will come back | **App data** – per app, with its support label and warnings |
| <img src="docs/images/macreplica-own-installers.png" alt="Your installers for DisplayCAL: its disk image with the apps inside, and an intact image that could not be opened, kept with the reason and details" width="420"> | <img src="docs/images/macreplica-backup-saved.png" alt="Backup saved and checked, complete, with a copy of MacReplica for Apple silicon and Intel, location, size and the Reinstall Guide" width="420"> |
| **Your installers** – what is inside, or why it could not be checked | **Backup saved** – checked, complete, with MacReplica inside |
| <img src="docs/images/macreplica-restore-selection.png" alt="Restore selection on the new Mac with a checkbox and count per area" width="420"> | <img src="docs/images/macreplica-restore-items.png" alt="Individual items with matches to confirm and the status of each app and Homebrew package on the new Mac" width="420"> |
| **Restore selection** – what to put onto this Mac | **Individual items** – status and decisions |
| <img src="docs/images/macreplica-dry-run.png" alt="Preview listing what would be installed or copied, nothing changed" width="420"> | <img src="docs/images/macreplica-conflicts.png" alt="Dialog with fonts and a colour profile that already exist on the new Mac, each with a choice such as keep this Mac's version or keep both" width="420"> |
| **Preview (Dry Run)** – nothing is changed | **Decisions** – nothing is overwritten without your choice |
| <img src="docs/images/macreplica-restore-complete.png" alt="Summary with successful, failed, skipped and waiting counts, guided steps for an App Store app and developer tools, and notes per item" width="420"> | <img src="docs/images/macreplica-tools.png" alt="Tools: Gatekeeper state with a check for one app, and macOS update settings" width="420"> |
| **Summary** – what worked and what is left for you | **Tools** – Gatekeeper, macOS updates, window corners |

<details>
<summary>More screenshots</summary>

| | |
|:---:|:---:|
| <img src="docs/images/macreplica-settings.png" alt="Settings with language, log files, update options, version and support link" width="380"> | <img src="docs/images/macreplica-about.png" alt="About window with version 1.1.0, macOS 13 or later on Apple silicon and Intel, Ko-fi and GitHub links" width="300"> |
| Settings | About MacReplica |

</details>

## Installation

1. Download the latest **`MacReplica-<version>.dmg`** from
   [Releases](https://github.com/itsab1989/MacReplica/releases/latest). Each release also lists the
   SHA-256 checksum of the disk image.
2. Open the disk image and drag **MacReplica** into **Applications**.
3. Open MacReplica from Applications.

**First launch.** MacReplica is not signed with an Apple Developer ID and not notarized (the project
has no paid Apple Developer membership), so macOS blocks the first launch. To allow it:

1. Try to open MacReplica once and close the message.
2. Open **Apple menu → System Settings → Privacy & Security**.
3. In **Security**, next to the message about MacReplica, click **Open Anyway** (shown for about an
   hour after the attempt), then enter your login password.

macOS remembers this; later launches work normally. Control-click → **Open** no longer works for this
since macOS 15. Details and sources: [Troubleshooting](docs/TROUBLESHOOTING.md#macos-says-macreplica-cannot-be-opened).

### Requirements and compatibility

MacReplica requires **macOS 13 Ventura or later** (the deployment target; the compiler checks every
API against it) and is one **universal app** for Apple silicon and Intel. What has actually been
run:

| macOS | Mac | What was tested |
|---|---|---|
| 27.0 | Apple silicon | developer's Mac: full test suite, all workflows in the real app with simulated Macs, release disk image downloaded with Safari, installed and launched; Intel slice launched and a full scan run under Rosetta |
| 26.6 | Apple silicon | CI: release disk image verified, installed and launched |
| 15.7 | Apple silicon | CI: full test suite; release disk image verified, installed and launched |
| 15.7 | Intel | CI: full test suite natively on x86_64; release disk image verified, installed and launched |
| 14.8 | Apple silicon | CI: release disk image verified, installed and launched |
| 13 | — | not tested (no test machine available); supported by the deployment target |

“Launched” means the app started completely (`scripts/smoke-test.sh`). Restoring onto a real
(non-simulated) Mac is done by users; please report problems on your macOS version.

**Updating:** *MacReplica → Check for Updates …* compares your version with the latest GitHub
release and opens the release page if there is a newer one. You can also let MacReplica check once a
week (*Settings*, off by default). MacReplica never downloads or installs updates by itself — to
update, download the new disk image and replace the app.

## Using MacReplica

**On the old Mac**

1. Click **Create Backup**. MacReplica scans the Mac; nothing is changed.
2. Review the results (**What do you want to take with you?**): confirm Homebrew packages for apps
   MacReplica was not sure about, and choose fonts, colour profiles, Python environments and app
   data. Passwords, keys and credentials are in the backup only if you add them (their contents are always encrypted).
3. Under **Backup location**, choose a folder — ideally on an external drive or in a cloud folder — and check the
   free space shown there; then click **Save Backup**. **Save Selection …** keeps your choices for the next backup.
   MacReplica copies the selected files, compares each copy with the original and shows where the
   backup is and how big it is.
4. Copy the whole backup folder to the new Mac (external drive, network share, cloud folder or
   AirDrop). **Check Backup** verifies a backup at any time.

**On the new Mac**

1. Open MacReplica, click **Restore** and choose the backup folder. MacReplica checks the backup
   and then the new Mac.
2. In **What do you want to put onto this Mac?** everything from the backup is selected except items
   that are not recommended on this Mac and the encrypted credentials (tick them and enter the passphrase or recovery
   key). Leave out what you do not want; use
   **Choose Individual Items …** for details and decisions.
3. Click **Preview (Dry Run)** to see exactly what would happen, or **Start Restore**.
4. If something needs administrator rights (Homebrew, packages with installers, shared folders),
   MacReplica explains why; for Homebrew packages it asks once per restore in its own window.
5. Read the summary: what worked, what failed and what to do about it, apps to install yourself
   and services to sign in to again. **Retry Failed Items** runs only the failed steps again.

**Tools** (fourth option on the start screen): three independent tools for this Mac. Each one shows what it
finds, asks before changing anything and checks the real result afterwards ([details](docs/TOOLS.md)):
- **Gatekeeper and app security:** why apps are or are not checked, a check of one app with Apple's “Open Anyway”,
  opening it or removing its quarantine mark on request, and – after a warning – a profile that turns app
  checking off for the whole Mac, with the way back.
- **macOS updates:** your update switches, whether your macOS version still gets security updates, a setup that
  keeps the current version up to date, and – where Apple still allows it – postponing major upgrades by up to
  90 days (not possible on macOS 27).
- **Window corners** (experimental, macOS 26.4 and later): less rounded app windows and panels, classic menus – one
  radius for everything or one per surface, with an example preview of each. Menus, popovers, Quick Look, toolbar
  groups and capsule buttons only through an optional plugin (Apple silicon) loaded by Plugin Playground, which needs partial SIP
  (debugging allowed; behind warnings, with a one-click setup and undo; MacReplica never changes SIP itself).

The backup folder also contains `restore/RESTORE_INSTRUCTIONS.html` — a readable guide with the
same steps, including commands for restoring by hand. Step-by-step instructions and the backup
folder layout are in the [user guide](docs/USER_GUIDE.md).

## Details

### Apps, Homebrew and the Mac App Store

- Apps installed with Homebrew are reinstalled with Homebrew. For apps you installed yourself,
  MacReplica looks for a matching Homebrew cask (using Homebrew's public cask list) and only uses one
  automatically when the app's bundle name matches the cask and a second signal (bundle identifier
  or name) confirms it. When several packages could fit, you choose (or install the app yourself).
- On a new Mac without them, MacReplica installs the **Xcode Command Line Tools** (Apple's own
  installation dialog) and **Homebrew** from Homebrew's official signed installer package, after
  checking its Developer ID Installer signature and Homebrew's team ID, and its SHA-256 checksum when GitHub
  publishes one for the package.
- Third-party Homebrew sources (*taps*) are only added if you allow them; on Homebrew 6 and later
  MacReplica then also trusts them (`brew trust --tap`), which Homebrew requires.
- Formulae installed as development builds (`--HEAD`) come back as such; you can choose the stable
  release instead.
- **Mac App Store** apps: `mas install` needs administrator rights since mas 7, so MacReplica does not
  use it. It opens each app's App Store page; you click *Get* (signed in with your Apple Account) and
  MacReplica checks that the app arrived.
- Already-installed apps are detected and not installed again; a restore can be run twice safely.

### Guided installation

Apps that cannot be installed automatically — App Store apps, apps from vendor installers, beta and
nightly builds — are installed in a guided step after everything else:

- MacReplica looks up **official downloads only**: the vendor's own update feed declared in the app
  (for the same channel as on the old Mac), the vendor download Homebrew's catalog points to, the App
  Store page or the vendor's website. Never download portals or mirrors, and nothing is fetched before
  you ask.
- Downloads are **verified before anything is installed**: the vendor's signature or Homebrew's
  checksum, then the app's bundle identifier, developer Team ID, code signature, architecture and
  minimum macOS version. Downloads keep the quarantine flag, so Gatekeeper still checks them.
- A **download queue** with pause, resume, retry and cancel; **install one after another** copies apps
  into Applications (never over an existing app, never with administrator rights) or opens installer
  packages in Apple's Installer for you.
- **Skip**, **Later** and **Cancel** are recorded as your decision, not as failures, and the restore
  remembers what is still open — even after quitting.

Details: [docs/DOWNLOADS.md](docs/DOWNLOADS.md).

### Developer tools and package managers

MacReplica records version managers, language versions, global tools and other package managers by
reading their files (no tool is started, credential files are never opened) and restores them on the
new Mac: managers from Homebrew, then versions, tools and environments with the managers' own
commands — never through a shell. Where a tool is a shell function (nvm, RVM, SDKMAN) or needs an
installer or administrator rights (MacPorts, Nix), MacReplica shows the exact command, checks the
result and continues with what depends on it. The full support matrix is in
[docs/DEVELOPER_ENVIRONMENTS.md](docs/DEVELOPER_ENVIRONMENTS.md).

### Application data

MacReplica knows where these apps keep data you created — for example settings, keymaps, snippets,
presets, styles, templates, LUTs, calibrations and AutoCorrect entries — and copies only those files:

Visual Studio Code · Cursor · Sublime Text · JetBrains IDEs · Xcode · BBEdit · iTerm2 · Zed · Ghostty ·
kitty · WezTerm · Alacritty · Karabiner-Elements · Hammerspoon · Adobe Photoshop (and beta) · Camera Raw /
Lightroom Classic presets · Capture One · DaVinci Resolve · Blender · After Effects · Motion · Logic Pro ·
Krita · GIMP · Inkscape · Scribus · LibreOffice · Microsoft Word, Excel and PowerPoint · Apple Mail · Cryptomator ·
DisplayCAL / ArgyllCMS · BenQ Palette Master Element · XP-Pen · VueScan · Final Cut Pro · KeePassXC (settings only) ·
Adobe colour settings · Keyboard Maestro · Alfred

Some categories were confirmed inside the real apps (*Fully supported*): Krita resources and preferences, GIMP's
profile, Inkscape preferences, templates and palettes, Scribus palettes and preferences, four LibreOffice categories
(settings, templates, dictionaries, menus/toolbars/shortcuts), Cryptomator's vault list, DisplayCAL calibrations and
settings, Word's AutoCorrect, panels and workspaces of the Photoshop beta, and Resolve's LUTs, keyboard presets and
preferences. Everything else is tested with data in the documented layout (*Check in the app*, or *Experimental* where
sources are thin) — the label is shown next to each item in the app.

Caches, databases, logs and credential stores are never included. Data that can contain secrets or
may not work with another app version is offered but not pre-selected. Apps that rewrite their data
on quit must be closed while restoring. Plug-ins, scripts and add-ins are offered but never pre-selected.
Paths of your home folder inside settings files are adjusted to the new Mac. You can add any other folder
inside your home folder yourself; files that look like keys or passwords are left out. Sources and the verification status
of each provider are documented in [docs/PROVIDERS.md](docs/PROVIDERS.md).

MacReplica also recognises tools and services that keep their login in the Keychain or tie it to the
Mac (GitHub CLI, Docker, cloud CLIs, Adobe Creative Cloud, Microsoft 365, Dropbox, Slack, …) and
lists them for signing in again — nothing is copied for them.

### Python environments

Virtual environments contain absolute paths and links to a specific Python installation, so copied
environments usually break. MacReplica records each environment's Python version, packages
(`requirements.txt`) and project files (including `uv.lock`, `poetry.lock`, `Pipfile.lock`,
`environment.yml`) instead. On the new Mac it uses exactly the recorded Python version from pyenv or uv
when those are restored, otherwise Homebrew's Python of the same minor version, and recreates each
environment with `venv` and `pip` — or, for uv projects with a lock file, with `uv sync --frozen`. If exact
package versions are no longer available, compatible versions are installed and reported. Packages
installed from local folders or repositories are listed for manual setup. MacReplica finds Homebrew,
pyenv and python.org interpreters, and environments in your home folder (for example `.venv` folders
in projects, `~/.virtualenvs`, pyenv). Desktop, Documents and Downloads are not searched
automatically — use **Search Another Folder …** for projects there.

### Fonts and ICC profiles

Fonts and colour profiles from `~/Library/Fonts`, `/Library/Fonts`, `~/Library/ColorSync/Profiles`
and `/Library/ColorSync/Profiles` are listed individually. On the new Mac each one is compared with
what is already there — by checksum, by font identity (PostScript name and version) and by the
computed ICC profile ID, never by file name alone:

- **Already present** – the same file or the same font/profile exists (possibly under another
  name). Nothing is copied, so no duplicates are created.
- **Provided by macOS** – macOS ships this font or profile; its own version is kept unless you
  choose otherwise. MacReplica never writes into `/System`.
- **Different version / different file with the same name** – you choose: keep this Mac's version,
  replace it (the old file is moved to a *Replaced Files* folder, never deleted), keep both, or skip.
- **Not recommended** – display profiles macOS generated for the old Mac's displays (never
  restored), Apple profiles this macOS no longer ships, legacy suitcase/PostScript Type 1 fonts and
  unreadable files.

Restored files are verified by checksum and by macOS itself (Core Text for fonts, ColorSync for
profiles). The rules and the research behind them are in
[docs/FONTS_AND_PROFILES.md](docs/FONTS_AND_PROFILES.md).

### Dry Run and resume

- **Preview (Dry Run)** goes through the same checks as a real restore without changing anything,
  and shows for each item what would happen and why. You can export it as a report.
- A restore saves its progress after every step. If MacReplica is stopped, quit or crashes, the
  start screen offers **Continue** (same choices, finished steps are not repeated), **Review …**
  (change what has not been restored yet) or **Discard**. The passphrase or recovery key for credentials is
  never stored and is asked for again.

## Permissions, security and privacy

**Permissions.** MacReplica runs with your normal user rights. It asks for **administrator rights**
only when a step needs them — installing the Command Line Tools or Homebrew, or copying fonts and
profiles into the shared folders in `/Library` — using the standard macOS password dialog. Files for
the shared folders are copied together after a single prompt. Homebrew packages with installers (for
example some casks) need `sudo`: MacReplica asks once per restore in its own window, checks the password
with macOS and hands it to Homebrew through a private channel (a socket only your user can open, plus a one-time
token); it stays in memory until the restore ends and is never stored or logged. While Homebrew runs, the programs
it starts (for example a cask's installer script) could ask for it too – only allow taps you trust. Full Disk Access
is only needed for Mail and Microsoft Office data. If macOS does not allow it to read a location,
the scan reports that location as *no permission* and offers a button to the privacy settings, in
case you want to grant access.

**Security model.**
- MacReplica only starts a fixed list of tools (Homebrew, `mas`, `xcode-select`, `pkgutil`,
  `installer`, Homebrew's Python, …) by their full path, never through a shell. Names and paths from
  a backup are passed as plain arguments and are never interpreted as commands. Steps that need administrator
  rights are the one exception: macOS runs them through AppleScript's `do shell script`, so MacReplica allows only a
  fixed set of operations and quotes every argument (`quoted form of`).
- Every path in a backup is checked before use: it must stay inside its expected folder.
- Every file in a backup has a SHA-256 checksum; damaged files are reported and not restored.
- Existing files are never overwritten silently; replaced files are kept. MacReplica only deletes
  folders it created itself and marked as its own.
- **Credentials** are never collected by default. Files that look like keys or password databases are
  recognised by name and header only and listed; you decide for each. The contents of what you add are encrypted
  per file (AES-256-GCM; the key is protected by your passphrase via PBKDF2-HMAC-SHA256, 600,000 iterations, and by a
  recovery key), checked after encrypting, and never written in plain text. File names, original paths, sizes and
  formats stay readable in the backup's list of contents. Without the passphrase and the recovery key the contents
  cannot be recovered. Keychains, passkeys, cookies and browser password stores are never copied; MacReplica shows
  the supported way to move them. Details: [docs/CREDENTIALS.md](docs/CREDENTIALS.md).
- **Everything else in the backup is stored as plain files**, as on the old Mac. Keep the backup on a drive only you
  can read, and delete it when you no longer need it.

**Privacy.** Your backup stays where you save it — MacReplica uploads nothing and has no analytics of its own.
It contacts these servers itself, and only for these purposes:

| When | What | Where |
|---|---|---|
| Scan, only if some apps could not be matched | Homebrew's public package lists (cached for 24 hours) | formulae.brew.sh |
| Restore, only if Homebrew is missing | Homebrew's latest release information and installer package | api.github.com, github.com |
| Guided installation, when you click **Look Up Downloads** or download | The vendor's own update feed declared in the app, and the vendor download you choose | the vendor's servers |
| **Check for Updates …** or the weekly check (off by default) | MacReplica's release list | api.github.com |
| Tools, when you use them | The list of macOS installers (`softwareupdate`); the window-corner plugin's loader package on one-click setup | Apple; github.com |

The tools MacReplica runs for a restore – Homebrew, `mas`, pip, uv, npm and others – download packages from their
usual sources. Homebrew's own anonymous analytics stay as you configured Homebrew (MacReplica does not change them;
`brew analytics off` turns them off). Logs and reports write your home folder as `~` and contain no passwords or
file contents; they do contain app names, file names and paths outside your home folder.

Details: [SECURITY.md](SECURITY.md) · [docs/FAILURE_MODES.md](docs/FAILURE_MODES.md)

## Logs and troubleshooting

MacReplica writes logs to `~/Library/Logs/MacReplica/`. Use **Help → Open Logs**, or
**Help → Export Diagnostic Report …** for a single file you can attach to an issue (it contains
logs and system information, with your home folder written as `~`, and no passwords or file
contents). If MacReplica did not start completely the last time, it starts in a safe mode and tells you.

| Problem | What to do |
|---|---|
| “Not signed in to the App Store” | Open the App Store, sign in, then **Retry Failed Items**. |
| A location shows *no permission* | macOS protects it. Grant access in *Privacy & Security* if you want it included, or continue without it. |
| An app could not be restored automatically | Install it yourself; the summary links to the vendor's website where it is known. |
| Homebrew or the Command Line Tools did not install | Check the network connection and confirm Apple's installation dialog, then **Retry Failed Items**. |
| Some Python packages are missing | The summary names them; they may only exist in newer versions or came from a local folder. |
| App data was not restored because the app is running | Quit the app and retry. |
| The restore was interrupted | Open MacReplica again and choose **Continue** or **Review …**. |
| A backup is reported as damaged or incomplete | Copy the whole folder again from the old Mac; **Check Backup** shows which files are affected. |
| The update check cannot reach GitHub | Check the connection; nothing else depends on it. |

More in [Troubleshooting](docs/TROUBLESHOOTING.md).

## Known limitations

- **Not everything can be reinstalled automatically.** Apps without a verifiable official download
  (licensed software, vendor accounts) and installer packages need you; MacReplica guides you and
  checks the result.
- **Logins are not migrated.** Accounts, licences and anything kept in the Keychain need a new
  sign-in; MacReplica tells you which apps and tools are affected.
- **App data is limited to the supported apps and folders you add**, and data from one app version
  may not work in another. Data of a versioned app is restored into the matching version folder.
  Apple Mail's signatures and rules are experimental: Mail itself could not be checked, and macOS 27 stores
  them differently.
- **Homebrew support depends on the Mac:** Homebrew fully supports Apple silicon with the three newest macOS
  versions; Intel Macs and older macOS versions are Tier 3 (packages may be built from source or fail), and Intel
  support is expected to end from September 2027. MacReplica shows this before the backup and on the new Mac.
- **Launchpad** exists only up to macOS 15; on macOS 26 and later the recorded layout is a reference.
- **App Store apps are installed by you** from the page MacReplica opens (signed in with your Apple
  Account); `mas install` needs administrator rights since mas 7.
- **Python environments are rebuilt, not copied.** Packages from local folders or private
  repositories, and package versions that no longer exist, need attention.
- **Protected locations** (macOS system folders, other apps' sandboxes) are not read. Mail and Microsoft
  Office data need Full Disk Access for MacReplica; without it those items are listed as waiting.
- **Architecture differences:** apps without a build for the new Mac's processor are skipped with an
  explanation; Apple silicon apps cannot run on Intel Macs.
- **Some developer tools are guided steps**, not automatic: nvm, RVM and SDKMAN (shell functions),
  MacPorts (administrator rights), installing Nix, .NET SDK versions, asdf and mise tools from
  third-party backends. pkgx and Fink are only listed. Real installations of MacPorts, Nix, rbenv,
  rustup, SDKMAN and .NET were not used for testing; see
  [docs/DEVELOPER_ENVIRONMENTS.md](docs/DEVELOPER_ENVIRONMENTS.md#verified-and-what-is-not).
- **Download verification needs a vendor signature, a Homebrew checksum or the original Team ID**;
  anything else is only offered as the vendor's website.
- **macOS settings** are limited to the listed categories; Accessibility, privacy permissions, wallpaper, login
  items, default apps and per-Mac settings are not transferred (they are listed with the reason). Keyboard shortcuts
  and input sources are offered by default only on the same major macOS version.
- **Printers are set up by you**, guided: drivers and the printing system's own settings are never copied, and
  whether a printer prints can only be tested with it switched on.
- **Passwords**: files that look like secrets are left out unless you include them; KeePass databases stay encrypted.
  Keychain passwords move with iCloud Keychain or the Passwords app – MacReplica explains how.
- **Microsoft Office** LTSC 2021 and 2024 cannot be told apart; a volume licence is never copied (run your licence
  package again).
- Fonts in apps that are already running appear after the app is reopened.
- Printer-driver colour profiles come back by reinstalling the printer driver.
- Releases are not signed with a Developer ID or notarized (see [Installation](#installation)).
- **The backup is not encrypted** except for the credentials you add (their contents only).
- The **window-corner plugin** runs only on Apple silicon and only on the macOS builds it was tested on (currently
  macOS 27.0.1, build 26A434); after a macOS update it stays inactive until a tested MacReplica version follows. The
  window-corner setting itself works on Intel and Apple silicon with macOS 26.4 or later.
- macOS 13 has not been tested yet. The Intel version was tested on GitHub's hosted Intel runner and
  under Rosetta, not on an Intel Mac at home.
- Application data marked *Check in the app* or *Experimental* is tested with synthetic data that mirrors
  the documented layouts, not inside the real app ([details](docs/PROVIDERS.md)).

## Building from source

Requirements: a Mac with the **Xcode Command Line Tools** (`xcode-select --install`) or Xcode,
providing **Swift 6.1 or newer** (Xcode 16.3 or later). Xcode itself is not required — MacReplica is
a Swift package. The built app runs on macOS 13 or later.

```sh
git clone https://github.com/itsab1989/MacReplica.git
cd MacReplica
scripts/test.sh                  # build and run all tests
scripts/build-app.sh build       # → build/MacReplica.app (universal, ad-hoc signed)
scripts/make-dmg.sh build        # → build/MacReplica-<version>.dmg
open build/MacReplica.app
```

Details, options and output locations: [BUILD.md](BUILD.md). Releases are built, validated and
published by GitHub Actions — see [docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md). Code structure:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing

```sh
scripts/test.sh                              # all tests (more than 600, Swift Testing)
scripts/test.sh --filter FontConflictTests   # one suite
```

The tests never touch your own apps or files: integration and end-to-end tests run against
**simulated Macs** — sandbox folders with stand-in versions of `brew`, `mas` and other tools — using
synthetic apps, fonts and profiles generated in code. Restoring into real system folders, the real
App Store and administrator dialogs are not covered by automated tests; they were validated by hand.
What was validated for developer tools and the guided installation is in
[docs/RECOVERY_REPORT.md](docs/RECOVERY_REPORT.md).

**Mutation testing** checks that the tests really catch mistakes in the critical modules (selection,
conflict decisions, restore, verification, clean-up, credentials, installer validation). Each release runs it on
the modules it changed; every module is at or above its threshold. How to run it and the results of every run:
[docs/MUTATION_TESTING.md](docs/MUTATION_TESTING.md). More: [docs/TESTING.md](docs/TESTING.md).

## Contributing

Bug reports, app support requests and pull requests are welcome — please read
[CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) first. Questions and
ideas: [Discussions](https://github.com/itsab1989/MacReplica/discussions). New app-data providers must come with tests and must only
copy documented, user-created data. Security problems: please report them privately as described in
[SECURITY.md](SECURITY.md).

## Support the developer

<p align="center">
  <a href="https://ko-fi.com/itsab1989"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Support MacReplica on Ko-fi" height="36"></a>
  <br>
  <sub>MacReplica is free and always will be. If it's useful to you, a coffee is a kind way to say thanks — completely optional, and the app stays fully featured either way.</sub>
</p>

## License

MacReplica is free software under the [GNU General Public License v3.0](LICENSE).
Homebrew, the Mac App Store, macOS and all app names mentioned are trademarks of their respective
owners; MacReplica is not affiliated with them.
