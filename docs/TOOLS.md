# Tools: Gatekeeper, macOS updates, window corners

The fourth option on MacReplica's start screen. Three independent tools for this Mac. Each one shows what it finds,
explains what a change would do, asks before anything changes, checks the real state afterwards and records the
change in a short history. None of them runs during an inventory, backup or restore, and none adds a permission for
users who don't open them.

Research date: 2026-10-13. Test Mac: macOS 27.0.1 (26A434, “Golden Gate”), Apple silicon, not enrolled in device
management. Version names: macOS 26 is Tahoe; macOS 27 is Golden Gate (released 2026-09-14, Apple silicon only; the
name and the board list come from the SOFA feed of the MacAdmins community and several news sites, not an apple.com
page).

## Architecture

| Layer | Where |
|---|---|
| Environment, capability states, verification, history | `Sources/MacReplicaCore/Tools/ToolKit.swift` (`ToolEnvironment`, `ToolCapability`, `ToolVerification`, `ToolOutcome`, `ToolHistoryStore` → `~/Library/Application Support/MacReplica/tools-history.json`) |
| Gatekeeper: state, per-app inspection | `Tools/GatekeeperTool.swift` |
| Software Update: settings, support status | `Tools/UpdatePreferencesTool.swift` |
| Profiles (Gatekeeper off, major-upgrade deferral) | `Tools/ConfigurationProfiles.swift` |
| Window corners | `Tools/WindowCornersTool.swift` |
| UI and flow (confirmation → change → re-read → history) | `Sources/MacReplica/App/AppModel+Tools.swift`, `Views/ToolsViews.swift` |

Capability states: Supported, Supported with limits, Experimental, Your step in System Settings, Needs administrator
password, Managed by your organisation, Not available on this macOS, Could not be determined.

Commands are fixed argument lists of allow-listed executables (`spctl`, `csrutil`, `profiles`, `codesign`,
`syspolicy_check`, `softwareupdate`), all read-only and without administrator rights. MacReplica never runs `sudo` for
these tools, never installs or removes a profile itself and never writes the Software Update settings: those steps are
the user's, in System Settings, where macOS asks for the password. The only thing MacReplica writes is the window-corner
setting in the user's own preferences, and the `.mobileconfig` files it prepares in its Application Support folder.

History entries hold: tool, change, previous and resulting state (machine-readable, no personal data), date, macOS
version, result, verification, and whether a revert is available.

## A. Gatekeeper and app security

Findings:
- `spctl --status` prints `assessments enabled`/`assessments disabled` (exit 1 when disabled) without administrator rights.
- Since macOS 15, `spctl --global-disable` only *reveals* “Anywhere” in Privacy & Security, and the user has to choose
  it there. Apple Developer News, 2024-08-06: https://developer.apple.com/news/?id=saqachfa. `man spctl` on 27 lists
  rule-database changes as “no longer supported”.
- A hand-installed profile with `com.apple.systempolicy.control` / `EnableAssessment = false` still turns assessments
  off on macOS 27. This was checked on the test Mac, which has such a profile from a third party. Its values are
  world-readable in `/Library/Managed Preferences/com.apple.systempolicy.control.plist`, with `_manualProfile = true`.
  Payload: https://developer.apple.com/documentation/devicemanagement/systempolicycontrol. Profiles can only be installed
  by the user in System Settings › General › Device Management (since macOS 11).
- `profiles -C`, `profiles status -type enrollment`, `csrutil status` and `system_profiler SPConfigurationProfileDataType`
  work without root. `profiles list -all` needs root and still exits 0.
- Per app: quarantine via `getxattr` (agent name stored with `\x20`), `codesign --verify --deep --strict`,
  `codesign -dv`, `codesign --verify -R=notarized` (online check; `stapler` needs Xcode),
  `spctl --assess --type execute -vv`, and `syspolicy_check distribution --json` on 14+, which exits 0 even with a fatal
  finding. When Gatekeeper is off, every verdict is `accepted` with `override=security disabled`; MacReplica shows
  this as “not checked”.
