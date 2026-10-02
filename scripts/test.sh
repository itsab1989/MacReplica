#!/bin/bash
# Runs the complete test suite. Usage: scripts/test.sh [extra swift test arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  export MACREPLICA_CLT_TESTING=1
fi
exec swift test "$@"
