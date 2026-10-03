# Distribution channels, official downloads and guided installation

Some apps cannot be reinstalled automatically: they are not in Homebrew, they come from the Mac App
Store, or they are a beta or nightly build from the vendor. For these, MacReplica offers a guided
installation that finds official downloads, verifies them and installs the apps one after another.

## What the backup records per app

| Field | Source | Notes |
|---|---|---|
| Release channel (stable, beta, nightly, insider, preview) | Homebrew cask token (`firefox@nightly`), bundle identifier (`…canary`, `…-EAP`, `…Insiders`), the end of the app name ("… Nightly"), version (`158.0b3`, `159.0a1`, `-insider`), feed URL | Recorded only with evidence, together with what it was derived from. Without evidence, no channel is recorded – MacReplica never assumes "stable". |
| Installation source | App Store receipt, Homebrew cask, installer package receipt, quarantine attribute (browser that downloaded it) | unchanged from earlier versions |
| Update feed | `SUFeedURL` and `SUPublicEDKey` from the app's `Info.plist` (Sparkle) | Only values from the signed bundle, which are the same for every user; never the app's preferences (they may contain license data). Placeholders, non-web URLs and URLs with credentials are ignored. |
| Developer Team ID | the app's code signature, read locally | Downloads must carry the same Team ID. |

Restoring reproduces the source where possible: a cask is reinstalled with the same token (so
`firefox@nightly` stays nightly), and a vendor feed offers the same channel first.

## Finding official sources

Only when the user clicks *Look Up Downloads* does MacReplica contact the network for these apps. It
considers, in this order:

1. **The vendor's own update feed** (Sparkle appcast) declared in the app. For each channel in the feed,
   the newest item that runs on this Mac (minimum and maximum macOS version, Apple-silicon-only
   items on Intel) is offered. Feeds over plain HTTP are only used if the app declares a vendor key,
   and then only items signed with it.
2. **The vendor download that Homebrew's cask points to**, downloaded directly – for apps that match a
   cask by bundle identifier or app name. The platform-specific URL for this Mac is used. Casks that
   need browser-like requests (cookies, special headers) or are disabled are not offered.
3. **The Mac App Store page** for App Store apps (`macappstore://` link).
4. **The vendor's website**, as recorded or from the cask.

Never: download portals, mirrors, search results or any other third-party source.

With several sources, the user chooses. MacReplica recommends the source with the same channel as on
the old Mac (stable if none was recorded) and the strongest verification.

## Verification

| Offer | Before anything is installed, MacReplica checks |
|---|---|
| Vendor feed with signature | file size as published; the vendor's **EdDSA signature over the whole file** with the public key from the original app (Sparkle's own scheme) |
| Homebrew cask download with checksum | **SHA-256** from Homebrew's reviewed cask |
| Download without published checksum | only offered when the original app had a Team ID; the downloaded app's **code signature must be valid and from the same Team ID** |
| Nothing verifiable | not downloaded – the vendor's website is opened instead |

After unpacking, every application additionally must have:

- the **same bundle identifier** as the original;
- the **same developer Team ID** and a valid code signature (all architectures, nested code, strict
  checking) when the original was signed;
- an architecture this Mac can run (Intel apps on Apple silicon only with Rosetta);
- a minimum macOS version this Mac meets.

Installer packages must be signed by a developer certificate issued by Apple (`pkgutil
--check-signature`) with the original Team ID when one is known.

A file that fails a check is deleted and nothing from it is opened. Every downloaded file gets the
macOS quarantine flag, so Gatekeeper still checks the app on first launch – exactly as for a
download in a browser. MacReplica never removes the quarantine flag.

## Installing

| Download | What happens |
|---|---|
| ZIP | unpacked with `ditto` into MacReplica's own folder |
| Disk image | mounted read-only, hidden, without opening it (`hdiutil attach -nobrowse -readonly -noautoopen`) and detached afterwards. Images with a license agreement are shown in Finder instead – the user accepts the license there; MacReplica never answers it. |
| Application | copied into `/Applications` – only if no app of that name exists, and only if the folder is writable without administrator rights; otherwise the app is shown in Finder to drag in |
| Installer package | opened in Apple's Installer; the user completes it there. MacReplica never runs `installer` or `sudo` for downloads. |

Afterwards MacReplica checks that the app is really installed (bundle identifier) before it counts as done.

## Download queue

Downloads run in the background (two at a time) with progress, **pause, resume, retry and cancel**.
Resuming continues where it stopped when the server allows it. Redirects from HTTPS to anything else
are refused. Files are named by MacReplica, not by the server, and kept in MacReplica's own folder
(`~/Library/Caches/MacReplica/Downloads`). All steps are logged.

## Installing one after another

*Install Selected One by One* works through the ticked apps: download (already started in the
background for the next apps), verify, install or hand over to Installer, App Store or website, wait
for the user, check the result, continue with the next app. While waiting, the user can answer
**Done** (check again), **Skip**, **Later** or **Cancel Installation**.

## Flexible and resumable

- Everything automatic runs first; guided installs come last and never block the rest.
- Each app can also be installed individually, skipped or postponed.
- Results are saved in the restore session after every app. The user's intent is kept apart from
  technical failures:

| Outcome | Meaning | Offered again when continuing |
|---|---|---|
| succeeded / already installed | done | no |
| skipped by you | intentionally not wanted | no |
| postponed by you | do it later | yes |
| cancelled by you | an installation was stopped | yes |
| waiting for you | a guided step not done yet | yes |
| failed | a technical problem (network, verification) | via *Retry Failed Items* |

When MacReplica is opened again, the start screen shows how many steps are waiting and continues
exactly there.
