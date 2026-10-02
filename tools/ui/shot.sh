#!/bin/bash
# Captures only MacReplica's front window (no desktop, no other apps).
# Usage: tools/ui/shot.sh <output.png> [owner]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${MACREPLICA_TOOLS_BIN:-$HERE/../../.build/ui-tools}"
mkdir -p "$BIN"
[ -x "$BIN/window-id" ] || swiftc -O "$HERE/window-id.swift" -o "$BIN/window-id"
ID="$("$BIN/window-id" "${2:-MacReplica}")"
screencapture -x -o -l "$ID" "$1"
echo "$1"
