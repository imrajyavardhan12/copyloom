# Copyloom Benchmarks

Performance claims require reproducible evidence. Do not use private clipboard data.

## Deterministic corpus

Generate the standard 100,000-record textual fixture:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift run \
  --package-path Packages/CopyloomKit \
  -c release \
  copyloom-corpus \
  --records 100000 \
  --output Benchmarks/Results/corpus-100k.jsonl
```

The generator uses a fixed seed, stable timestamps and synthetic `.invalid` URLs. `Benchmarks/Results/` is ignored because generated corpora and machine-specific measurements do not belong in source control.

Reference output for the current generator at 100,000 records is 29,641,831 bytes with SHA-256 `a1f9783bf8101bbd50855e0ef8901aa56b8512246ec79cacf213aef79b6d53cf`. This detects accidental fixture drift; it is not a search-performance result.

## Required search benchmark report

Before the `<30 ms` warm-search target is claimed, the benchmark runner must record:

- Copyloom commit and Release build configuration;
- hardware, architecture, macOS, Xcode/Swift and SQLite versions/compile options;
- corpus count, byte/length distribution and generator seed/version;
- database, WAL and attachment sizes;
- one warm-up plus at least 30 measured samples;
- median, P95, P99, min/max and result-count checksum;
- rare/common/prefix/phrase/Unicode and filter-only queries;
- search while a bounded capture writer is active;
- peak RSS and CPU/energy observations.

M1 provides the deterministic corpus prerequisite. The database load/search runner arrives with the measured M2 search slice; no performance result is claimed yet.
