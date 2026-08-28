# Database Schema Design

_Status: logical schema design; text/FTS migration 001, application-source migration 002, and clip-lifecycle migration 003 are implemented in `ClipStore/Migrations.swift`_
_Updated: 2026-08-21_

Migration policy is governed by [ADR 0002](decisions/0002-migrations-hashing-and-safety-defaults.md): migration 001 is intentionally limited to the accepted-text persistence/search tracer. Tables shown for later capabilities are logical designs, not promises that they all belong in migration 001.

## Design rules

1. Stable UUIDs are external/sync/archive identity; integer primary keys are local join/FTS identity.
2. One logical clip owns ordered pasteboard items and multiple representations.
3. Collections, tags, queues and bundles reference clips; they do not copy payloads.
4. Hash algorithm versions are stored explicitly; they are not hidden only inside irreversible digests.
5. Large binaries are content-addressed files. SQLite stores relational metadata and small bounded values.
6. Search has a rebuildable derived document and FTS index. It is never the source of truth.
7. Source application is nullable and carries provenance/confidence; it is not a verified security fact.
8. Security-critical settings are not stored in the history DB.
9. Dates are UTC integer milliseconds since Unix epoch. UI/calendar interpretation occurs outside storage.
10. Enum values are stable integers mapped by explicit code, never Swift enum declaration order.
11. Foreign keys are enabled on every connection.

## Relationship overview

```text
applications ─┬─< clip_application_sources >─ clips ─┬─< clip_representations >─ attachments
              │                                      ├─< clip_files
              └──────────── latest source ────────────┤
                                                     ├─1 search_documents ─1 clip_fts
collections ─< collection_items >─────────────────────┤
tags ────────< clip_tags >────────────────────────────┤
bundles ─────< bundle_items >─────────────────────────┘   (later migration)
```

## Logical core schema

The SQL below communicates the intended mature shape and constraints. Exact GRDB migration syntax and capability migration may differ. The actual migration creates parent tables before child tables even when this document presents the hot-path `clips` table first. Migration 001 contains only the subset exercised by accepted text clips and FTS search.

### `clips`

```sql
CREATE TABLE clips (
    id                    INTEGER PRIMARY KEY,
    uuid                  TEXT NOT NULL UNIQUE,
    kind                  INTEGER NOT NULL,
    primary_uti           TEXT,
    hash_version          INTEGER NOT NULL,
    dedupe_hash           BLOB NOT NULL,
    representation_set_hash BLOB NOT NULL,
    byte_count            INTEGER NOT NULL CHECK (byte_count >= 0),
    created_at            INTEGER NOT NULL,
    last_seen_at          INTEGER NOT NULL,
    last_used_at          INTEGER,
    copy_count            INTEGER NOT NULL DEFAULT 1 CHECK (copy_count >= 1),
    use_count             INTEGER NOT NULL DEFAULT 0 CHECK (use_count >= 0),
    title                 TEXT,
    notes                 TEXT,
    is_pinned             INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0,1)),
    is_favorite           INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0,1)),
    sensitivity           INTEGER NOT NULL DEFAULT 0,
    sensitivity_version   INTEGER NOT NULL DEFAULT 0,
    latest_application_id INTEGER REFERENCES applications(id) ON DELETE SET NULL,
    latest_source_provenance INTEGER NOT NULL DEFAULT 0,
    expires_at            INTEGER,
    revision              INTEGER NOT NULL DEFAULT 1,
    deleted_at            INTEGER,
    created_by_device     TEXT
);

CREATE UNIQUE INDEX clips_live_dedupe_hash
    ON clips(hash_version, dedupe_hash) WHERE deleted_at IS NULL;
CREATE INDEX clips_timeline
    ON clips(is_pinned DESC, last_seen_at DESC, id DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX clips_kind_timeline
    ON clips(kind, last_seen_at DESC, id DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX clips_favorite_timeline
    ON clips(last_seen_at DESC, id DESC)
    WHERE deleted_at IS NULL AND is_favorite = 1;
CREATE INDEX clips_expiration
    ON clips(expires_at, id)
    WHERE deleted_at IS NULL AND expires_at IS NOT NULL AND is_pinned = 0;
```

