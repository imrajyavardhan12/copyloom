# M2 Search Benchmarks

_Date: 2026-09-07 · Commit `e15463d` · Release configuration_

_Status: measured. Representative classes pass; giant-match ranked sorts miss
— see verdict._

## Environment

- MacBook Air, Mac15,12, arm64, 8 CPUs
- macOS 26.6.2 (25G83), Xcode 26.6 (`DEVELOPER_DIR`), Swift 6.3.2
- SQLite 3.51.0, WAL, Apple system build
- Corpus: deterministic 100,070 records (100,000 generator fixtures at seed
  `0xC0FFEE12345678` + 50 phrase probes + 20 Unicode probes),
  SHA-256 `a1f9783b…`, 29.6 MB JSONL
- Machine report: `Benchmarks/Results/report.json` (git-ignored, reproducible
  via `Benchmarks/README.md`)

## Results (30 measured samples after 5 warm-up, `LIMIT 100`)

| Query class | Matches | p50 | p95 | p99 |
|---|---|---|---|---|
| rare-term | 1 | 0.25 | 0.27 | 0.32 |
| unicode-term | 20 | 0.23 | 0.23 | 0.23 |
| phrase | 50 | 0.45 | 0.48 | 0.49 |
| pinned / type / date filters | 100–100k | 0.46–0.46 | 0.47–0.51 | 0.48–0.55 |
| app: filter | 33k | 0.54 | 0.56 | 0.60 |
| recent timeline | 100k page | 0.45 | 0.47 | 0.47 |
| mid-term (`item`, 7.7k matches) | 7.7k | 13.87 | 14.68 | 14.79 |
| mixed term+filter | 22k ranked | 41.01 | 41.50 | 41.70 |
| common-term (`postgres`, 66k matches) | 66k | 51.52 | 52.14 | 52.81 |

- Search under a 300-write concurrent load: p95 54.65 ms (common-term)
- Result checksum across samples: 29130 (deterministic)
- Load: 100,070 records in 39 s (2,527/s, release)
- Dedup re-save ×1,000: 2,976/s
- Retention expire (~50k rows): 0.36 s · purge: 0.26 s
- DB 112 MiB (+19 MiB WAL pre-checkpoint) · peak RSS 129 MiB · process CPU 40 s

## What moved during this slice

Two findings, both fixed and re-measured:

1. **Bare `app:` filter: 87 ms → 0.56 ms.** The per-row `EXISTS` with
   `instr()` string matching ran on every visited clip. Application
   substrings now resolve to IDs once against the tiny applications table;
   the hot path probes the source index with an `IN` list.
2. **Timeline-order pages: 50 ms → 0.5 ms.** Without table statistics the
   planner built a full sort for the bare timeline query while a
   kind-filtered twin walked the index — identical `EXPLAIN QUERY PLAN`
   summaries, different bytecode (verified `Sort`/`OpenEphemeral` vs indexed
   walk with early stop). Non-FTS pages now pin `INDEXED BY clips_timeline`;
   a top-N timeline page must always walk that index, and the force fails
   loudly if the index is renamed. FTS pages keep planner freedom.

## Verdict vs the `<30 ms` target

**10 of 13 classes pass, most under 1 ms.** The 3 misses share one cause:
ranking the full match set with `bm25` before `LIMIT`. Our corpus vocabulary
is 20 words, so any single common term matches ~two-thirds of history —
adversarial by construction, not representative. The realistic common-term
proxy (`item`, 7.7k matches) passes at 14.68 ms p95.

No plan trick removes the giant-match sort without changing ranking
semantics, so this stays open as a product decision, not a tuning task.
Options, in order: (a) accept — as-you-type `AND` narrowing shrinks match
sets per keystroke in real use; (b) two-phase retrieval with a documented
ranking contract change; (c) larger-vocabulary corpus profile to right-size
the "common" definition. Recommendation: (a) for M2, revisit with Library
relevance work.

## Not covered here

- Quick Paste warm-open timing and unchanged-monitor CPU/energy: need a
  signed running app + Instruments; manual protocol to follow (no code).
- Cross-machine comparison: baselines are this-machine only per the
  regression policy; rerun, don't compare across hardware.
