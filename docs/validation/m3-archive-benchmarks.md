# M3 Slice 6 — Archive Scale Measurements

_Date: 2026-10-31 · Base `88d4d0341d35eb8f7423e4e771a863c62737fab3`
plus the benchmark/memory-fix patch · Release configuration_

_Status: measured. This closes the automated 100k scale-evidence gap, **not**
the owner sandbox/Finder acceptance checks in [m3-export-import.md](m3-export-import.md).

## Environment and fixture

- MacBook Air, Mac15,12, arm64, 8 CPUs; sequential runs, no concurrent build/test load.
- macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`).
- System SQLite 3.54.0, WAL, production `AppDatabase` configuration (`synchronous=FULL`).
- Standard corpus: 100,000 input records, 29,641,831 bytes, seed `0xC0FFEE12345678`,
  SHA-256 `a1f9783bf8101bbd50855e0ef8901aa56b8512246ec79cacf213aef79b6d53cf`.
- **100,000 live clips, not just input lines.** The standard corpus contains
  125 exact duplicate texts and otherwise seeds only 99,875 live clips.
  This archive-only profile appends `\narchive-sequence-<zero-based index>` to
  every input text (`archive-sequence-v1` in the report), then runs the real
  text gate. The shared corpus and historical search baselines are unchanged.
- Sources rotate Safari/Ghostty/Preview. Every 1,000th clip is pinned,
  tagged and placed in one collection, with a recorded use; every 1,500th is
  favorited. One saved query is included. No real clipboard/history is used.
- Retention cleanup and background OCR workers do not run. Import uses a
  fixed time after the fixture timestamps, with no retention cutoff.

## Measurement method

`copyloom-archive-bench` runs each phase in a fresh process. Setup loads the
corpus and seeds both the source and an empty target, but its memory/time is
**excluded**. Correctness re-exports are also separate, unmeasured processes.

- **Export:** production database-backed source, text gate and archive writer.
- **Verify:** standalone diagnostic pass; no clip JSON decoding or import.
- **Plan / apply:** each independently verifies the archive again, matching
  `LibraryImportWiring`; both run the real text/image gates and production sink.
- **Re-import:** independently verifies and applies to the populated target.
- `seconds` includes database open/count/close around the phase. Separate
  verification and operation timings are also reported. `peakRSSBytes` is
  macOS process-lifetime `getrusage` RSS; CPU is process CPU, not energy.
- Filesystem caches are warm after setup/export. These are not cold-disk
  measurements. Process startup is excluded from wall time but contributes
  to lifetime RSS/CPU. DB/WAL sizes are sampled before close/checkpoint.
- Swift/Xcode version fields describe runtime-selected tools, not embedded
  compiler provenance.
- Three independent complete runs at 100k and for the image profile; one
  10k scale probe. Report medians and ranges, **not** P95 from three samples.

## 100k text results (after the memory fix)

| Phase | Median wall time | Range | Median peak RSS | Maximum peak RSS | Median CPU |
| --- | --- | --- | --- | --- | --- |
| Export | 24.689 s | 24.649–24.717 s | 36.31 MiB | 36.33 MiB | 24.676 s |
| Verify only | 0.060 s | 0.060–0.061 s | 13.77 MiB | 13.78 MiB | 0.063 s |
| Verify + plan | 16.951 s | 16.921–16.963 s | 18.47 MiB | 18.59 MiB | 16.955 s |
| Verify + apply | 29.507 s | 29.462–29.645 s | 35.30 MiB | 35.36 MiB | 28.442 s |
| Verify + re-import | 18.181 s | 18.178–18.215 s | 31.41 MiB | 31.44 MiB | 18.159 s |

- Complete new-library import (plan + apply, excluding the confirmation
  wait): **46.470 s median**. Standalone diagnostic verification is not added
  again; both user-facing phases already include verification.
- Export throughput: approximately 4,050 clips/s; apply including verification:
  approximately 3,389 clips/s.
- Archive: **66,487,773 bytes (63.41 MiB)**; no skipped/rejected records.
- Representative source DB: 126,615,552 bytes (120.75 MiB), WAL 943,512 bytes
  (0.90 MiB). Target after apply: same DB bytes, WAL 3,193,032 bytes (3.05 MiB).
- All three runs: plan adds 100,000 while leaving target count at zero;
  apply adds 100,000; re-import adds zero and merges 100,000.
- Re-exports after apply and re-import match **every logical file's size and
  digest**, including `clips.jsonl` and `library.json`, with equal manifest
  counts and passing FTS integrity. This is logical archive equivalence,
  not a claim that SQLite/WAL files are byte-identical.

Raw reports: ignored `Benchmarks/Results/archive-100k-20261031-r{8,9,10}/report.json`.

## Finding and fix: temporary read buffers grew with the archive

The initial measurement exposed archive-sized retention in
`ArchiveHashing.scan`: Foundation's `FileHandle` read buffers could remain
autoreleased for the whole synchronous scan, despite reading in 1 MiB chunks.
This affected both verification and export's final hashing.

A regression through the command's verification phase compares fresh processes
scanning approximately 1 MiB and 128 MiB archives. Before the fix, the larger
file added **133,840,896 bytes (127.64 MiB)** of peak RSS. A per-read
`autoreleasepool` now releases those temporary buffers. Re-running the same
probe measured **15.09 / 15.14 MiB** (0.05 MiB difference).

The CI test allows a generous 64 MiB differential, rather than asserting
machine-specific absolute RSS or timing. Integrity checks, line statistics,
file access, limits and privacy policy are unchanged.

| 100k phase | Before median peak RSS | After median peak RSS |
| --- | --- | --- |
| Export | 92.28 MiB | 36.31 MiB |
| Verify + plan | 82.27 MiB | 18.47 MiB |
| Verify + apply | 96.83 MiB | 35.30 MiB |
| Verify + re-import | 93.17 MiB | 31.41 MiB |

Before reports: `archive-100k-20261031-r{5,6,7}`. Timings were essentially
unchanged. This is a buffer-lifetime fix, not weakened scanning or a new cache.

## 10k scale probe

First 10,000 records of the same corpus, with the same suffix and metadata
rules; SHA-256 `94865d94fb3474faca15fc924ae38189be68fb5779b61336560af982cd3cf4d1`.
Archive: 6,634,172 bytes. One run, not a statistical latency baseline.

| Phase | Wall time | Peak RSS |
| --- | --- | --- |
| Export | 1.687 s | 22.05 MiB |
| Verify only | 0.013 s | 13.77 MiB |
| Verify + plan | 1.699 s | 18.19 MiB |
| Verify + apply | 2.733 s | 28.14 MiB |
| Verify + re-import | 1.801 s | 21.42 MiB |

Verification and planning memory no longer track the clips file's size.
Export/import still have SQLite caches, UUID sets and relationship metadata;
these measurements do not establish constant memory for all possible archives.
Export time grows more than 10× between 10k and 100k: keep this as a scaling
observation, not an unsupported claim of linear throughput or a reason for a
speculative schema/ranking change.

Raw report: `Benchmarks/Results/archive-10k-20261031-r3/report.json`.

## Separate real-Vision image profile

100 textual fixtures (first 100 corpus records) plus 12 distinct synthetic
1024×768 PNG cards with fixed non-sensitive captions. Production
`ImageAcceptanceGate` + `VisionImagePreflight` are used during setup, planning,
apply and re-import. No stub recognizer or permissive image gate.

| Phase | Median wall time | Range | Median / maximum peak RSS |
| --- | --- | --- | --- |
| Export | 0.035 s | 0.032–0.037 s | 14.48 / 14.50 MiB |
| Verify only | 0.009 s | 0.009–0.012 s | 13.12 / 13.14 MiB |
| Verify + plan | 0.929 s | 0.799–1.014 s | 66.19 / 69.66 MiB |
| Verify + apply | 0.910 s | 0.866–1.000 s | 64.19 / 66.41 MiB |
| Verify + re-import | 0.996 s | 0.879–1.106 s | 72.58 / 72.62 MiB |

Archive: 391,941 bytes. All 112 clips and 12 attachments round-trip;
12 pending background OCR jobs after import, still 12 after re-import.
No derived OCR queue throughput is claimed. These small captioned cards do
**not** represent large screenshots or demonstrate OCR accuracy/privacy recall.
An initial uniform-colour, uncaptioned fixture was refused by the existing
image gate; it was not bypassed. Owner clean/secret/blank checks stay pending
in [m3-ocr.md](m3-ocr.md).

Raw reports: `Benchmarks/Results/archive-images-20261031-r{6,7,8}/report.json`.

## Worker lifetime and 100k follow-up (2026-11-01)

_Lifecycle checks last verified 2026-11-03; the performance spot check below
was measured on 2026-11-01._

On macOS, Foundation `Process` put launched workers in separate process groups,
so killing only the Python-owned group left work running. `BenchmarkProcess`
now uses `posix_spawn` to preserve the orchestrator's group for phases and
version probes, with distinct phase PIDs, deliberate standard-I/O redirection,
closed unrelated descriptors and child reaping.

The sequential main-thread CLI shares `owned_process` acquisition/teardown
between normal commands and asynchronous fixtures. Timeout and handled
SIGINT/SIGTERM stop the owned group, drain pipes and reap before temporary-file
cleanup. Signals during acquisition/cleanup are deferred until ownership is
safe; interrupted CLI exits are 130/143. Diagnostics contain no arguments or
paths. SIGKILL cannot be handled.

Public-boundary regressions verify:

- A synthetic descendant survived the old timeout path but stops with group
  cleanup. All five measured workers retain the parent's group; this check
  failed against the Foundation launcher and passes with the native launcher.
- SIGINT/SIGTERM sent to the actual test CLI after workload readiness leave no
  live parent/descendant, return 130/143 and expose no command-path diagnostics.
- SIGTERM delivered immediately after creating a group, before returning its
  handle, left live work with unguarded acquisition. The shared ownership scope
  now kills/reaps it and exits 143. Interrupting the enclosing fixture before
  normal PID publication also exposed an orphan under forced caller teardown;
  graceful nested-owner teardown now passes both SIGINT/SIGTERM cases. Atomic
  PID metadata prevents partial-publication cleanup errors. Liveness is recorded
  before rescue cleanup; disabling acquisition deferral makes all three cases
  fail, including the direct case that rescue previously masked. Restoring the
  guard passes, with no synthetic child left running.

One additional Release run with this launcher verifies 100,000 live clips,
logical round-trip fidelity, zero-addition re-import and matching worker/parent
group IDs. This is a spot check, not a replacement for the three-run baseline.

| Phase | Wall time | Peak RSS |
| --- | --- | --- |
| Export | 24.552 s | 36.25 MiB |
| Verify only | 0.060 s | 13.81 MiB |
| Verify + plan | 16.848 s | 18.50 MiB |
| Verify + apply | 29.451 s | 35.36 MiB |
| Verify + re-import | 18.058 s | 31.44 MiB |

Raw report: `Benchmarks/Results/archive-review-fixes-20261101/report.json` (ignored).

## Verification and remaining acceptance

- Red–green CLI test for the initial command, duplicate-text scale semantics,
  resource-report fields and standalone verification; public archive artifacts
  are independently hashed by the smoke test.
- Red–green 1 MiB versus 128 MiB verification memory regression; normal CI
  also checks command failure/redaction and non-overwrite behavior.
- Local combined `./scripts/ci.sh` (2026-11-03): **351 Swift tests across seven
  runners and nine CLI/resource checks passed**, strict formatting and unsigned
  app build passed. Representative emitted lines: `Test run with 102 tests in
  18 suites passed` and `Copyloom checks passed.` Hosted Xcode 16.4/Swift 6.1
  and CodeQL tracing have not been run for this patch.
- Reproduce using [Benchmarks/README.md](../../Benchmarks/README.md).
  Intermediate generated stores/archives were cleaned up; JSON reports are
  retained, along with the complete final 100k run (`r10`).
- No new permissions, dependencies in the app, persisted types or schema.
- No live clipboard, real history, permission prompt or cross-app paste was
  exercised. Owner archive, OCR and Paste Queue validation remains open.