`created_at` is the first capture time. `last_seen_at` and `copy_count` update on exact duplicates. `use_count` counts app-initiated copy/paste actions, not external copy observations.

`hash_version` identifies the canonicalization algorithm. `dedupe_hash` is SHA-256 over its domain-separated canonical payload and drives duplicate detection. `representation_set_hash` covers every retained representation and detects representation changes without being unique. Hash version 1 is defined in ADR 0002. Future ordered multi-item canonicalization must preserve rich formatting distinctions as described there.

`deleted_at` is useful immediately for undo/recovery and later for sync tombstones. Normal queries always exclude deleted rows. Physical purge is a separate maintenance operation.

### `clip_representations`

```sql
CREATE TABLE clip_representations (
    id              INTEGER PRIMARY KEY,
    clip_id         INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    item_index      INTEGER NOT NULL CHECK (item_index >= 0),
    uti             TEXT NOT NULL,
    mime_type       TEXT,
    role             INTEGER NOT NULL DEFAULT 0,
    storage_kind     INTEGER NOT NULL,
    inline_text      TEXT,
    inline_blob      BLOB,
    attachment_id   INTEGER REFERENCES attachments(id) ON DELETE RESTRICT,
    byte_count      INTEGER NOT NULL CHECK (byte_count >= 0),
    sha256           BLOB NOT NULL,
    metadata_json   TEXT,
    created_at      INTEGER NOT NULL,
    UNIQUE (clip_id, item_index, uti),
    CHECK (
      (storage_kind = 1 AND inline_text IS NOT NULL AND inline_blob IS NULL AND attachment_id IS NULL) OR
      (storage_kind = 2 AND inline_text IS NULL AND inline_blob IS NOT NULL AND attachment_id IS NULL) OR
      (storage_kind = 3 AND inline_text IS NULL AND inline_blob IS NULL AND attachment_id IS NOT NULL) OR
      (storage_kind = 4 AND inline_text IS NULL AND inline_blob IS NULL AND attachment_id IS NULL)
    )
);
CREATE INDEX clip_representations_clip ON clip_representations(clip_id, item_index, id);
```

Proposed storage kinds: inline text, inline blob, managed attachment, and metadata-only/external reference. Inline limits are configuration constants covered by tests; oversize payloads become managed attachments or are rejected by capture policy.

`metadata_json` is limited to non-queryable representation-specific metadata. Any field needed for filters/joins gets a real typed column/table.

### `attachments`

```sql
CREATE TABLE attachments (
    id              INTEGER PRIMARY KEY,
    sha256           BLOB NOT NULL UNIQUE,
    relative_path   TEXT NOT NULL UNIQUE,
    byte_count      INTEGER NOT NULL CHECK (byte_count >= 0),
    uti              TEXT,
    width_pixels    INTEGER,
    height_pixels   INTEGER,
    encryption      INTEGER NOT NULL DEFAULT 0,
    key_version     INTEGER,
    created_at      INTEGER NOT NULL,
    verified_at     INTEGER
);
```

Paths are generated from the digest and validated to remain under the attachment root. Reference counts are derived with SQL to avoid a mutable count drifting from reality. Attachment GC selects rows with no representation references, then uses a grace period/file reconciliation protocol.

Regular v1 history attachments are not app-level encrypted. `encryption` reserves migration compatibility; it is not a Vault design.

### `clip_files`

```sql
CREATE TABLE clip_files (
    id                INTEGER PRIMARY KEY,
    clip_id           INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    item_index        INTEGER NOT NULL CHECK (item_index >= 0),
    ordinal           INTEGER NOT NULL CHECK (ordinal >= 0),
    original_url      TEXT NOT NULL,
    display_name      TEXT NOT NULL,
    bookmark_data     BLOB,
    file_resource_id  BLOB,
    byte_count        INTEGER,
    modified_at       INTEGER,
    UNIQUE (clip_id, item_index, ordinal)
);
```

Copied files remain references; the app does not silently duplicate arbitrary file contents. A bookmark is stored only when the OS legitimately grants persistent access. Missing/stale files are represented honestly.

