# Package managers and developer environments

MacReplica restores more than apps: version managers, language versions, global tools and other
package managers come back on the new Mac as well. This page lists exactly what is supported, how,
and what is not.

## How it works

- **Scanning reads files only.** No tool is started while scanning. Versions come from the managers'
  version folders, global tools from their metadata (`package.json`, gemspecs, `.crates2.json`,
  `uv-receipt.toml`, `pipx_metadata.json`, Conda's `conda-meta/history`, the build information
  embedded in Go programs, the MacPorts registry …).
- **The backup records what is installed, never the tools themselves** – environments and runtimes
  contain absolute paths and compiled code, so they are rebuilt.
- **Credentials are never read.** Files that can hold tokens or passwords are not opened at all
  (for example `~/.npmrc`, `~/.cargo/credentials.toml`, `~/.gem/credentials`, uv's
  `credentials/` folder, `~/.netrc`, `~/.pypirc`, NuGet and Maven settings). From mise's
  configuration only the `[tools]` table is read, never `[env]`. Conda channel URLs with
  credentials or tokens are dropped.
- **Restoring never uses a shell.** Each step runs the manager's own program by absolute path with
  validated arguments. For one restore, the command allow-list is extended by exactly the programs
  of that restore's steps; shells, `env`, `sudo` and similar are always refused.
- **Managers come from Homebrew** when Homebrew has a package for them (for example `uv`, `pyenv`,
  `rustup`, the `miniforge` cask). Steps that need the manager depend on it, so they run after it.
- **Guided steps** are used when MacReplica cannot or must not run something itself: the tool is a
  shell function (nvm, RVM, SDKMAN), it needs administrator rights (MacPorts) or an installer script
  (Nix). MacReplica shows the exact command or page, the user does it, and MacReplica checks the
  result ("Check Again") and continues with what depends on it. A guided step is never counted as
  a failure; the restore remembers it until it is done, skipped or discarded.

## Support matrix

"Automatic" means installed and verified by MacReplica. "Guided" means MacReplica shows the step and
verifies it. "Listed" means recorded in the backup and the restore instructions only.

### Package managers

| Manager | Recorded | Restore |
|---|---|---|
| Homebrew formulae, casks, taps | requested formulae, casks, taps | automatic (unchanged). Third-party taps the user allows are trusted with `brew trust --tap` on Homebrew 6 and later. Formulae installed with `--HEAD` are reinstalled with `--HEAD` unless the user picks the stable release. |
| Mac App Store | apps with their App Store ID | guided: MacReplica opens the app's App Store page and checks the installation. (`mas install` requires root since mas 7, so it is not used.) |
| MacPorts | requested ports with variants (registry database) | guided: install MacPorts for this macOS version, then `sudo port -N install <port> +variants`; MacReplica checks each port |
| Nix (`nix profile`) | packages from the profile's `manifest.json` | installing Nix is guided; packages from Nixpkgs are then automatic (`nix profile add nixpkgs#<attr>`). Packages from other flakes are third-party sources and are listed only. |
| Pixi | global environments (`pixi-global.toml`) | automatic (`pixi global install --environment …`) |
| mise | tools in `~/.config/mise/config.toml` | automatic for tools from mise's registry (`mise use --global`); tools from other backends (`ubi:`, `aqua:` …) are guided |
| asdf | `~/.tool-versions` | guided (`asdf plugin add` / `asdf install`): plugins are Git repositories with their own scripts |
| pkgx / pkgm | packages in `~/.local/pkgs` | listed |
| Fink | installed packages (dpkg database) | listed |

### Languages

