# M4 Slice 1 Validation — Paste Queue

_Design: [ADR 0007](../decisions/0007-paste-queue.md)_
_Status: implemented and unit-tested; `scripts/ci.sh` green. Owner live
check **pending**: synthetic key events, held modifiers and the frontmost
app can only be observed in the signed app._

## Automated evidence

- `PasteQueueTests` (12 tests, one with two cases): value semantics;
  in-order paste with `recordUse`; copy-only still advances; a refused
  delivery (keys held, Copyloom frontmost) keeps the item and records no
  use; a clip deleted after queueing is skipped and never delivered; an all-deleted queue ends without delivering; an
  undeliverable image is skipped instead of blocking; a failed delivery keeps
  the item; an unwired lookup fails closed; a second press during a paste is
  ignored; clearing mid-paste never drops an item queued after the clear;
  Quick Paste `⇧↵` queues without dismissing.
- `ClipRepositoryTests`: `clip(id:)` returns the live clip and `nil` after
  delete, after retention expiry and for an unknown ID.
- Preview mode renders `quickpaste-queue-{light,dark}` (footer shows
  "2 queued · ⌃⌥V pastes next") and the Library inspector with
  **Add to Queue**.

## Live check (owner)

Rebuild invalidates the ad-hoc signature: re-grant Accessibility for the new
binary first (path in Settings → Permissions).

| # | Do | Expect |
| --- | --- | --- |
| Q1 | In Quick Paste, select three text clips one after another with `⇧↵` each | Panel stays open; footer reads "3 queued · ⌃⌥V pastes next". |
| Q2 | Open TextEdit, press **⌃⌥V** three times | The three clips are pasted in order, each exactly once, with **no** stray characters (no `√`, no Control/Option side effects). Menu status ends with "Paste Queue finished." **No Input Monitoring prompt appears** (if one does, ADR 0007's "no new permission" is false: stop and record it). |
| Q3 | Repeat Q2 in Safari (a form with three fields; Tab between presses) and in Terminal | Same result in each app. |
| Q4 | Queue three clips. Press ⌃⌥V and **keep holding** the keys for about three seconds, then release | Nothing is pasted while held, and nothing after release; status says to release ⌃⌥. **Record how many items the queue lost** (menu count before and after): expected **0**. A normal press afterwards pastes the first item. |
| Q4b | Queue a clip, bring the Library window to the front, press ⌃⌥V | Nothing is pasted; status says to switch to the target app; the queue count is unchanged. |
| Q5 | Queue two clips, delete the first in the Library, press ⌃⌥V | The second clip is pasted; status mentions one skipped clip. The deleted text never appears. |
| Q6 | Turn Accessibility off for Copyloom, queue a clip, press ⌃⌥V | Status says "Copied queued text; press ⌘V to paste. Enable Automatic Paste to paste directly." ⌘V pastes it. |
| Q7 | Library inspector **Add to Queue** twice | "2 queued" appears beside the button; the menu shows **Paste Next (2 Queued)** and **Clear Paste Queue**; Clear empties it. |
| Q7b | Queue a clip, click into TextEdit, then choose **Paste Next** from the Copyloom menu | The text lands in TextEdit exactly once. |
| Q8 | Queue an image clip, press ⌃⌥V in TextEdit (rich text) | The image is pasted. |
| Q9 | Quit and relaunch Copyloom | The queue is empty (session-only by design). |

## Result log

| Check | Result | Notes |
| --- | --- | --- |
| Q1–Q3 | | |
| Q4, Q4b | | |
| Q5–Q6 | | |
| Q7, Q7b, Q8, Q9 | | |
