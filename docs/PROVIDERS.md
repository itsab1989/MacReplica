# Migration providers: evidence, status and limitations

Research date: **2026-10-02**; Photoshop, Adobe colour settings, Camera Raw defaults and DaVinci Resolve
**2026-10-03** (evidence in [APP_DATA_RESEARCH.md](APP_DATA_RESEARCH.md)). Status terms:

- **Fixture-tested** — implemented; the complete path (detection → backup → manifest → restore → verification → error
  handling) is covered by automated tests with synthetic data that mirrors the documented layout. The real
  application was **not** launched by the tests.
- **Detection confirmed** — additionally, read-only detection was run against a real installation on the development
  Mac (`MacReplicaSimulator detect-live`, which prints only provider, category and file counts).
- **Verified** — backup and restore of the user's real data on the development Mac, and the restored data
  confirmed *inside the real application* (scripting probe after launching it). Listed per category below.

The restore engine contains no application knowledge. Providers are data in
`Sources/MacReplicaCore/Providers/AppDataCatalog.swift` (applications and guidance) and
`Sources/MacReplicaCore/Credentials/Credentials.swift` (credentials). Adding a provider means adding an entry plus a
fixture test; the engine does not change.

## Classification rules

Every category of every provider is classified. Only offered classes are ever copied:

| Class | Copied? | Default |
|---|---|---|
| `safe` — user-created customization, stable format | yes | selected |
| `compatibilitySensitive` — may not work in another app version | yes | **not selected**, explained |
| `mayContainSecrets` — user content that can hold API keys (automation workflows, macros) | yes | **not selected**, warned |
| `cache`, `database`, `temporary`, `log`, `credential` | never | — |

Apps marked *must be closed* are not restored while they run (the restore step fails with "The app is open" and can be
retried).

## Application data providers

