# Copyloom

Local-first, privacy-first clipboard workspace for macOS: Swift 6 (strict concurrency), SwiftUI with focused
AppKit, SQLite + FTS5 through GRDB, sandboxed menu-bar agent. Logic lives in `Packages/CopyloomKit`; `App/` stays
thin. Before changing capture, storage, paste or permissions, read `ARCHITECTURE.md` and `THREAT_MODEL.md`.
Decisions are ADRs in `docs/decisions/`.

## Commands

- `./scripts/ci.sh`: strict swift-format lint, CopyloomKit tests, unsigned app build (~15 s incremental)
- `./scripts/format.sh`: fix formatting
- `./scripts/run.sh`: build the signed Debug app and relaunch a single instance; `./scripts/check-menu-bar.sh`
  then checks its menu-bar item

## Verify before you say done

- Every change: `./scripts/ci.sh`. Quote `Test run with N tests … passed` and `Copyloom checks passed.`
- Behaviour work is red–green at a public seam: add one failing test, watch it fail, then implement. Tests use
  only the seams in `docs/testing.md`; never private functions, GRDB records or call counts.
- UI: render it instead of guessing. Build the signed Debug app as `docs/testing.md` § Visual preview shows, then
  run `COPYLOOM_PREVIEW=1 .build/RunDerivedData/Build/Products/Debug/Copyloom.app/Contents/MacOS/Copyloom`. It
  renders the Library, Quick Paste and Settings in light and dark from synthetic clips, prints the PNG folder,
  and runs export/import round trips whose expected stderr lines are in `docs/testing.md`. Look at the PNGs.
- Hot paths (capture, search, OCR, import): bring numbers from `Benchmarks/`; see `docs/validation/`.
- TCC prompts, Accessibility, cross-app paste and secure fields can't be automated: give the maintainer a short
  checklist with expected results, and record outcomes in `docs/validation/`.

## Rules

- Capture policy runs before persistence, FTS, thumbnails and logs.
- Never log or print clip content, search queries, OCR output, secrets or raw file paths, including in tests.
- No network behavior, telemetry, broad permissions or new persisted content types without a design/security
  review. GRDB is the only runtime dependency; a new one needs the written justification in CONTRIBUTING.md.
- Permission-gated features keep a useful fallback.
- Conventional commit messages (`feat:`, `fix:`, `docs:`).