### `applications` and source aggregation

```sql
CREATE TABLE applications (
    id            INTEGER PRIMARY KEY,
    bundle_id     TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL
);

CREATE TABLE clip_application_sources (
    clip_id        INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    application_id INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    provenance     INTEGER NOT NULL,
    first_seen_at  INTEGER NOT NULL,
    last_seen_at   INTEGER NOT NULL,
    copy_count     INTEGER NOT NULL DEFAULT 1 CHECK (copy_count >= 1),
    PRIMARY KEY (clip_id, application_id, provenance)
);
CREATE INDEX clip_sources_app_recent
    ON clip_application_sources(application_id, last_seen_at DESC, clip_id);
```

Provenance values distinguish unknown, cooperative `org.nspasteboard.source`, and frontmost-at-detection inference. `clips.latest_source_provenance` records the latest event even when `latest_application_id` is `NULL`, so a deduplicated clip can transition among all three states. The join table aggregates known sources over time. Display names can change; bundle ID is the rule key.

### Collections and tags

```sql
CREATE TABLE collections (
    id          INTEGER PRIMARY KEY,
    uuid        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    parent_id   INTEGER REFERENCES collections(id) ON DELETE SET NULL,
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER
);

CREATE TABLE collection_items (
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    clip_id       INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    position      INTEGER NOT NULL DEFAULT 0,
    added_at      INTEGER NOT NULL,
    PRIMARY KEY (collection_id, clip_id)
);
CREATE INDEX collection_items_order ON collection_items(collection_id, position, added_at, clip_id);

CREATE TABLE tags (
    id          INTEGER PRIMARY KEY,
    uuid        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    normalized  TEXT NOT NULL,
    parent_id   INTEGER REFERENCES tags(id) ON DELETE SET NULL,
    created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX tags_unique_sibling
    ON tags(COALESCE(parent_id, 0), normalized);

CREATE TABLE clip_tags (
    clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (clip_id, tag_id)
);
CREATE INDEX clip_tags_tag ON clip_tags(tag_id, clip_id);
```

A clip may belong to multiple collections and tags. Moving in UI may mean add/remove membership; no payload is copied.

### Saved/smart queries

```sql
CREATE TABLE saved_queries (
    id            INTEGER PRIMARY KEY,
    uuid          TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    query_version INTEGER NOT NULL,
    query_text    TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    deleted_at    INTEGER
);
```

Store the canonical user query plus parser version, not generated SQL. Smart Collections reference a saved query in a later UI migration or can initially be a saved-query section.

## Search projection and FTS5

The source-of-truth tables are flattened into one derived row per live/searchable clip.

```sql
CREATE TABLE search_documents (
    clip_id       INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    body          TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL DEFAULT '',
    notes         TEXT NOT NULL DEFAULT '',
    tags          TEXT NOT NULL DEFAULT '',
    filenames     TEXT NOT NULL DEFAULT '',
    urls          TEXT NOT NULL DEFAULT '',
    ocr           TEXT NOT NULL DEFAULT '',
    applications  TEXT NOT NULL DEFAULT '',
    updated_at    INTEGER NOT NULL
);

CREATE VIRTUAL TABLE clip_fts USING fts5(
    body,
    title,
    notes,
    tags,
    filenames,
    urls,
    ocr,
    applications,
    content='search_documents',
    content_rowid='clip_id',
    tokenize='unicode61 remove_diacritics 2',
    prefix='2 3 4'
);
```

The migration creates standard external-content insert/update/delete triggers on `search_documents`. The repository updates source rows, rebuilds the flattened document, and writes it in the same transaction. Migration tests verify trigger behavior. Repair supports:

```sql
INSERT INTO clip_fts(clip_fts) VALUES('rebuild');
INSERT INTO clip_fts(clip_fts) VALUES('integrity-check');
```

Exact FTS commands are gated against the deployed SQLite version. Prefix lengths are provisional and retained only if benchmarks justify their storage/write cost.

