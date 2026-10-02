#!/bin/bash
# Drives MacReplica through the macOS accessibility interface (System Events).
# Development tool for on-screen validation.
#   tools/ui/ax.sh click <identifier-or-label>   press the first element whose AXIdentifier, AXTitle or AXDescription matches
#   tools/ui/ax.sh list                          print role | identifier | title | description | value of all elements
#   tools/ui/ax.sh key <char> [cmd]              send a keystroke
set -euo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  click)
    osascript - "$1" <<'APPLESCRIPT'
on run argv
  set target to item 1 of argv
  tell application "System Events"
    tell process "MacReplica"
      set frontmost to true
      repeat with w from 1 to count of windows
        set L to entire contents of window w
        repeat with i from 1 to count of L
          set e to item i of L
          set matched to false
          repeat with a in {"AXIdentifier", "AXTitle", "AXDescription"}
            try
              if (value of attribute (contents of a) of e) as text is target then set matched to true
            end try
          end repeat
          if matched then
            try
              perform action "AXPress" of e
            on error
              click e
            end try
            return "clicked " & target
          end if
        end repeat
      end repeat
    end tell
  end tell
  error "not found: " & target
end run
APPLESCRIPT
    ;;
  list)
    osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "MacReplica"
    set out to ""
    repeat with w from 1 to count of windows
      set L to entire contents of window w
      repeat with i from 1 to count of L
        set e to item i of L
        repeat with a in {"AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue"}
          try
            set out to out & ((value of attribute (contents of a) of e) as text)
          end try
          set out to out & " | "
        end repeat
        set out to out & linefeed
      end repeat
    end repeat
    return out
  end tell
end tell
APPLESCRIPT
    ;;
  key)
    if [ "${2:-}" = "cmd" ]; then
      osascript -e "tell application \"System Events\" to tell process \"MacReplica\" to keystroke \"$1\" using command down"
    else
      osascript -e "tell application \"System Events\" to tell process \"MacReplica\" to keystroke \"$1\""
    fi
    ;;
  *) echo "usage: ax.sh click <id> | list | key <char> [cmd]" >&2; exit 2 ;;
esac
