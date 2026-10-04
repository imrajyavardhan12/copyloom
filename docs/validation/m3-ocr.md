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
