# M3 Slice 4 Validation — Searchable OCR

_Date: 2026-09-09 · Base commit `16ccd59`; landed as `cf653e6`_
_Status: implemented, tested, bench-measured. Owner screenshot evidence
**still pending**: `cf653e6` was committed before the three checks in
§Live evidence were run, so the original commit gate was not met. Treat the
OCR feature as unverified in the real app until each check below records a
result._

## Implemented behavior (ADR-0005 §3–4)

- **Migration 006** (`006_ocr_search`): adds **only** the `ocr` column to
  `search_documents`, rebuilds `clip_fts` as `fts5(body, ocr, applications)`
  with the same tokenizer/prefixes (002 is the template), and creates
  `image_ocr_jobs(clip_id PK, status, attempts, updated_at)` with a
  `(status, updated_at, clip_id)` claim index. Pre-OCR image clips backfill
  as pending; text clips get no jobs.
- **Background queue** (`ImageOCRQueue`, ClipboardCapture target): serial,
  `.background` priority, cancellable, crash-resumable (jobs are marked only
  after a scan completes, so interruptions stay pending). Started once from
  `AppModel`, cancelled on shutdown, polling every 5 s.
- **Quarantine**: detector finding *or* the OCR-tolerant PEM check withholds
  the text entirely (any indexed text is cleared); pixels stay; the clip
  stays findable by `type:`/`app:` but never by content. Recognizer errors,
  undecodable bytes and missing files bump attempts; past 3 attempts the job
  quarantines instead of failing open. Inspector shows an orange
  “Image text withheld” banner with one-tap Delete; pending shows an
  indexing note.
- **`has:ocr` filter**: repository implements it as `search_documents.ocr <>
  ''` (indexed non-empty OCR only). Blank scans index empty text and stay
  out of the filter by design.

## Automated evidence

- `scripts/ci.sh` green: swift-format, full package suite, unsigned app build.
- New: `OCRSearchTests` (11 — enqueue, indexed search/`has:ocr`,
  quarantine withholding + metadata findability, blank scans, withhold
  clearing, dedup state retention, delete/expiry job shedding, attempt
  counts, rebuild survival, 005→006 backfill) and `ImageOCRQueueTests`
  (9 — clean index, detector quarantine, mangled-PEM quarantine, retry→
  withhold, blank scan, undecodable bytes, drain, deleted-clip skip, empty
  queue), plus a Library quarantine passthrough test.

## Bench evidence (release, Mac15,12, 100,070 records)

- **FTS rebuild at full corpus: 0.71 s.** One-time inside migration 006 —
  fast enough to run synchronously; no background-migration machinery needed.
- Result checksum **29130**, identical to the M2 record: text search behavior
  is unchanged by the added column.

## Inspector refresh follow-up (2026-11-01)

The inspector previously read status only when selection changed. It now
observes the selected image while its Library window is visible, reading at
most once per second while pending, and stopping on indexed/withheld/missing
jobs. Close, hide, minimize or fully occlude the window to stop refresh work;
showing it again reads fresh state. The OCR worker itself is unchanged.

`LibraryModel` owns status, unavailable-state feedback and a stale-read
generation token. A separate observable selection/presentation revision keys
SwiftUI's observer task, so coalesced A → B → A or visible → hidden → visible
changes still restart observation. Starting an observer does not change its
task identity. Cancelled or superseded reads cannot paint another image's
status. Read failures show "Image text status unavailable" rather than implying
indexing completed. Select another clip and return, or reopen the Library, to
retry.

Automated evidence:

- Nine new public-model tests (two parameterized) cover pending → indexed /
  withheld without reselection, selection clearing, late replies after
  selection or reopen, cancellation (including an already-cancelled observer
  trying to replace the current one), hidden/non-image inspectors, disappearing
  jobs and storage errors. Tests use controlled continuations, not time bounds
  or repository call counts.
- Hosted SwiftUI regressions coalesce selection and visibility ABA changes
  without manually starting a replacement observer. Both failed to reach
  withheld before the task-revision fix and pass afterward; their generous
  deadline is a failure watchdog, not a latency target.
- Local combined `./scripts/ci.sh`: 351 Swift tests and nine archive CLI/resource
  checks passed, with strict format lint and unsigned app build.
- Signed Debug preview rendered `library-ocr-{pending,withheld,indexed}-{light,dark}.png`
  from a throwaway synthetic store, with no OCR worker racing its states.
  All six images were inspected: pending shows the note/spinner, withheld
  shows the orange warning and Delete action, indexed has neither banner.
- The same preview's production-wired export/import checks emitted:
  `import first: added=19 present=0`,
  `import second: added=0 present=19 (idempotent=true)`, and
  `import hostile: added=0 refused=1 credentialStored=false`.

The signed preview also mounts the actual Library inspector on a pending
image, coalesces hide/reopen and completes the job through the repository seam.
It emits `preview check ocr-coalesced-reopen-light: passed=true` and the dark
equivalent. Restoring the old clip-ID/visibility task key made both checks
fail and preview exit 1; restoring the revision key made both pass. Failed
hosted checks exit nonzero, and snapshot windows close afterward to cancel
their tasks.

This does **not** satisfy the real capture/recognition checks below. Additional
owner checks, still pending: leave a pending image selected until indexing
finishes (note disappears or becomes the withheld warning without reselection);
switch images mid-scan (no old image's warning appears); hide/minimize and
reopen the Library (fresh status for the current selection). Record failures
here rather than treating model/preview evidence as live-window evidence.
Rebuilding the signed Debug app invalidated its prior ad-hoc Accessibility
identity; grant it once again before also testing automatic paste.

## Live evidence (owner, required before commit)

Rebuild invalidates the ad-hoc signature: re-grant Accessibility for the new
binary (System Settings → Privacy & Security → Accessibility; the running-app
path is in the Copyloom menu diagnostics), then capture each probe and check
the Library inspector + search:

1. **Clean** (e.g. screenshot of Terminal output): inspector shows no
   banner, searching a visible word finds the image, `has:ocr` lists it.
2. **Secret-bearing** (e.g. a `PASSWORD=…` line or PEM header on screen):
   capture gate may already refuse it; if it persists, the inspector shows
   the orange withheld banner, searching the secret finds nothing, `has:ocr`
   excludes it, `type:image` still lists it, Delete removes it.
3. **Blank** (plain wallpaper crop): inspector shows no banner, `has:ocr`
   excludes it, `type:image` lists it.
