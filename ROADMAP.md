# Roadmap

This roadmap uses vertical slices and evidence gates. Dates are intentionally absent until the signing/distribution and minimum-OS decisions are confirmed.

## M0 — Research and architecture (complete)

- [x] Competitor and open-source research
- [x] NSPasteboard, privacy marker, hotkey, paste and permission research
- [x] GRDB/SQLite/FTS5 and license research
- [x] Initial architecture, database, permission and threat-model documents
- [x] Confirm product name, bundle identifier, repository owner, deployment target and distribution strategy
- [x] Record accepted decisions as ADRs

**Exit:** significant alternatives are explicit; no production implementation has begun.

## M1 — Open-source and engineering foundation (complete)

- Apache-2.0 `LICENSE`, `README.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`, third-party notices
- GitHub bug/feature templates and pull-request template
- Xcode workspace plus local Swift package modules
- Swift 6 strict-concurrency build, SwiftFormat/SwiftLint choice with minimal configuration
- CI for build, unit tests, formatting/lint, dependency review and secret scanning
- GRDB pin with written dependency justification
- migration harness, fixture factory and deterministic clock/UUID services
- benchmark executable and 100k deterministic corpus generator
- accepted ADRs for distribution/sandbox, deployment target, minimal migrations/hash version, retention, auto-paste permission flow, attachment limits and GRDB

**Evidence:** local and hosted package/app builds, migrations, tests, formatting, CodeQL and corpus generation pass; see [`docs/validation/m1-foundation.md`](docs/validation/m1-foundation.md).

**Exit:** clean checkout builds/tests with one documented command on supported CI; no clipboard UI required.

## M2 — First serious vertical slice (in progress)

**Implemented tracer:** explicit opt-in text/link capture, privacy-marker and sensitive-content rejection before storage, source provenance, deduplication, app-container persistence, pause/resume, ignore-next-copy, and local clip count. Quick Paste, configurable ignored-app UI, retention cleanup, global hotkey, automatic paste, and images remain.

### Capture and privacy

- menu-bar app and capture-state menu
- `NSPasteboard.changeCount` monitor with self-write marker
- plain text, links and images; preserve useful original representations
- marker/app/size/content policy before persistence, including fail-closed in-memory Vision privacy preflight for images
- local sensitive-text detector and ignored applications
- pause, ignore-next-copy and configurable retention
- source provenance (`declared`, `frontmost heuristic`, `unknown`)

### Persistence and search

- migrations from schema version 1
- content-addressed attachments and orphan reconciliation
- race-safe exact dedup with recency/copy-count/source aggregation
- FTS5 search and structured parser: quoted text, `app:`, `type:`, `is:`, `after:`, `before:`, `tag:`, `has:ocr`
- delete and pin
- migration, corruption and retention tests

### Quick Paste

- prewarmed AppKit `NSPanel` hosting SwiftUI
- keyboard and mouse navigation, Enter, copy-only, plain-text paste, preview, ⌘1–9, delete and pin
- previous-app retention and Accessibility-gated Command-V
- VoiceOver labels, Reduced Motion, system appearance and focus tests

### Evidence

- warm search P95 `<30 ms` for representative normal queries over 100k textual records on named Apple Silicon hardware
- unchanged-monitor CPU/energy measurements with poll interval recorded
- panel warm-open measurements
- peak memory and attachment/dedup measurements
- automated unit/integration/UI tests plus a documented manual TCC/cross-app matrix

**Milestone acceptance:** all 17 checks versioned in [`docs/acceptance/m2-vertical-slice.md`](docs/acceptance/m2-vertical-slice.md) pass; any non-automated permission/focus checks have recorded manual evidence.

## M3 — Library, OCR and developer workflows

- Library: History, Favorites, Pinned, Images, Links, Files, Code and Colors
- compact list and visual-card densities; collection drag/drop
- background Vision OCR with searchable output and privacy-safe quarantine policy
- collections, tags and saved-query Smart Collections
- transform protocol/registry and initial JSON/text/URL/Base64/file/color actions
- syntax-highlighted code preview
- import/export archive v1 with manifest and integrity verification

**Not included:** semantic search, sync, Vault, MCP, text expansion.

## M4 — Multi-clip and reusable workflows

- transient Paste Queue with explicit lifecycle
- reusable heterogeneous bundles referencing clip IDs
- snippets
- optional global text expansion after a separate Input Monitoring/Accessibility design review
- screenshot-folder monitoring after explicit folder selection

## M5 — Optional secure and distributed capabilities

Each item requires its own design/security review and may ship independently:

1. encrypted Vault with Keychain/Touch ID, auto-relock, no normal FTS/OCR leakage;
2. CloudKit adapter with identity, tombstones, outbox, conflict and key-recovery policy;
3. fully local semantic index, disabled by default;
4. local MCP stdio bridge with per-client scoped authorization, disabled by default;
5. documented portable backup/import adapters.

## Explicitly deferred

Windows, Linux, iOS, Android, team collaboration, proprietary cloud, hosted AI, plugin marketplace, broad image editing, background removal suite, and unauthenticated/network-exposed MCP.

## Regression policy

- Every migration is forward-tested from fixtures for all shipped schema versions.
- Every correctness bug receives a regression test when realistically automatable.
- Hot-path benchmark baselines are stored with hardware/OS/build metadata; percentage regressions trigger review, not brittle cross-machine CI failure.
- Security-sensitive TODOs must reference an issue and state the safe current behavior; otherwise the feature remains disabled.
