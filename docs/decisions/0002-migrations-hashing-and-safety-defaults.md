# ADR 0002: Migrations, deduplication hashing, and safety defaults

- **Status:** Accepted
- **Date:** 2026-08-21

## Context

Copyloom must evolve without freezing speculative future tables into its first schema. Deduplication hashes also need an explicit version that can be migrated, and capture limits must fail safely before untrusted payloads reach storage.

## Decisions

### Minimal append-only migrations

- Each migration contains only schema exercised by a shipped capability.
- Migration 001 is limited to accepted text clips and lexical search: `clips`, text `clip_representations`, `search_documents`, FTS5, and their synchronization triggers.
- Applications, binary attachments, file references, collections/tags, derived jobs, bundles, sync and Vault arrive in the migration that first ships their tested behavior.
- Migrations are append-only and transactional where SQLite permits.
- Developer fixtures may be regenerated before the first public release, but Copyloom never silently resets a user's database.

### Versioned hashes

- `hash_version` is a real integer column and participates in the live uniqueness key.
- `dedupe_hash` identifies the canonical content used for duplicate detection.
- `representation_set_hash` describes every retained representation and is not unique.
- Migration 001 uses hash version 1: SHA-256 over a domain-separated, length-prefixed UTF-8 text payload after Unicode NFC and CRLF/CR to LF normalization. Case, leading/trailing whitespace and all other characters remain significant.
- Future multi-representation versions define one canonical payload per ordered pasteboard item. Lower-priority alternate representations may be merged only when the canonical dedupe payload is unchanged. A newly richer canonical payload creates a distinct clip rather than silently collapsing formatting.

### Safety defaults

- Retention is 30 days. Pinned and favorite clips are durable and exempt until the user removes that state.
- Accessibility is requested only after contextual explanation when automatic paste is enabled/invoked. Copy-only always works.
- Initial capture ceilings are conservative guardrails, not performance claims:
  - 5 MiB per textual representation;
  - 25 MiB per binary representation;
  - 50 MiB aggregate per pasteboard snapshot;
  - 40 megapixels per decoded image;
  - 2 GiB default managed-history disk budget, with durable items visible when they prevent cleanup.
- Payloads exceeding a ceiling are skipped before persistence wherever the platform exposes size soon enough; otherwise they are discarded immediately after bounded materialization.
- Image persistence is fail closed until an in-memory Vision text/sensitivity preflight succeeds. M2 may use OCR only as a privacy gate; storing/searching OCR output remains M3. If the scan times out, exceeds limits or fails, the default is skip with a content-free notification and explicit one-time manual override.

## Consequences

- Migration 001 stays small enough to test exhaustively.
- Hash algorithms can be identified and migrated.
- Same text with changed case or whitespace remains distinct; line-ending/Unicode encoding noise does not.
- Rich formatting is not silently discarded to force deduplication.
- Image capture requires a minimal Vision privacy preflight even before searchable OCR ships.
- Limits can change through a reviewed migration/settings policy, but tests pin the current defaults.
