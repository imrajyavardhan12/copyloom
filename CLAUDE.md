# Copyloom

A local-first, privacy-first clipboard workspace for macOS: Swift 6 (strict concurrency), SwiftUI with focused
AppKit, SQLite + FTS5 through GRDB, sandboxed menu-bar agent. Most logic lives in `Packages/CopyloomKit`; the app
target in `App/` stays thin.
How to contribute (workflow, privacy rules, dependencies): @CONTRIBUTING.md
Read `ARCHITECTURE.md` and `THREAT_MODEL.md` before changing capture, storage, paste or permissions, and
`docs/testing.md` for which seams tests may use. Decisions are ADRs in `docs/decisions/`.

## Checks

- `./scripts/ci.sh`: swift-format lint (strict), CopyloomKit tests, unsigned app build (~15 s incremental).
  Run it after every change and quote the result (`Test run with N tests … passed`, `Copyloom checks passed.`).
- `./scripts/format.sh` fixes formatting. `./scripts/run.sh` builds the signed Debug app and relaunches a single
  instance; `./scripts/check-menu-bar.sh` then checks its menu-bar item.

## Proving a change works

- Behaviour work is red–green at a public seam (`docs/testing.md`): add one failing test, watch it fail, then fix.
  Never test private functions, GRDB records or call counts.
- UI: render it with preview mode instead of guessing. Build as `docs/testing.md` § Visual preview shows, then run
  `COPYLOOM_PREVIEW=1 .build/RunDerivedData/Build/Products/Debug/Copyloom.app/Contents/MacOS/Copyloom`.
  It renders the Library, Quick Paste and Settings in light and dark from synthetic clips (it never touches real
  history), prints the PNG folder to stderr, and runs export/import round trips whose expected stderr lines are
  in `docs/testing.md`. Look at the PNGs.
- Hot paths (capture, search, OCR, import): bring benchmark numbers (`Benchmarks/`); see `docs/validation/`.
- TCC prompts, Accessibility, cross-app paste and secure fields can't be automated. Give the maintainer a short
  manual checklist with expected results, and record outcomes in `docs/validation/`.
- Never log or print clip content, queries, OCR output or file paths, including in tests and debug output.
