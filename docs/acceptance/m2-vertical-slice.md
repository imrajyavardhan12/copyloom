# M2 First Vertical Slice Acceptance

This document versions the 17 user-visible acceptance checks from the product brief. M2 is complete only when every row has automated evidence or a recorded manual result on the named OS/build.

| ID | Check | Evidence plan |
|---|---|---|
| A01 | Launch Copyloom | XCUITest launch smoke + manual signed-host check |
| A02 | Copy several text values from different applications | Signed integration/manual matrix; repository pipeline assertions |
| A03 | Copy an image | Signed integration/manual matrix; fail-closed image privacy-policy test |
| A04 | Press the global shortcut | Signed manual hotkey matrix + registration integration test |
| A05 | History appears immediately | XCUITest plus warm-open benchmark |
| A06 | Search by text | Repository/FTS integration tests + XCUITest |
| A07 | Filter/find using source application metadata | Parser/repository tests + manual source-provenance matrix |
| A08 | Navigate entirely with the keyboard | XCUITest and accessibility audit |
| A09 | Press Enter on a selected result | XCUITest action routing |
| A10 | Selected item pastes into the originally focused app | Signed manual cross-app/Spaces matrix; target-retention integration test |
| A11 | Pin an item | Repository + XCUITest |
| A12 | Restart Copyloom | XCUITest relaunch/manual host test |
| A13 | Pinned item and history persist | On-disk reopen integration test + XCUITest |
| A14 | Ignore an application | Capture-policy test + signed manual source test |
| A15 | Copies from the ignored application are not persisted | No-persistence integration assertion across repository/search/attachments/log sink |
| A16 | Pause clipboard capture | Capture-state test + menu/XCUITest |
| A17 | New clips are not stored while paused | Capture-pipeline/repository integration test + manual verification |

## Required metadata for manual evidence

- Copyloom commit and build configuration;
- macOS/Xcode versions and hardware architecture;
- signature type and sandbox state;
- granted/revoked permission state;
- source and target applications/versions;
- pass/fail with a content-free failure description.

Developer/ad-hoc local signing is valid for M2 implementation evidence. Developer ID notarization is a later release gate when paid membership is available and must never be marked complete prematurely.

## Sign-off (2026-09-08)

Builds cited are ad-hoc Debug on Mac15,12 / macOS 26.6.2 unless noted.
`XCUITest` rows below rest on manual host evidence: no UI test target exists
yet, so every keyboard/focus claim was exercised live by the owner across the
`3dbe448`–`e42bb5` builds rather than by automation. That gap is recorded,
not waived.

| ID | Result | Evidence |
|---|---|---|
| A01 | Pass | Daily signed-host launches incl. restart/relaunch cycles |
| A02 | Pass | Captures from Safari/Ghostty/TextEdit/Brave with provenance in rows |
| A03 | Pass | `docs/validation/m2-images.md` (capture, thumbnail, paste-back, refusal) |
| A04 | Pass | `⌃⌘V` exercised in every session since `3ec2f5b` |
| A05 | Pass | Panel telemetry: ~48 ms + 1 frame warm-open (`m2-benchmarks.md`) |
| A06 | Pass | FTS/repo tests + live typed search in panel |
| A07 | Pass | Parser/repo tests + source names in rows; `type:`/`app:` filters live |
| A08 | Pass | Arrows/Enter/Esc/`⌘1–9`/`⌘P`/delete used live; VoiceOver labels in code |
| A09 | Pass | Enter delivery verified on every paste test |
| A10 | Pass | TextEdit paste verified across builds; copy-only fallback verified |
| A11 | Pass | Repo tests + pinned row live (pin icon in screenshots) |
| A12 | Pass | macOS reboot + same-binary relaunch; capture resumed |
| A13 | Pass | On-disk reopen tests + live history/count surviving restart |
| A14 | Pass | Policy tests + Settings add/remove/reset exercised live |
| A15 | Pass | Policy + pipeline no-persistence tests; ignored-copy status live |
| A16 | Pass | Pause/resume state tests + menu controls live |
| A17 | Pass | Pipeline pause tests; pause adopts change count (no retro-capture) |

### Explicitly deferred (not claimed)

- Spaces/full-screen/secure-field paste matrix
- XCUITest automation for panel/keyboard/focus paths
- Energy in mW (`powermetrics` never run; idle CPU ~0% as proxy)
- Configurable shortcut and primary-action preference
- Plain-text paste action (hidden until rich-text capture exists)
- Full 2 GiB budget enforcement and `has:ocr` index (M3 scope)
