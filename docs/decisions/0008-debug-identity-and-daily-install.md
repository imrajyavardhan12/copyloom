# ADR 0008: Debug builds have their own identity; the daily copy is installed from a commit

- **Status:** Accepted
- **Date:** 2026-11-05

## Context

The maintainer uses Copyloom every day while developing it on the same Mac. Two things got in the way:

- **One bundle ID for everything.** A sandboxed app's container, defaults, database and TCC entries belong to its
  bundle ID. Debug builds shared the daily copy's ID, so visual previews, export/import checks and every test launch
  ran against the real clipboard history, and a half-finished change could write to it.
- **A new identity on every rebuild.** Local builds are ad-hoc signed, so macOS sees a different app after each
  build and drops the Accessibility grant that automatic paste needs. It had to be removed and added again after
  every rebuild.

The same two problems were solved in a sibling project (Holdall, ADR 0008 and 0018); this applies the part that fits.

## Decision

- **Debug builds are "Copyloom Debug":** bundle ID `io.github.imrajyavardhan12.copyloom.debug`, executable
  `CopyloomDebug`. Release builds keep `io.github.imrajyavardhan12.copyloom`. Entitlements are the same in both, so
  nothing new is requested. The module name stays `Copyloom` in every configuration.
- **The daily copy is `~/Applications/Copyloom.app`, installed by `scripts/install.sh`** from the last commit, built
  in a worktree of its own after lint and the package tests pass, so work in progress never reaches it.
- **It is signed with the keychain's "Apple Development" identity** when there is exactly one. That is a free
  identity (a personal team in Xcode); it needs no paid membership and gives no notarization. The signature is stable
  across rebuilds, so macOS keeps the Accessibility grant. Ad-hoc otherwise, or when asked
  (`COPYLOOM_INSTALL_ADHOC=1`).
- **The installed copy carries exactly the two entitlements it declares** (app sandbox, user-selected files). Xcode
  adds `com.apple.security.get-task-allow` to non-distribution builds, which would let any process of the same user
  attach a debugger and read clipboard content from memory, so Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`.
  Debug builds keep it for debugging. (Found by trying the install: it is in `codesign -d --entitlements -`.) The
  install checks the built app and stops if it is not sandboxed or carries that entitlement, as a commit from before
  this setting would.
- **It will not silently drop the signature:** if the installed copy has a team and this Mac does not have exactly
  one valid identity, the install stops and says how to proceed. It also stops if the keychain's identity is
  another team's. A build that is not installed is removed, so no team-signed copy is left where it could be started.
- **`scripts/run.sh` runs the Debug build** and quits the installed copy first, because both register the same
  global shortcuts and menu-bar item. It brings nothing back; `open ~/Applications/Copyloom.app` does.
  `scripts/install.sh` quits the Debug build for the same reason; `scripts/run.sh` brings that back.
- **The first team-signed start backs up the data folder first** (`scripts/backup-before-signing.sh`). Holdall
  measured that the first team-signed launch locks the sandbox container against every other program for good, the
  app's own data staying readable. The backup is the way back; it lands in
  `~/Library/Application Support/Copyloom Backups/`.
- **The install does not go on to that start without the copy.** If the data folder exists and cannot be read or
  copied whole, nothing is installed, unless asked (`COPYLOOM_INSTALL_NO_BACKUP=1`). A trial install
  (`COPYLOOM_INSTALL_DIR`) builds ad-hoc for the same reason: a team-signed copy with the release bundle ID, started
  from anywhere, is that first start.
- **That backup is the maintainer's to delete.** It is taken only while the installed copy is not yet team-signed,
  so later installs never recreate one that was deleted, even from a shell that can still read the container. An
  install that did not finish leaves its backup, and the next one makes a current copy beside it: none is deleted
  by a script, because the newest is not always the best. Every install names the folder while a backup exists and
  says to delete it once the installed copy shows the history.

## Consequences

- Previews, export/import checks and experiments run in the Debug container and start empty. The installed copy's
  history is never read or written by a Debug build.
- **Before the first install, the history lives in the Release bundle ID's container, which Debug builds used until
  now.** The first `scripts/install.sh` opens that same container, so the history carries over to the installed copy;
  until then a Debug build starts empty.
- After the first signed install, other programs (a shell, a script) can no longer read the installed copy's
  container. Use the app itself (Library export), or its logs, to inspect it.
- **The backup holds clipboard history in the clear**, like the database it was copied from, but outside the
  container: any program of the same user can read it, which is no longer true of the signed copy's container. It
  stays in the same user account and nothing leaves the machine; `THREAT_MODEL.md` (T6) records it.
- The Accessibility grant is per identity: the installed copy keeps its grant across updates, and a Debug build
  needs its own grant, only when testing paste there.
- Releases are a separate matter. Without a paid membership there is no Developer ID signature or notarization; this
  ADR changes nothing about distribution.
- Changing the release bundle ID would move the installed copy's container and its history with it.
