# M3 Slice 6 Validation — Export / Import Library

_Base commit `ed9ebc7` (export `4658735`, import `cfb6387`)_
_Status: implemented and tested; the DEBUG preview run exercises export and
import end-to-end against a synthetic library. Owner click-through evidence
**still pending**: sandbox folder grants are only observable in the signed app
with real panels, so slice 6 stays open until every check below records a
result._

## What is already proven without the owner

- `scripts/ci.sh` green (all test targets, format lint, unsigned app build);
  hosted CI and CodeQL green on `ed9ebc7`.
- Preview mode (`COPYLOOM_PREVIEW=1`, see `docs/testing.md`) exports through
  the production wiring, verifies the archive, confirms a planted fake
  credential is absent, then imports it twice into a clean library (the
  second run changes nothing) and refuses a hostile archive.
- Package tests cover tamper, path safety, limits, export policy, idempotent
  import, merge rules, UUID collisions, gates, resume and the retention count
  (`docs/archive-format.md`, Test plan).

## What only the owner can show

Real `NSOpenPanel` grants under the sandbox, a real library, Finder, and
alerts as a person reads them.

## Setup

1. Build and run the signed Debug app (rebuilding invalidates the ad-hoc
   signature, so re-grant Accessibility if you want Quick Paste to paste).
2. Have a real library with: at least one pinned clip, one favorite, a tag,
   a collection, an image clip, and (if you can) a Smart Collection.
3. Make an empty destination folder, for example `~/Desktop/export-test`.

Record the result of each check as **pass**, **fail** or **n/a** with a
sentence of what you saw.

## A. Export

| # | Do | Expect |
| --- | --- | --- |
| A1 | Library toolbar **··· → Export Library…** | Alert “Export Library?” says the export is **not encrypted**, that anyone who can open the folder can read the clips, and that sensitive clips and images with withheld text are left out. Buttons: Choose Folder…, Cancel. |
| A2 | Press **Cancel** | Nothing happens; no folder panel; no files created. |
| A3 | Repeat, press **Choose Folder…**, pick `export-test` | The panel's button reads **Export Here**; its message reads “Choose where to save the export folder.” |
| A4 | Confirm the export | A new folder `Copyloom Export <yyyy-MM-dd HHmm>` appears inside `export-test` (no `.partial` folder left behind). |
| A5 | Read the **Export Complete** alert | Counts match your library minus anything sensitive; any “Left out” line names a reason. **Reveal in Finder** selects the new folder. |
| A6 | Open the folder in Finder | Contains `manifest.json`, `clips.jsonl`, `library.json` and an `attachments/` tree (if you have images). |
| A7 | Search `clips.jsonl` for text you know is sensitive (a copied password or key) | Not present. |
| A8 | Export again into the same folder within the same minute | A second folder with a ` 2` suffix; the first is untouched (never overwritten). |
| A9 | Start an export and press **Cancel** in the progress (needs a big library; **n/a** if too fast to catch) | No archive and no `.partial` folder remain. |

## B. Import into the same library (idempotence)

| # | Do | Expect |
| --- | --- | --- |
| B1 | **··· → Import Library…** | Panel button reads **Check Export**; message “Choose a Copyloom export folder to import.” |
| B2 | Pick the folder from A4 | Alert “Import “Copyloom Export …”?” says it adds **0** clips (“There are no new clips to add.”) and N already in your library, never changed except for a missing pin, favorite, tag or collection. Nothing has been written yet. |
| B3 | Press **Import** | **Import Complete**: “Added 0 clips … N were already in your library.” The library looks identical (counts, pins, favorites, tags, collections). |

## C. Import into a clean library (round trip)

Use a second macOS user account, or temporarily move the database aside
(quit Copyloom, rename the `Copyloom` folder inside
`~/Library/Containers/io.github.imrajyavardhan12.copyloom/Data/Library/Application Support/`,
relaunch, and **restore it afterwards**). Do not do this on your only copy of
the library without a backup.

| # | Do | Expect |
| --- | --- | --- |
| C1 | Import the A4 folder | The plan lists the clips to add, “Also adds N collections …”, and, if any image is present, the note that every image gets the same privacy screening and a large import can take a while. |
| C2 | Confirm | Progress with a Cancel button, then **Import Complete**. |
| C3 | Look at the Library | Clips, pins, favorites, tags, collections and (matching version) Smart Collections are back; original creation times are preserved; image clips show their thumbnails. |
| C4 | Wait a minute, then open an imported image | It is indexed in the background (OCR); a screenshot with text is findable by a visible word and `has:ocr`. |
| C5 | Import the same folder again | Plan says no new clips; result adds 0. |

## D. Refusals and edge cases

| # | Do | Expect |
| --- | --- | --- |
| D1 | Import a folder that is not an export (any random folder) | **Import Failed** with a plain message; nothing is written. |
| D2 | Edit one byte of `clips.jsonl` in a copy of the export, then import the copy | **Import Failed** (digest mismatch); nothing is written. |
| D3 | Delete `manifest.json` from a copy and import it | **Import Failed** (incomplete archive); nothing is written. |
| D4 | Retention warning: import an archive that holds unpinned clips older than your History Retention window (for example, set retention to 7 days in Settings, then import an export of a library with older clips; **n/a** if you have none) | The alert turns to a warning; the **default** button is **Cancel**; “Import Anyway” is the second button; the text names your window in days. |
| D5 | Start an import and press **Cancel** mid-way (large archive; **n/a** if too fast) | **Import Stopped**: clips already imported are kept; importing again finishes without duplicates. |

## E. Sandbox and permissions

| # | Do | Expect |
| --- | --- | --- |
| E1 | Run `codesign -d --entitlements - /path/to/Copyloom.app` (use the path shown in Settings → Permissions) | `com.apple.security.files.user-selected.read-write` is present; no network, Full Disk Access or other new entitlement. |
| E2 | Export to a folder, quit Copyloom, relaunch and Export again without choosing a new folder | The panel appears again; no stale access to the old folder is relied on. |
| E3 | Check System Settings → Privacy & Security | No new permission entry was created by export or import. |

## Result log

Fill this in, then set the status line at the top to **verified** (or list
the failures and open a fix).

| Check | Result | Notes |
| --- | --- | --- |
| A1–A9 | | |
| B1–B3 | | |
| C1–C5 | | |
| D1–D5 | | |
| E1–E3 | | |
