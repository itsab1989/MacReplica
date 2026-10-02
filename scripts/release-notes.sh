#!/bin/bash
# Writes the GitHub release notes for a version to stdout:
# the CHANGELOG section, download and first-launch instructions, compatibility and support.
#
#   scripts/release-notes.sh <version> [notarized: true|false]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; NOTARIZED="${2:-false}"

# GitHub shows every line break in release notes, so wrapped lines are joined into one line per
# paragraph or list item (code blocks are left alone).
unwrap() {
  /usr/bin/env python3 -c '
import re, sys
out, fence = [], False
for line in sys.stdin.read().split("\n"):
    if line.startswith("```"):
        fence = not fence; out.append(line); continue
    continuation = (not fence and out and out[-1].strip() and line.strip()
                    and not re.match(r"\s*([-*]|\d+\.|#|\||>)\s", line) and not out[-1].startswith(("#", "|", "```")))
    if continuation:
        out[-1] = out[-1].rstrip() + " " + line.strip()
    else:
        out.append(line)
print("\n".join(out))'
}
{

# The section of this version, without the link references at the end of the file.
awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  /^## \[/ { on = 0 }
  /^\[[^]]+\]: / { next }
  on' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'

cat <<EOF

## Download and install

1. Download **MacReplica-$VERSION.dmg** below. To check it, compare
   \`shasum -a 256 MacReplica-$VERSION.dmg\` with the attached \`.sha256\` file.
2. Open the disk image and drag **MacReplica** into **Applications**.
EOF
if [ "$NOTARIZED" = "true" ]; then
  echo "3. Open MacReplica from Applications."
else
  cat <<'EOF'
3. Open MacReplica from Applications. This build is **not signed with an Apple Developer ID and not
   notarized**, so macOS blocks the first launch: open **System Settings → Privacy & Security**,
   click **Open Anyway** next to the message about MacReplica and enter your login password. Details:
   [Troubleshooting](https://github.com/itsab1989/MacReplica/blob/main/docs/TROUBLESHOOTING.md#macos-says-macreplica-cannot-be-opened).
EOF
fi
cat <<'EOF'

**Compatibility:** macOS 13 or later; one universal app for Apple silicon and Intel. What was
tested is listed in the [README](https://github.com/itsab1989/MacReplica#requirements-and-compatibility).
Known limitations: [README](https://github.com/itsab1989/MacReplica#known-limitations).

MacReplica is free and always will be. If it's useful to you, a coffee is a kind way to say
thanks — completely optional, and the app stays fully featured either way:
[ko-fi.com/itsab1989](https://ko-fi.com/itsab1989)
EOF
} | unwrap
