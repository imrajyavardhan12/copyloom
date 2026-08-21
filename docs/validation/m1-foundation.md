# M1 Foundation Validation

_Date: 2026-08-21_
_Host: arm64 macOS 26.6.2_
_Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5_

## Automated checks

`./scripts/ci.sh` passed:

- strict `swift-format` lint;
- 9 Swift Testing tests across parser, database and repository seams;
- exact dependency resolution for GRDB 7.11.1 revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`;
- unsigned Debug app build through the shared workspace/scheme from deleted local build caches.
- Xcode static `analyze` completed successfully.

Storage tests exercised:

- migration 001 and idempotent reopen;
- WAL mode and FTS5 integrity command;
- on-disk accepted-text persistence and reopen;
- external-content FTS5 search;
- version-1 normalized dedup while preserving the first original text representation;
- corrupt database open failure without replacing the original bytes;
- FTS operator/quote escaping so user text cannot become executable MATCH syntax.

Parser tests exercised free terms, phrases, quoted app values, initial structured filters, URLs, and typed malformed quote/date errors.

## App-host checks

A locally ad-hoc-signed Debug app was built and launched. Observed:

- bundle ID `io.github.imrajyavardhan12.copyloom`;
- `LSUIElement = true`;
- minimum system version `14.0`;
- app sandbox entitlement present;
- no Team identifier and no paid signing credential;
- process remained alive during the menu-bar host smoke check;
- no clipboard access, TCC prompt or network behavior is implemented in M1.

A signing-disabled Release app compiled as a universal `x86_64 arm64` binary. This proves compilation, not execution on an Intel Mac or macOS 14.

## Corpus tooling

The Release corpus generator produced 100,000 deterministic synthetic JSONL records:

- bytes: `29,641,831`;
- SHA-256: `a1f9783bf8101bbd50855e0ef8901aa56b8512246ec79cacf213aef79b6d53cf`;
- generation wall time on this host: 2.25 seconds, including an already-cached 0.16-second build plan.

This is fixture-generation evidence only. No `<30 ms` database search claim has been made.

## Deferred evidence

- GitHub-hosted CI has not run because no remote repository has been created/pushed.
- macOS 14 runtime and Intel runtime tests have not run.
- Developer ID signing, hardened-runtime notarization and Mac App Store validation require future paid membership.
- Clipboard capture, global hotkey, Accessibility paste, Quick Paste and their TCC/manual matrix belong to M2.
