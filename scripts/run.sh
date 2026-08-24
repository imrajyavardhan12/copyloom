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
open -n "$APP"
printf 'Opened %s\n' "$APP"
