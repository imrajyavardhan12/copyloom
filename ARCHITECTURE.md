# Architecture

_Status: accepted foundation architecture; changes require an ADR_
_Updated: 2026-08-21_

## Goals

Build a native macOS utility whose critical path is:

> global shortcut → query → select → paste into the retained application

The system must also remain a durable, inspectable local library. Privacy policy is enforced before storage, expensive work never runs on the UI path, and domain behavior is testable without AppKit or a live pasteboard.

## Recommended decisions

| Area | Decision | Why |
|---|---|---|
| Language/UI | Swift 6, SwiftUI, targeted AppKit | Native panel/focus/pasteboard/drag behavior with modern declarative views |
| Deployment | macOS 14+ | Modern SwiftUI/Vision/Swift concurrency while retaining a useful install base |
| Distribution | Source/local development now; sandboxed Developer ID-signed/notarized direct build when membership is funded; preserve Mac App Store viability | Paid membership is not needed for development, while normal public binaries must not depend on Gatekeeper bypasses |
| License | Apache-2.0 | Permissive plus explicit contributor patent grant |
| Database | System SQLite through GRDB, `DatabasePool`, WAL | FTS5, migrations, raw SQL and safe concurrent UI reads during capture |
| Attachments | Content-addressed files outside SQLite; small bounded payloads inline | Avoid database bloat, deduplicate binaries and load lazily |
| Search | Parsed query AST + bound SQL metadata filters + FTS5 external-content index | Fast, extensible and injection-safe |
| State | Feature-scoped observable models and injected service protocols | Avoid a giant singleton `AppState` |
| Concurrency | Swift structured concurrency; one serial capture pipeline; GRDB owns DB scheduling; UI on `@MainActor` | Explicit ownership and cancellation |
| Network | No core network client; adapters are optional and visible | Offline/privacy promise |

## System context

```text
                 ┌────────────────────────────────────────┐
NSPasteboard ───▶│ ClipboardCapture                       │
                 │ poll → snapshot → preflight → classify │
                 └───────────────┬────────────────────────┘
                                 │ immutable CaptureEnvelope
                    ┌────────────▼────────────┐
                    │ CapturePipeline actor   │
                    │ hash/dedup/store/jobs   │
                    └──────┬──────────┬───────┘
                           │          │
                ┌──────────▼───┐  ┌──▼────────────────┐
                │ ClipStore    │  │ ContentAnalysis   │
                │ GRDB + files │  │ OCR/thumbnail/etc │
                └──────┬───────┘  └──┬────────────────┘
                       │              │ derived updates
             ┌─────────▼──────────────▼─────────┐
             │ Search documents + FTS5         │
             └───────────┬──────────────────────┘
                         │ ClipSummary pages
       ┌─────────────────┼───────────────────┐
       ▼                 ▼                   ▼
 Quick Paste        Library/Settings    Future adapters
 NSPanel+SwiftUI    SwiftUI windows     Sync / MCP
       │
       ▼
 PasteCoordinator → NSPasteboard → retained NSRunningApplication → CGEvent ⌘V
```

## Module boundaries

Use one local Swift package with a deliberately small target graph, plus a thin app target. Do not create empty future modules.

### `ClipDomain`

Pure Swift/Foundation models and protocols:

- `Clip`, `ClipKind`, `ClipRepresentationDescriptor`, source provenance, sensitivity result
- collection/tag/bundle value types
- repository, attachment, clock, UUID, capture-policy and paste-delivery protocols
- use cases that contain no AppKit, SwiftUI, GRDB, Vision or network code

### `ClipboardCapture`

AppKit boundary:

- `NSPasteboardClient`
- `PasteboardMonitor`
- immutable pasteboard snapshots
- self-write markers
- capture pipeline orchestration

It does not execute SQL and does not update views.

### `ClipSearch`

- tokenizer/parser for quoted terms and structured tokens
- typed query AST and validation errors
- date expression resolution through injected clock/calendar
- future filter registry

It emits a semantic query, never SQL. `ClipStore` compiles that query into bound FTS/SQL.

### `ClipStore`

The only module importing GRDB:

- database configuration/migrations
- repositories and query compiler
- derived search-document builder
- attachment store and garbage collector
- retention, backup, integrity and recovery operations

No view imports GRDB or opens the database directly.

### `ContentAnalysis`

- ordered content classifier protocol and versioned classification outputs
- local sensitive-content detector
- Vision OCR adapter
- thumbnail generation
- transform protocol/registry and pure built-in transforms

Classification never determines whether raw input is safe by itself. Capture policy runs before persistence; post-capture analyses may only add derived metadata or trigger the documented quarantine/delete policy.

### `MacIntegration`

