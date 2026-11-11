#!/usr/bin/env bash
# Quits the running app with bundle ID $1 normally, so it closes its database cleanly: a force-quit could cut a
# write short. Prints $2, if given, when there is something to quit.
set -euo pipefail

id=$1
running() { [ -n "$(lsappinfo find bundleid="$id")" ]; }

running || exit 0
[ -z "${2:-}" ] || echo "$2"
if ! osascript -e "tell application id \"$id\" to quit" >/dev/null; then
    echo "Couldn't ask $id to quit (see the error above)." >&2
    exit 1
fi
for _ in $(seq 50); do
    running || exit 0
    sleep 0.2
done
echo "$id is still running: quit it, then try again." >&2
exit 1
