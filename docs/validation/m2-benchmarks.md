# M2 Search Benchmarks

_Date: 2026-09-07 · Commit `e15463d` · Release configuration_

_Status: measured. Representative classes pass; giant-match ranked sorts
missed in M2 and pass since bounded ranking (2026-11-28, last section)._

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

## Live-app measurements (2026-09-08, ad-hoc build `e42bb5`, Mac15,12)

- Panel warm-open over 16 user taps (`⌃⌘V` → `Esc`, bare and typed): window
  show median ~44 ms settling to ~25 ms warm; data load median ~3.5 ms
  (p95 17 ms). End-to-end open-to-usable ≈ 48 ms + one render frame ≈
  64 ms typical, under the ~100 ms instantaneous bar. Numeric-only `os_log`
  telemetry (`quickpaste panel-show` / `load-recent`), no content logged.
  Follow-up: reuse the hosting view instead of rebuilding it per open to
  shave ~20–40 ms off the show cost.
- Idle cost with clipboard untouched for 2 minutes: 0.0% CPU, +0.01 s process
  time over the window, 36 MB footprint, against the 0.5 s coalescing poll
  with 20% tolerance. Energy in mW not measured (no `powermetrics` run);
  ~zero CPU makes material energy impact unlikely.

## Prefix search and bounded ranking (2026-11-28, on `e7308d7`, Mac15,12)

From its second letter, each free search word now matches the words it
begins. It also matches as a whole word, which gives exact words a bm25 boost.
A search is ranked by `bm25` only when at most 5,000 clips match its text
(`AppDatabase.defaultRelevanceRankingLimit`, found with a capped count). Any
other search lists its matches like the history: pinned first, then newest
first. The contract is in `ARCHITECTURE.md` § Search architecture.

Environment: macOS 27.2.1 (26B131), Xcode 27.0 (27A266a), Swift 6.4,
SQLite 3.54.0, the same 100,070-record corpus, release, 30 samples after
5 warm-up, `LIMIT 100`. Match counts marked ≈ are twice those in the 50k
post-retention database the run leaves behind. All runs were made the same
day on this machine:

- *Whole-word* is the same tree with the old clause builder; prefix classes
  matched nothing in it.
- *All ranked* is the first prefix version, which ranked every search.
- *Final* is the one committed.

Times are p50 / p95 in ms.

| Query class | Matches | Whole-word | All ranked | Final |
|---|---|---|---|---|
| prefix-one-char (`c`) | 0 (no word "c") | — | 95.13 / 130.04 | 0.10 / 0.10 |
| prefix-two-char (`co`) | all | — | 111.09 / 113.23 | 9.79 / 10.11 |
| prefix-three-common (`pos`) | 66k | — | — | 6.49 / 6.75 |
| prefix-common (`postg`) | 66k | — | 76.10 / 77.24 | 8.30 / 8.39 |
| prefix-second-word (`postgres con`) | ≈46k | — | 66.23 / 67.28 | 9.75 / 10.17 |
| prefix-second-word-one-char (`postgres c`) | 0 | — | — | 1.92 / 1.96 |
| prefix-rare-second-word-one-char (`rare c`) | 0 | — | — | 0.14 / 0.14 |
| prefix-mid (`ite`) | 7.7k | — | 16.23 / 17.02 | 1.37 / 1.46 |
| prefix-short-rare (`ra`) | ≈100 | — | — | 0.62 / 0.64 |
| prefix-short-rare-app (`ra app:Safari`) | 34 | — | — | 0.37 / 0.39 |
| prefix-rare (`rare-mark`) | ≈100 | — | — | 0.70 / 0.72 |
| common-term (`postgres`) | 66k | 74.48 / 77.06 | 56.05 / 58.45 | 9.25 / 9.34 |
| mixed-term-filter | 22k | 53.81 / 79.89 | 56.69 / 59.19 | 9.35 / 9.58 |
| mid-term (`item`) | 7.7k | 16.84 / 17.61 | 14.00 / 14.68 | 1.51 / 1.53 |
| rare-term | 1 | 0.14 / 0.16 | 0.21 / 0.23 | 0.18 / 0.18 |
| phrase | 50 | 0.41 / 0.42 | 0.39 / 0.41 | 0.47 / 0.52 |
| unicode-term | 20 | 0.17 / 0.19 | 0.19 / 0.19 | 0.22 / 0.23 |
| filter-only and timeline | 100–100k | 0.40–0.48 | 0.40–0.49 | 0.38–0.49 |

- Search under the 300-write concurrent load: p95 10.17 ms, against 84.02 ms
  in the whole-word run.
- **Verdict: every class passes `<30 ms` p95, the first run where the runner
  reports `verdict30ms=true`.** The slowest p99 is 10.31 ms. That includes the
  giant-match classes left open above: no ranked search sorts more than 5,000
  matches.
- **Why the bound.** Ranking sorts the whole match set before `LIMIT`. Every
  search starts with a short word, and a word like `co`, `htt` or `the`
  matches most of a real history. Relevance among more than a few thousand
  matches says little, so such searches list like the history. That is a walk
  of `clips_timeline` that keeps the clips in the `MATCH` set and stops at a
  full page. The capped count (`LIMIT 5001`) cost about 2 ms in the SQLite
  shell on the 50k database.
- **Why one letter matches only the whole word.** No prefix index serves a
  one-letter prefix, and it begins most words. In the shell it cost 7 ms to
  count and 12 ms per page for `c`, and 26 ms in all for `postgres c`. Typing
  the next letter brings prefix matching back.
- **The worst case of the history page** is a word over the limit whose page a
  filter keeps from filling, so the whole index is walked. In the shell, `c*`
  with a date filter leaving few rows took 12.4 ms against 20.1 ms ranked.
- **Trade-off:** a word matching more than 5,000 clips no longer ranks by
  relevance. `item` (7.7k here) lists newest first. The count looks at the
  text only, so `postgres tag:work` lists newest first even when the tag
  leaves a few clips.
- **Matching the whole word too costs nothing measurable.** "Whole word OR
  prefix" measured the same as prefix only (`postg` 26.5 against 31.0 ms,
  `co` 58.6 against 60.7 ms, in the shell). It is a bm25 boost, not a
  guarantee: a short clip with several words starting with the term can still
  outrank a long clip with the exact word.