- registered global hotkey client
- previous-application tracker
- permission status/request clients
- paste coordinator and event synthesizer
- Quick Look, drag/drop, launch-at-login and file-access adapters

### App target and feature folders

- `App/`: composition root, menu-bar lifecycle, scenes, route/deep-link handling
- `Features/QuickPaste/`: panel controller, feature model, SwiftUI views
- `Features/Library/`: Library feature model/views
- `Features/Settings/`: capture/privacy/permission/retention UI
- `SharedUI/`: reusable native components and accessibility helpers

Feature models receive narrow protocols. The composition root constructs concrete services once; it is not a mutable global state bag.

## Capture pipeline

### 1. Observe

A coalescing main-run-loop timer compares `NSPasteboard.general.changeCount`. Initial proposal: 500 ms with timer tolerance; stop while paused, sleeping, or logged out. On resume, adopt the current count without retroactively capturing unknown content.

There is no documented event-driven replacement. Poll frequency is a measured energy/latency decision.

### 2. Preflight before payload reads

For every pasteboard item:

1. reject when paused or ignore-next is armed;
2. inspect declared types for concealed/transient/autogenerated/vendor markers;
3. evaluate the currently inferred source against ignore rules;
4. retain only supported UTTypes;
5. apply per-type and total-size policy as early as the API permits.

Ignored rules are loaded before monitoring starts. If rule decoding fails, monitoring fails closed and presents a visible error.

### 3. Snapshot

AppKit pasteboard access stays on its designated boundary. Read useful representations into immutable bounded values. Record `changeCount` before and after; if it changed, discard the inconsistent snapshot and process the latest state. Preserve ordered pasteboard-item boundaries for multi-file/multi-item fidelity.

`NSPasteboard` does not expose payload size before every read, so a malicious provider can still force an expensive read. Only supported types are requested, data is capped immediately after receipt, and this remains a threat-model residual risk.

### 4. Privacy/classification/hash

The serial `CapturePipeline` actor:

- runs deterministic local text-sensitive detection before disk;
- derives a primary kind without discarding UTTypes;
- computes per-representation SHA-256 and an ordered exact aggregate hash;
- creates a source record with confidence/provenance;
- decides `skip`, `quarantine`, or `persist`.

For image OCR-sensitive detection, the privacy-first design is an in-memory bounded quarantine: perform OCR before normal persistence when enabled and feasible. Time/size/error policy must be explicit; do not write a temporary plaintext image to disk and call it “not persisted.”

### 5. Persist/deduplicate

One short GRDB transaction performs a race-safe upsert:

- exact live hash match: update `last_seen_at`, `copy_count`, latest source and aggregate source relation; merge only missing equivalent representations;
- no match: insert clip, representations, sources and search document;
- enqueue derived work only after commit.

Do not normalize case or whitespace for dedup. Exact text normalization is limited to stable encoding details such as Unicode NFC and line-ending canonicalization, and the original bytes/representations remain available. Rich formatting differences are not collapsed merely because plain text matches.

### 6. Derive asynchronously

Separate bounded task queues perform OCR, thumbnail generation, classification refinements and metadata extraction. Jobs are idempotent and keyed by clip UUID + analysis version. Results update the search document in a transaction. Cancellation, app termination or failure leaves a usable clip and retryable job state.

No OCR/thumbnail/parser work runs in the polling callback or UI actor.

## Search architecture

### Query language

`ClipSearch` parses quoted phrases, free terms and registered filters:

- `app:Safari`
- `type:image|code|link|file|color|…`
- `is:pinned`, `is:favorite`
- `after:today`, `before:2026-08-01`
- `tag:project`
- `has:ocr`

Output is a typed AST. Unknown filters produce a visible diagnostic and are treated consistently; malformed dates/quotes do not silently broaden the query. The parser is extensible through filter descriptors, not UI conditionals.

### Execution

- free terms/phrases become safely constructed FTS5 patterns;
- metadata becomes indexed SQL predicates/joins;
- ranking begins with weighted BM25 and uses recency/use count only as deterministic tie-breakers;
- results are projections (`ClipSummary`), not loaded attachment graphs;
- searches are cancellable; stale result sets never replace newer queries;
- filter-only queries use ordinary indexes without invoking FTS.

Optional regex is later and explicit. It must run through a bounded/cancellable SQLite function or a bounded candidate set with query limits; never interpolate arbitrary regex into SQL.

### Performance strategy

- create/open the database pool before first Quick Paste invocation;
- construct the panel once and keep it hidden;
- fetch recent summaries lazily in pages;
- load thumbnails on demand through an `NSCache` with memory pressure handling;
- benchmark before adding prefix indexes, custom tokenizers or result caches;
- meet the stated `<30 ms` warm normal-query target at P95 on a documented 100k corpus/hardware profile.

