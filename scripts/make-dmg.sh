#!/bin/bash
# Packs a built MacReplica.app into a compressed disk image with an Applications link.
#
#   scripts/make-dmg.sh [build-folder]        default: ./build (must contain MacReplica.app)
#
# Environment:
#   MACREPLICA_SIGN_IDENTITY  "Developer ID Application: …" to sign the disk image (optional).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(cd "${1:-build}" && pwd)"
APP="$OUT/MacReplica.app"
[ -d "$APP" ] || { echo "No MacReplica.app in $OUT – run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/MacReplica-$VERSION.dmg"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/macreplica-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacReplica.app"
ln -s /Applications "$STAGE/Applications"

# Replace only an earlier MacReplica disk image.
case "$(basename "$DMG")" in MacReplica-*.dmg) rm -f "$DMG" ;; esac
hdiutil create -volname "MacReplica $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
if [ -n "${MACREPLICA_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$MACREPLICA_SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> $DMG"
