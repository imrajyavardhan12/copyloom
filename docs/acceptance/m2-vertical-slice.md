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
