# macOS Permissions and Capability Boundaries

_Status: proposed least-privilege policy_
_Updated: 2026-08-21_

The core history and copy-back experience must degrade gracefully. No permission is requested at first launch merely because a later feature might need it.

## Summary matrix

| Feature | Permission / capability | Request timing | Fallback |
|---|---|---|---|
| Monitor/read general clipboard | Historically no dedicated TCC prompt. Newer macOS documents Paste from Other Apps behavior via `NSPasteboard.accessBehavior`; test per OS. | During explicit clipboard-history onboarding, only because this is the core feature | Manual capture / guidance to System Settings if access is denied |
| Write selected clip to clipboard | No Accessibility permission | User invokes Copy or Paste | None needed |
| Registered global Quick Paste shortcut | No Input Monitoring expected when using `RegisterEventHotKey` | User assigns/enables shortcut | Menu-bar invocation |
| Restore prior app focus | No Automation permission for `NSRunningApplication.activate` | On paste action | Copy only if target is gone or activation fails |
| Synthesize Command-V | **Accessibility / Post Events** | Explain and request only when the user enables or first invokes automatic paste | Copy content and show “Press ⌘V” |
| Broad keystroke monitoring for text expansion | **Input Monitoring**, and likely Accessibility/Post Events for replacement | Only when user explicitly enables text expansion | Snippets remain copy/paste actions without expansion |
| Vision OCR on a captured image | None beyond access to the image | No prompt | Mark OCR unavailable/failed |
| Quick Look/thumbnail of an accessible file | None beyond file access | No prompt | Generic icon/metadata |
| Monitor screenshot folder | User-selected read access + security-scoped bookmark in sandbox; Files & Folders behavior may apply | User explicitly enables and selects a folder | Clipboard screenshots still work; no folder monitoring |
| Capture screen pixels | **Screen & System Audio Recording** | Not in v1; only if a future explicit capture feature is enabled | Import/copy an existing image |
| Notifications/reminders | Notifications authorization | When first reminder is created | In-app reminder state only |
| Start at login | `SMAppService`; user-visible Login Items setting | When user enables Launch at Login | Manual launch |
| Control apps with AppleScript/Apple Events | **Automation**, `NSAppleEventsUsageDescription`, entitlement(s) | Not planned for v1 | Use focus activation + CGEvent path |
| Read broad protected storage | Full Disk Access | **Never for current scope** | User selects the specific folder/file |
| iCloud sync | iCloud/CloudKit entitlements and signed container | Only when future sync is enabled | Fully local operation |
| MCP over stdio/local app IPC | No network listener; explicit in-app client authorization | Future, disabled by default | No MCP |
| MCP over loopback HTTP | Local-only binding and strong auth; verify current Local Network privacy behavior | Future only if stdio bridge is insufficient | stdio bridge |

## Detailed policy

### Clipboard access

`NSPasteboard.general` is the core data source. Apple now documents an `accessBehavior` model for newer macOS versions in which programmatic reads can be ask/allow/deny and a **Paste from Other Apps** privacy setting may appear. The app must:

1. show an onboarding explanation before the first monitoring read;
2. inspect availability/access behavior where the SDK supports it;
3. provide a manual-capture/degraded state rather than looping prompts;
4. never infer that system permission means content is safe to retain;
5. test macOS 14, 15, and current macOS 26 behavior before release.

References: [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard), [`accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972).

### Accessibility / Post Events

Automatic paste writes the selected representations, reactivates the retained target, and posts Command-V. Check `CGPreflightPostEventAccess()` (and where necessary `AXIsProcessTrusted`) before the action. Request access through `CGRequestPostEventAccess()` only after an explanation.

Accessibility is not required for clipboard capture, search, OCR, preview, copy-only, a registered hotkey, or ordinary app-local keyboard navigation. Denial must not make the app useless.

References: [`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29), [`CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29).

### Input Monitoring

Do not use a broad global event tap for Quick Paste. A registered hotkey is narrower and should not need Input Monitoring.

Optional text expansion is different: detecting arbitrary typed abbreviations requires observing global keyboard input, and replacing them requires generated input. Before implementing, produce a dedicated design and explain that Input Monitoring can observe keystrokes across applications. The feature stays disabled by default and must exclude secure-input/password contexts where possible.

### Automation / Apple Events

Do not use System Events or AppleScript to paste in v1. That would add per-target Automation consent, sandbox/hardened-runtime entitlement complexity, and a larger control surface. `NSRunningApplication.activate` plus Accessibility-gated `CGEvent` is the proposed path.

### Files and screenshot folder monitoring

Do not hard-code or broadly scan Desktop. The user chooses a directory in `NSOpenPanel`; a sandboxed app stores a security-scoped bookmark, starts access only while required, and stops access afterward. FSEvents triggers a rescan; ingestion waits for file size/modification stability.

Do not request Full Disk Access. Direct Desktop/Documents/Downloads access may also present Files & Folders controls; selecting the exact folder is the least-privilege route.

### Screen sharing and Privacy Shield

There is no reliable public permission/API by which this app can prevent Zoom, Teams, OBS, ScreenCaptureKit, or screenshots from capturing its windows. `NSWindow.sharingType = .none` is not a security guarantee for modern capture.

Privacy Shield may:

- mask previews when the user manually enables presentation mode;
- provide a global panic shortcut that immediately hides all app windows/panels;
- avoid notifications/previews while shielded;
- offer best-effort signals if future public APIs expose useful state.

It must never claim “cannot be captured.” Screen Recording permission is not justified merely to guess whether someone else is sharing.

### Network transparency

Core capture, indexing, OCR, search, previews for local files, and transforms perform no network requests. Link metadata fetching is off by default because it reveals a copied URL and the user's IP to the target origin. Every future network feature must have:

- a named adapter and visible enablement state;
- an invocation-time disclosure when clip content leaves the Mac;
- timeouts and cancellation;
- no silent fallback to an external provider;
- a privacy-log entry containing metadata, not clipboard plaintext.

## Entitlement/distribution validation gates

Before Phase 2 implementation is declared complete, test a locally signed/ad-hoc sandboxed host build for:

- pasteboard read behavior on each supported macOS;
- registered shortcut behavior;
- Accessibility request/revocation and post-event behavior;
- source app activation across Spaces/full-screen apps;
- user-selected folder bookmarks across restart;
- drag/drop of images and file URLs;
- hardened-runtime-compatible build settings.

Developer ID signing and notarization are a separate public-release gate deferred until paid Apple Developer Program membership is funded. They must not block local M2 evidence and must not be reported as tested before credentials exist.
