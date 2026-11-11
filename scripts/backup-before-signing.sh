#!/usr/bin/env bash
# Copies the data of the app with bundle ID $1 aside into folder $2, for `install.sh`, while that can still be done.
# The first team-signed start locks an app's sandbox container against every other program, for good (see ADR 0008
# and Holdall's ADR 0018, where this was measured). So this looks at the folder, not at any signature, and says what
# it did in every case. It fails, leaving nothing behind, if there is data it can't read or can't copy whole: the
# install must not go on to that start without a copy. A copy goes under a `.partial` name until it is whole.
#
# `install.sh` calls this only before the first team-signed start, and every call copies the data as it is now: a
# copy from an install that didn't finish would be missing what was captured since. Earlier copies are kept, because
# the newest is not always the best one (the data may have been reset since); deleting them is the maintainer's call.
#
# A backup holds the clipboard history in the clear, like the database it was copied from, but outside the sandbox
# container, where any program of this user can read it. Delete the folder once the installed copy shows the
# history; `install.sh` says so after every install while a backup exists (THREAT_MODEL.md, T6).
set -euo pipefail

container="$HOME/Library/Containers/$1"
library="$container/Data/Library"
root=$2

# Absent only when the folder above can be listed and doesn't have it: a folder this shell isn't allowed to look at
# must not pass for one that isn't there.
absent() {
    local names
    names=$(ls -A "$(dirname "$1")" 2>/dev/null) || return 1
    # Ignoring case, as the usual macOS volume does: on one that doesn't, a near match is then looked at, not skipped.
    ! grep -qixF "$(basename "$1")" <<<"$names"
}

if absent "$container" || absent "$container/Data" || absent "$library"; then
    echo "No backup of Copyloom's data: it has none yet."
    exit 0
fi
if ! ls "$library" >/dev/null 2>&1; then
    echo "Copyloom's data folder can't be read, so it can't be backed up. Either a signed copy has already locked" >&2
    echo "it, or this terminal isn't allowed in: System Settings → Privacy & Security → Full Disk Access." >&2
    exit 1
fi

folders=()
for folder in "Application Support" Preferences; do
    if absent "$library/$folder"; then continue; fi
    if [ ! -d "$library/$folder" ]; then
        echo "Copyloom's \"$folder\" folder can't be read, so its data can't be backed up." >&2
        exit 1
    fi
    folders+=("$folder")
done
if [ "${#folders[@]}" = 0 ]; then
    echo "No backup of Copyloom's data: there is nothing in its folder yet."
    exit 0
fi

backup="$root/before-signing-$(date +%Y%m%d-%H%M%S)"
if [ -e "$backup" ]; then backup="$backup-$$"; fi
# An earlier failure's leftovers, and this one's if it fails: on a full disk they would be what's filling it.
rm -rf "$root"/before-signing-*.partial
trap 'rm -rf "$backup.partial"' EXIT
mkdir -p "$backup.partial"
for folder in "${folders[@]}"; do
    ditto "$library/$folder" "$backup.partial/$folder"
done
mv "$backup.partial" "$backup"
trap - EXIT
echo "Backed up Copyloom's data to $backup."
