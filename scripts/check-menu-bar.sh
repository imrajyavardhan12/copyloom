#!/usr/bin/env bash
set -euo pipefail

if ! pgrep -qf '/Copyloom.app/Contents/MacOS/Copyloom'; then
    echo 'FAIL: Copyloom is not running.' >&2
    exit 1
fi

result="$(osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "Copyloom") then return "NO_PROCESS"
  tell process "Copyloom"
    set extras to {}
    repeat with barRef in menu bars
      repeat with itemRef in menu bar items of barRef
        try
          if subrole of itemRef is "AXMenuExtra" then
            set end of extras to name of itemRef
          end if
        end try
      end repeat
    end repeat
    if extras contains "Copyloom" then return "PASS"
    if (count of extras) is 0 then return "NO_STATUS_ITEM"
    return "WRONG_LABEL:" & (extras as text)
  end tell
end tell
APPLESCRIPT
)"

if [[ "$result" != "PASS" ]]; then
    echo "FAIL: $result" >&2
    exit 1
fi

echo 'PASS: Copyloom has a discoverable menu-bar item.'
