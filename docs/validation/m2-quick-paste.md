# M2 Quick Paste Tracer Validation

_Date: 2026-08-28_

## Implemented behavior

- A preconstructed native AppKit `NSPanel` hosts the SwiftUI Quick Paste surface.
- The panel is nonactivating, floating, multi-Space/full-screen auxiliary, and positioned on the screen containing the pointer.
- The registered global shortcut is `⌃⌘V` through Carbon `RegisterEventHotKey`; it does not require broad Input Monitoring.
- The Copyloom menu provides a fallback **Open Quick Paste** action if registration conflicts.
- FTS5 search updates after a 40 ms cancellable debounce and accepts structured filters such as `app:Safari`, `type:link`, `is:pinned`, and date filters supported by the repository.
- Arrow keys move selection; Enter copies and dismisses; Escape dismisses; ⌘1–9 selects/copies; ⌘P pins; ⌥⌫ or ⌘⌫ deletes.
- Copy writes plain text plus Copyloom's self-write marker and original-source marker, preventing capture loops.
- The UI shows type, source, relative time, copy count, pin state, selection and keyboard hints with Reduced Motion and VoiceOver-aware behavior.
- Migration 003 adds use count and last-used metadata; repository actions pin, record use, and soft-delete while keeping FTS consistent.

## Automated evidence

The Swift package contains model tests for loading, bounded navigation, structured search, copy/use/dismiss, pin, and delete behavior. Storage tests cover pin/use/delete, count, soft-delete search exclusion, FTS integrity, and migrations 001→002→003.

## Signed-host end-to-end evidence

A locally ad-hoc-signed sandboxed build was launched and validated through the actual macOS UI path:

1. `⌃⌘V` opened one `680 × 492` accessibility-visible system panel while Copyloom remained non-frontmost.
2. The panel exposed an accessibility-labeled search field and keyboard footer.
3. Synthetic clips were inserted into the local test store.
4. Typing `zebra` into the focused panel searched FTS5 and selected the matching clip.
5. Enter wrote the matching text to `NSPasteboard`, recorded use, and dismissed the panel.
6. `pbpaste` matched the expected synthetic fixture exactly.
7. Synthetic rows were removed; `foreign_key_check` and FTS integrity completed without findings.

The manual automation required Accessibility for the driving Terminal/System Events process only. Copyloom itself did not request Accessibility or Input Monitoring for opening/searching/copying.

## Deferred

Enter currently **copies** the selected clip. Restoring the previous application and synthesizing Command-V remains the next Accessibility-gated tracer. Rich representations, paste-as-plain-text variants, Space preview, drag/drop, images, and the optional notch/edge shelf remain later work.
