#!/usr/bin/env bash
set -euo pipefail

# The Debug build by default; pass `Copyloom` to check the installed copy.
PROCESS="${1:-CopyloomDebug}"
copyloom_pids=($(pgrep -x "$PROCESS" || true))
if (( ${#copyloom_pids[@]} == 0 )); then
    echo "FAIL: $PROCESS is not running." >&2
    exit 1
fi
if (( ${#copyloom_pids[@]} != 1 )); then
    printf 'FAIL: expected one Copyloom process, found %d (%s).\n' \
        "${#copyloom_pids[@]}" "${copyloom_pids[*]}" >&2
    exit 1
fi

result="$(osascript - "$PROCESS" <<'APPLESCRIPT'
on run argv
set processName to item 1 of argv
tell application "System Events"
  if not (exists process processName) then return "NO_PROCESS"
  tell process processName
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
end run
APPLESCRIPT
)"

if [[ "$result" != "PASS" ]]; then
    echo "FAIL: $result" >&2
    exit 1
fi

echo 'PASS: Copyloom has a discoverable menu-bar item.'
