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
osascript -e 'tell application id "io.github.imrajyavardhan12.copyloom" to quit' \
    >/dev/null 2>&1 || true
for _ in {1..20}; do
    if ! pgrep -qf '/Copyloom.app/Contents/MacOS/Copyloom'; then
        break
    fi
    sleep 0.1
done
open -n "$APP"
printf 'Opened %s\nLook for the clipboard icon in the menu bar (accessibility label: Copyloom).\n' "$APP"