- The supported per-app route is “Open Anyway” in Privacy & Security, available for about an hour after a blocked launch
  (https://support.apple.com/en-us/102445). Removing the quarantine attribute skips Apple's malware check;
  MacReplica does not do it.

What MacReplica does:
- Shows the state: Gatekeeper, the profile that sets it (a third-party one, MacReplica's own, or an organisation's), device
  management and SIP. It never confuses one app's quarantine with the global state.
- Checks one app and gives advice: opens normally / asks once / blocked → guided “Open Anyway” (opens the app and the
  pane, then re-checks) / damaged / not checked because Gatekeeper is off.
- On request, after a warning, it prepares **its own** profile `io.github.itsab1989.MacReplica.gatekeeper`. The user
  installs it, and MacReplica verifies it with `profiles -C` plus `spctl --status`. To turn checking back on, the user
  removes that profile only, and MacReplica verifies again. If another profile turns Gatekeeper off, MacReplica points to
  Device Management but neither touches that profile nor adds a second one. On a managed Mac it only shows the state.

| | 13 | 14 | 15 | 26 | 27 |
|---|---|---|---|---|---|
| Read state (`spctl`, profiles, SIP, enrolment) | yes | yes | yes | yes | **verified** |
| Per-app inspection | yes (no `syspolicy_check`) | yes | yes | yes | **verified** |
| “Open Anyway” route | yes (and Ctrl-click) | yes (and Ctrl-click) | only route | only route | only route |
| Gatekeeper-off profile, manual install | works | works | works | works (Oakley) | **works** (same payload on the test Mac) |

## B. macOS updates

Findings:
- The switches are in `/Library/Preferences/com.apple.SoftwareUpdate.plist` (world-readable, root-writable). Missing keys:
  check → on, download → on, install macOS updates → **off**, security/config data → on (compared with the
  27 UI). The 27 sheet has three switches; there is no “Check” switch and no App Store switch.
- Apple installs a new major version only after the user clicks “Upgrade” (update vs. upgrade:
  https://support.apple.com/en-us/108382). Risks: “Update all”, the list under “More info…”, and notification buttons.
- Major-upgrade deferral (`com.apple.applicationaccess` `forceDelayedMajorSoftwareUpdates` +
  `enforcedSoftwareUpdateMajorOSDeferredInstallDelay`, 1–90 days, per release):
  - Works with a hand-installed profile on 13–15.7.4.
  - From 15.7.5 there is one period for all updates, so security updates are delayed too.
  - 26 has a separate major period but deprecates the key.
  - **27 removed it.** Its successor (declarative `softwareupdate.settings`) needs supervised MDM.
  - Sources: https://developer.apple.com/documentation/devicemanagement/restrictions, https://support.apple.com/126206.
- There is no supported way to hide the upgrade badge or banner. `softwareupdate --ignore` is gone on 27.
- Support status: `softwareupdate --list-full-installers` (no root, asks Apple) lists the versions this Mac can install. A
  major version older than the three newest offered is reported as “probably no longer receives security updates”;
  Apple publishes no end dates.

What MacReplica does:
- Shows the switches and warns when security updates are off.
- Asks Apple about this version on request.
- Compares the switches with “stay on this version, stay secure” (download, install macOS updates, security on), opens
  Software Update and re-reads the plist afterwards. The result is “checked”, or “not done yet” with the missing switches.
- “Restore previous settings” goes back to the recorded state. It warns if that state has security updates off.
- On 13–15.7.4 and 26 it prepares its own deferral profile `io.github.itsab1989.MacReplica.defer-major-upgrades` (30,
  60 or 90 days, never more). It verifies the profile, the managed preference, and `Deferred: YES` in Apple's installer
  list when a newer version exists; otherwise the result is “partly checked”. On 15.7.5+ and 27 the option is not shown;
  the card explains why.

| | 13 | 14 | 15.0–15.7.4 | 15.7.5+ | 26 | 27 |
|---|---|---|---|---|---|---|
| Read switches | yes | yes | yes | yes | yes | **verified** |
| Guided change + re-read | yes | yes | yes | yes | yes | yes (simulated plist) |
| Deferral profile (≤ 90 days) | offered | offered | offered | not offered (delays security updates) | offered (deprecated) | **not possible** |
| Hide upgrade badge | no supported way in any version | | | | | |

## C. Window corners

Findings (all measured on 27.0.1 in throwaway test apps; values passed as launch arguments or into the test app's own
preference domain, so nothing on the Mac was changed; images in the validation folder):
- **`NSConvolutionOverride1`**: a private AppKit default, in AppKit's own strings. Its value is the corner radius in
  points of titled windows (`NSThemeFrame`), read in each app's process at launch. The default on 27 is 16 pt.

  Measured: 4 → ≈5 pt, 7 → ≈7 pt, 10 → ≈10 pt, 20 → ≈20 pt, 26 → ≈26 pt.
- **`NSConvolutionOverride2`**: the same for utility panels and inspectors.
- **`NSGlassMenusEnabled = NO`**: AppKit falls back to its older menu window without glass, with ≈6 pt corners instead of
  11.9 pt. This is a fixed style, not a radius, and the menu material changes too. It applies to context and pop-up menus
  and the menus of menu-bar items in AppKit apps.
- **Versions**: reported to work from 26.4 (TinkerTool 11.7). Earlier versions ignore it, and macOS 15 and older use about
  10 pt anyway.
- **No setting affects** popovers (≈20 pt), the Quick Look panel (≈20.5 pt), toolbar groups (capsules, radius = half the
  height) or capsule buttons (`NSButton.borderShape` automatic/capsule). These draw their own shapes.

  Tested without effect: `QLUseCGRoundedCorners`, `NSCornerRadius*`, `NSMenuUseGlassWindowStyle`,
  `NSPopoverUseSolariumGlassShadow`, `NSPopoverFrameCanEmbedContentInGlass`, `NSControlSolariumMetrics`,
  `NSControlFauxSolariumMetrics`, `NSButtonMayNeedLegacyAutomaticBezelStyleBehavior`, `NSSolariumEnabled`,
  `com.apple.SwiftUI.DisableSolarium`, and Reduce Transparency.
- **All of these surfaces are drawn inside each app's own process**, so code loaded into the app can change them:
  - Menus: `NSPopupMenuWindow` → glass `cornerRadius` and `_setCornerRadius:`.
  - Popovers and the Quick Look frame: `-[NSPopoverFrame _copyFrameMaskPathInRect:]`.
  - Toolbar groups: the glass view in `NSToolbarPlatterView` after layout.
  - Buttons: `borderShape` set to rounded rectangle.
- **The rounded picture area inside Quick Look** (≈15 pt) comes as an image from the protected `QuickLookUIService` and
  cannot be made smaller.

What MacReplica does (experimental, 26.4+ only; elsewhere the card says it isn't available and shows no controls):
- **Without anything else:**
  - one radius (2–24 pt) for app windows and for utility panels;
  - classic menus as a separate switch;
  - written to the user's global preferences through CFPreferences, the same as `defaults write -g`.
- **With the corner plugin** (behind a warning): its own radius for menus, popovers, the Quick Look window and toolbar
  groups, plus capsule buttons drawn as rounded rectangles in all apps.
- **Radius per surface:** one radius for everything by default, or a separate radius per surface. Every surface can be
  left out.
- **One step for all keys:** one confirmation, one history entry with a snapshot of every key's exact previous value.
  “Restore previous” writes all of them back exactly; “Restore macOS default appearance” removes them all.

### The corner plugin (advanced, at the user's own risk)

`Extras/CornerPlugin/MacReplicaCorners.m` is built into the app as `Contents/Library/CornerPlugin/MacReplicaCorners.dylib`
(arm64 and arm64e), next to `MacReplicaCorners.dylib.blacklist`. It is loaded by the Ammonia tweak loader
(github.com/CoreBedtime/ammonia), which needs:
- System Integrity Protection off (recoveryOS: `csrutil disable`);
- the boot argument `-arm64e_preview_abi`;
- the loader itself installed.

MacReplica never changes System Integrity Protection or boot arguments. It shows the steps to enable and to undo
everything, detects each requirement (`csrutil status`, `nvram boot-args`, the tweak folder), and installs or removes
exactly its two files in `/var/ammonia/core/tweaks/`. This uses the administrator password and fixed `install`/`rm`
commands; `rm` is refused for any other path.

Safety design of the plugin:
- It does nothing on macOS builds other than the tested ones. Currently that is only 26A434 = 27.0.1, and a test keeps
  the list in Swift and in the plugin identical.
- It never loads into system processes: the blacklist excludes `/usr`, `/System/Library/(Private)Frameworks`, the
  login window and similar.
- It only hooks what was chosen.
- It checks every class and method before replacing it, and adds overrides only on the exact class.
- It catches exceptions around every change.

Costs while System Integrity Protection is off: Apple Pay and iPhone/iPad apps do not work, and security is weaker. A
crash in a loaded plugin would affect apps. Recovery is always possible by removing the plugin (in MacReplica, or in
recoveryOS Terminal) and turning System Integrity Protection back on, which also stops all loading.

Measured in the test app with the real plugin (menu / popover / Quick Look):

| Setting | Menu | Popover | Quick Look |
|---|---|---|---|
| Plugin without settings | 11.9 pt | 20.5 pt | 20.5 pt (unchanged) |
| Shared radius 6 | ≈6.8 pt | ≈6.8 pt | ≈6.8 pt |
| Separate radii 4 / 10 / 16 | ≈5.1 pt | ≈10.2 pt | ≈17.1 pt |

Further results:
- Toolbar group 18 → 7 pt; the large capsule button and Quick Look's “Open with …” became rounded rectangles.
- A build of the plugin whose tested list does not contain this Mac's build changed nothing.
- Untested on Apple's own apps (Finder, Safari): that would need System Integrity Protection off on the test Mac.

| | 13–15 | 26.0–26.3 | 26.4+ | 27 |
|---|---|---|---|---|
| Windows / panels (no plugin) | no (not needed) | no (key ignored) | experimental (reported, not tested here) | experimental, **verified visually** |
| Classic menus (no plugin) | – | not tested | not tested | **verified in test app** |
| Plugin surfaces | – | – | plugin inactive (untested builds) | **verified in test app** (26A434) |
| Relaunch needed | – | – | apps | apps |
| Survives macOS update | – | – | not guaranteed | not guaranteed; the plugin switches itself off |
| Revert | – | – | exact previous values | exact previous values |

## Verification (2026-10-13)

| Capability | Status | Evidence |
|---|---|---|
| Tools as the fourth start option, all three cards, 7 languages | Verified | Real app on screen; localisation tests |
| Gatekeeper state incl. third-party profile | Verified | Real macOS 27 state on screen: “off”, “a configuration profile you installed” |
| Per-app inspection | Verified | IINA on screen: signature, notarised (online), quarantine by Homebrew Cask, “not checked – Gatekeeper is off” |
| “Open Anyway” guidance | Not verified | Needs a blocked app with Gatekeeper on, and the user's password; the test Mac has Gatekeeper off |
| Gatekeeper-off profile: prepare, install, verify, remove, verify | Simulated | Stand-ins for `profiles`/`spctl` on a simulated 27 Mac; generated payload checked. The same payload works on the real test Mac (third-party profile) |
| Update switches | Verified | Real plist on 27 matches the System Settings sheet |
| Support status | Verified | Real Apple installer list: simulated 14.8.4 → “probably no longer…”, update 14.8.9 available |
| Guided update change, “not done yet” → “checked”, revert | Simulated | Sandbox plist changed between checks, standing in for the user's change |
| Deferral profile on 26 (Intel) | Simulated | Stand-ins; “partly checked” because nothing newer is offered to an Intel Mac |
| Deferral on 27 | Unsupported | Apple removed the key; the card says so and shows no button |
| Corner setting: write → read back → visual → exact revert | Verified | MacReplica's write path into a test app's own domain via cfprefsd; real window 7 px → 13 px corner run (≈5 pt → ≈7 pt) |
| Corner tool in the app UI | Simulated | Sandbox preference file on a simulated 27 Mac (apply 10/10, revert to “not set”) |
| Classic menus key | Verified (test app) | 11.9 → 6.8 pt in a test app; not tested system-wide (would change the user's settings) |
| Corner tool UI: shared/separate radius, each surface on/off, apply, exact revert | Simulated | Sandbox preference file on a simulated 27 Mac |
| Corner plugin: menus, popovers, Quick Look, toolbar groups, buttons | Verified (test app) | Real plugin injected into a throwaway app: measured radii above; inert on an untested build |
| Corner plugin: install / remove, requirements | Simulated | Stand-ins for `csrutil`/`nvram` and a sandbox tweak folder; installed file identical to the bundled one |
| Corner plugin in Finder, Safari, other apps | Not verified | Needs System Integrity Protection off on the test Mac |
| Quick Look picture area | Unsupported | Drawn by QuickLookUIService (≈15 pt) |
| Corners on 26.4–26.x | Not verified | Reported by TinkerTool; no 26.4 Mac available |
| Gatekeeper: open app, remove/restore quarantine of one app | Verified | Throwaway app on screen: mark removed, put back byte for byte, app opened (translocated while quarantined) |

Nothing in these tests changed the test Mac's Gatekeeper, update or appearance settings. The global corner value (7, set
by the user before) was read but never written.
