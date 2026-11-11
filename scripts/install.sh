#!/usr/bin/env bash
# Checks and builds HEAD, then installs it as the copy in daily use, ~/Applications/Copyloom.app (ADR 0008).
#
# HEAD is built in a worktree of its own, so work in progress never reaches the installed copy, and checked and built
# by HEAD's own `ci.sh` and project. The worktree is kept between installs: checking out the next commit changes only
# the files it touches, so builds are incremental. This script and its helpers (`signing-team.sh`, `quit-app.sh`,
# `backup-before-signing.sh`) are the working tree's: they are the install tool, not what is installed.
#
# Signed with the keychain's "Apple Development" identity when there is exactly one, so the app keeps one identity
# across rebuilds and macOS keeps its Accessibility grant. Ad-hoc otherwise.
#
# Environment:
#   COPYLOOM_INSTALL_ADHOC=1      install ad-hoc signed even when a team identity is available
#   COPYLOOM_INSTALL_NO_BACKUP=1  install team-signed for the first time without backing the data folder up
#   COPYLOOM_INSTALL_DIR=DIR      install into DIR instead of ~/Applications, for trying this script: it then neither
#                                 quits the running app, nor backs up data, nor launches the copy, and it builds
#                                 ad-hoc, because starting a team-signed copy locks the data folder (see below)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
src="$repo/.build/install/src"
id=io.github.imrajyavardhan12.copyloom
trial=false
if [ -n "${COPYLOOM_INSTALL_DIR:-}" ]; then trial=true; fi
if $trial && { [ "${COPYLOOM_INSTALL_DIR%/}" = "$HOME/Applications" ] || [ "$COPYLOOM_INSTALL_DIR" -ef "$HOME/Applications" ]; }; then
    echo "COPYLOOM_INSTALL_DIR is the real install folder: leave it unset to install there." >&2
    exit 1
fi
app="${COPYLOOM_INSTALL_DIR:-$HOME/Applications}/Copyloom.app"
backups="$HOME/Library/Application Support/Copyloom Backups"
head=$(git -C "$repo" rev-parse HEAD)
commit=$(git -C "$repo" rev-parse --short "$head")
release="$src/.build/Release"
product="$release/Build/Products/Release/Copyloom.app"
# Staged outside the install folder, which LaunchServices watches and would register the copy in.
staged="$repo/.build/install/Copyloom.app"
lock="$repo/.build/install/lock"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# The team an app is signed for; nothing when it is ad-hoc signed, unsigned or missing.
team_of() {
    codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | grep -v '^not set$' || true
}

# The value of one of the built app's entitlements ($1, dots escaped); nothing when it has none or can't be read.
entitlement() {
    codesign -d --entitlements - --xml "$product" 2>/dev/null | plutil -extract "$1" raw -o - - 2>/dev/null || true
}

# A run that ended mid-swap left the previous copy under `.old`: this puts it back.
restore_previous() {
    if [ ! -e "$app" ] && [ -e "$app.old" ]; then
        if ! mv "$app.old" "$app"; then
            echo "The previous copy is at $app.old: move it back to $app." >&2
            return 1
        fi
    fi
}

# However this script ends, with every step tried even if one fails:
# - no built copy is left where it could be started by hand: before the first signed install, starting a team-signed
#   one locks the data folder with no backup made;
# - a new copy that is only partly in place is removed, and the previous copy is put back;
# - the daily copy runs again if this run quit it, or installed a new one.
swapping=false
installed=false
launch=false
on_exit() {
    set +e
    rm -rf "$staged"
    if ! $installed; then
        rm -rf "$product"
        if $swapping; then rm -rf "$app"; fi
    fi
    restore_previous
    if $launch && [ -e "$app" ]; then open "$app"; fi
    rmdir "$lock"
}

# One install at a time: two would stage, swap and clean up over each other.
mkdir -p "$repo/.build/install"
if ! mkdir "$lock" 2>/dev/null; then
    echo "Another install is running. If none is, one was killed: remove $lock and run again." >&2
    exit 1
fi
trap on_exit EXIT

restore_previous
if ! git -C "$repo" diff --quiet HEAD || [ -n "$(git -C "$repo" ls-files --others --exclude-standard)" ]; then
    echo "Installing $commit; uncommitted changes are left out."
fi

# Reuses the directory only when git confirms it is that worktree: in a plain directory git would find the main
# checkout above it, and a forced checkout there would discard its uncommitted changes.
git -C "$repo" worktree prune
if [ -f "$src/.git" ] && [ "$(git -C "$src" rev-parse --show-toplevel 2>/dev/null)" = "$src" ]; then
    if ! { git -C "$src" checkout --quiet --force --detach "$head" && git -C "$src" clean -fdq; }; then
        echo "Couldn't update the install worktree: remove $src and run again." >&2
        exit 1
    fi
else
    rm -rf "$src"
    git -C "$repo" worktree prune
    git -C "$repo" worktree add --quiet --detach "$src" "$head"
fi

