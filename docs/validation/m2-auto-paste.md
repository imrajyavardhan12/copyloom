# M2 Previous-App Automatic Paste Validation

_Date: 2026-08-29_

_Status: implementation complete; clean permission-grant end-to-end check pending_

## Implemented behavior

- Quick Paste records the frontmost `NSRunningApplication` before the nonactivating panel opens and retains that wrapper strongly until delivery completes.
- Enter writes the selected clip to `NSPasteboard`, hides the panel, reactivates only that retained application, waits for confirmed frontmost status plus a short key-focus settling interval, rechecks post-event permission, and posts Command-V through `CGEvent`.
- Command-Return is always copy-only and never requests Accessibility.
- Missing/terminated/unresponsive targets and missing/revoked permission degrade to copy-only with a content-free status.
- The menu exposes **Enable Automatic Paste…**. It explains exactly why Accessibility is needed before calling the system request API. No Input Monitoring is requested.
- Permission setup is presented after the status-menu click has completed so that the originating event cannot activate the alert's default action.

## Automated evidence

Quick Paste model tests verify primary and explicit copy-only delivery-mode routing, use tracking, dismissal, search, navigation, pin, and delete behavior. Repository tests cover migration 003, last-used/use-count updates, and FTS-safe soft deletion.

## Signed-host diagnosis and corrections

A red-capable TextEdit harness now verifies the clipboard value and target text with explicit failure branches. It found two independent conditions:

1. The selected clip was written correctly, but the first implementation retained the target `NSRunningApplication` weakly. The wrapper disappeared before delivery and Copyloom correctly reported `Copied; the original application is no longer available.` The coordinator now holds the target strongly for one panel session and clears it after delivery.
2. After rebuilding/resetting the ad-hoc development app, Copyloom's own post-event permission was absent. Copyloom copied successfully and reported that automatic paste must be enabled. An explicit menu setup action now makes this state visible and recoverable.

Command-Return has passed the real signed-host copy-only path. Clipboard content, panel dismissal, foreign keys, and FTS integrity were verified with synthetic fixtures and cleaned afterward.

A previous draft of this document claimed a TextEdit paste success. That result is withdrawn: the shell harness used a standalone `[[ ... ]]` assertion whose failure did not terminate that command as assumed. The harness now uses explicit `if`/`exit` failure branches, which exposed the issues above.

## Permission boundary

The driving Terminal/System Events process has Accessibility for test automation. Copyloom's ad-hoc development signature may require its own Accessibility grant to be re-enabled after rebuilds. The user must choose **Enable Automatic Paste…** and enable Copyloom under **System Settings → Privacy & Security → Accessibility** before the final Enter-to-TextEdit pass is recorded.

## Deferred

- clean grant/revocation confirmation after the current user enables Copyloom;
- sleep, fast-user-switch, full-screen/Spaces and target-termination matrix;
- rich-text versus plain-text representation selection;
- configurable shortcut and primary-action preference.
