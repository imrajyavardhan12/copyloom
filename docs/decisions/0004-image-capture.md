# ADR 0004: Image capture with fail-closed Vision preflight

- **Status:** Proposed
- **Date:** 2026-09-07

## Context

Copyloom captures text/links only. M2 acceptance item A03 requires copying an
image, and Supaste-parity memory needs screenshots. ADR-0002 already constrains
the design:

- 25 MiB per binary representation, 50 MiB aggregate per snapshot,
  40 megapixels per decoded image;
- image persistence is **fail closed** until an in-memory Vision
  text/sensitivity preflight succeeds; M2 uses OCR only as a privacy gate,
  storing/searching OCR output stays M3;
- 2 GiB default managed-history disk budget;
- attachments live as content-addressed files outside SQLite; temp/rename/commit
  protocol with a grace-period orphan reconciler;
- retention must bound disk (fixed by `purgeDeleted`, see review of `d369e20`).

This ADR decides the schema, pipeline, and slice order before code.

## Decisions

### 1. Accepted input types

Read NSPasteboard image data in this preference order: `public.png`,
`public.tiff`, `public.jpeg`. First available wins; the stored UTI records what
was kept. Promised-file and file-URL flavors are **out of scope** (file
references are an M3 slice, not this one).

### 2. Preflight order (privacy before persistence)

Per pasteboard snapshot:

1. existing marker/app checks (unchanged, before any payload read);
2. type gate: text/link path as today, else image path if an accepted image
   type is present, else `.unsupportedType`;
3. byte-size gate on the raw data (25 MiB) and aggregate cap before decode;
4. bounded decode for dimensions only; reject above 40 MP without rendering
   full bitmaps into long-lived memory;
5. **in-memory Vision preflight**: OCR the decoded image, run the existing
   local sensitive-content detector over the OCR text;
   - sensitive match → `.sensitiveContent`, nothing persisted;
   - Vision timeout, error, or over-limit → skip with a content-free status
     (fail closed), no persistence, explicit one-time manual override lives in
     Settings later, not this slice;
   - OCR text is **not stored** in this slice (M3 makes it searchable).
6. persist + deduplicate; derived thumbnail/OCR-index jobs stay M3.

Preflight runs off the polling callback in a bounded async task with an
explicit timeout (proposed 10 s). Snapshots are immutable values, so a
`changeCount` move during preflight discards the stale snapshot.

For testability the preflight sits behind an `ImagePrivacyPreflight` protocol
(Vision implementation + stub). The capture service takes it as injected
dependency, mirroring `SensitiveContentDetecting`.

### 3. Schema: migration 004

- `ClipKind.image = 2` (append-only raw value; existing 0/1 untouched).
- New `attachments` table:
  `id, sha256 UNIQUE, uti, byte_count, width, height, relative_path, created_at`.
- `clip_representations` gains nullable `attachment_id REFERENCES
  attachments(id) ON DELETE CASCADE`. `inline_text` stays `NOT NULL`; image
  rows store `''` there. Rationale: avoids a table rebuild for a nullability
  change; documented here as intentional tech debt, revisited if a second
  binary kind needs richer columns.
- Dedup is exact-bytes SHA-256 over the stored canonical data. Cross-format
  duplicates (same pixels as PNG vs TIFF) intentionally create distinct clips;
  collapsing formats would silently discard the original representation.
- Attachment paths are versioned: `Attachments/v1/<aa>/<bb>/<sha256>.<ext>`.
  The `v1/` prefix lets a future layout migrate by version, not by walk.

### 4. File protocol and orphans

ARCHITECTURE.md's protocol stands: validate digest → private temp file →
atomic rename → commit DB reference. Deletion is two-phase: the purge
transaction collects newly-orphaned paths (attachments with zero referencing
representations); files are removed after commit. A startup/idle reconciler
deletes unreferenced files older than a grace period (proposed 24 h) to cover
crashes between commit and unlink.

### 5. Retention and disk budget

`purgeDeleted` extends naturally: its transaction additionally collects
orphaned attachment paths, unlinked post-commit. Full 2 GiB budget
enforcement (oldest-first pressure expiry with durable-item visibility) is
**deferred** past this slice; this slice records attachments-dir size during
cleanup and exposes it in Settings later. Capturing images without the purge
hookup is explicitly out: no slice lands image persistence before the
file-GC path exists.

### 6. Retrieval, paste-back, search (M2 scope)

- Repository gains `saveAcceptedImage` + attachment fetch by clip ID.
- Paste-back writes the stored bytes plus the self-write marker, so Enter
  pastes images and copy-loop suppression keeps working.
- Quick Paste shows image rows with dimensions and a lazily loaded thumbnail
  (`NSCache`, memory-pressure aware); no stored thumbnails in this slice.
- Search: `type:image` filter via kind. No FTS body for images; `has:ocr`
  stays M3.

## Schema conformance note (slice 1)

`docs/database-schema.md` sketches a fuller future schema (`storage_kind`,
`mime_type`, `clip_files`, `attachment_id … ON DELETE RESTRICT`). Migration
004 implements the minimal subset this slice needs: `attachments` with
non-null `uti`/`width`/`height`, and `attachment_id … ON DELETE CASCADE`.
CASCADE is intentional — purge collects orphan paths in-transaction before
deleting rows, so RESTRICT would only add statements, not safety. Aligning
the remaining aspirational columns happens in the migration that first uses
them, per ADR-0002's minimal-migration rule.

## Slice order
1. **Migration 004 + AttachmentStore**: tables, content-addressed
   write/read, orphan reconciler, purge-file hookup, tests. No capture change.
2. **Capture image path**: type gate, size/pixel caps, `saveAcceptedImage`,
   dedup, stubbed preflight, fake-pasteboard integration tests.
3. **Vision preflight**: implementation, timeout, sensitive-fixture tests,
   signed-host manual evidence (screenshot with text, secret-bearing image).
4. **UX + acceptance**: Quick Paste thumbnails, image paste-back,
   retention-file GC wiring, A03 matrix, `docs/validation/m2-images.md`.

## Consequences

- Tombstone purge from review fix `9d14b20` becomes load-bearing for images;
  landing it first was required, not optional.
- `inline_text = ''` for images is the one wart to revisit with M3 file
  references; everything else follows existing architecture without
  exceptions.
- OCR stays a gate, not an index, until M3's Vault-aware search design says
  where OCR text may live.
