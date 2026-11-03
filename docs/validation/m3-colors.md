# M3 Color Swatch Follow-up

_Date: 2026-11-01 · Base `88d4d03` plus the color-swatch follow-up_

## Change

RGB/RGBA and HSL/HSLA color clips now show actual swatches in Quick Paste
rows, Library rows/cards and the inspector, alongside existing HEX colors.
Alpha is retained; malformed or unsupported literals keep the existing
non-swatch fallback. Capture classification, stored text and paste behavior
are unchanged.

Color-card swatches expose an explicit `Color, <literal>` accessibility label
and `clip.color.swatch` identifier, bounded to the old card's 200-character
text prefix. Hex parsing rejects an invalid complete literal instead of
silently substituting zero-valued channels or opacity.

The public `ClipColorComponents.init?(text:)` value shares the existing
`ClipTransforms` parser and exposes normalized sRGB channels/opacity. The
SwiftUI adapter is in `ClipPresentation.swift`; the old duplicate HEX-only
parser is removed. The app links the already-used local `ClipTransforms`
product explicitly. No new third-party dependency, content type or permission.

## Evidence

- Five public-component tests cover known RGB channels, HSL hue
  wrap/blue/achromatic values, alpha in HEX/RGBA/HSLA, whitespace/case,
  malformed/out-of-range/non-finite values and fullwidth/mixed Unicode hex
  in channel/alpha positions. Recognized-color and Unicode regressions were
  verified red–green: invalid Unicode returns nil, never black/transparent.
- Local `./scripts/ci.sh`: 351 Swift tests plus nine archive CLI/resource
  checks, strict format lint and unsigned app build passed.
- Signed Debug preview, Mac15,12 / macOS 27.0.1 / Xcode 27.0:
  inspected all eight new screenshots:
  `library-color-{rgb,hsl,cards}-{light,dark}.png` and
  `quickpaste-colors-{light,dark}.png`. RGB/HSL colors fill row badges,
  cards and inspector previews; alpha variants blend into light/dark surfaces;
  literals and actions remain readable. In-process preview's known sidebar
  vibrancy / inactive-window rendering limitations still apply.
- Fixtures use a throwaway synthetic-only store and the real capture text
  gate. Production-wired archive previews still emit
  `import first: added=19 present=0`,
  `import second: added=0 present=19 (idempotent=true)`, and
  `import hostile: added=0 refused=1 credentialStored=false`.

## Accessibility acceptance (owner, pending)

**VoiceOver output is still unverified.** On macOS 27.0.1 the public in-process
SwiftUI accessibility subtree was empty even for a labeled minimal probe,
on-screen and off-screen, so no automated accessibility pass is claimed.
Preview emits `preview accessibility library-color-cards-light:
ownerCheck=pending` and the dark equivalent; the PNGs do not verify spoken labels.

1. Capture non-sensitive RGB/HSL literals; open Library → Colors → Cards.
2. With VoiceOver or Accessibility Inspector, verify each card exposes
   `Color, <literal>`, not just source/age. Also check HEX/RGBA/HSLA cards;
   their swatch identifier is `clip.color.swatch`.
3. Verify selection and context actions remain usable. Record actual outcomes
   here; do not substitute PNG inspection for this check.

No real clipboard capture, permission prompt or cross-app paste was exercised.
The existing owner OCR/archive/Paste Queue acceptance checks remain pending.