| Provider | Bundle ID(s) | Copied (relative to `~/`) | Not copied | Status | Sources |
|---|---|---|---|---|---|
| Visual Studio Code | `com.microsoft.VSCode` | `Library/Application Support/Code/User/` `settings.json`, `keybindings.json`, `snippets/`, `profiles/`; extension **IDs** from `~/.vscode/extensions` (listed for reinstalling) | `globalStorage`, `workspaceStorage`, caches, logs, extension binaries | Fixture-tested | [settings](https://code.visualstudio.com/docs/configure/settings), [profiles](https://code.visualstudio.com/docs/configure/profiles), [marketplace](https://code.visualstudio.com/docs/configure/extensions/extension-marketplace) |
| Cursor | `com.todesktop.230313mzl4w4u92` | `Library/Application Support/Cursor/User/` settings, keybindings, snippets; extension IDs | caches, extension binaries | Fixture-tested | [migration guide](https://cursor.com/docs/configuration/migrations/vscode) (paths community-sourced) |
| Sublime Text 3/4 | `com.sublimetext.4`, `.3` | `Library/Application Support/Sublime Text[ 3]/Packages/User` | Package Control caches/CA files, `Local/` (licence, session), `Installed Packages` | Fixture-tested | [revert](https://www.sublimetext.com/docs/revert.html), [Package Control syncing](https://packagecontrol.io/docs/syncing) |
| JetBrains IDEs | `com.jetbrains.*` (12 products) | `Library/Application Support/JetBrains/<Product><YYYY.N>/` keymaps, codestyles, colors, templates, fileTemplates, inspection, tools | `options/` (machine paths), `plugins/`, caches, logs, licence keys | Fixture-tested | [directories](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html), [sharing settings](https://www.jetbrains.com/help/idea/sharing-your-ide-settings.html) |
| Xcode | `com.apple.dt.Xcode` | `Library/Developer/Xcode/UserData/{CodeSnippets,FontAndColorThemes,KeyBindings}`, `Library/Developer/Xcode/Templates` | DerivedData, archives, device support, provisioning profiles, `com.apple.dt.Xcode.plist` | Fixture-tested | [Apple Developer Forums, community answer](https://developer.apple.com/forums/thread/705846) — Apple does not document these paths |
| BBEdit | `com.barebones.bbedit` | `Library/Application Support/BBEdit/{Clippings,Text Filters,Scripts,Stationery,Language Modules,Color Schemes}` | Auto-Save Recovery, licence | Fixture-tested | [Bare Bones "Read Me.txt"](https://github.com/gingi/BBEdit-Support/blob/master/Read%20Me.txt) (mirror) |
| iTerm2 | `com.googlecode.iterm2` | `Library/Application Support/iTerm2/DynamicProfiles` | main preferences plist (cfprefsd cache; use iTerm2's Export/Import), Keychain items | Fixture-tested | [Dynamic Profiles](https://iterm2.com/documentation-dynamic-profiles.html) |
| Adobe Photoshop (presets) | `com.adobe.Photoshop` | `Library/Application Support/Adobe/Adobe Photoshop <YYYY>/Presets/{Actions,Brushes,Styles,Gradients,Patterns,Color Swatches,Custom Shapes,Keyboard Shortcuts,Tools,Contours,Menu Customization,Custom Toolbars,Curves,Levels,…}` — may go into the version installed on the new Mac | AutoRecover, font caches, AddOnModules | Fixture-tested | [backup & restore](https://helpx.adobe.com/photoshop/desktop/get-started/settings-and-preferences/backup-and-restore-preferences.html), [migrate presets](https://helpx.adobe.com/photoshop/using/preset-migration.html) |
| Adobe Photoshop (settings) | `com.adobe.Photoshop` | `Library/Preferences/Adobe Photoshop <YYYY> Settings/`: the ten Adobe-listed panel files (selected, may go into another version), `Color Settings.csf`; *not selected, same version only:* `WorkSpaces`, `WorkSpaces (Modified)`, `Workspace Prefs.psp`, new-document presets, `… Prefs.psp` | `MachinePrefs.psp`, `PluginCache.psp`, `FMCache.psp`, launch flags, GPU logs | Fixture-tested | as above |
| Adobe Photoshop (Beta) (presets, settings) | `com.adobe.Photoshop` (same ID as the release) | the same, in `Adobe Photoshop (Beta)` / `Adobe Photoshop (Beta) Settings` — always restored into the beta's folders | as above | **Settings: verified** (panel contents, workspaces, document presets, preferences); presets: fixture-tested | [Photoshop beta](https://helpx.adobe.com/photoshop/desktop/whats-new/photoshop-desktop-beta-overview.html) |
| Adobe colour settings | Photoshop, Illustrator, InDesign, Lightroom | `Library/Application Support/Adobe/Color/{Settings,Proofing}` | — | Fixture-tested | preference file names KB |
| Lightroom Classic / Camera Raw | `com.adobe.LightroomClassicCC7`, `com.adobe.Photoshop` | `Library/Application Support/Adobe/CameraRaw/{Settings,CameraProfiles,Defaults}` | catalogs (`.lrcat`), caches, logs, GPU/model data | Fixture-tested, **detection confirmed** | [file locations](https://helpx.adobe.com/lightroom-classic/desktop/kb/preference-file-and-other-file-locations.html), [raw defaults](https://helpx.adobe.com/camera-raw/kb/acr-raw-defaults.html) |
| Capture One | `com.captureone.captureone16` | `Library/Application Support/Capture One/{Styles,Presets60,KeyboardShortcuts,Workspaces}` | ImageCore/CaptureCore, diagnostics, plug-in binaries, catalogs and sessions | Fixture-tested, **detection confirmed** | [moving styles & presets](https://support.captureone.com/hc/en-us/articles/27728350991261), [workspaces & presets](https://support.captureone.com/hc/en-us/articles/360002418657) |
| DaVinci Resolve (Fusion) | `com.blackmagic-design.DaVinciResolve`, `…Lite` | `Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/{Templates,Macros,Fuses,Settings,LUTs}`; `Scripts` *may contain secrets* | DiskCache, profile preferences | Fixture-tested | Resolve 21.1 manual, Fusion Templates README |
| DaVinci Resolve (LUTs) | same | **`/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT`** (shared), without the LUTs in Resolve's installer receipt (`com.blackmagic-design.Manifest`); waits until Resolve is installed | Resolve's own LUTs, extra LUT locations (machine paths) | **Verified** | manual p. 3484, 4328 |
| DaVinci Resolve (ACES, Fairlight) | same | `…/DaVinci Resolve/ACES Transforms`, `…/DaVinci Resolve/Fairlight/Presets` | Fairlight plug-in scans, monitoring, control surfaces | Fixture-tested (Fairlight presets restored on the real Mac by checksum) | DaVinciCTL README |
| DaVinci Resolve (preferences) | same | `Library/Preferences/Blackmagic Design/DaVinci Resolve/`: `keyboard.preset.xml`, `UI.preset`, `config.user.presets.xml`, smart bins, metadata/HDR presets; `config.user.xml` *not selected* — only into the same or a newer Resolve, waits until Resolve is installed | `config.dat` (GPU, video I/O, media storage, scripting), `dblist.conf`, `recentprojects.conf`, licence, logs | **Keyboard presets and user preferences: verified**; layout, user-preference, smart-bin and metadata presets: restored on the real Mac and checked by checksum (Resolve has no read API) | manual p. 60, 109, 122–124; tech note on the configuration folder |
| Blender | `org.blenderfoundation.blender` | `Library/Application Support/Blender/<X.Y>/config/{userpref.blend,startup.blend,bookmarks.txt}`, `scripts/presets`; `scripts/addons`, `extensions` *compatibility-sensitive* | `recent-files.txt`, autosave, caches | Fixture-tested | [directory layout](https://docs.blender.org/manual/en/latest/advanced/blender_directory_layout.html) |
| Adobe After Effects | `com.adobe.AfterEffects` | `Library/Preferences/Adobe/After Effects/<version>/{aeks,ModifiedWorkspaces}` — *compatibility-sensitive* | — | Fixture-tested | [preferences](https://helpx.adobe.com/after-effects/using/preferences.html) (search excerpt) |
| Keyboard Maestro | `com.stairways.keyboardmaestro.editor`, `.engine` | `Library/Application Support/Keyboard Maestro/` — *may contain secrets* | licence (Preferences) | Fixture-tested | [vendor FAQ](https://wiki.keyboardmaestro.com/Frequently_Asked_Questions) |
| Alfred | `com.runningwithcrayons.Alfred` | `Library/Application Support/Alfred/Alfred.alfredpreferences` — *may contain secrets* | caches, clipboard history | Fixture-tested | [disable sync](https://www.alfredapp.com/help/advanced/sync/disable-sync/), [sync](https://www.alfredapp.com/help/advanced/sync/) |

Plus **user-chosen folders** (any folder in the home folder except credential stores, `~/Library` itself and other
too-broad or sensitive locations; secret-looking files are always skipped).

## Credential providers (opt-in, encrypted, never selected by default)

All use the same vault (AES-256-GCM, key from PBKDF2-HMAC-SHA256, 600 000 iterations; passphrase never stored).
Restored files get owner-only permissions; parent folders `0700`.

| Provider | Files (relative to `~/`) | Why it is portable | Not handled | Sources |
|---|---|---|---|---|
| SSH | `.ssh/id_*`, `config`, `known_hosts` | static key files | `authorized_keys`, Keychain-stored passphrases (`ssh-add --apple-use-keychain` again) | [ssh(1)](https://man.openbsd.org/ssh.1), [Apple TN2449](https://developer.apple.com/library/archive/technotes/tn2449/_index.html) |
| AWS | `.aws/credentials`, `.aws/config` | long-lived access keys in a file | `.aws/sso/cache`, `.aws/cli/cache` (short-lived) → guidance "AWS SSO: sign in again" | [config files](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html), [SSO](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) |
| Git credential store | `.git-credentials` | plain-text file of the `store` helper | Keychain (`osxkeychain`), Git Credential Manager | [git-credential-store](https://git-scm.com/docs/git-credential-store) |
| npm | `.npmrc` | static registry tokens | — | [npmrc](https://docs.npmjs.com/cli/v10/configuring-npm/npmrc) |
| Kubernetes | `.kube/config` | embedded certificates/tokens | exec-plugin users still need their cloud CLI to be signed in | [kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/) |
| Terraform | `.terraform.d/credentials.tfrc.json` | static API token | — (path per Terraform docs; folder not quoted in the docs) | [terraform login](https://developer.hashicorp.com/terraform/cli/commands/login) |

Git **configuration** is handled separately (sanitized `~/.gitconfig`, default on; email only on request).

## Re-authentication required (detected and explained, never migrated)

GitHub CLI and GitLab CLI (Keychain by default), Docker (credential store), Google Cloud CLI, Azure CLI (MSAL cache),
AWS IAM Identity Center (SSO), GitHub Desktop, Adobe Creative Cloud (activation limit), Microsoft 365, Dropbox,
OneDrive, Google Drive, Slack, Microsoft Teams, Zoom, Things. Each entry in `GuidanceCatalog` cites its source.

## Manual migration (detected; the app's own export is recommended)

Raycast (encrypted database; official `.rayconfig` export), BetterTouchTool (full backup/preset export), Hazel (rule
export; file copy unreliable because of aliases), Rectangle (JSON export), Terminal (`.terminal` profile export), Affinity
(per-panel export; internal formats undocumented), Adobe Premiere Pro (shortcuts in `~/Documents`, Sync Settings
discontinued), DaVinci Resolve PowerGrades, render/project presets and project libraries (LUTs and keyboard/layout presets are restored).

## Investigated and rejected

| Candidate | Reason |
|---|---|
| Copying the macOS Keychain or any Keychain item | not portable, not a supported mechanism; never done |
| gcloud / Azure CLI token stores | refresh tokens tied to the session; re-authentication required |
| Docker `config.json` | usually only points to the Keychain credential store; inline `auths` are rare and the file can name a helper missing on the new Mac |
| GitHub/GitLab CLI `hosts.yml` / `config.yml` | configuration only; the token is in the Keychain |
| Obsidian | vault settings travel with the vault (`.obsidian`) |
| Slack, Teams, Discord, Zoom data folders | caches and session tokens; settings are account-synced |
| Things / OmniFocus databases | databases with official sync; copying is not recommended by the vendors |
| Bartender | settings format changes across major versions; official import/export only |
| DaVinci Resolve project library, PowerGrades, render and project presets | stored in the project database; guidance: Project Manager *Back Up/Restore*, Gallery DRX export, render preset export |
| Photoshop plug-ins and scripts | architecture- and licence-dependent or inside the app folder; reinstall from the vendor / Creative Cloud |

## Verification performed

- Automated: `Tests/MacReplicaCoreTests/ProviderCatalogTests.swift` (catalog integrity, version patterns, detection,
  malformed locations, "nothing installed", caches never copied, default selection, running-app refusal, version
  notes, provider isolation, guidance, extension IDs) and `FileCredentialProviderTests` (exact detection, opt-in round
  trip, permissions, no secrets outside the vault). All run on synthetic data only.
- Read-only detection on the development Mac: Capture One (styles, presets, shortcuts, workspaces) and Camera Raw
  develop presets were detected (only provider, category and file counts were printed).
- `CreativeAppProviderTests`: beta/release separation, machine state never copied, presets into the installed
  Photoshop version or the original one by choice, Resolve LUTs without receipt files, waiting until Resolve is
  installed and continuing, permission denied, never into an older Resolve, keep/replace/skip for differing files,
  older manifests.
- **Real applications (2026-10-03, Photoshop beta 27.12, DaVinci Resolve Studio 21.1, development Mac):** the
  user's real data was backed up with the real MacReplica app, exactly the backed-up files were moved aside, both
  apps were opened (they recreated their defaults: Photoshop showed only Adobe's default action sets, Resolve had
  no custom keyboard preset and could not apply the custom LUTs), MacReplica restored with *Replace with the
  backup*, all 47 files matched their checksums, and after relaunching: Photoshop's action sets and preset lists
  were identical to before (scripting probe), Resolve listed and used the custom keyboard preset again and applied
  the custom LUTs (`SetLUT` on a temporary project, a non-existent LUT still refused). Evidence:
  `~/Desktop/MacReplica-Staging/validation/real-apps/`, screenshots R1–R8. Photoshop release (non-beta) was not
  installed and is verified with synthetic data only.
