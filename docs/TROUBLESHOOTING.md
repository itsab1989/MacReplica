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
Access for the scan; it reports these locations and continues. If you want them included, click the button next to
the message to open *Privacy & Security* and grant access, then scan again — or continue without them. Apple Mail and
Microsoft Office data can only be read and restored with Full Disk Access for MacReplica; without it, those items
wait and are listed as such.

## An App Store app is waiting for you

`mas install` needs administrator rights since mas 7, so MacReplica does not install App Store apps
itself. In the guided installation it opens each app's App Store page: sign in to the App Store with
your Apple Account, click *Get* or the download button, then **Done**. MacReplica checks that the app
is installed. Apps removed from the App Store or licensed through an organisation (VPP) cannot be
reinstalled this way.

## Homebrew or the Command Line Tools did not install

- Make sure the Mac is online, then **Retry Failed Items**.
- The Command Line Tools are installed by Apple's own dialog — confirm it when it appears; on a slow
  connection it can take a while.
- If Homebrew is installed but broken, the summary says so; repair it (`brew doctor`) and retry.
- **Casks fail with “Unexpected method … called on Cask” or “Do not report this issue until you've run
  `brew update`”:** the Homebrew on this Mac is too old for today's package definitions – typically one brought
  back from a Time Machine backup with automatic updates off. MacReplica then runs `brew update` once by itself
  (only on this evidence; it never updates a working Homebrew) and tries the package again; the summary notes it.
  If that update fails, the items say **Homebrew is too old**: run `brew update` in Terminal, then **Retry Failed
  Items**.

## Fonts or profiles for all users failed with “Operation not permitted”

MacReplica 1.1.1 and earlier let the administrator copy read each file straight from the backup drive. macOS
can refuse that to the administrator copy when the backup is on a network share or a drive you mounted, and the
first refusal stopped all remaining files. Now every file is first copied to this Mac as you and checked
against its checksum; only that copy is installed. Files that did arrive before a failure count as restored.

## An app could not be restored automatically

Apps without a Homebrew package come back in the **guided installation**: MacReplica looks up the
vendor's own update feed, the vendor download from Homebrew's catalog, the App Store or the vendor's
website, verifies downloads and installs them one after another. If no official download is found,
install the app the way you got it originally and click **Check Again**.

## A download was “not verified”

The file did not match the vendor's signature, Homebrew's checksum, the original app's bundle
identifier or developer Team ID, or does not run on this Mac. MacReplica deleted it without opening
it. Install the app from the vendor's website instead. If the vendor changed the developer account,
this is expected — check the vendor's website.

## A developer tool step is waiting or failed

- **Waiting for you:** the tool is a shell function (nvm, RVM, SDKMAN) or needs an installer or
  administrator rights (MacPorts, Nix). Run the command shown (**Copy**) in Terminal, then click
  **Check Again**; steps that depend on it (for example npm packages) follow automatically.
- **Required tool is missing:** the version or package manager is not installed, for example because
  its Homebrew package was unticked. Select or install it, then **Retry Failed Items**.
- **Conda reports terms of service:** Anaconda's default channels require accepting Anaconda's terms.
  MacReplica never accepts them for you — run `conda tos accept` yourself if you agree, then retry.
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

A restore stays open while steps wait for you (guided installations, printers and scanners), also after you quit
MacReplica or restart the Mac. **Continue** brings you back to its summary: **Continue with Guided Steps** opens
the apps, printers and scanners that wait, and **Retry Failed Items** runs the failed steps again – in the same
restore, so what already worked stays listed. The guided steps are only in MacReplica; the HTML restore report
lists them but cannot run them.

## Launchpad was not arranged

- *“Launchpad does not exist on this macOS”* appears only on macOS 26 and later, which replaced Launchpad with the
  Apps view; the old layout stays in the backup's report.
- *“Not arranged: MacReplica could not find Launchpad's database”*: this macOS has Launchpad, but MacReplica could not
  use its database; your current arrangement is not changed. The restore log (`~/Library/Logs/MacReplica`) records
  what macOS reported for each folder – please include it when you report this. Choose **Skip** if you do not need it.
- *“macOS does not let MacReplica read Launchpad's database”*: give MacReplica Full Disk Access, **quit MacReplica and
  open it again** (macOS applies the permission only then), then choose **Continue**.

## An app from Homebrew does not open (“built for another processor”)

An outdated Homebrew can install an app for the wrong processor, for example the Apple-silicon-only GIMP on an Intel
Mac, and still count it as installed. MacReplica checks the app's code: Homebrew's copy is reinstalled once; if that
does not help, the item says **Built for another processor**. To check an app yourself:
`lipo -archs "/Applications/GIMP.app/Contents/MacOS/$(defaults read /Applications/GIMP.app/Contents/Info CFBundleExecutable)"`
– an Intel Mac needs `x86_64` in the answer.

## A file says “Backup copy could not be read”

MacReplica could not find or read the copy in the backup – usually because the backup drive or network share
was disconnected (or went to sleep) during the restore. This is **not** damage: connect the backup again and
choose **Retry Failed Items**. **Check Backup** shows whether the files are intact. Only a copy whose checksum
differs is reported as **Damaged in the backup**.

## A backup is reported as damaged or incomplete

Copy the whole backup folder again from the old Mac. **Check Backup** lists the affected files;
damaged files are never restored, everything else can be.

**Check Backup** checks the files that are *in* the backup. Files that could not be saved when the backup was made
are not in it, so no checksum can find them: for such a backup the check says *“The saved files are undamaged – but
the backup is not complete”* and lists the missing files, like the reinstall guide does.

## An installer I chose is not used, or its contents were not checked

Under **Your installers (offline)** every file says what MacReplica found; **Checked:** or **Details:** names the
tool and what it reported.

- **Incomplete** or **damaged**: proven from the file itself (its end is missing, or its own checksum does not
  match). Download it again from the developer.
- **Not an installer**: the file is something else with an installer's name, often a web page saved instead of the
  download. Download it again.
- **Not recognised**: macOS could not open it and MacReplica does not know its format; damage is *not* proven. Try
  opening it in Finder; if it opens, choose the app inside it instead.
- **Contents not checked** (kept): the file is intact, but MacReplica could not look inside – it is
  password-protected, macOS did not open it on this Mac, the check did not finish (a slow or sleeping drive: choose
  it again), or there is no app where MacReplica looks. Tick **Use this unverified installer** if you trust it; on
  the new Mac it is opened in Finder for you.

An installer that is open in Finder can be chosen; it stays open. See [INSTALLER_VALIDATION.md](INSTALLER_VALIDATION.md).

## The update check cannot reach GitHub

Check the internet connection or try later. Nothing else depends on the update check.

## MacReplica does not start, or starts in safe mode

If MacReplica did not start completely last time, it starts in **safe mode** (unfinished restores are
not loaded automatically, English interface) and offers the logs and a diagnostic report. Choose
**Continue Normally** once you have saved the report. If it does not start at all, make sure you use
macOS 13 or later, then open an issue with the files from `~/Library/Logs/MacReplica/`.
