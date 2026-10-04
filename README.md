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
  <img src="docs/images/macreplica-start.png" alt="MacReplica start screen with Create Backup, Restore and Check Backup" width="720">
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
- [Using MacReplica](#using-macreplica)
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
| **Your installers** *(optional)* | Installers you keep (`.pkg`, `.dmg`, `.zip`, e.g. Office LTSC with its activation package) — optionally copied into the backup | Used offline, only if checksum and developer still match |
| **Fonts and ICC profiles** | Each file individually selectable, with its identity | Compared with what the new Mac already has before anything is copied |
| **Git settings** | Name, aliases and preferences (email only if you choose) | Written to `~/.gitconfig` |
| **Credentials** *(optional)* | Only if you opt in per provider — encrypted with your passphrase | Restored only with the passphrase |

MacReplica does **not** clone your disk, copy whole Library folders, move system settings, or
migrate logins stored in the Keychain.

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

All screenshots show the real app with synthetic test data.

| | |
|:---:|:---:|
| <img src="docs/images/macreplica-inventory.png" alt="Scan results: how each app will be restored, matches to confirm, fonts, profiles and Python" width="420"> | <img src="docs/images/macreplica-app-data.png" alt="Application data grouped by app, with warnings for data that may contain secrets or depend on the app version" width="420"> |
| **Scan results** – how each app will come back | **App data** – per app, with clear warnings |
| <img src="docs/images/macreplica-restore-selection.png" alt="Restore selection on the new Mac with status per area" width="420"> | <img src="docs/images/macreplica-restore-items.png" alt="Individual fonts and profiles with their status on the new Mac and decisions" width="420"> |
| **Restore selection** – what to put onto this Mac | **Individual items** – status, details and decisions |
| <img src="docs/images/macreplica-dry-run.png" alt="Preview listing what would be installed, what is already present and what needs a decision" width="420"> | <img src="docs/images/macreplica-progress.png" alt="Restore in progress with finished steps and time estimate" width="420"> |
| **Preview (Dry Run)** – nothing is changed | **Restoring** – each step is checked |
| <img src="docs/images/macreplica-restore-problems.png" alt="Summary with a failed App Store app and guidance to sign in and retry" width="420"> | <img src="docs/images/macreplica-restore-complete.png" alt="Restore complete with apps to install manually and services to sign in to" width="420"> |
| **Problems are explained** – with a retry | **Done** – and what is left for you |

<details>
<summary>More screenshots</summary>

| | |
|:---:|:---:|
| <img src="docs/images/macreplica-backup-saved.png" alt="Backup saved and checked, with size, location and transfer instructions" width="420"> | <img src="docs/images/macreplica-conflicts.png" alt="Dialog asking how to handle files that already exist" width="420"> |
| Backup saved and checked | Items that need a decision |
| <img src="docs/images/macreplica-start-dark.png" alt="Start screen in dark mode" width="420"> | <img src="docs/images/macreplica-languages.png" alt="Language menu with seven languages" width="420"> |
| Dark mode | Seven languages, switchable in the app |
| <img src="docs/images/macreplica-settings.png" alt="Settings with language, logs, update options and support link" width="380"> | <img src="docs/images/macreplica-about.png" alt="About window with version, Ko-fi and GitHub links" width="300"> |
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
   data. Credentials are off unless you opt in.
3. Click **Save Backup …** and pick a folder, ideally on an external drive or in a cloud folder.
   MacReplica copies the selected files, compares each copy with the original and shows where the
   backup is and how big it is.
4. Copy the whole backup folder to the new Mac (external drive, network share, cloud folder or
   AirDrop). **Check Backup** verifies a backup at any time.

**On the new Mac**

1. Open MacReplica, click **Restore** and choose the backup folder. MacReplica checks the backup
   and then the new Mac.
2. In **What do you want to put onto this Mac?** everything from the backup is selected except items
   that are not recommended on this Mac. Leave out what you do not want; use
   **Choose Individual Items …** for details and decisions.
3. Click **Preview (Dry Run)** to see exactly what would happen, or **Start Restore**.
4. If something needs administrator rights (Homebrew, shared folders), MacReplica explains why and
   macOS asks for your password.
5. Read the summary: what worked, what failed and what to do about it, apps to install yourself
   and services to sign in to again. **Retry Failed Items** runs only the failed steps again.

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
  checking its signature, Homebrew's team ID and its SHA-256 checksum.
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
Krita · GIMP · Inkscape · Scribus · Microsoft Word, Excel and PowerPoint · Apple Mail · Cryptomator ·
DisplayCAL / ArgyllCMS · BenQ Palette Master Element · XP-Pen · Keyboard Maestro · Alfred

Krita, GIMP, Inkscape, Scribus, Cryptomator, DisplayCAL, Word's AutoCorrect, the Photoshop beta's settings and
Resolve's LUTs and presets were confirmed inside the real apps (*Fully supported*); the others are tested with
data in the documented layout (*Check in the app*, or *Experimental* where sources are thin).

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
  (change what has not been restored yet) or **Discard**. An encryption passphrase for credentials is
  never stored and is asked for again.

## Permissions, security and privacy

**Permissions.** MacReplica runs with your normal user rights. It asks for **administrator rights**
only when a step needs them — installing the Command Line Tools or Homebrew, or copying fonts and
profiles into the shared folders in `/Library` — using the standard macOS password dialog. Files for
the shared folders are copied together after a single prompt. It does **not** request Full Disk
Access. If macOS does not allow it to read a location,
the scan reports that location as *no permission* and offers a button to the privacy settings, in
case you want to grant access.

**Security model.**
- MacReplica only starts a fixed list of tools (Homebrew, `mas`, `xcode-select`, `pkgutil`,
  `installer`, Homebrew's Python, …) by their full path, never through a shell. Names and paths from
  a backup are passed as plain arguments and are never interpreted as commands.
- Every path in a backup is checked before use: it must stay inside its expected folder.
- Every file in a backup has a SHA-256 checksum; damaged files are reported and not restored.
- Existing files are never overwritten silently; replaced files are kept. MacReplica only deletes
  folders it created itself and marked as its own.
- **Credentials** are never collected by default. There is no scanning for secrets. If you opt in
  to a credential provider (SSH keys, AWS, Git credentials, npm, Kubernetes, Terraform), those files
  are encrypted in the backup with AES-256-GCM using a key derived from your passphrase
  (PBKDF2-HMAC-SHA256, 600,000 iterations). Passwords, tokens, cookies, browser data and the Keychain
  are never copied.

**Privacy.** Your backup stays where you save it — MacReplica uploads nothing. It has no analytics.
It makes three kinds of network requests itself: Homebrew's public cask list (during the scan, to
match apps), the update check (only when you ask or enable it) and Homebrew's installer package
(during a restore). Logs and reports write your home folder as `~` and contain no passwords or file
contents.

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
- Fonts in apps that are already running appear after the app is reopened.
- Printer-driver colour profiles come back by reinstalling the printer driver.
- Releases are not signed with a Developer ID or notarized (see [Installation](#installation)).
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
scripts/test.sh                              # all tests (about 340, Swift Testing)
scripts/test.sh --filter FontConflictTests   # one suite
```

The tests never touch your own apps or files: integration and end-to-end tests run against
**simulated Macs** — sandbox folders with stand-in versions of `brew`, `mas` and other tools — using
synthetic apps, fonts and profiles generated in code. Restoring into real system folders, the real
App Store and administrator dialogs are not covered by automated tests; they were validated by hand.
What was validated for developer tools and the guided installation is in
[docs/RECOVERY_REPORT.md](docs/RECOVERY_REPORT.md).

**Mutation testing** checks that the tests really catch mistakes in the critical modules (selection,
conflict decisions, restore, verification, clean-up, credentials). The last full run killed 85.5 %
of 712 mutants, with every module at or above its threshold. How to run it and the detailed results:
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
