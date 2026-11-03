# Testing Strategy and Public Seams

_Status: accepted seams for M1; extend through ADR/review when a new capability begins_

Tests specify observable behavior through public module boundaries. They do not test private parser functions, GRDB record internals, view implementation details, or collaborator call counts.

## M1 seams

### `SearchQueryParser`

```swift
func parse(_ input: String, context: SearchParseContext) throws -> SearchQuery
```

Verify free terms, quoted phrases, registered filters, deterministic relative dates through an injected calendar/clock, and typed validation errors. Do not expose or test lexer internals.

### `ClipRepository`

The `ClipDomain` protocol is implemented by `ClipStore`. M1 behavior:

- save an already policy-accepted text clip;
- list recent summaries with a bounded limit;
- search using a parsed `SearchQuery` with a bounded limit;
- preserve results after closing and reopening the database.

Repository tests use a temporary on-disk database and public methods. Raw SQL is reserved for schema, migration and FTS integrity contracts.

### `AppDatabase`

Verify that fresh migration and reopening succeed, required SQLite/FTS5 capabilities are reported, and open/corruption errors are surfaced without replacing the file. Schema-version and FTS rebuild checks are valid storage-contract tests.

### App-host launch

A host smoke test verifies that Copyloom launches as a menu-bar agent, exposes an honest “Capture is not running yet” status, and can quit. M1 performs no pasteboard read and requests no TCC permission.

### Determinism services

`Clock` and `UUIDGenerating` are injected to make outputs stable. Tests use fixed implementations but do not assert interaction counts.

## M2 seams reserved by the approved architecture

- `CapturePolicy.evaluate(snapshotMetadata:)` before payload persistence;
- `SensitiveContentDetecting.classify(_:)` with local fixtures;
- `PasteboardMonitoring` against a fake client plus signed-host interoperability tests;
- `PasteDelivering` with retained target identity and copy-only fallback;
- `RetentionCleaning` through repository behavior;
- Quick Paste keyboard behavior through accessibility identifiers.

These tests begin only when each M2 vertical tracer begins.

## Red–green rule

For behavior work: add one failing public-seam test, verify the expected failure, implement only enough to pass, then continue with the next behavior. Broad refactoring occurs only after the tracer is green and reviewed.

## Color preview components

`ClipColorComponents.init?(text:)` is the pure public presentation seam for
HEX/RGB/HSL swatches. Test normalized RGBA values against known colors and
reject malformed/out-of-range values. It shares the transform parser; tests
do not reach into parser helpers. Capture classification is unchanged.

## Library inspector OCR status

`LibraryModel` owns the selected clip's observable OCR status. Tests use its
selection, presentation and observation methods with a fake repository and
an injected refresh wait. Cover pending → indexed/withheld, selection changes,
hidden inspectors, cancellation and unavailable jobs/errors. Assert displayed
state and completion, not read counts or private tasks. AppKit owns actual
window visibility; SwiftUI cancels the observation task when its identity or
presentation changes. Hosted SwiftUI tests bind the model's public observation
revision to `.task(id:)` and coalesce selection/presentation ABA changes without
manually starting another observer. A generous watchdog prevents a failed
restart from hanging CI; it is not a latency target. Signed preview checks
also exercise the real inspector task wiring. This is read-only presentation
work, not a new OCR or capture policy.

## Archive benchmark command (developer tooling)

