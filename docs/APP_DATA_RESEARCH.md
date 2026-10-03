# Adobe Photoshop and DaVinci Resolve: research for the application data providers

Research date: **2026-10-03**. Confidence: **H** = official vendor source, **M** = vendor community expert or
consistent excerpt of a vendor page, **L** = community only, observed on a real installation, or inference.

Adobe's HelpX pages could not be fetched directly (HTTP 403); Adobe statements below come from search
excerpts of those pages and should be re-read before quoting them. Blackmagic statements come from the
DaVinci Resolve 21.1 Reference Manual and the technical notes that ship with Resolve
(`/Applications/DaVinci Resolve/DaVinci Resolve Manual.pdf`,
`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Technical Documentation/`,
`…/Developer/Scripting/README.md`), read on the development Mac.

## Adobe Photoshop (release and beta)

| Location (macOS) | Contents | Classification | MacReplica | Source | Conf. |
|---|---|---|---|---|---|
| `~/Library/Preferences/Adobe Photoshop <v> Settings/` `Actions Palette.psp`, `Brushes.psp`, `Swatches.psp`, `Gradients.psp`, `Patterns.psp`, `Styles.psp`, `CustomShapes.psp`, `Contours.psp`, `Default Type Styles.psp`, `ToolPresets.psp` | Panel contents | Adobe lists them as “setting files that you can manually copy from one installation to another” | *Panel contents*, selected, may go into another version | [Preset migration](https://helpx.adobe.com/photoshop/using/preset-migration.html) | H |
| same folder: `Color Settings.csf` | Active colour settings | portable | *Active color settings*, selected | [Preference file names](https://helpx.adobe.com/photoshop/kb/preference-file-names-locations-photoshop.html) | M |
| same folder: `Adobe Photoshop <v> Prefs.psp` | Preferences dialog (contains scratch-disk and plug-in paths) | version- and machine-dependent | *Preferences (same version only)*, not selected | same | H/M |
| same folder: `WorkSpaces/`, `WorkSpaces (Modified)/`, `Workspace Prefs.psp` | Workspaces | mostly portable, version-sensitive | offered, not selected | Adobe community expert | M |
| same folder: `New Doc Sizes.json`, `Favorite New Doc Sizes.json` | New-document presets | portable (JSON) | offered, not selected | Adobe community | M |
| same folder: `MachinePrefs.psp`, `PluginCache.psp`, `FMCache.psp`, `LaunchEndFlag.psp`, `QuitEndFlag.psp`, `sniffer-out*.txt` | GPU/hardware preferences, caches, launch markers, GPU log | machine state / cache | **never copied** | Preference file names KB (“re-created … the next time Photoshop launches”), display-driver KB | H |
| `~/Library/Application Support/Adobe/Adobe Photoshop <v>/Presets/<kind>/` (Actions, Brushes, Tools, Keyboard Shortcuts, Menu Customization, Custom Toolbars, Curves, Levels, …) | Files saved from the panels | portable files, version-named folder | one item per kind, selected, may go into another version | Preset migration: “the default location for saving/loading/replacing presets” | H |
| same folder: `AutoRecover/`, `CT Font Cache/`, `FontFeatureCache/`, `AddOnModules/` | Recovery data, font caches, downloaded modules | temporary / cache | **never copied** | Troubleshoot fonts KB | H/L |
| `~/Library/Application Support/Adobe/Color/{Settings,Proofing}` | Custom colour settings and proof setups, shared by all Adobe apps | portable | *Adobe color settings*, selected | Preference file names KB | H |
| `~/Library/Application Support/Adobe/CameraRaw/Defaults` | Raw defaults (XMP) | portable | added to the Camera Raw provider | [Camera Raw defaults](https://helpx.adobe.com/camera-raw/kb/acr-raw-defaults.html) | M |
| `/Library/Application Support/Adobe/Plug-Ins/CC`, app `Plug-ins`, UXP plug-ins | Third-party and Marketplace plug-ins | architecture- and licence-dependent | not copied; reinstall from the vendor / Creative Cloud | [Plug-ins troubleshooting](https://helpx.adobe.com/photoshop/kb/plug-ins-photoshop-troubleshooting.html) | H/L |
| `/Applications/Adobe Photoshop <v>/Presets/Scripts` | Scripts (inside the app folder) | tied to the installed version | not copied | [Scripting](https://helpx.adobe.com/photoshop/using/scripting.html) | H |

**Beta.** “Beta apps have separate preferences and default user documents folders”
([Photoshop beta](https://helpx.adobe.com/photoshop/desktop/whats-new/photoshop-desktop-beta-overview.html), H). The folders
are named `Adobe Photoshop (Beta)` / `Adobe Photoshop (Beta) Settings`, but the beta app has the **same bundle
identifier** as the release (`com.adobe.Photoshop`, seen on Photoshop beta 27.12). MacReplica therefore
keeps the two apart by folder, with separate providers, and never moves beta data into a release folder.

**Closing.** Photoshop saves its preferences when it quits (H), so it must be closed during the restore.

**Versions.** Adobe's *Migrate Presets* only reads an older version on the same Mac. MacReplica restores
presets and the Adobe-listed panel files into the Photoshop version installed on the new Mac when the
backup's version is not there (the user can choose the original version instead). Preferences, workspaces
and document presets only go back into the version they came from.

**Verification.** Photoshop's AppleScript `do javascript` runs ExtendScript; Action Manager
`executeActionGet` lists action sets (`ASet`, name and action count) and the preset manager lists
(brushes, swatches, gradients, styles, patterns, contours, shapes, tool presets). Address the app by name
(`Adobe Photoshop (Beta)`), not by bundle ID. Used for the real-application check below.

## DaVinci Resolve

| Location (macOS) | Contents | Classification | MacReplica | Source | Conf. |
|---|---|---|---|---|---|
| `/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/` | LUTs and DCTLs (subfolders allowed), shared by all users; created by Resolve's installer | portable files | *LUTs* (shared folder), without the LUTs listed in Resolve's installer receipt; waits until Resolve is installed | Manual p. 3484, 4328 | H |
| `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/ACES Transforms/{IDT,ODT,AMF}` | ACES transforms, loaded at start | portable | *ACES transforms* | DaVinciCTL README, manual p. 250 | H |
| `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/{Templates,Macros,Fuses,Settings,LUTs,Scripts}` | Titles/transitions/effects templates, macros, fuses, tool presets, Fusion LUTs, scripts (scanned at start) | portable; scripts may contain keys | Fusion provider (scripts not selected) | Templates README, manual p. 1436, 1818, Scripting README | H/M |
| `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fairlight/Presets` | EQ, dynamics, macro FX, fades | portable | *Fairlight presets* | observed | M |
| `~/Library/Preferences/Blackmagic Design/DaVinci Resolve/keyboard.preset.xml` | All custom keyboard presets (one file, database version in its header) | same or newer Resolve only | *Keyboard shortcut presets*, selected, never to an older Resolve | Tech note “New Configuration location: $HOME/Library/Preferences/…”, manual p. 122–124 | H |
| same folder: `UI.preset`, `config.user.presets.xml`, `usersmartfolder.xml`/`usersmartfilter.xml`, `mediametadata.preset.xml`/`primaryhdr.preset.xml` | Layout presets and window layout, user-preference presets, user smart bins, metadata/HDR presets | same or newer Resolve only | selected | manual p. 60, 109 | M |
| same folder: `config.user.xml` | User preferences (contains absolute paths, last project) | version-sensitive | *User preferences*, not selected | inspected | M |
| same folder: `config.dat` | System preferences: GPU, decoding, video I/O, media storage, custom LUT paths, scripting mode | machine-specific | **never copied** | manual p. 94, inspected | H |
| same folder: `dblist.conf`, `recentprojects.conf` | Project library list (PostgreSQL entries may hold access details), recent projects | database / possible credential | **never copied** | inspected; manual p. 4230 | H/L |
| `…/Resolve Project Library/` (disk database) | Projects, PowerGrades, render presets, project-setting presets | database | **not copied**; guidance: Project Manager *Back Up/Restore*, Gallery DRX export, render preset export | manual p. 3342–3347, 4112, 4225–4227 | H |
| `/Library/…/DaVinci Resolve/.license/` | Activation | licence | **never copied** | tech note | H |
| logs, `.ui.cache.db`, `.LUT/` thumbnails, `Fusion/DiskCache` | caches and logs | cache | **never copied** | inspected | H |

**Important finding.** Resolve 21 reads its configuration from `~/Library/Preferences/Blackmagic Design/DaVinci
Resolve/` (its log names that folder); copies of the same files in Application Support on the development
Mac were stale. MacReplica uses the Preferences folder.

**Closing.** Resolve rewrites its preference files when it quits, so preferences are restored only while
it is closed. LUTs can be added while it runs; Resolve lists them after *Update Lists* or a restart.

**Versions.** The preference files carry Resolve's database version. MacReplica records the Resolve version
of the old Mac and never restores these files into an older Resolve (the step waits; updating Resolve and
continuing the restore restores them).

**Verification.** Resolve Studio (external scripting set to *Local*) can be scripted with the bundled
`ResolvePython`: `GetKeyboardPresetList()`, `GetCurrentKeyboardPreset()` (21.1+), `Project.RefreshLUTList()`
and `Graph.SetLUT()`, which only succeeds for LUTs Resolve has discovered. The free version allows scripting
only from Resolve's own console. Layout presets, smart bins and user-preference presets have no read API;
they are verified by checksum only.
