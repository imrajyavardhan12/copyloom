#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH="$(uname -m)"
DERIVED_DATA="$ROOT/.build/RunDerivedData"

xcodebuild \
    -quiet \
    -workspace Copyloom.xcworkspace \
    -scheme Copyloom \
    -configuration Debug \
    -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build

APP="$DERIVED_DATA/Build/Products/Debug/Copyloom.app"

# LaunchServices can address only one instance when several development builds
# share the same bundle identifier. Terminate every stale Copyloom process so a
# single instance owns the menu item, hotkey, database, and TCC identity.
osascript -e 'tell application id "io.github.imrajyavardhan12.copyloom" to quit' \
    >/dev/null 2>&1 || true
sleep 0.2
stale_pids=($(pgrep -x Copyloom || true))
if (( ${#stale_pids[@]} > 0 )); then
    kill "${stale_pids[@]}" 2>/dev/null || true
fi
for _ in {1..30}; do
    remaining_pids=($(pgrep -x Copyloom || true))
    if (( ${#remaining_pids[@]} == 0 )); then
        break
    fi
    sleep 0.1
done
remaining_pids=($(pgrep -x Copyloom || true))
if (( ${#remaining_pids[@]} > 0 )); then
    kill -KILL "${remaining_pids[@]}" 2>/dev/null || true
fi

open -n "$APP"
for _ in {1..30}; do
    launched_pids=($(pgrep -x Copyloom || true))
    if (( ${#launched_pids[@]} == 1 )); then
        break
    fi
    sleep 0.1
done
launched_pids=($(pgrep -x Copyloom || true))
if (( ${#launched_pids[@]} != 1 )); then
    printf 'Failed to launch exactly one Copyloom process (found %d).\n' "${#launched_pids[@]}" >&2
    exit 1
fi

printf 'Opened %s\nLook for the clipboard icon in the menu bar (accessibility label: Copyloom).\n' "$APP"
