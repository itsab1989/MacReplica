#!/bin/bash
# Notarizes and staples a signed MacReplica disk image.
#
#   scripts/notarize.sh build/MacReplica-<version>.dmg
#
# Credentials come from the environment (GitHub Actions secrets), never from the repository:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (an app-specific password)
set -euo pipefail
DMG="$1"
: "${APPLE_ID:?APPLE_ID is not set}" "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}" "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is not set}"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
