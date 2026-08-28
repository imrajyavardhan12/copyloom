# M2 Previous-App Automatic Paste Validation

_Date: 2026-08-28_

## Implemented behavior

- Quick Paste records the frontmost `NSRunningApplication` before the nonactivating panel opens.
- Enter writes the selected clip to `NSPasteboard`, hides the panel, reactivates only that retained application, waits up to 400 ms for confirmed frontmost status, rechecks post-event permission, and posts Command-V through `CGEvent`.
- Command-Return is always copy-only and never requests Accessibility.
- Option-Return uses the plain-text delivery mode; current clips are text-native, while the mode preserves the future representation boundary.
- Missing/terminated/unresponsive targets degrade to copy-only with a content-free status.
- If Accessibility is absent, Copyloom first explains exactly why it is needed and offers **Open Accessibility Settings** or **Copy Only**. No Input Monitoring is requested.

## Automated evidence

Quick Paste model tests verify primary and explicit copy-only delivery-mode routing, use tracking, dismissal, search, navigation, pin, and delete behavior. The repository tests cover migration 003, last-used/use-count updates, and FTS-safe soft deletion.

## Signed-host evidence

A locally ad-hoc-signed sandboxed build passed the real macOS workflow:

1. TextEdit was opened with a new synthetic document containing `prefix:`.
2. `⌃⌘V` opened Copyloom while TextEdit remained the retained target.
3. Enter copied the synthetic selected clip, dismissed Quick Paste, reactivated TextEdit, and posted Command-V.
4. TextEdit's accessibility value exactly matched `prefix:Copyloom automatic paste smoke`.
5. The synthetic database row/document were removed afterward; foreign-key and FTS integrity remained valid.

A separate Command-Return run copied the selected clip, dismissed Quick Paste, and did not invoke automatic-paste permission UI.

## Permission boundary

The driving Terminal/System Events process had Accessibility for test automation. Copyloom's own post-event access was already granted on this host. Clean-user behavior still requires a manual denial/request/revocation matrix before M2 is complete.

## Deferred

- clean-user Accessibility denial, grant, revocation, sleep and fast-user-switch tests;
- full-screen/Spaces and target-termination matrix;
- rich-text versus plain-text representation selection;
- configurable shortcut and primary-action preference.
