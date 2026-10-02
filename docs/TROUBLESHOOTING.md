# Troubleshooting

When something goes wrong, MacReplica says what happened and what to do — on the summary screen and
in the logs. This page collects the common cases.

**Logs:** `~/Library/Logs/MacReplica/` (*Help → Open Logs*). **Diagnostic report:**
*Help → Export Diagnostic Report …* writes one file with recent logs and system information (your
home folder appears as `~`; no passwords or file contents). Read it before attaching it to an issue.

## macOS says MacReplica cannot be opened

**What happened:** MacReplica releases are not signed with an Apple Developer ID and not notarized
(the project has no paid Apple Developer membership). macOS Gatekeeper therefore blocks the first
launch of the downloaded app and shows a message that it cannot verify the app.

**What to do** (Apple's procedure for apps from unidentified developers, valid for all macOS versions
MacReplica supports — [Apple Support](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)):

1. Try to open MacReplica once and close the message.
2. Open **Apple menu → System Settings → Privacy & Security**.
3. In the **Security** section, next to the message about MacReplica, click **Open Anyway**. The
   button is shown for about an hour after the blocked attempt.
4. Enter your login password and confirm. MacReplica opens and is remembered as an exception; later
   launches work normally.

Control-clicking the app and choosing **Open** no longer bypasses this check since macOS 15 Sequoia
([Apple Developer](https://developer.apple.com/news/?id=saqachfa)); on macOS 13 and 14 the
Privacy & Security way above works as well.

**What was verified:** the release disk image is assessed as *rejected* by Gatekeeper (`spctl`) on
GitHub's macOS 14, 15 and 26 runners, i.e. macOS will block it until you allow it. On the
developer's Mac Gatekeeper is turned off, so the dialogs themselves could not be observed there;
the steps above follow Apple's documentation. If the wording on your Mac differs, please open an issue.

To check that the download is intact, compare `shasum -a 256 MacReplica-<version>.dmg` with the
`.sha256` file attached to the release.

## A location shows “no permission” in the scan

macOS protects some folders (for example other apps' data). MacReplica does not ask for Full Disk
Access; it reports these locations and continues. If you want them included, click the button next to
the message to open *Privacy & Security* and grant access, then scan again — or continue without them.

## “Not signed in to the App Store”

App Store apps are reinstalled with `mas`, which cannot sign in for you. Open the App Store, sign in
with your Apple Account, then click **Retry Failed Items**. You can also install the app from your
purchases in the App Store.

## Homebrew or the Command Line Tools did not install

- Make sure the Mac is online, then **Retry Failed Items**.
- The Command Line Tools are installed by Apple's own dialog — confirm it when it appears; on a slow
  connection it can take a while.
- If Homebrew is installed but broken, the summary says so; repair it (`brew doctor`) and retry.

## An app could not be restored automatically

Apps without a Homebrew package or App Store entry, licensed software and apps from installers are
listed under **Install these apps yourself**, with a link to the vendor's website where it is known.

## Python environment problems

- **Python version not available:** Homebrew no longer offers that Python version. Create the
  environment with a newer version; the restore instructions in the backup list the packages.
- **Some packages are missing:** they may only exist in newer versions, or were installed from a
  local folder or repository — the summary names them.
- **Something else exists at the environment's location:** MacReplica never overwrites it; move it
  away and retry.

## App data was not restored

- **The app is running:** quit it and retry — some apps overwrite their files when they quit.
- **Different app version:** data is restored into the version folder it came from; if that version
  is not installed, the summary notes it. Data from one major version may not work in another.

## A font or profile shows “Provided by macOS” or “Different version”

macOS already has it, or has another version. Keep this Mac's version unless you need the old file;
see [FONTS_AND_PROFILES.md](FONTS_AND_PROFILES.md). Fonts appear in apps after you reopen them.

## The restore was interrupted

Open MacReplica again. The start screen offers **Continue** (same choices; finished steps are not
repeated), **Review …** (change what has not been restored yet) or **Discard**. If credentials are
part of the restore, the passphrase is asked for again — it is never stored.

## A backup is reported as damaged or incomplete

Copy the whole backup folder again from the old Mac. **Check Backup** lists the affected files;
damaged files are never restored, everything else can be.

## The update check cannot reach GitHub

Check the internet connection or try later. Nothing else depends on the update check.

## MacReplica does not start, or starts in safe mode

If MacReplica did not start completely last time, it starts in **safe mode** (unfinished restores are
not loaded automatically, English interface) and offers the logs and a diagnostic report. Choose
**Continue Normally** once you have saved the report. If it does not start at all, make sure you use
macOS 13 or later, then open an issue with the files from `~/Library/Logs/MacReplica/`.
