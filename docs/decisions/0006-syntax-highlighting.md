# ADR 0006: Syntax highlighting for code previews

- **Status:** Proposed (needs the owner's decision)
- **Date:** 2026-10-13

## Context

M3's last open item is a syntax-highlighted code preview. Today a clip with
`kind == .code` shows plain monospace text in the Library inspector and list
rows. [ADR 0005](0005-library.md) §6 required a dependency case using the
standing template (purpose, alternatives, license, transitive graph,
maintenance, binary impact, privacy/network behavior, removal plan), and
`ARCHITECTURE.md` says no highlighter is approved.

What makes this clipboard-specific rather than an editor feature:

- Clips are arbitrary, often partial, language-unknown snippets (a shell
  line, half a JSON object, a stack trace, SQL, CSS, Swift, Python).
- The input is untrusted and can be up to the 5 MiB text ceiling. The preview
  already caps display at `textPreviewLimit`; any highlighter must honor the
  same cap and must not be able to stall the main thread.
- The app is sandboxed and offline. Nothing may fetch grammars or themes.
- A wrong or garish highlight is worse than none; the design pass made the UI
  deliberately quiet.

## Options

Facts about each package below were **not re-verified in this session**
(versions, last release, license text, grammar counts). Verify them against
the upstream repository and record them in this file before accepting.

| | A. Splash | B. Highlightr | C. Tree-sitter | D. In-house tokenizer | E. Do nothing |
| --- | --- | --- | --- | --- | --- |
| What | Pure-Swift highlighter | Swift wrapper that runs highlight.js in JavaScriptCore | Incremental parsers, one grammar per language | ~300 lines: strings, comments, numbers, a keyword set per language family | Keep plain monospace |
| Languages | Swift only | Many (highlight.js grammars) | Many, but one package per grammar | A handful, approximate | n/a |
| License | MIT | MIT | MIT | ours | n/a |
| Cost | Wrong tool for polyglot clips | Bundles a JS engine path and large JS asset; regex-based grammars on untrusted input need a length and time cap | One dependency per language, large binary growth, C targets | We own correctness forever | none |
| Risk | Languages the user copies are mostly not Swift | Catastrophic-backtracking style stalls on hostile input; harder to cancel | Build complexity on the pinned hosted toolchain | Looks wrong on edge cases | none |

Elimination:

- **A** fails the main requirement. ADR 0005 already rejected it.
- **C** is the right tool for an editor and the wrong size for a preview.
  One package per language multiplies the supply-chain surface this project
  is trying to keep at one dependency (GRDB, [ADR 0003](0003-grdb-dependency.md)).
- **B** is the only dependency that covers many languages for little code.
  Its costs are a JavaScript engine in the render path of untrusted text and
  a larger binary.

## Recommendation

**E now, D if highlighting is wanted, B only on demonstrated need.**

1. Do not add a dependency in M3. Mark the roadmap item as *deferred by
   decision* rather than *open*. Plain monospace is already a complete,
   fast, accessible code preview with no new attack surface.
2. If highlighting is wanted before M4 ends, build **D** behind a
   `CodeHighlighter` protocol in `LibraryFeature` (pure, no AppKit):
   - input is the first `textPreviewLimit` characters only;
   - output is attribute runs, computed off the main thread and cancellable;
   - one pass, linear time, no backtracking regexes;
   - unknown language means no highlighting (never a guess shown as truth);
   - colors come from semantic styles (`.secondary` for comments, a single
     muted accent for strings/keywords) so light, dark and increased
     contrast all work.
3. Choose **B** only if D proves too narrow for real users. The protocol in
   step 2 is the removal and swap seam, so the later choice stays cheap.

## Consequences

- No change to `Package.swift`, `THIRD_PARTY_NOTICES.md` or the binary.
- The roadmap line changes from "needs its own dependency decision" to
  "deferred: see ADR 0006".
- If D is built it needs: tests for linear-time behavior on a 5 MiB input
  (the Transform pretty-printer already has such a scale test as a pattern),
  a cancellation test, and an accessibility check that VoiceOver still reads
  the plain text unchanged (attributes must not alter the string).

## Open question for the owner

Is code highlighting important enough to spend a slice on before M4 (paste
queue, snippets)? The recommendation is no: it is polish, while M4 is
product capability. Accepting this ADR as written closes M3 apart from the
owner's click-through evidence.
