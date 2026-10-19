# Checking the installers you keep

How MacReplica decides what an installer you chose (**Use my installer …** or **Add installer folder …**) is, and
when it may call one damaged. Introduced in 1.1.0 after beta feedback on 1.0.7: working disk images — the DisplayCAL
installer the tester had just installed from, AppPolice, Adobe's Color Printer Utility — were reported as *“damaged,
incomplete (an interrupted download?) or encrypted”*.

## What went wrong

Every failure of `hdiutil imageinfo` or `hdiutil attach` was reported as damage. Neither tells why it failed:

- its exit status is `1` for every failure (damaged image, image already attached, mount folder gone, no file
  system macOS can mount);
- its messages are translated into the user's language even with `LANG=en_US` (“Keine aktivierbaren Dateisysteme”,
  “Image nicht erkannt”), so MacReplica cannot read them.

Failures that are not damage were therefore shown as damage. Reproduced with real files (2026-10-15, macOS 27.0.1):

| Situation | `hdiutil` | 1.0.7 showed |
|---|---|---|
| The folder the image is mounted in disappears during the attach (it happened when two inspections shared one work folder and the first removed it) | `attach failed – no mountable file systems`, exit 1 | damaged |
| An intact image without a file system macOS mounts (`hdiutil verify`: checksum VALID) | `attach failed – no mountable file systems`, exit 1 | damaged |
| A password-protected image | `imageinfo` waits for the password in a dialog until MacReplica's 120-second limit | damaged |
| The image is already open in Finder (as after installing from it) | `attach failed – resource busy`, exit 1; MacReplica's retry then **force-ejected the user's volume** | (worked, but ejected the volume) |

The tester's exact trigger could not be determined: his drive and log were not available, and 1.0.7 did not log
`hdiutil`'s message. His three images, downloaded from their official sources, are intact (`hdiutil verify`: VALID).
The exact `hdiutil` commands of 1.0.7 succeed on them on macOS 14.8, 15.7 (Apple silicon and Intel), 26.6 and 27.0,
with and without the browser's quarantine flag and with Gatekeeper on; on macOS 27 also from APFS, HFS+, exFAT, FAT32
and read-only volumes, and the 1.0.7 app inspects DisplayCAL from such a volume correctly. 1.1.0 records what each
tool reported, so a recurrence can be identified.

## The checks, each with its own verdict

| Step | How | Can prove damage? | If it fails |
|---|---|---|---|
| 1. Readable | MacReplica reads the file and computes its SHA-256 | — | *cannot be read* (drive gone, no permission) |
| 2. Bytes | Start and end of the file, without any tool (`FileFormatEvidence`): UDIF directory (`koly`) present and inside the file, its list of contents (the XML property list it points to) readable, encryption header (`encrcdsa`/`cdsaencr`), partition map or file system of a raw image, zip end record, `xar!` package header, web page, PDF, empty file | **yes**: a disk image whose directory is missing or points past the end, or whose list of contents is not a property list (`hdiutil` then fails without a report, “error 3840”); a zip without its end record | *incomplete* (cut short) or *not an installer* (e.g. a saved error page); an encrypted image is **kept**, `hdiutil` is never run on it |
| 3. Description | `hdiutil imageinfo -plist`; `pkgutil --check-signature` for packages | no — only together with step 5 | kept: *description could not be read*; unknown bytes **and** unreadable: *not recognised* (damage not claimed) |
| 4. Mount | Already attached? Then read where it is open and leave it open. Otherwise `hdiutil attach -readonly -nobrowse` into a folder of this inspection only | no — only together with step 5 | kept: *could not be opened on this Mac* |
| 5. Own checksum | `hdiutil verify -plist` (UDIF images that carry a checksum): its report of the **calculated** and the **expected** checksum (English keys, hex values – independent of the user's language); `pkgutil` reports `package is invalid (checksum did not verify)` | **yes**, only when the report shows two different checksums. A failure without a report (e.g. “Resource temporarily unavailable” while the disk-image service is busy) is tried three times and then counts as *checksum not checked* – the image is kept (1.1.8; before, every failed `verify` counted as damage) | *damaged* |
| 6. Contents | Apps at the top or one folder down (suites such as DisplayCAL), else a package or a nested disk image | no | kept: *no app or installer package found where MacReplica looks* |
| 7. Developer | Developer ID signature of the app or package, compared with the installed app | — | *developer cannot be verified* (used only after the user confirms) |
| 8. Compatibility | Architectures of the app (`Intel`, `Apple silicon`) are shown; on the new Mac the app is checked against the CPU and macOS version | — | shown; on the new Mac: *needs a newer macOS* / *does not run on this Mac* |

A kept installer whose contents are unknown (`contentsLimit`: `encrypted`, `notMountable`, `notReadable`,
`timedOut`, `notRecognised`, `notUnpacked`) is treated like a disk image with a licence agreement: it is listed with
the reason and a **Details** line (what each tool reported), it is used only after the user ticks **Use this
unverified installer**, its checksum is recorded, and on the new Mac it is opened in Finder for the user — after its
checksum was verified — if MacReplica cannot open it there either. An installer verified by its developer keeps all
of MacReplica's own checks on the new Mac and is never handed to Finder.

Nothing was weakened: the checksum of every kept file is still recorded and verified before use, the developer check
is unchanged, and an unverified installer still needs the user's explicit confirmation. Packages that `pkgutil`
reports as invalid were accepted as merely “not signed” before 1.1.0; they are now rejected.

## Clean-up

Each inspection works in a folder of its own (`inspect-<id>-<random>`), removed afterwards; the app's run uses a
folder of its own as well. MacReplica detaches only what it attached: attachments that existed before (an image open
in Finder, or attached by another program without a volume) are never detached. An attach that succeeded without a
volume is detached again at once. The original installer is never changed, moved or deleted.

## Tests

- `InstallerEvidenceTests` (fast, no tools): byte classification, records written by older and newer versions, every
  reason in all seven languages, `hdiutil info` and `pkgutil` output.
- `InstallerValidationTests` (real `hdiutil`, `pkgutil`, `ditto`): an intact image that does not mount is kept (the
  regression), an image already open stays open, attachments by others are never detached, two parallel inspections
  of one file, an encrypted image runs no `hdiutil`, unusual layouts are kept, a changed image is damaged by its
  checksum, cut-short images, zips and packages are incomplete/damaged, web pages and empty files are *not an
  installer*, unknown bytes are *not recognised*, and on the new Mac a confirmed image that does not open goes to
  Finder while a verified one does not.
- **Real installers** workflow (`.github/workflows/real-installers.yml`, on demand): MacReplica's inspection on real,
  officially published installers on macOS 14, 15, 26 and 15 (Intel), plus copies that are renamed (spaces,
  non-ASCII), quarantined, cut short, changed, a saved web page, a cut-short package, and DisplayCAL already open.
  `MacReplicaSimulator inspect-installer <file …>` runs the same inspection locally.
