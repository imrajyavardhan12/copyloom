# ADR 0005: Library (M3) architecture

- **Status:** Proposed
- **Date:** 2026-09-08

## Context

M2 proved capture, search, and paste. M3 turns history into a workspace:
a full Library window, organization (collections/tags/smart), searchable OCR,
transforms, code preview, and portable export. ROADMAP also lists Library
densities, drag/drop, and syntax highlighting. This ADR sets module shape,
migration staging, and the OCR quarantine policy before any UI code.

## Decisions

### 1. Module: new `LibraryFeature` package target

UI logic stays testable: `LibraryFeature` mirrors `QuickPasteFeature`
(models + queries, no AppKit), depending on `ClipDomain` and `ClipSearch`.
The App target owns the window, drag/drop glue, and QuickLook — all thin.
No feature imports GRDB or opens the database; everything flows through
`ClipRepository` protocol seams, extended per slice.

### 2. Window shape: `NavigationSplitView`, three columns

Sidebar (sections + collections + smart) / content (list or cards) /
inspector (preview, metadata, actions). Native component, accessible by
default, no custom layout. Densities in M3: compact list + visual cards.
Board view is explicitly not M3. Drag/drop in M3: clips into collections and
out to other apps; drop *into* Copyloom from outside stays later.

### 3. Migration staging (minimal-migration rule, ADR-0002)

- **005 — organization**: `collections`, `collection_items`, `tags`,
  `clip_tags`, `saved_queries` per `docs/database-schema.md` §Collections.
  One migration because Library organization first-uses them together.
- **006 — OCR search**: adds **only** the `ocr` column to
  `search_documents` plus the FTS rebuild (002 is the template), plus
  `image_ocr_jobs(clip_id PK, status, attempts, updated_at)` for queue
  state. The schema doc sketches a full title/notes/tags/filenames/urls/ocr
  projection at once; titles/notes/filenames have no producing feature yet,
  so each arrives with its own migration per the minimal rule. The FTS
  rebuild cost at 100k rows gets measured in the bench before 006 lands.

### 4. OCR quarantine policy

Background OCR re-examines stored images (serial queue, idle priority,
cancellable, crash-resumable via `image_ocr_jobs`). States:

- **pending** → OCR in memory → detector over the text.
- **safe** → OCR text stored in `search_documents.ocr`, FTS updated,
  job marked indexed.
- **sensitive** → **quarantine**: OCR text withheld entirely, clip and pixels
  stay (user data), clip remains findable by `type:`/`app:` but never by
  content, UI marks it withheld with one-tap delete. No new columns: the
  `image_ocr_jobs` status *is* the tri-state.
- **recognizer error/timeout** → job stays pending with attempt count;
  bounded retries, then withheld with a visible reason. Never fail-open
  into the index.

Rationale: M2's capture gate already screened these pixels, but detectors
improve and early captures predate the tolerant header check — rescan must
assume findings. Withholding beats deleting: the user chose to keep the
pixels, and deletion would destroy data on a heuristic's say-so. This is
consistent with THREAT_MODEL T2 (never index skipped content) and the
fail-closed default.

### 5. Transforms: pure protocol + registry

```swift
protocol ClipTransform {
  var id, title: String { get }
  func applies(to clip: ClipSummary) -> Bool
  func apply(_ input: String) throws -> String
}
```

Pure functions, exhaustively unit-tested, no UI imports. Built-ins in M3:
JSON pretty/minify/validate, uppercase/lowercase/title-case,
trim/collapse-whitespace, URL encode/decode, Base64 encode/decode, HEX/RGB/HSL
conversion. UI offers apply → preview → copy or save-as-clip. Library first;
Quick Paste actions menu follows.

### 6. Code preview and export

- Syntax highlighting needs a dependency decision in its slice using the
  standing template (purpose, alternatives, license, transitive graph,
  maintenance, removal plan). Current lean: a pure-Swift MIT highlighter.
- Export v1 gets its own mini-design at its slice: SQLite online backup +
  attachments + `manifest.json` (schema version, counts, per-file SHA-256)
  + verify path. No format decisions here.

### 7. Smart Collections

Stored canonical query text + parser version (`saved_queries`). Executed by
re-parsing at open through the real `SearchQueryParser`; re-parse failure
shows a visible error and an empty collection — never silent broadening,
matching the parser's existing philosophy.

## Slice order

1. **Shell + History + favorites parity**: `LibraryFeature`, sidebar with
   five backed sections (History/Favorites/Pinned/Images/Links —
   Files/Code/Colors stay out until detection backs them in slice 2),
   list/cards densities, favorite toggle (also in Quick Paste via `⌘F`).
   No migration.
2. **Type sections + code preview**: Images/Links/Files/Code/Colors backed
   by existing filters; highlighter decision inside this slice.
3. **Organization**: migration 005, collections/tags CRUD, drag/drop,
   Smart Collections over saved queries.
4. **Searchable OCR**: migration 006, background queue, quarantine UX,
   `has:ocr`, bench-measured FTS rebuild.
5. **Transforms**: registry, built-ins, Library actions.
6. **Export/import v1**: archive format mini-design, manifest, verify.

## Consequences

- Library UI logic is unit-tested from day one; App-target code stays glue.
- OCR text is the first derived index with a sensitive-content policy baked
  in rather than bolted on — the pattern Vault search must follow later.
- The FTS table will be rebuilt twice more (005 needs none; 006 rebuilds).
  Each rebuild is measured, not assumed.
