#!/bin/bash
# Builds MacReplica.app (universal: Apple silicon + Intel).
#
#   scripts/build-app.sh [output-folder]        default: ./build
#
# Environment:
#   MACREPLICA_SIGN_IDENTITY  "Developer ID Application: …" for distribution.
#                             Without it the app is signed ad hoc (local use only).
#   MACREPLICA_ARCHS          default "arm64 x86_64"
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${1:-$ROOT/build}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/MacReplicaCore/System/SystemInfo.swift)"
MINOS="$(sed -n 's/.*static let minimumMacOS = "\(.*\)".*/\1/p' Sources/MacReplicaCore/System/SystemInfo.swift)"
BUILD_NUMBER="${MACREPLICA_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${MACREPLICA_ARCHS:-arm64 x86_64}"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> Building MacReplica $VERSION ($BUILD_NUMBER) for: $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}" --product MacReplica
swift build -c release "${ARCH_FLAGS[@]}" --product MacReplicaAskpass
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$OUT/MacReplica.app"
# Only ever replace an earlier MacReplica build, never another app.
if [ -d "$APP" ]; then
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" = "io.github.itsab1989.MacReplica" ]; then
    rm -rf "$APP"
  else
    echo "Refusing to overwrite $APP (not a MacReplica build)" >&2; exit 1
  fi
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/MacReplica" "$APP/Contents/MacOS/MacReplica"
cp "$BIN/MacReplicaAskpass" "$APP/Contents/Helpers/MacReplicaAskpass"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Sources/MacReplicaCore/Resources/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__MINOS__/$MINOS/" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing"
if [ -n "${MACREPLICA_SIGN_IDENTITY:-}" ]; then
  SIGN=(codesign --force --timestamp --options runtime --entitlements Packaging/MacReplica.entitlements --sign "$MACREPLICA_SIGN_IDENTITY")
else
  SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" "$APP/Contents/Helpers/MacReplicaAskpass"
"${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/MacReplica"
echo "==> $APP"