| Ecosystem | Recorded | Restore |
|---|---|---|
| Python – pyenv | versions, global version | automatic (`pyenv install --skip-existing`, `pyenv global`) |
| Python – uv | managed Pythons, tools (with `--with`, extras, pinned Python) | automatic (`uv python install`, `uv tool install`) |
| Python – pipx | applications, injected packages | automatic (`pipx install`, `pipx inject`); installs from URLs or folders are listed |
| Python – Conda (Miniconda, Anaconda, Miniforge) | named environments with the packages the user asked for and their channels; user additions to `base` | the matching cask installs the distribution; environments are recreated with `conda env create`. Anaconda's terms of service are never accepted on the user's behalf. |
| Python – virtual environments | interpreter version, packages, dependency files (`requirements*.txt`, `pyproject.toml`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `environment.yml`, `pylock.toml`, `hatch.toml`) | automatic. Rebuilt with exactly the recorded pyenv or uv Python if that is restored, otherwise Homebrew's Python of the same minor version. uv projects with `uv.lock` are rebuilt with `uv sync --frozen`. |
| Node.js – nvm | versions, default alias | guided (`nvm install …`): nvm is a shell function |
| Node.js – fnm | versions, default | automatic |
| Node.js – Volta | Node versions, global tools | automatic (Volta itself is no longer maintained upstream) |
| Node.js – npm / pnpm / Yarn 1 globals | packages per Node installation | automatic with that installation's own `npm`, once it exists; git and local packages are listed |
| Ruby – rbenv | versions, global version | automatic (`rbenv install --skip-existing`) |
| Ruby – RVM | rubies, default | guided |
| Ruby – gems | gems per Ruby (default and bundled gems excluded) | automatic with that Ruby's `gem` |
| Rust – rustup | toolchains with extra components and targets, default | automatic, installed for the new Mac's processor |
| Rust – Cargo | programs from `cargo install` with features | automatic (`cargo install --locked --version`); git and path installs are listed |
| Go | Go installations; programs in `GOBIN`/`~/go/bin` with module path and version | Go from Homebrew; programs automatic (`go install path@version`); local builds are listed |
| Java – JDKs | version and vendor | automatic as the matching Homebrew cask (Temurin, Zulu, Corretto, Oracle, Microsoft); other vendors guided |
| Java – SDKMAN | candidates and defaults | guided |
| .NET | SDK versions, global tools | SDKs guided (Microsoft's download page for the version); global tools automatic (`dotnet tool install -g`) |

## Python: rebuild (default) or saved copy (optional)

Rebuilding from the recorded interpreter version and exact package versions stays the default for every
environment. For reinstalling macOS on the *same* Mac, a virtual environment can additionally be kept as a
complete copy (*Also keep a complete copy of this environment*, not selected by default):

- **Backup:** the folder is packed with `ditto` (symbolic links and permissions kept). An environment that
  contains files that look like credentials is refused. The manifest records the archive checksum, a salted
  hash of the home folder path, the architectures and highest minimum macOS of its native extensions
  (`.so`/`.dylib`), and whether packages point to local folders (editable installs).
- **Restore:** *Rebuild from packages (recommended)* or *Saved copy – checked, rebuilt if it does not fit*.
  The copy is used only if the home folder is the same (virtual environments contain absolute paths), the
  native code runs on this Mac's processor, macOS is new enough for it, the base interpreter it links to
  exists, and the archive matches its checksum. It is then **verified by running it**: the environment's own
  Python (isolated mode) must report the recorded minor version, the expected location, every reinstallable
  package in its recorded version, and import the packages' top-level modules.
- **Fallback:** if any check fails, the reason is shown (*different home folder*, *other processor*, *needs a
  newer macOS*, *base interpreter missing*, *archive damaged*, *could not be unpacked*, *did not run as
  expected*) and the environment is rebuilt from its packages instead; that result is also verified by
  running the environment's Python. Nothing is reported as restored on file presence alone.

Tested: a real Python 3 environment packed, restored and verified (`RealPythonPreservationTests`); in the
real app with simulated Macs: same-Mac reinstall with the copy used (scenario B), damaged archive → rebuilt
(E), other Mac/home folder → rebuilt (D). The processor and macOS checks are unit-tested.

## Choosing what to keep

- **Backup:** each manager can be left out on the scan results screen (*Developer Tools*).
- **Restore:** *Developer Tools* and *Other Package Managers* are components that can be switched off;
  every runtime, tool and environment can be unticked individually.

## Verified, and what is not

The scanners, restore commands, dependency order, guided steps, resume and second-run behavior are
covered by automated tests against synthetic data and simulated tools (see
[TESTING.md](TESTING.md)). Formats were checked against the real tools where they were available to
the developer (uv, Pixi, Conda and Homebrew in an isolated folder; Go's module markers against Go's
source). Real installations of MacPorts, Nix, rbenv, rustup, SDKMAN and .NET SDKs were **not** run;
their parsers follow the projects' documentation and are tested with synthetic files only.

Known limitations (verified):

- npm packages installed under a custom `prefix` from `~/.npmrc` are not found (`.npmrc` is never read).
- Poetry, Hatch and Pipenv environments in the Library folder are not listed; project environments are
  rebuilt from the project's files (or recorded packages), not with `poetry install` / `hatch env create`.
- Packages installed into the Conda `base` environment by the installer itself are not recorded.
- nix-darwin and home-manager configurations are not reproduced; back up their configuration
  repositories yourself.
