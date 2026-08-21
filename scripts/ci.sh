#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

printf '==> Toolchain\n'
xcodebuild -version
xcrun swift --version

printf '\n==> Format lint\n'
xcrun swift-format lint \
    --recursive \
    --parallel \
    --strict \
    App/Sources \
    Packages/CopyloomKit/Sources \
    Packages/CopyloomKit/Tests

printf '\n==> Package tests\n'
xcrun swift test \
    --package-path Packages/CopyloomKit \
    --scratch-path "$ROOT/.build/SwiftPM"

printf '\n==> Unsigned app build\n'
xcodebuild \
    -quiet \
    -workspace Copyloom.xcworkspace \
    -scheme Copyloom \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/.build/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build

printf '\nCopyloom checks passed.\n'
