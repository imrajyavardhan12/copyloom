# Archive Format v1 (Export / Import)

_Status: accepted design for M3 slice 6; 6a (format core) implemented._
_Updated: 2026-10-05_
_Supersedes the sketch in [ADR 0005](decisions/0005-library.md) §6 ("SQLite online backup + attachments + manifest"); see [Decision 1](#decision-1-a-logical-archive-not-a-database-snapshot)._

## Goal

Let a user take their library out of Copyloom and bring it back (or into another Copyloom) as **portable, user-owned, verifiable data**, without making the archive a new place where secrets leak or a new way to attack the app.

Non-goals for v1: encryption or signing (that is Vault territory), sync, importing other apps' formats, partial/scoped export, settings transfer, disaster-recovery restore of the live database.

## Decisions

### Decision 1: a logical archive, not a database snapshot

The archive describes clips, collections, tags and saved queries as plain records. It does **not** contain SQLite files.

| Concern | SQLite snapshot | Logical archive (chosen) |
|---|---|---|
| Portability | needs SQLite + exact schema knowledge | readable with any JSON tool; documented here |
| Untrusted import | opening or `ATTACH`ing a foreign database exposes the engine to hostile triggers, views, virtual tables and FTS shadow tables | the importer parses bounded JSON and validates every field; no foreign SQL ever runs |
| Schema coupling | tied to the migration version that wrote it | `formatVersion` is independent of migrations |
| Merge | row IDs collide; needs remapping anyway | identity is UUID/content hash from the start |
| Leakage | copies derived data wholesale (`search_documents.ocr`, withheld-OCR state) | derived data is simply not written |
| Idempotent re-import | hard | natural (see [Import](#import)) |

A full-fidelity **backup/restore (replace)** built on SQLite's online backup API is still valuable for disaster recovery. It is a separate, later feature with different guarantees and is intentionally not part of this format.

### Decision 2: a directory package, not a zip

Foundation has no public ZIP API, and a third-party archiver is a new dependency that needs the full justification template in `CONTRIBUTING.md`. A directory package needs none.

The archive is a folder named `*.copyloom` declared as a package type (`io.github.imrajyavardhan12.copyloom.archive`, conforming to `com.apple.package`), so Finder presents it as a single file. A zip wrapper can be added later without changing the contents or `formatVersion`.

### Decision 3: derived data is never exported

Excluded on purpose: `search_documents`, FTS contents, OCR text, OCR job state, dedupe hashes, thumbnails, tombstoned (deleted) clips and all settings.

- OCR text and search documents are recomputed on import under the **current** privacy policy, so an archive can never carry text a newer detector would reject.
- Hashes are recomputed on import; a hash in an archive is never trusted.
- Capture settings (ignored apps, retention, paused state) are security-relevant. Importing someone else's archive must not be able to weaken them, so they never travel in it.

### Decision 4: export never contains anything the app itself has quarantined

This extends [THREAT_MODEL](../THREAT_MODEL.md) invariant 1 ("content the policy rejects must not reach … exports") to content accepted earlier and judged differently later, the same situation the OCR quarantine handles.

At export time:

- every text-bearing clip is re-checked with the current `TextOutputGate`; clips it refuses are **skipped and counted**, not exported;
- image clips whose OCR state is `withheld` are skipped and counted;
- nothing is deleted from the library by exporting.

The export result reports counts by reason (`sensitive`, `quarantinedImage`, `missingAttachment`) and never content, hashes or paths of skipped items.

## Layout

```text
My Library.copyloom/
  manifest.json
  clips.jsonl
  library.json
  attachments/
    ab/cd/abcdef…<64 hex>.png
```

Written to `My Library.copyloom.partial/` and renamed only after everything verifies. **A directory without `manifest.json` is incomplete by definition**, and the importer rejects it.

### `manifest.json`

```json
{
  "format": "io.github.imrajyavardhan12.copyloom.archive",
  "formatVersion": 1,
  "createdAt": "2026-10-05T03:00:00.000Z",
  "createdBy": { "app": "Copyloom", "appVersion": "0.1.0", "schemaVersion": 6 },
  "counts": { "clips": 1200, "attachments": 87, "collections": 4, "tags": 9, "savedQueries": 2 },
  "skipped": { "sensitive": 3, "quarantinedImage": 1, "missingAttachment": 0 },
  "files": [
    { "path": "clips.jsonl", "bytes": 482113, "sha256": "…" },
    { "path": "library.json", "bytes": 1840, "sha256": "…" },
    { "path": "attachments/ab/cd/abcd….png", "bytes": 52114, "sha256": "…" }
  ],
  "archiveDigest": "…"
}
```

- `files` lists **every** other file with size and SHA-256. `archiveDigest` is SHA-256 over the `path\0sha256\n` lines sorted by path, so one short value summarizes the whole archive and can be compared out of band.
- The manifest is **integrity, not authenticity**. Anyone who can edit the folder can edit the manifest too. The format does not claim tamper-proofing; signing belongs with Vault.
- Readers reject `formatVersion` greater than they support. Within a version, new fields are optional and unknown fields are ignored.

### `clips.jsonl`

One JSON object per line, ordered by `createdAt` then `uuid`. JSON Lines keeps memory bounded at 100k+ clips and confines corruption to a line.

```json
{"uuid":"…","kind":"text","createdAt":"…","lastSeenAt":"…","lastUsedAt":null,
 "copyCount":3,"useCount":1,"isPinned":false,"isFavorite":true,
 "representations":[{"uti":"public.utf8-plain-text","text":"hello"}],
 "sources":[{"bundleId":"com.apple.Safari","name":"Safari","provenance":"declared",
             "firstSeenAt":"…","lastSeenAt":"…","copyCount":3}],
 "tags":["project-x"]}
```

An image clip carries `{"uti":"public.png","attachment":"attachments/ab/cd/<sha>.png","sha256":"…","bytes":52114,"width":800,"height":600}` instead of `text`.

- `kind` and `provenance` are **strings** (`text`, `link`, `image`, `code`, `color`, `file`; `unknown`, `declared`, `frontmost`), so the file does not depend on Swift enum order.
- Timestamps are ISO 8601 UTC with milliseconds.
- `file` clips carry the path text as stored today (references only, never file bytes), consistent with the schema's no-silent-duplication rule. Paths are local to the exporting machine; the importer keeps them as references and does not resolve them.

### `library.json`

Collections (`uuid`, `name`, `parentUuid`, `createdAt`, `updatedAt`, ordered `clipUuids`), tags (`name` plus the `normalized` form for validation), and saved queries (`uuid`, `name`, `queryVersion`, `queryText`). Membership is by clip UUID. No payload is duplicated.

## Export

1. Take one GRDB read snapshot, so counts and relationships are consistent while capture keeps running.
2. Stream live (non-tombstoned) clips; for each, apply the [Decision 4](#decision-4-export-never-contains-anything-the-app-itself-has-quarantined) checks.
3. Copy each referenced attachment into the package, **verifying its SHA-256 against the database as it is read**. A missing or mismatched file skips that clip (`missingAttachment`); it never aborts the export.
4. Write `clips.jsonl` and `library.json`, hash every file, write `manifest.json` last, then rename out of `.partial`.

The UI states plainly before the user picks a destination: **the archive is unencrypted plain data readable by anything that can read the folder.**

## Import

Import has three phases and the first two have **no side effects**.

### 1. Verify (read-only)

- Reject unless `manifest.json` exists, is under 1 MiB, and `format`/`formatVersion` are supported.
- For every manifest entry: path is relative, has no `..` or empty components, is not absolute, resolves (after standardizing) inside the package root, and is **not a symlink**. Reject the whole archive on any violation.
- Attachment paths must equal the layout derived from their own digest (`ab/cd/<hex>.<ext>`) with an extension in `AttachmentStore.supportedUTIs`. The importer regenerates the stored path from the digest and never uses the archive's string for the destination.
- Check each file's byte size, then stream its SHA-256 and compare. Files present on disk but absent from `files` are ignored and reported, never read.
- Hard limits: ≤ 1,000,000 clips, `clips.jsonl` lines ≤ 32 MiB (5 MiB text ceiling plus JSON escaping), attachments ≤ the capture image ceiling (25 MiB). Anything over a limit is a verification failure.

**Verification is a point-in-time check, so reading does not trust it.** Files can change between verifying and reading. Every file the verifier or reader touches is opened component by component with `openat(..., O_NOFOLLOW)` (no link is followed at any level), and its size is taken from `fstat` on the descriptor that is then read, so what is checked is exactly what is opened. The reader reads no more than the declared size, re-hashes while streaming (a digest mismatch at the end of the stream aborts the import), and bounds every line. Records already delivered before such a failure are untrusted, which is why apply runs in batches.

### 2. Plan (dry run)

Parse and validate every record, then show the user a summary **before** anything is written: clips to add, clips already present, collections/tags to add, records rejected and why, and a retention warning (below). The user confirms or cancels.

### 3. Apply

Batched transactions (for example 500 clips each), not one giant transaction. A failure leaves a valid, partial import, and re-running the same archive completes it.

- **Gates:** text goes through the same `TextOutputGate` as capture (size, sensitive detector, kind). Images use the existing image ceilings and decode check, are stored through `saveAcceptedImage`, and then flow through the normal background OCR queue, so sensitive text is quarantined and never indexed.
- **Identity:** dedupe uses a hash **recomputed** from the imported content. A clip's UUID is preserved when free; if it collides with an existing clip that has different content, a new UUID is assigned and counted in the report.
- **Merge, never overwrite:** if the content already exists, keep the existing clip and apply only monotonic changes: pinned/favorite become true if the archive says so, earliest `createdAt` wins, tags and collection memberships are unioned. Counters (`copyCount`, `useCount`) are **not** added, so importing the same archive twice changes nothing (**idempotency is a tested invariant**).
- **Collections and tags:** collections match by UUID (an existing one keeps its name and gains members); tags match by normalized name; saved queries match by UUID and are imported only if `queryVersion` equals the current version, otherwise reported as skipped.
- **Files first:** attachment bytes are written using the existing temp-file, verify-digest, atomic-rename protocol before the database rows that reference them.

### Retention interaction

Retention expires unpinned, unfavorited clips whose `last_seen_at` is older than the window (30 days by default). An import that preserves original timestamps would see old history deleted at the next cleanup.

**Decision:** timestamps are preserved (faithful history beats a silent rewrite). The plan phase counts the clips that would fall outside the current retention window and says so explicitly, with the choices: continue, cancel, or raise retention in Settings first. No automatic favoriting and no timestamp rewriting.

## Permissions

Export and import need `com.apple.security.files.user-selected.read-write` so `NSSavePanel` / `NSOpenPanel` can grant access. This is the narrow, user-mediated sandbox entitlement: the app can touch only the folder the user picks, only during the action. It must be added to `App/Copyloom.entitlements` and listed in [permissions.md](permissions.md). No other permission and no network access is involved.

## Module and layering

```text
ClipDomain            record types are NOT here (format is not domain)
ClipArchive (new)     pure: ArchiveManifest, ClipRecord, LibraryRecord, path validator,
                      ArchiveWriter / ArchiveVerifier / ArchiveReader (file IO + digests),
                      ArchiveExporter / ArchiveImporter orchestration,
                      protocols: ClipArchiveSource, ClipArchiveSink
ClipStore             implements ClipArchiveSource / ClipArchiveSink over GRDB
LibraryFeature        export/import intent models + progress state (no AppKit panels)
App                   NSSavePanel / NSOpenPanel, progress and result UI
```

`ClipArchive` depends only on `ClipDomain` and Foundation/CryptoKit. Privacy gates are injected closures (the same pattern as `LibraryModel.transformOutputKind`) and **default to refusing**, so an unwired importer cannot persist anything.

## Slices

1. **6a, format core:** records, manifest, path validation, writer, verifier. Pure and exhaustively unit-tested.
2. **6b, export:** `ClipArchiveSource` in `ClipStore`, quarantine/sensitive skipping, Library/Settings "Export Library…", entitlement, `permissions.md`.
3. **6c, import:** dry-run plan, batched apply, merge rules, retention warning, UI.

Each slice leaves `main` green and is useful on its own (6b alone is a verified backup a user can inspect).

## Test plan

- **Format:** round-trip every record field; unknown optional fields ignored; `formatVersion` too new rejected.
- **Tamper:** altered byte in `clips.jsonl` and in an attachment, truncated file, wrong declared size, deleted listed file, extra unlisted file, manifest edited without updating digests, missing manifest (incomplete archive).
- **Path safety:** `../` components, absolute paths, empty components, a symlinked attachment, a symlinked directory, an attachment path that doesn't match its digest, an unsupported extension.
- **Limits:** oversize line, oversize attachment, over-count archive.
- **Export policy:** a sensitive text clip, a withheld-OCR image and a missing attachment are skipped and counted, with no content in the report; deleted clips are absent; export runs while a capture writes.
- **Import:** idempotent double import (database unchanged on the second run); duplicate content merges with monotonic flags only; UUID collision with different content gets a new UUID; sensitive text in a hostile archive is refused; an image is queued for OCR; interrupted import resumes; saved query with a stale version is skipped; retention warning count is correct.
- **Scale:** export and import of the 100k benchmark corpus with throughput and peak memory recorded in `docs/validation/` (measured, not promised; memory must stay bounded because both directions stream).
- **Manual evidence:** a Finder round trip on a signed host, since sandbox grants are only observable there.

## Decisions on the original open questions (2026-10-05)

1. **Scope:** v1 exports the **whole library** only. Exporting a collection or Smart Collection is the next step; the format already supports it (a filtered record set), so it needs no format change.
2. **Archive type:** v1 uses an **ordinary folder name** and does not register a `.copyloom` type. Registration is deferred until the format has survived real use, because the extension is hard to change once archives exist in the wild.

Status: design accepted. **6a (format core) implemented** in `ClipArchive` (records, manifest, path whitelist, writer, verifier, reader; 40 tests). 6b (export) and 6c (import) pending.
