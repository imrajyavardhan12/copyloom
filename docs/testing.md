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
- renders in-process (`NSHostingView` + `cacheDisplay`), so it needs no Screen Recording permission. PNGs land in the sandbox container's temporary directory (`~/Library/Containers/io.github.imrajyavardhan12.copyloom/Data/tmp/`) and the path is printed to stderr.

Known limits of in-process rendering: sidebar vibrancy, window chrome and toolbars are not drawn, and prominent buttons appear gray because the window is never key. Judge sidebar/toolbar changes in the real app. The code is `#if DEBUG` and absent from release builds.

Do not launch the app with `scripts/run.sh` for this: it starts the real app against the real database.
