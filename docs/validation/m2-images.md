# M2 Image Capture Validation (slices 1–4)

_Date: 2026-09-07_

_Status: automated + signed-host evidence complete except full Spaces/full-screen
paste matrix (shared with the text workflow)_

## Environment

- macOS 26.6.2 (25G83), arm64
- Ad-hoc-signed Debug builds (`bc88b5`, `cccb1d`); Accessibility re-granted per
  build (known ad-hoc TCC tax, release fix is Developer ID signing)
- Real user container with history carried from the text slices

## Migration 004

Ran against the live 86-clip database on first launch of the slice-4 build.
Menu showed normal capture state (no "Storage unavailable"), history intact,
`grdb_migrations` contains `004_image_attachments`. No data loss.

## Capture (A03)

- `Ctrl+Shift+Cmd+4` screenshot to clipboard → menu
  `Captured image from …`, clip count +1
- Attachment file present under `Attachments/v1/<aa>/<bb>/<sha256>.png`
- Quick Paste (`⌃⌘V`) lists the image row with a lazily loaded thumbnail;
  `type:image` filter finds it, `type:text` excludes it

## Paste-back

Image row → `Enter` pastes the image into a TextEdit rich-text document.
`⌘Enter` copies without pasting. Loop suppression verified implicitly: pasted
images carry the self-write marker and do not re-capture (no runaway count).

Known target limitation: Terminal does not consume raw PNG/TIFF pasteboard
flavors, so image paste into Terminal does nothing. File-URL flavor support
is M3 file-references scope.

## Privacy gate

### Miss found live, then fixed

First pass: a screenshot of a fake `-----BEGIN PRIVATE KEY-----` block was
**captured** instead of refused. OCR probe of the captured bytes showed why:

- `•---BEGIN PRIVATE KEY...`
- `----BEGIN PRIVATE KEY-....`

Vision mangles dash runs, so the text detector's exact five-dash PEM pattern
never fires on screenshots. Fix: OCR-specific tolerant header pre-check
(2+ dashes, flexible whitespace, RSA/OPENSSH/DSA/EC variants), running only
on OCR output; prose merely mentioning keys still passes (tested).

### Re-verified

Same fake-key screenshot after the fix → menu
`Sensitive content was not saved`, clip count unchanged. Earlier pre-fix
secret captures were deleted by the user via Quick Paste (`⌥⌫`).

## Retention interplay

- Expired image tombstones keep bytes until the deletion ages out; purge then
  unlinks the file (tested: file present after expiry, gone after purge)
- Startup orphan reconciliation active in the launch cleanup pass
- Note: the 86→10 count move during testing was deliberate user deletion plus
  a 14-day retention-stepper test expiring old synthetics — one-way by design,
  not data loss

## Automated evidence

71 package tests / 11 suites green, including: attachment round-trip/dedup,
orphan reconciliation (relative-path matching after a `/var`→`/private/var`
symlink bug found by the test), migration 003→004 preservation, image
persist/dedup/filter/reject/expiry/purge-file, gate allow/deny/timeout/empty,
Vision allow/mangled-refusal/prose-allow/undecodable/recognizer-error plus a
live-Vision blank-image plumbing test, thumbnail loading, reconcile sweep.
Unsigned app build green.

## Deferred

- Full 2 GiB budget enforcement with oldest-first pressure expiry
- `has:ocr` searchable OCR index (M3, Vault-aware design first)
- File-URL / promised-file flavors (M3 file references)
- `VNRequest.cancel()` wiring for hung requests (one pool thread worst case)