# The installed copy keeps the identity macOS holds its Accessibility grant and its data folder under: an ad-hoc
# build goes over a signed one only on request, and a build for another team never does.
team=""
installed_team=$(team_of "$app")
if ! $trial && [ -z "${COPYLOOM_INSTALL_ADHOC:-}" ]; then
    team=$("$repo/scripts/signing-team.sh")
    if [ -z "$team" ] && [ -n "$installed_team" ]; then
        echo "The installed Copyloom is signed for team $installed_team, but this Mac doesn't have exactly one valid" >&2
        echo "Apple Development identity (security find-identity -v -p codesigning). Nothing was installed." >&2
        echo "To install ad-hoc anyway: COPYLOOM_INSTALL_ADHOC=1 scripts/install.sh" >&2
        exit 1
    fi
    if [ -n "$team" ] && [ -n "$installed_team" ] && [ "$team" != "$installed_team" ]; then
        echo "The installed Copyloom is signed for team $installed_team, but the keychain's identity is team $team's." >&2
        echo "Another team's copy would lose the Accessibility grant and may be kept out of the data folder." >&2
        echo "Nothing was installed." >&2
        exit 1
    fi
fi

# Lint, package tests and an unsigned app build, by the scripts of the commit being installed.
"$src/scripts/ci.sh"

# Packages come from the clone `ci.sh` just made in the worktree, so this build shares nothing with the main checkout.
signing=()
if [ -n "$team" ]; then
    signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" "DEVELOPMENT_TEAM=$team")
fi
xcodebuild \
    -quiet \
    -workspace "$src/Copyloom.xcworkspace" \
    -scheme Copyloom \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$release" \
    -clonedSourcePackagesDirPath "$src/.build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ${signing[@]+"${signing[@]}"} \
    build
codesign --verify --strict "$product"

# What was built, not what was asked for: an older commit's settings don't pass the team on.
built_team=$(team_of "$product")
if [ "$built_team" != "$team" ]; then
    echo "Asked for team '$team' but this commit built '$built_team'. Nothing was installed." >&2
    echo "To install it as it built, if that is ad-hoc: COPYLOOM_INSTALL_ADHOC=1 scripts/install.sh" >&2
    exit 1
fi

built_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product/Contents/Info.plist")
if [ "$built_id" != "$id" ]; then
    echo "The Release build has bundle ID '$built_id', not '$id'. Nothing was installed." >&2
    exit 1
fi

# The installed copy holds the real history, so it must be sandboxed and must not carry get-task-allow, which lets
# any process of this user attach a debugger and read clips from memory (ADR 0008). Xcode adds that entitlement to
# development builds unless the commit's Release settings turn it off. Entitlements that can't be read count as wrong.
sandboxed=$(entitlement 'com\.apple\.security\.app-sandbox')
debuggable=$(entitlement 'com\.apple\.security\.get-task-allow')
if [ "$sandboxed" != true ] || [ "$debuggable" = true ]; then
    echo "The Release build must be sandboxed and must not carry get-task-allow (ADR 0008). This commit's has" >&2
    echo "app-sandbox '$sandboxed' and get-task-allow '$debuggable'. Nothing was installed." >&2
    exit 1
fi

# Only the installed copy should carry the release bundle ID, or LaunchServices may open another one instead. The
# product is registered only when Xcode chose to, so not finding it is fine.
"$lsregister" -u "$product" 2>/dev/null || true

rm -rf "$staged"
ditto "$product" "$staged"
mkdir -p "$(dirname "$app")"

if ! $trial; then
    # Both copies register the same global shortcuts and menu-bar item, so the Debug build is quit first, while
    # nothing has been touched yet; `scripts/run.sh` brings it back.
    "$repo/scripts/quit-app.sh" "$id.debug" "Quitting Copyloom Debug; \`scripts/run.sh\` brings it back."

    # Once the daily copy is quit, `on_exit` starts whichever copy is installed when this script ends.
    if [ -n "$(lsappinfo find bundleid="$id")" ]; then
        "$repo/scripts/quit-app.sh" "$id"
        launch=true
    fi

    # Before the first team-signed start only, while the data folder can still be copied: that start locks it
    # against everything else. Later installs make no copy, so a backup the maintainer deleted stays deleted.
    if [ -n "$team" ] && [ -z "$installed_team" ] && [ -z "${COPYLOOM_INSTALL_NO_BACKUP:-}" ]; then
        if ! "$repo/scripts/backup-before-signing.sh" "$id" "$backups"; then
            echo "Copyloom's data was not backed up, so nothing was installed: the message above says why." >&2
            echo "To install without a backup: COPYLOOM_INSTALL_NO_BACKUP=1 scripts/install.sh" >&2
            exit 1
        fi
    fi
fi

# Swaps the new app in. If that fails or is interrupted, `on_exit` removes what arrived of the new copy and puts
# back the one moved aside here: across volumes a move is a copy, and a failed one leaves part of the bundle behind.
if [ -e "$app" ]; then
    rm -rf "$app.old"
    mv "$app" "$app.old"
fi
swapping=true
if ! mv "$staged" "$app"; then
    echo "Couldn't move the new app into place. Nothing was installed." >&2
    exit 1
fi
installed=true
if ! $trial; then launch=true; fi
rm -rf "$app.old" || echo "Couldn't remove the previous copy, $app.old: delete it." >&2

if [ -n "$built_team" ]; then signature="signed for team $built_team"; else signature="ad-hoc signed"; fi
echo "Installed $commit at $app, $signature."
if ! $trial; then
    for backup in "$backups"/before-signing-*; do
        if [ -d "$backup" ] && [[ "$backup" != *.partial ]]; then
            echo "A copy of your history from before the first signed start is still in $backups, unencrypted."
            echo "Delete that folder once this copy shows your history."
            break
        fi
    done
fi
