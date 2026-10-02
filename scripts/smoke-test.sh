#!/bin/bash
# Launches a built MacReplica.app and checks that it starts completely.
#
#   scripts/smoke-test.sh <MacReplica.app> [expected-version] [simulation-root]
#   SMOKE_ARCH=x86_64 scripts/smoke-test.sh …   run the Intel slice (under Rosetta on Apple silicon)
#
# MacReplica records every launch in <logs>/startup.json; the newest record must be
# "completed": true (the user interface came up) and carry the expected version. Without a
# simulation root the app runs normally and the logs are in ~/Library/Logs/MacReplica — use
# that only on throwaway machines such as CI runners. Exits non-zero on failure.
set -euo pipefail
APP="$1"; EXPECTED="${2:-}"; SIMULATION="${3:-}"
[ -d "$APP/Contents/MacOS" ] || { echo "not an app bundle: $APP" >&2; exit 1; }
EXEC="$APP/Contents/MacOS/MacReplica"
if [ -n "$SIMULATION" ]; then
  LOGS="$SIMULATION/home/Library/Logs/MacReplica"
  ARGS=(--simulation-root "$SIMULATION")
else
  LOGS="$HOME/Library/Logs/MacReplica"
  ARGS=()
fi
STARTUP="$LOGS/startup.json"
BEFORE=0
[ -f "$STARTUP" ] && BEFORE=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$STARTUP")

echo "==> Architecture of this Mac: $(uname -m); macOS $(sw_vers -productVersion)"
echo "==> Launching $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ -n "${SMOKE_ARCH:-}" ]; then
  /usr/bin/arch -"$SMOKE_ARCH" "$EXEC" "${ARGS[@]+"${ARGS[@]}"}" > /dev/null 2>&1 &
else
  "$EXEC" "${ARGS[@]+"${ARGS[@]}"}" > /dev/null 2>&1 &
fi
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  sleep 1
  kill -0 "$PID" 2>/dev/null || { echo "MacReplica exited during startup" >&2; exit 1; }
  [ -f "$STARTUP" ] || continue
  RESULT=$(/usr/bin/python3 - "$STARTUP" "$BEFORE" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
if len(records) <= int(sys.argv[2]):
    print("waiting"); sys.exit()
last = records[-1]
print(("completed" if last.get("completed") else "waiting") + " " + str(last.get("version")) + " " + " ".join(last.get("stages", [])))
PY
)
  case "$RESULT" in
    completed*)
      VERSION=$(echo "$RESULT" | awk '{print $2}')
      echo "==> Startup completed: $RESULT"
      if [ -n "$EXPECTED" ] && [ "$VERSION" != "$EXPECTED" ]; then
        echo "version $VERSION, expected $EXPECTED" >&2; exit 1
      fi
      ps -o pid=,comm= -p "$PID" > /dev/null && echo "==> Process $PID is running"
      # Rosetta's runtime in the process means the Intel slice is running translated.
      if /usr/sbin/lsof -p "$PID" 2>/dev/null | grep -q "libRosettaRuntime"; then
        echo "==> Running the x86_64 slice under Rosetta"
      else
        echo "==> Running natively ($(uname -m))"
      fi
      kill "$PID"; wait "$PID" 2>/dev/null || true
      trap - EXIT
      echo "==> Smoke test passed"
      exit 0 ;;
  esac
done
echo "startup did not complete within 60 seconds" >&2
[ -f "$STARTUP" ] && tail -c 2000 "$STARTUP" >&2
exit 1
