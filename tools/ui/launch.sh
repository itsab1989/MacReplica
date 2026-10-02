#!/bin/bash
# Launches the built MacReplica.app against a simulation root for on-screen validation.
# Usage: tools/ui/launch.sh <simulation-root> [language] [unused] [width height]
# For dark mode, switch the system appearance temporarily (see docs/VALIDATION.md).
set -euo pipefail
ROOT="$1"; LANGUAGE="${2:-en}"; W="${4:-760}"; H="${5:-600}"
APP="${MACREPLICA_APP:-$HOME/Desktop/MacReplica-Staging/build/MacReplica.app}"
osascript -e 'quit app "MacReplica"' >/dev/null 2>&1 || true
sleep 1
defaults write io.github.itsab1989.MacReplica.simulation appLanguage "$LANGUAGE"
ARGS=(--simulation-root "$ROOT")
open -n "$APP" --args "${ARGS[@]}"
for _ in $(seq 1 40); do
  if osascript -e 'tell application "System Events" to tell process "MacReplica" to get name of window 1' >/dev/null 2>&1; then break; fi
  sleep 0.5
done
osascript -e 'tell application "System Events" to tell process "MacReplica" to set position of window 1 to {100, 40}' \
          -e "tell application \"System Events\" to tell process \"MacReplica\" to set size of window 1 to {$W, $H}" >/dev/null
sleep 0.8
