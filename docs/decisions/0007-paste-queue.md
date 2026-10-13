# ADR 0007: Paste Queue (M4 slice 1)

- **Status:** Proposed (three owner decisions open, see the end)
- **Date:** 2026-10-13

## Context

The M4 roadmap lists a "transient Paste Queue with explicit lifecycle" and,
separately, reusable bundles. `docs/database-schema.md` (§Reusable
multi-clip bundles) already says a transient queue lives in session state
unless the user saves it as a bundle, and that queues and bundles reference
clips rather than copying payloads.

The job: the user picks several clips (say an address, a tracking number and
a link), then pastes them one after another into another app's fields
without reopening Quick Paste each time.

What the current code gives and does not give:

- `PasteCoordinator.deliver` is built for Quick Paste. It writes the
  pasteboard, re-activates the app that was frontmost when the panel opened,
  waits for it to become frontmost, and posts ⌘V. It drops its target after
  every call.
- `GlobalHotKey` registers Carbon hotkeys (no Input Monitoring). Each
  shortcut is its own registration so a conflict degrades to menu-only.
- `ClipRepository` has no fetch-by-ID. Quick Paste works from `ClipSummary`
  snapshots returned by `recent`/`search`.
- Pasteboard writes carry the `ownWrite` marker, so delivery is never
  re-captured.

## Decisions

### 1. The queue holds clip IDs, never content

The queue is an ordered list of clip UUIDs in memory. At paste time each ID
is re-read from the database. A clip that was deleted, tombstoned or removed
by retention since it was queued is **skipped with a status line and never
pasted**. Storing `ClipSummary` snapshots would paste text the user had
already deleted, which is a privacy bug, not a staleness bug.

Slice 1 adds `ClipRepository.clip(id:) -> ClipSummary?` returning `nil` for
missing or tombstoned clips. No migration.

### 2. Lifecycle

```text
          add            paste next (items remain)
 empty ───────▶ ready ◀──────────────┐
   ▲             │                   │
   │             └── paste next ─────┘
   │                 (last item) ─────▶ empty   ("Queue finished")
   └──── clear / quit ◀── ready
```

- **empty**: nothing queued; the paste-next shortcut does nothing but say
  "Paste Queue is empty".
- **ready**: one or more items and a cursor at the next one. Adding appends;
  the same clip may be queued twice (pasting a value twice is legitimate).
- Leaves **ready** only by: pasting the last item, Clear, or quitting the
  app. Nothing is written to disk; a crash or quit loses the queue. That is
  the "transient" in the roadmap and is stated in the UI.
- Saving a queue as a reusable bundle is the bundles slice (later
  migration), not this one.

### 3. Building the queue

- **Quick Paste:** `⇧↵` adds the selected clip and keeps the panel open, so
  several clips can be added in one visit. A small count ("Queue · 3")
  appears in the footer while the queue is non-empty. `⇧↵` is unused today
  (`↵` paste, `⌘↵` copy only, `⌥↵` plain text, `⌘1–9`, `⌘P`, `⌘F`,
  `⌘⌫`/`⌥⌫`).
- **Library:** an "Add to Paste Queue" action in the inspector and the row
  context menu.
- **Menu bar:** a Paste Queue submenu shows the count and the next item's
  one-line preview (for text clips), with **Paste Next**, **Clear Queue**.
- **Collect mode** (every new copy is appended automatically) is **out of
  slice 1**; see open question 3.

### 4. Pasting: one press, one paste

A new global shortcut, **Paste Next**, pastes the item under the cursor
into the app that is frontmost *at that moment* and advances the cursor.

- It does **not** re-activate any remembered app (the user is already in
  the target field), so it needs a delivery path separate from the Quick
  Paste one: write pasteboard → wait for the hotkey's modifier keys to be
  released → post ⌘V. It keeps the same checks: Accessibility granted,
  frontmost app is not Copyloom, event creation succeeded.
- **Modifiers still held:** the user is still holding the shortcut's
  modifiers when the handler runs; posting ⌘V then can reach the app as
  ⌃⌥⌘V. Before posting, poll `CGEventSource.flagsState(.combinedSessionState)`
  until the shortcut's modifiers are up (bounded, about 500 ms); if they never
  release, leave the item on the clipboard and say "Copied; press ⌘V to
  paste". This is the main risk to verify live.
- **Without Accessibility:** Paste Next copies the item and advances the
  cursor, and the status says "Copied next queue item; press ⌘V". The user's
  own ⌘V then pastes it. The cursor advances on copy so the next press gets
  the next item.
- **No "paste all".** The target app reads the pasteboard asynchronously
  after receiving ⌘V; writing the next item right after posting ⌘V races
  that read and can paste the wrong item. One press per item is the only
  correct behavior without a read-acknowledgement signal. (A lazy pasteboard
  data provider could signal reads, but other clipboard tools and Universal
  Clipboard read too, so it would advance on reads that were not pastes.)
- Every pasted item calls `recordUse`, as Quick Paste does.
- Images paste through the existing image copy path; file clips paste their
  stored path text, as they do from Quick Paste.

### 5. The clipboard after a run

After the queue runs, the general pasteboard holds the last pasted item, just
as it does after a Quick Paste. Restoring the user's previous clipboard would
mean reading and holding it (which may be content Copyloom deliberately did
not capture, such as a concealed password) and racing the target app's
read. **Recommendation: do not restore.** Open question 2.

### 6. Where the code lives

- A pure `PasteQueue` value type (IDs, cursor, add, advance, clear, skip
  missing) in `QuickPasteFeature`, unit-tested without AppKit.
- `clip(id:)` in `ClipStore`, tested for live, tombstoned and missing IDs.
- App: the third `GlobalHotKey` registration (own instance, like ⌃⌘L), the
  queue delivery method on `PasteCoordinator`, the panel `⇧↵` binding, the
  Library action and the menu submenu.
- Swift 6.1.2 hosted toolchain: no `~Copyable` types (see the ClipLineSource
  crash fixed in `40d0a6b`).

## Tests

- `PasteQueue`: add/advance/clear, duplicate entries, cursor at end becomes
  empty, skipping a missing ID advances past it, clearing mid-run.
- Store: `clip(id:)` returns `nil` after delete and after retention expiry.
- Delivery (fake pasteboard/event poster): Paste Next with no access copies
  and advances; with access waits for modifiers, then posts once; refuses
  when Copyloom is frontmost; a deleted queued clip is skipped, never
  written to the pasteboard.
- Manual (owner): the modifier-release behavior in TextEdit, Safari and a
  terminal; a three-field form filled with three presses.

## Threat-model notes

- No new permission. Paste Next uses the existing Accessibility grant for
  posting ⌘V; without it the feature degrades to copy-only.
- No content leaves memory or is logged; status lines name the kind, never
  the text.
- A queue cannot resurrect deleted content (Decision 1).

## Open questions for the owner

1. **Paste Next shortcut.** Proposed: **⌃⌥V** (two modifiers, next to the
   existing ⌃⌘V). Alternatives: ⌃⌥⌘V (harder to clash, more modifiers to
   release), or no default shortcut (menu only, user sets one later).
2. **Restore the previous clipboard after the queue finishes?**
   Recommended: no (Decision 5).
3. **Collect mode in slice 1?** Recommended: no. It changes what a copy
   *does* while active, so it needs a visible on/off indicator, and skipped
   copies (sensitive, ignored app) make the queue count differ from the
   number of copies, which the UI must explain. Better as slice 2 after the
   basic queue is in use.