## Quick Paste windowing and paste delivery

Use an AppKit `NSPanel` hosting SwiftUI because panel level, key status, focus, Spaces/full-screen behavior, activation and dismissal need AppKit control. It is screen-centered or cursor/active-screen aware and independent of a notch.

On open:

1. retain the currently frontmost application and activation identity;
2. show the already-constructed panel;
3. focus search and populate cached recent summaries;
4. keep keyboard routing inside one feature model.

On Enter:

1. resolve the selected clip and representations;
2. write them plus a private app marker and original-source metadata;
3. hide the panel;
4. if auto-paste is authorized, reactivate only the retained target and await confirmation briefly;
5. post Command-V; otherwise report copy-only success.

The selected clip remains on the system clipboard. v1 does not restore the prior clipboard afterward, avoiding lazy-read and overwrite races.

## Storage and attachments

- Database, WAL/SHM and attachment root live in the app container/Application Support.
- Original captured images and large representation blobs are content-addressed by SHA-256 under two-level relative paths.
- Copied file URLs are references, not silently duplicated file contents. Persist ordered URLs and, where legitimately granted, security-scoped bookmark data. Surface stale/unavailable references.
- File creation protocol: validate digest → write private temp file → optional fsync according to durability policy → atomic rename → commit DB reference. A startup/idle reconciler removes old unreferenced temp/orphan files after a grace period.
- Deletion removes DB references transactionally; physical shared attachment removal occurs only when no representation references it.
- Backups use SQLite online backup plus attachment manifest/checksums. Never copy only the SQLite main file while WAL is active.

See [docs/database-schema.md](docs/database-schema.md).

## Privacy architecture

Privacy decisions occur in this order:

1. system access status;
2. capture pause/manual/ignore-next state;
3. pasteboard marker deny rules;
4. inferred/declared source rules;
5. content-type and size rules;
6. local sensitive detector;
7. persistence;
8. derived indexing/OCR.

A value rejected at steps 1–6 is not logged, indexed, thumbnailed or persisted. Diagnostics contain reason codes and sizes/types, never content or hashes that could function as secret verifiers.

Regular history is local plaintext SQLite in v1 and relies on the macOS account/FileVault boundary. The UI must say this plainly. The future Vault is a distinct cryptographic design and index; see [THREAT_MODEL.md](THREAT_MODEL.md).

## Settings architecture

Security-critical capture settings (pause/manual mode, ignored apps/types, sensitive policy, retention) live outside the history database through a versioned `SettingsStore` so history corruption cannot silently erase exclusions. Settings load and validate before capture starts. Unknown/corrupt security settings fail closed.

Ordinary UI preferences may use `UserDefaults`. Secrets/tokens/keys use Keychain. Clipboard payloads never enter `UserDefaults`, logs, crash metadata or Spotlight.

## Error handling and recovery

- Database open/migration failure disables capture before any data is read and opens a recovery UI.
- Keep the damaged database untouched; offer verified backup, integrity check, export when readable, and create-new-store flows.
- Run `foreign_key_check`, targeted FTS consistency checks and an on-demand `integrity_check`; use `quick_check` for bounded diagnostics where appropriate.
- Every migration is append-only and tested from all released fixtures. Large migrations use backup/preflight/create-copy-validate-swap.
- Capture failures are isolated per event; repeated failures pause monitoring visibly instead of silently dropping everything.

## Test strategy

### Unit

Dedup/hash policy, classification, sensitive detection, parser/filter dates, transforms, retention, collection/tag operations, bundle references and paste representation selection.

### Storage integration

Every migration path, transaction rollback, FTS synchronization/rebuild, concurrent search+capture, online backup/restore, attachment orphan handling, corruption diagnostics and tombstone/delete behavior.

### Platform integration

Fake pasteboard/source/hotkey/event clients for deterministic tests, plus signed-host tests for real NSPasteboard types, multiple items/files, self-write suppression and focus state.

### UI and manual permission matrix

XCUITest for panel focus, keyboard navigation, actions and accessibility identifiers. TCC prompts, cross-application paste, Spaces/full-screen apps, keyboard layouts, secure fields, permission revocation and macOS pasteboard privacy require a documented manual matrix on clean test users/VMs.

### Performance

Release-only benchmarks with deterministic 100k corpus: capture transaction, dedup, warm/cold-ish search, filter-only search, timeline pages, OCR queue, attachment IO, retention, migration and concurrent readers/writer. Record median/P95/P99, RSS, CPU/energy, DB/WAL/attachment sizes and full environment metadata.

## Proposed repository structure

