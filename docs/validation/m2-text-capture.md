# M2 Text/Link Capture Tracer Validation

_Date: 2026-08-24_

## Implemented behavior

- Clipboard capture is disabled by default and begins only after an explanatory user action.
- A tolerant 500 ms pasteboard change-count monitor runs only while capture is enabled and not paused.
- Concealed, transient, auto-generated, known password-manager/text-expander, own-write, ignored-app, unsupported, oversize and high-confidence sensitive text paths are rejected before repository persistence.
- Declared and frontmost source bundle IDs are both checked against ignored applications; declared source remains labeled as untrusted provenance.
- Plain text and HTTP(S) links are classified, persisted, deduplicated, indexed and counted.
- Source applications are aggregated across duplicates; the latest source/provenance is retained.
- Pause/resume adopts the current change count so copies made while paused are not captured.
- Ignore-next-copy is consumed exactly once.
- Clipboard changes during metadata or payload reads are rejected as inconsistent snapshots.
- The menu-bar app shows capture state, local clip count and content-free privacy outcomes.

## Automated evidence

Swift package tests cover:

- metadata rejection before payload reads;
- ignored-source defense against declared-source spoofing;
- inconsistent snapshot rejection;
- sensitive-text no-persistence behavior;
- URL classification and declared-source preference;
- pause adoption and ignore-next semantics;
- private keys, credential assignments, access tokens, JWT-like structured tokens and Luhn-valid payment-card candidates;
- ordinary developer-text false-positive fixtures;
- source aggregation, latest provenance and free/app-filter search;
- an end-to-end fake-pasteboard → privacy policy → GRDB → reopen → type/app-filter search tracer;
- migration 002 and FTS5 rebuild/integrity, including an automated upgrade from migration 001 with existing searchable text.

The shared workspace builds both `arm64` and `x86_64` package/app code under Swift 6 strict concurrency.

## Signed host smoke

A locally ad-hoc-signed sandboxed Debug app launched with zero stderr output. It created/opened:

`~/Library/Containers/io.github.imrajyavardhan12.copyloom/Data/Library/Application Support/Copyloom/history.sqlite`

Both migrations were present. Capture remained off by default, so this smoke test did not trigger a pasteboard privacy prompt.

## Deferred manual evidence

A person must click **Enable Clipboard Capture…**, review the explanation, respond to the macOS pasteboard privacy prompt, then copy synthetic text from at least two applications. Until that signed-host matrix is recorded, real macOS 15.4+/26 pasteboard authorization and source-attribution behavior are not claimed as validated.

Quick Paste, global hotkeys, Accessibility-based automatic paste, image quarantine/OCR, retention cleanup and user-configurable ignored applications remain outside this tracer.