A normal search joins `clip_fts.rowid = clips.id`, applies `MATCH`, metadata predicates and `deleted_at IS NULL`, orders by weighted BM25 plus deterministic recency/use tie-breakers, and limits before loading details.

Do not index sensitive skipped content, Vault content, private marker payloads, raw attachment bytes, security-scoped bookmarks, or secret-detector match details.

## Derived work queue

Migration 001 may include a compact local job table if crash-resumable OCR/thumbnail work is required in the first slice:

```sql
CREATE TABLE derived_jobs (
    id               INTEGER PRIMARY KEY,
    clip_id          INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    kind             INTEGER NOT NULL,
    algorithm_version INTEGER NOT NULL,
    state            INTEGER NOT NULL,
    attempt_count    INTEGER NOT NULL DEFAULT 0,
    not_before       INTEGER,
    last_error_code  TEXT,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    UNIQUE (clip_id, kind, algorithm_version)
);
```

Errors contain codes only, never clipboard content. If Phase 2 excludes OCR, this table can wait for the OCR migration rather than exist unused.

## Later migrations

### Reusable multi-clip bundles

```sql
CREATE TABLE bundles (
    id INTEGER PRIMARY KEY,
    uuid TEXT NOT NULL UNIQUE,
    name TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
);
CREATE TABLE bundle_items (
    bundle_id INTEGER NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
    clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL,
    options_json TEXT,
    PRIMARY KEY (bundle_id, ordinal)
);
```

A transient paste queue stays in session state unless the user saves it as a bundle. Bundle deletion never deletes referenced clips; clip deletion must warn or tombstone while references exist according to product policy.

### Sync

Before CloudKit implementation, add a device table, durable outbox, server metadata and acknowledged tombstones in a dedicated reviewed migration. Never overload `updated_at` as a conflict-resolution clock.

### Vault

Vault is not added by sprinkling encryption columns into these tables. Its schema/index/key lifecycle requires a separate security design. Normal `search_documents` must never contain Vault plaintext.

## Dedup semantics

1. Select the versioned canonical payload for every ordered pasteboard item and compute `dedupe_hash`; separately compute `representation_set_hash` over all retained representations.
2. In one transaction, select/insert under the partial unique `(hash_version, dedupe_hash)` index.
3. On conflict, update recency/copy count, latest source provenance and aggregate known-source information.
4. Preserve earliest creation, user title/notes, pins, favorites, collection/tag memberships and bundle references.
5. Merge a missing lower-priority representation only when the canonical dedupe payload is unchanged and `(item_index, UTI, digest)` is absent. If a richer representation becomes canonical, store a distinct clip rather than collapse formatting.
6. A user-deleted/tombstoned clip may be captured anew because the partial index excludes deleted rows. Future sync must define resurrection policy separately.

## Retention and deletion

- `expires_at` is calculated from the active retention policy at capture/update time; policy changes can recalculate in bounded batches.
- Pinned and favorite clips are exempt by default, as accepted in ADR 0002.
- Cleanup selects bounded pages, tombstones rows transactionally, then schedules attachment GC.
- “Clear non-pinned” uses the same deletion path; it is not a direct file wipe.
- SQLite/WAL/SSD behavior means ordinary deletion is not forensic secure erase. UI/security docs must not claim otherwise.

## Database configuration

Proposed connection preparation:

- `PRAGMA foreign_keys = ON`
- WAL through `DatabasePool`
- finite busy timeout
- explicit `synchronous` policy (start with `FULL`; measure `NORMAL` before changing)
- no network/cloud-synced database path
- bounded WAL checkpointing while idle, never on the UI thread
- periodic `PRAGMA optimize`

Record SQLite version/compile options in diagnostics without recording clip data.

## Migration and corruption tests

- brand-new schema and every historical migration fixture
- rollback on injected migration failures
- old data backfill before FTS trigger activation/rebuild
- duplicate races
- foreign key and FTS integrity checks
- interrupted attachment temp write/rename/DB commit
- missing/corrupt attachment checksums
- WAL recovery after forced process termination
- online backup + manifest restore
- unreadable/corrupt DB opens in fail-closed recovery mode, never with capture active
