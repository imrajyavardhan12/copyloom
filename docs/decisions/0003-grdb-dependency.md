# ADR 0003: GRDB dependency

- **Status:** Accepted
- **Date:** 2026-08-21

## Decision

Use [GRDB.swift](https://github.com/groue/GRDB.swift) version **7.11.1**, exact-pinned through Swift Package Manager, as the only initial runtime dependency. `ClipStore` is the only module allowed to import GRDB. GRDB uses Apple's system SQLite; Copyloom does not bundle a database server or custom SQLite build.

## Evidence

- Upstream release: `v7.11.1`, published 2026-06-18.
- License: MIT; preserve the upstream notice in `THIRD_PARTY_NOTICES.md`.
- Local Apple SQLite: 3.51.0 with `ENABLE_FTS5`; functional FTS5/BM25 smoke test passed.
- Local toolchain: Xcode 26.6 (17F113), Swift 6.3.3.

## Why

GRDB materially reduces correctness risk for parameter binding, transactional migrations, serialized writes, WAL-backed read concurrency, error propagation, observations, online backup and FTS5 integration while retaining raw SQL control.

Direct `sqlite3` would require Copyloom to own and audit those facilities. SwiftData/Core Data do not provide the same explicit FTS5/schema/migration control needed for the 100k-record search target.

## Supply-chain policy

- Use an exact semantic version and commit generated `Package.resolved` files.
- Review lockfile diffs and upstream release notes before upgrades.
- Dependabot may propose updates; updates do not merge automatically.
- The app target does not add a second direct GRDB reference.
- Runtime behavior remains fully offline.
