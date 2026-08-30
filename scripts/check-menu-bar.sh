#!/usr/bin/env bash
set -euo pipefail

copyloom_pids=($(pgrep -x Copyloom || true))
if (( ${#copyloom_pids[@]} == 0 )); then
    echo 'FAIL: Copyloom is not running.' >&2
    exit 1
fi
if (( ${#copyloom_pids[@]} != 1 )); then
    printf 'FAIL: expected one Copyloom process, found %d (%s).\n' \
        "${#copyloom_pids[@]}" "${copyloom_pids[*]}" >&2
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
