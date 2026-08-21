# Phase 0 Research

_Status: architecture input, not implementation specification_
_Research snapshot: 2026-08-21_

This document records public product and platform research for an original, native, open-source macOS clipboard workspace. No proprietary code, visual assets, branding, or layouts were used. Product claims below are facts only when a cited first-party source states them; implementation and product recommendations are labeled as analysis.

## Executive conclusions

1. The opportunity is not another history list. The strongest product combines Maccy/Raycast retrieval speed, Paste/Supaste visual recall, and PastePal/PasteBar organization while making privacy and network boundaries inspectable.
2. Native SwiftUI plus focused AppKit integration is the correct v1 stack. A web shell or portability layer would add cost to the most important paths: panels, pasteboard fidelity, focus restoration, permissions, drag/drop, and accessibility.
3. macOS exposes no documented pasteboard-change notification. A clipboard historian must poll `NSPasteboard.changeCount`; energy and missed-intermediate-state behavior must be measured rather than hidden.
4. Source-app attribution is best effort. `org.nspasteboard.source` is voluntary and forgeable; sampling `NSWorkspace.frontmostApplication` can misattribute background writers. Ignored-app rules are valuable but cannot be marketed as a perfect security boundary.
5. Concealed/transient markers must be rejected before persistence, but they are community conventions, not complete secret detection. Local pattern detection and conservative defaults remain necessary.
6. Automatic paste is separate from capture. Writing the pasteboard needs no Accessibility grant on current shipping macOS versions; synthesizing Command-V does. Copy-only must remain a usable fallback.
7. GRDB over system SQLite is justified by migrations, concurrency, transaction safety, FTS5 support, and raw SQL access. It is the only proposed runtime dependency at architecture sign-off.
8. Large binary content belongs in a content-addressed attachment directory with checksums and atomic file handling; searchable metadata belongs in SQLite.
9. Plaintext FTS and a biometric-locked encrypted Vault are different stores/security domains. Vault plaintext must never enter the normal FTS index, WAL, thumbnails, or logs.
10. Apache-2.0 remains the recommended project license because its explicit contributor patent grant is valuable for a long-lived extensible project. MIT dependencies are compatible when their notices are retained.

## Requirements distilled

### Must — first usable vertical slice

- Native menu-bar macOS app; provisional macOS 14+.
- Reliable text/link/image capture with useful original representations, exact deduplication, source provenance, persistence and restart recovery.
- Privacy policy before disk: concealed/transient/generated markers, ignored apps/types, local sensitive-text detection, pause, ignore-next, retention and deletion.
- FTS5 lexical search across clip text and source metadata, with quoted strings and the initial structured tokens.
- Prewarmed keyboard-first Quick Paste panel with search, arrows, Enter, copy-only, plain-text paste, preview, ⌘1–9, delete and pin.
- Retain the prior app and paste through a contextual Accessibility grant; copy-only remains fully functional without it.
- Migration, dedup, classification, sensitivity, parser/filter, retention, transform, corruption and collection tests.
- A reproducible 100k-record benchmark proving—not assuming—the search/CPU/memory targets.
- Native accessibility: VoiceOver labels, keyboard focus, Reduced Motion, contrast/system appearance.
- Apache-2.0 repository foundation, security/threat documentation and CI.

### Should — after the core is proven

- Full Library with compact and visual densities; favorites, collections, tags and saved-query Smart Collections.
- Background Vision OCR and searchable OCR with an explicit image-sensitive quarantine policy.
- File/multi-file capture, Quick Look, drag/drop, colors, code and richer technical classification.
- Protocol-based transforms for JSON, text, URL, Base64, files and colors.
- Paste Queue, reusable bundles referencing clips, snippets, portable verified export/backup.
- Explicitly selected screenshot-folder monitoring.

### Later — design now only at boundaries

- Optional text expansion, encrypted Vault, CloudKit/self-hosted sync adapters, local semantic search, local MCP bridge, external BYOK AI, QR/barcode extraction and bounded image utilities.
- Windows/Linux/mobile, collaboration, plugin marketplace, proprietary backend and hosted AI remain out of scope until the native core is exceptional.

## Competitor capability matrix

This matrix summarizes publicly documented capabilities, not hands-on verification.

