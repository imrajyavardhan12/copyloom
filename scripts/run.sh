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

APP="$DERIVED_DATA/Build/Products/Debug/CopyloomDebug.app"
PROCESS=CopyloomDebug
DEBUG_ID=io.github.imrajyavardhan12.copyloom.debug
INSTALLED_ID=io.github.imrajyavardhan12.copyloom

# Debug builds have their own bundle ID, container and database (ADR 0008), so they never touch the installed
# copy's history. Both copies register the same global shortcuts and menu-bar item, though, so the installed copy is
# quit (normally) while the Debug build runs; `open ~/Applications/Copyloom.app` brings it back.
"$ROOT/scripts/quit-app.sh" "$INSTALLED_ID" \
    "Quitting the installed Copyloom; \`open ~/Applications/Copyloom.app\` brings it back."

# LaunchServices can address only one instance when several development builds share a bundle identifier.
# Terminate every stale Debug process so a single instance owns the menu item, hotkey and database.
osascript -e "tell application id \"$DEBUG_ID\" to quit" >/dev/null 2>&1 || true
sleep 0.2
stale_pids=($(pgrep -x "$PROCESS" || true))
if (( ${#stale_pids[@]} > 0 )); then
    kill "${stale_pids[@]}" 2>/dev/null || true
fi
for _ in {1..30}; do
    remaining_pids=($(pgrep -x "$PROCESS" || true))
    if (( ${#remaining_pids[@]} == 0 )); then
        break
    fi
    sleep 0.1
done
remaining_pids=($(pgrep -x "$PROCESS" || true))
if (( ${#remaining_pids[@]} > 0 )); then
    kill -KILL "${remaining_pids[@]}" 2>/dev/null || true
fi

open -n "$APP"
for _ in {1..30}; do
    launched_pids=($(pgrep -x "$PROCESS" || true))
    if (( ${#launched_pids[@]} == 1 )); then
        break
    fi
    sleep 0.1
done
launched_pids=($(pgrep -x "$PROCESS" || true))
if (( ${#launched_pids[@]} != 1 )); then
    printf 'Failed to launch exactly one Copyloom process (found %d).\n' "${#launched_pids[@]}" >&2
    exit 1
fi

printf 'Opened %s\nLook for the Copyloom weave icon in the menu bar (accessibility label: Copyloom). This is the Debug build, and its history is separate from the installed copy.\n' "$APP"