```text
.
├── App/
│   ├── Sources/
│   │   ├── App/
│   │   ├── Features/{QuickPaste,Library,Settings}/
│   │   └── SharedUI/
│   ├── Resources/
│   └── Copyloom.entitlements
├── Packages/CopyloomKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── ClipDomain/
│   │   ├── ClipboardCapture/
│   │   ├── ClipSearch/
│   │   ├── ClipStore/
│   │   ├── ContentAnalysis/
│   │   └── MacIntegration/
│   └── Tests/
├── Tests/
│   ├── AppUITests/
│   ├── IntegrationTests/
│   ├── Fixtures/
│   └── MigrationFixtures/
├── Benchmarks/
│   ├── CorpusGenerator/
│   ├── SearchBenchmarks/
│   └── CaptureBenchmarks/
├── docs/
│   ├── research.md
│   ├── database-schema.md
│   ├── permissions.md
│   ├── decisions/
│   └── archive-format.md          # when designed
├── scripts/
├── .github/
│   ├── workflows/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
├── ARCHITECTURE.md
├── THREAT_MODEL.md
├── ROADMAP.md
├── README.md
├── LICENSE
└── THIRD_PARTY_NOTICES.md
```

`Sync`, `Vault`, `SemanticSearch`, and `MCP` directories are not created until their design gates pass. Their future implementations depend on domain/repository authorization protocols, never direct UI or database access.

## Major technical risks

| Risk | Impact | Mitigation / evidence gate |
|---|---|---|
| Polling can miss rapid intermediate clipboard states or cost energy | Lost clips or battery/CPU regression | Coalescing timer, change-count consistency checks, rapid-copy tests and Instruments energy baseline; document unavoidable API limit |
| Newer macOS Paste from Other Apps behavior may impede unattended history | Core feature unavailable or prompt-heavy | Full-Xcode signed prototype on every supported OS before committing the deployment/distribution matrix |
| Source attribution is untrusted | Ignored-app rule can miss or falsely exclude data | Provenance labels, marker/type/content defense-in-depth, manual/pause controls; no security guarantee claim |
| Accessibility paste can target incorrectly across focus/Spaces/secure fields | Unintended disclosure | Retained target identity, activation confirmation/timeout, copy-only fallback, signed manual matrix |
| FTS target may not hold at 100k records | Product-defining latency failure | Deterministic Release benchmark before UI polish; tune schema/prefixes from evidence only |
| Pasteboard providers and image payloads are unbounded/untrusted | UI stall, memory pressure, parser crash | Supported types only, immediate caps, bounded queues, fuzz/adversarial fixtures; acknowledge pre-read size limit |
| File and DB writes are not one transaction | Orphans or missing attachments | Temp/rename/commit protocol, checksums, grace-period reconciler and crash tests |
| Plaintext FTS conflicts with a future locked Vault | Secret leakage or architecture rewrite | Keep Vault out of normal schema/index and require separate cryptographic/search design |
| Sandboxing/distribution differences | Entitlement, update or App Review blockers | Decide channel early and validate sandboxed direct + MAS-compatible behavior before Phase 2 |
| Xcode 26 project output could unnecessarily raise the contributor toolchain floor | Contributors on older supported Xcode cannot build | Use conventional checked-in groups/project format, document Xcode 26.6 baseline, and validate the project through shared CLI schemes |

## Dependency policy

Initial runtime dependency:

- **GRDB (MIT):** materially reduces migration, binding and concurrency risk while preserving SQL/FTS control.

No syntax highlighter, hotkey package, analytics SDK, networking layer or cryptography package is approved yet. Before addition, document purpose, alternatives, license, transitive graph, maintenance, binary impact, privacy/network behavior, and removal plan.

## Accepted project inputs and remaining stop points

Accepted in [ADR 0001](docs/decisions/0001-project-identity-and-initial-distribution.md):

- product name: **Copyloom**;
- GitHub owner: `imrajyavardhan12`;
- bundle ID: `io.github.imrajyavardhan12.copyloom`;
- minimum deployment: macOS 14;
- source/local development without paid Apple membership; direct notarized distribution when membership is funded, while preserving Mac App Store viability;
- default retention: 30 days, with pinned/favorite clips exempt;
- contextual Accessibility onboarding with a copy-only fallback;
- conservative capture/disk ceilings and fail-closed image preflight in [ADR 0002](docs/decisions/0002-migrations-hashing-and-safety-defaults.md).

No additional owner input blocks M1. Limits can be tuned only from measured evidence without weakening the pre-persistence safety contract. Vault encryption/search, CloudKit key recovery and MCP client identity remain future irreversible decisions and explicitly do not block the first vertical slice.