| Product | Positioning and UX | Search / OCR | Organization / multi-paste | Privacy / sync | Architecture / license lesson |
|---|---|---|---|---|---|
| [Supaste](https://www.supaste.com/) | Visual Mac clipboard and screenshot library; quick search, notch shelf, Library, drag/drop, last-10 shortcuts | Content, app and type filters; screenshot/image OCR | Categories, favorites/pins, reminders, text shortcuts, heterogeneous Multi-Clip | Local-first and sensitive detection are claimed. Its [homepage](https://www.supaste.com/) advertises iCloud while its [privacy policy](https://www.supaste.com/privacy) says no cloud sync; current behavior is unresolved. | Proprietary reference only. The notch is a presentation option, not a core architecture. |
| [Maccy](https://github.com/p0deje/Maccy) | Focused menu-bar utility; extremely direct keyboard workflow; copy/paste/plain-text actions | Exact, regex, fuzzy and mixed search; current source includes Vision OCR | Pins and paste stack; deliberately narrower than a library product | Local; ignored apps/types/regex; concealed/transient markers; no mandatory service | MIT, native SwiftUI/AppKit. Strong precedent for polling, multi-representation capture, an `NSPanel`, and copy-only fallback. Avoid its singleton-style coupling in a new architecture. |
| [Paste](https://pasteapp.io/) | Polished visual timeline across Mac/iPhone/iPad; direct paste, edit, preview and drag | Instant text/metadata search, app/type/date/device filters, OCR image search | Pinboards, shared pinboards, multi-select and Paste Stack | Device/private-iCloud positioning; ignored apps and transient/confidential handling | Proprietary. Demonstrates value of a coherent visual timeline and durable collections, but v1 should not inherit mobile/sync scope. |
| [Raycast Clipboard History](https://manual.raycast.com/clipboard-history) | Fast keyboard command inside a launcher; action panel; preserves original formats | Search/type filter, on-device OCR, QR extraction | Pin, rename, snippets, sequential paste | Local encrypted history; app exclusions; history is excluded from Raycast Cloud Sync; longer retention is Pro | Proprietary. Best lesson is action speed and format-aware paste. Avoid becoming a general launcher. |
| [PastePal](https://indiegoodies.com/pastepal) | Native configurable side panel/menu-bar utility with several invocation styles | Indexed search, source/type grouping, OCR | Collections, paste stack, drag/drop, extensive settings | Local/no-tracking claim; optional iCloud off by default; peer share | Proprietary. Breadth and configurability are useful, but discoverability cost argues for progressive disclosure. |
| [PasteBar](https://github.com/PasteBar/PasteBarApp) | Broad clipboard workstation: history, saved clips, boards/tabs, quick paste, forms and backup | Observed repository search uses SQL `%LIKE%` plus filters, not FTS5 | Collections/boards, protected collections, templates and many operations | Local-storage claim; cross-platform | Tauri/React/Rust/Diesel/SQLite. Useful schema/capture lessons, but not a native model. Its [custom CC BY-NC-style license](https://github.com/PasteBar/PasteBarApp/blob/main/CC-LICENSE) is not permissive/OSI-style; use clean-room product research only. |

### Product lessons

**Facts from public documentation**

- Supaste, Paste, Raycast, and PastePal all make images and source/type context visually useful rather than treating every clip as a string.
- Raycast and Maccy demonstrate that keyboard speed and explicit action semantics matter more than decorative UI in the quick path.
- Paste, PastePal, Supaste, and PasteBar demonstrate demand for durable organization and multi-item workflows.
- Most products expose exclusions and retention, but public privacy language often omits implementation limits. Supaste's sync documentation is internally inconsistent.

**Analysis for this product**

- Use two distinct surfaces: a prewarmed, low-decoration Quick Paste panel and a richer Library window. Do not force one layout to serve both speed and browsing.
- Make a clip a durable typed object with faithful original representations, provenance confidence, metadata, actions, and membership references.
- Treat collections, queue/bundles, transforms, and eventually MCP as views/actions over the same clip identity. Never duplicate clip payloads to implement organization.
- Display capture state, pause state, retention, ignored rules, sync/network state, and permission state in one privacy dashboard.

## Open-source implementation lessons

### Maccy

The current public Maccy tree is a SwiftUI/AppKit hybrid. It polls `NSPasteboard.general.changeCount` on a repeating timer, preserves several pasteboard representations, uses a custom marker for self-authored writes, samples the frontmost app, stores history with SwiftData, hosts SwiftUI in an AppKit floating panel, and uses `CGEvent` for automatic paste. Its default documented poll interval is 500 ms. It rejects `org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType`, and `org.nspasteboard.AutoGeneratedType` plus known vendor markers.

Useful source references:

- [Clipboard capture and paste](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift)
- [Search](https://github.com/p0deje/Maccy/blob/master/Maccy/Search.swift)
- [Floating panel](https://github.com/p0deje/Maccy/blob/master/Maccy/FloatingPanel.swift)
- [MIT license](https://github.com/p0deje/Maccy/blob/master/LICENSE)

Lesson: preserve representations and test platform behavior, but inject clocks, pasteboard access, storage, source resolution, permission checks, and event synthesis instead of coupling them through global state.

### PasteBar

The public repository is a Tauri 1 application with React/TypeScript UI and a Rust backend using Diesel and bundled SQLite. It separates backend commands/services/models and stores images outside relational metadata, but its observed history search uses `%LIKE%`, and clipboard policy/classification/persistence are concentrated in a large callback path.

Useful references:

- [Repository and stack](https://github.com/PasteBar/PasteBarApp)
- [Rust clipboard path](https://github.com/PasteBar/PasteBarApp/blob/main/src-tauri/src/clipboard/mod.rs)
- [Schema](https://github.com/PasteBar/PasteBarApp/blob/main/src-tauri/src/schema.rs)
- [History search service](https://github.com/PasteBar/PasteBarApp/blob/main/src-tauri/src/services/history_service.rs)
- [Custom license](https://github.com/PasteBar/PasteBarApp/blob/main/CC-LICENSE)

Lesson: keep the useful separation and attachment-store idea, but do not copy code/schema/UI. Use a native stack and FTS5 from the beginning.

## macOS platform research

### Clipboard monitoring

**Fact:** AppKit has no documented general-pasteboard change notification equivalent to iOS pasteboard notifications. `NSPasteboard.changeCount` changes when ownership/content changes, so historians poll it. A poll sees states, not guaranteed user Copy events; rapid writes between polls can be coalesced into the latest observable state.

Sources: [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard), [`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount), [Apple pasteboard concepts](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbConcepts.html), [Apple DTS discussion](https://developer.apple.com/forums/thread/737659).

**Recommendation:** use a tolerant/coalescing main-run-loop timer, initially 500 ms, stop it when paused/asleep, and benchmark shorter intervals. Compare `changeCount` before and after snapshotting; discard inconsistent snapshots. Perform only pasteboard access and bounded copying on the AppKit boundary, then hand immutable data to asynchronous processing.

**Residual limit:** no interval guarantees every intermediate state. “Effectively zero CPU” means measured negligible CPU while unchanged, not literally no wakeups.

### Transient, concealed, generated, and source types

[NSPasteboard.org](https://nspasteboard.org/) documents community conventions:

- `org.nspasteboard.TransientType`: do not record.
- `org.nspasteboard.ConcealedType`: confidential; do not persist by default.
- `org.nspasteboard.AutoGeneratedType`: not an explicit user copy; normally ignore.
- `org.nspasteboard.source`: optional UTF-8 bundle identifier.
- Existing vendor markers include `com.agilebits.onepassword`, `de.petermaurer.TransientPasteboardType`, `com.typeit4me.clipping`, `Pasteboard generator type`, and `net.antelle.keeweb`.

These are not Apple-enforced and adoption is incomplete. The app must inspect marker types before reading/storing payloads, but absence is not proof of safety. A declared source and a sampled frontmost source must be stored with different provenance values.

### Pasteboard privacy on newer macOS

Apple now documents `NSPasteboard.accessBehavior` and detection APIs for an upcoming/newer macOS pasteboard privacy model in which programmatic reads may be `.ask`, `.alwaysAllow`, or `.alwaysDeny`, while user-initiated paste-related access is treated differently. Users may see **Privacy & Security → Paste from Other Apps**. Exact shipping behavior and SDK availability must be tested on every supported macOS release; the current machine has Command Line Tools but not a selected full Xcode installation.

Sources: [`accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972), [AppKit updates](https://developer.apple.com/documentation/Updates/AppKit?changes=_9_4&language=objc).

### Global shortcut

A registered global hotkey (`RegisterEventHotKey`) receives only configured combinations and normally avoids Input Monitoring. It is a legacy Carbon API but remains the established least-privilege route; maintained libraries such as [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) wrap it. Broad `CGEventTap`/global monitors require Input Monitoring and should not be used for v1's single shortcut.

**Recommendation:** first build a small in-repository `GlobalHotKeyClient` abstraction over registered hotkeys. Add a dependency only if recording/layout/conflict behavior proves materially unreliable.

### Paste to the previous application

Capture the prior `NSRunningApplication` before the panel appears. On selection, write all selected representations with a private self-origin marker, dismiss the panel, reactivate only the retained target, wait for activation confirmation with a short timeout, then synthesize Command-V. `CGEvent` post access / Accessibility is needed for the final step. If unavailable or the target changed/quit, leave the selected content on the clipboard and report “Copied—press ⌘V”; never paste into whichever app happens to be frontmost.

Sources: [`NSRunningApplication.activate`](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate%28options%3A%29), [`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29), [`CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29).

### OCR, previews, files, screenshots, and screen sharing

- Vision OCR (`VNRecognizeTextRequest`) is local and needs no TCC permission for images the process can already read. [Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- Quick Look thumbnail generation is asynchronous through `QLThumbnailGenerator`. [QuickLookThumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)
- Screenshot folder monitoring should use a user-selected folder plus a security-scoped bookmark and FSEvents. FSEvents is a rescan signal and can coalesce/drop events; it does not mean a file is complete. [FSEvents](https://developer.apple.com/documentation/coreservices/file_system_events), [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- `NSWindow.sharingType = .none` is not a reliable defense against modern ScreenCaptureKit-based recorders. There is no public API that reliably detects every share or prevents arbitrary capture. Privacy Shield must be described as best effort; a panic shortcut is reliable because it simply hides our UI. [NSWindow sharing type](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

## Storage and search research

| Option | Strengths | Costs | Decision |
|---|---|---|---|
| Direct `sqlite3` | No package dependency; total SQL control | Must build/test bindings, errors, migrations, pooling, observations, cancellation and concurrency policy | Reject for v1; false economy for a security-sensitive persistent store |
| SQLite.swift | Thin typed layer; raw SQLite remains visible | Less complete migration/concurrency tooling; richer migration support is separate | Viable fallback, not preferred |
| [GRDB](https://github.com/groue/GRDB.swift) | Raw SQL escape hatch, `DatabaseMigrator`, serialized writes, WAL-backed `DatabasePool`, observations, FTS5 helpers; mature MIT project | One runtime dependency; contributors must learn GRDB conventions | **Choose**, pinned through SPM and isolated inside `ClipStore` |

Use Apple's system SQLite initially. At startup/CI, record `sqlite_version()`, `PRAGMA compile_options`, and run an FTS5 smoke test on the supported OS matrix. Do not bundle SQLite until a measured missing feature requires it.

FTS facts and implications:

- FTS5 provides `MATCH`, prefix indexes, `bm25()`, `highlight()` and `snippet()`. [SQLite FTS5](https://www.sqlite.org/fts5.html)
- External-content tables avoid another stored plaintext content copy but must stay synchronized; triggers do not backfill old rows, so migration/repair must issue `rebuild` and test consistency.
- User text cannot be passed through as raw MATCH syntax. Parse quoted terms and filters into an AST, then build bound/escaped patterns.
- WAL allows concurrent readers with one writer; long readers can block checkpoints and grow the WAL. It is not for network filesystems. [SQLite WAL](https://sqlite.org/wal.html)
- A backup must use SQLite's online backup API (and include attachments); copying only the main file during WAL use is unsafe. [SQLite backup API](https://sqlite.org/backup.html)

The `<30 ms` warm search target remains an unproven requirement. The benchmark must generate a deterministic 100,000-record corpus, use Release builds, run at least 30 measured samples after warm-up, report median/P95/P99, result checksums, RSS, DB/WAL size, SQLite/OS/hardware metadata, and cover rare/common/prefix/phrase/Unicode/filter-only queries plus concurrent capture.

## License research

[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0.txt) and [MIT](https://opensource.org/license/mit) are permissive and permit commercial use. Apache-2.0 adds an explicit contributor patent grant and patent-litigation termination, plus change/NOTICE mechanics. MIT is shorter and has no express patent clause.

**Recommendation:** Apache-2.0 for original project code. Keep exact notices for GRDB and any other distributed dependency in `THIRD_PARTY_NOTICES.md`; inspect the built app bundle before release. Maccy is MIT and can be studied; copied substantial source would require its notice. PasteBar's custom restrictions mean no code/assets should be copied without separate legal review. This is engineering research, not legal advice.

## Assumptions requiring validation

- Minimum deployment target can be macOS 14.
- The app can remain sandboxed while direct/notarized distribution and Accessibility-gated paste are validated.
- A 500 ms coalescing poll reaches acceptable capture latency and negligible unchanged CPU.
- System SQLite on every supported OS includes the required FTS5 behavior.
- A prewarmed AppKit panel plus warm database pool meets quick-open goals.
- Captured file URLs can be faithfully re-emitted after restart; preview/persistent file access behavior needs a sandbox spike.
- Newer macOS pasteboard privacy behavior permits a user to grant persistent access suitable for a historian.

## Research limitations

- Competitor behavior was documented from public first-party pages/source, not installed-product testing.
- Vendor privacy/encryption/performance claims were not independently audited.
- Public product pages can change; pricing and feature gates are a snapshot.
- Supaste's first-party sync claims conflict and are intentionally left unresolved.
- No search performance number is claimed yet.
- Full Xcode 26.6 is installed and first-launch-ready, but the machine-wide selector still points at Command Line Tools. Build scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; signed entitlement/TCC behavior still requires the documented host test matrix.