`copyloom-archive-bench` is tested through its command-line interface against
synthetic JSONL corpora and temporary, on-disk libraries. Its smoke test checks
the report, round-trip content, re-import convergence and refusal to overwrite
an existing work directory. Its isolated verification phase also exercises
`ArchiveVerifier.verify(at:)` on approximately 1 MiB and 128 MiB archives in
fresh processes: a generous differential memory bound catches retained
read buffers, not machine-specific latency. It never imports implementation
details or opens GRDB records. `scripts/test-archive-bench.py` runs this seam
in CI; performance numbers come only from separate Release runs, not the
smoke/resource tests. `benchmark_process.run_command` is the developer-tool
subprocess seam: a real synthetic parent/descendant helper verifies timeout
cleanup and fixed diagnostics. The shared public `owned_process` scope also
owns asynchronous CLI fixtures through acquisition/teardown; scopes are
sequential, main-thread and non-nesting. A deterministic subprocess-boundary
fixture delivers SIGTERM just after creating a group but before returning its
handle. It also interrupts the enclosing owner before normal PID publication,
using independent atomic PID observation to check that no live work escapes.
Liveness is recorded before rescue cleanup, so fallback killing cannot mask
an ownership regression. Nested-owner fixtures use graceful, bounded teardown
before forced group cleanup; fallback PID metadata is published atomically.
A nested invocation signals the actual test CLI after its owned workload
initializes, checking SIGINT/SIGTERM
cleanup and exit codes. Handler installation belongs to the sequential
main-thread CLI, not arbitrary library callers. Benchmark reports also expose process-group
IDs so the CLI test checks that native worker launches remain in the runner's
owned group, rather than escaping group cancellation.

## Non-automatable evidence

TCC prompts, Accessibility revocation, cross-application focus, Spaces/full-screen behavior, secure fields, keyboard layouts and newer macOS Paste from Other Apps behavior require a signed manual matrix. Manual evidence is versioned; it is not reported as automated coverage.

## Visual preview (developer-only)

Layout and visual regressions are easy to miss from code and impossible to catch with unit tests. A DEBUG build can render its own surfaces without a screen:

```bash
# Build the signed Debug app the way scripts/run.sh does, but do not launch it:
xcodebuild -quiet -workspace Copyloom.xcworkspace -scheme Copyloom -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/RunDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -onlyUsePackageVersionsFromResolvedFile build

COPYLOOM_PREVIEW=1 .build/RunDerivedData/Build/Products/Debug/Copyloom.app/Contents/MacOS/Copyloom
```

The app must be signed (the sandbox needs its entitlements), so the unsigned `scripts/ci.sh` build cannot be used for this.

Preview mode:

- uses a separate `Copyloom-Preview` database seeded with obviously synthetic clips, so it never reads or writes real history;
- never starts clipboard capture or retention cleanup;
- runs a real export, then a real import of that export into a throwaway database through the production wiring (including the Vision image gate), twice, and offers it a hostile archive carrying the planted fake credential. Expect on stderr: `import first: added=N present=0`, `import second: added=0 present=N (idempotent=true)`, and `import hostile: added=0 refused=1 credentialStored=false`;
- renders the Library (list, cards, transform preview, image, colors, empty state), Quick Paste and Settings in light and dark, then quits;
- also renders `library-ocr-{pending,withheld,indexed}-{light,dark}` from a throwaway synthetic store without a background OCR worker, so each inspector state is stable;
- after the pending snapshot, coalesces hide/reopen on the real inspector and completes its job; expect `preview check ocr-coalesced-reopen-light: passed=true` and the dark equivalent. A failed hosted check exits nonzero. No test manually starts its replacement observer;
- renders `library-color-{rgb,hsl,cards}-{light,dark}` and `quickpaste-colors-{light,dark}` from a separate synthetic store, including HEX and alpha variants. `ownerCheck=pending` accessibility lines are not passes; VoiceOver/Accessibility Inspector must verify the `clip.color.swatch` labels;
- renders in-process (`NSHostingView` + `cacheDisplay`), so it needs no Screen Recording permission. PNGs land in the sandbox container's temporary directory (`~/Library/Containers/io.github.imrajyavardhan12.copyloom/Data/tmp/`) and the path is printed to stderr.

Known limits of in-process rendering: sidebar vibrancy, window chrome and toolbars are not drawn, and prominent buttons appear gray because the window is never key. Judge sidebar/toolbar changes in the real app. The code is `#if DEBUG` and absent from release builds.

Do not launch the app with `scripts/run.sh` for this: it starts the real app against the real database.
