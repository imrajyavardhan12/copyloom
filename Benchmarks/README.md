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

The runner is `copyloom-bench` (`Packages/CopyloomKit/Sources/CopyloomBenchmarks/`).
It loads the corpus plus fixed probe documents, resolves rotating sources,
warm-loads, then reports load/dedup/retention throughput, per-class latency
(median/P95/P99, 30 samples after 5 warm-up), result checksums, DB/WAL sizes,
peak RSS and a `<30 ms` verdict. `Benchmarks/Results/` stays ignored; the
interpreted record lives in `docs/validation/m2-benchmarks.md`.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift run \
  --package-path Packages/CopyloomKit \
  -c release \
  copyloom-bench \
  --corpus Benchmarks/Results/corpus-100k.jsonl \
  --workdir Benchmarks/Results/bench-work \
  --output Benchmarks/Results/report.json \
  --commit "$(git rev-parse HEAD)"
```

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

2026-09-07: measured in `docs/validation/m2-benchmarks.md` (Mac15,12, 100,070
records, release). 10 of 13 classes pass, most under 1 ms; giant-match `bm25`
sorts over the adversarial 20-word-vocab corpus miss and stay open as a
product decision. Two fixes landed from the numbers: app-filter ID
pre-resolution (87 ms → 0.56 ms) and pinned timeline-index walks for
non-FTS pages (50 ms → 0.5 ms).

## Archive export/import

`copyloom-archive-bench` is separate from the search runner: that runner holds
its input fixtures in memory and later expires part of the library. Neither
is appropriate when measuring archive phase RSS or claiming 100k live clips.

After generating the standard corpus above:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift build --package-path Packages/CopyloomKit \
  --scratch-path .build/SwiftPM -c release --product copyloom-archive-bench
BIN_DIR="$(xcrun swift build --package-path Packages/CopyloomKit \
  --scratch-path .build/SwiftPM -c release --show-bin-path)"
"$BIN_DIR/copyloom-archive-bench" \
  --corpus Benchmarks/Results/corpus-100k.jsonl --records 100000 \
  --workdir Benchmarks/Results/archive-100k-run1 \
  --commit "$(git describe --always --dirty)"
```

The parent of `--workdir` must exist, but the directory itself must **not**.
The command refuses reuse rather than deleting files. It writes `report.json`
inside the work directory and prints only a fixed success/failure line with
counts or reason codes. Failed runs leave their synthetic artifacts for
inspection; use a new directory for the next run. Never use private history.

Setup, export, verify, verify+plan, verify+apply, correctness re-export,
verify+re-import and final re-export run in separate processes. Setup and
correctness work do not inflate phase timings or peak RSS. Plan and apply
each verify independently, as the app does. A report is published only after
live counts, all logical archive-file digests, FTS integrity and re-import
convergence pass. No retention cleanup or background OCR worker is started.

The input has 125 exact duplicate texts at 100k. An archive-only, versioned
uniqueness suffix ensures **100k live clips** while leaving the shared search
corpus unchanged. The report identifies the original corpus hash, suffix,
text/image counts, base commit, build/toolchain/hardware/OS/SQLite, phase
process/group IDs, wall/CPU times, peak RSS, archive size and DB/WAL sizes.
Workers and version probes explicitly inherit the orchestrator's process group;
CLI checks launch an owned session and terminate that entire group on timeout
or handled SIGINT/SIGTERM, with a fixed diagnostic and reaping before artifact
cleanup (SIGKILL cannot be handled). Runtime-selected
tool versions are not embedded compiler provenance. Use three
or more sequential Release runs and report median/range; do not call three
samples P95. Do not run builds/tests concurrently with measurements.

For a separate small image profile (real Vision, not a fake gate):

```bash
head -n 100 Benchmarks/Results/corpus-100k.jsonl > Benchmarks/Results/corpus-100-archive.jsonl
"$BIN_DIR/copyloom-archive-bench" \
  --corpus Benchmarks/Results/corpus-100-archive.jsonl --records 100 --images 12 \
  --workdir Benchmarks/Results/archive-images-run1 \
  --commit "$(git describe --always --dirty)"
```

Images are generated 1024×768 cards, not screenshots; a refused image aborts
rather than bypassing privacy screening. The phase protocol (`--phase verify`
with an existing marked work directory) also permits isolated verification
probes without decoding or importing clip records.

The CLI smoke/resource tests use only temporary synthetic files and run in
`./scripts/ci.sh` via Python 3. They are correctness checks, not performance
baselines. Measurements, the read-buffer memory fix and the cancellation-safe
launcher's 100k follow-up are recorded in
[`docs/validation/m3-archive-benchmarks.md`](../docs/validation/m3-archive-benchmarks.md).
Owner sandbox/Finder acceptance remains separate.
