# Contributing to Copyloom

Thank you for helping build a trustworthy open-source macOS utility.

## Before contributing

- Read [ARCHITECTURE.md](ARCHITECTURE.md), [THREAT_MODEL.md](THREAT_MODEL.md), and [docs/testing.md](docs/testing.md).
- Do not add network behavior, telemetry, broad permissions or persistence of new content types without an explicit design/security review.
- Do not copy proprietary competitor source, assets, branding, text or layouts.
- Discuss large product or schema changes in an issue before implementation.

## Setup

Requirements: macOS 14+, Xcode 16.3+ and Git.

```bash
git clone https://github.com/imrajyavardhan12/copyloom.git
cd copyloom
./scripts/ci.sh
```

If needed:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Open `Copyloom.xcworkspace`, never only a generated package checkout. No paid Apple Developer membership is required for normal development.

## Development workflow

1. Choose one vertical behavior at an approved public seam.
2. Add one failing test and verify the expected failure.
3. Implement the smallest behavior that passes.
4. Run `./scripts/ci.sh`.
5. Update architecture, threat, permission or migration documentation when boundaries change.
6. Submit a focused pull request with evidence and residual risks.

Tests should assert public behavior, not private functions, GRDB implementation records, collaborator call counts or broad snapshots.

## Security and privacy rules

- Capture policy must run before persistence, FTS, thumbnails and logs.
- Never log clipboard content, search queries, OCR output, secrets, hashes of rejected secrets or raw file paths.
- Permission-gated features must retain a useful fallback.
- No external request may contain clip content unless the user explicitly enables and invokes that named feature.
- Security-sensitive TODOs require a linked issue and safe disabled behavior.

Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Dependencies

Dependencies require written justification covering alternatives, license, maintenance, transitive graph, privacy/network behavior, binary cost and removal strategy. GRDB is currently the sole runtime dependency.

## Pull requests

Include:

- user-observable behavior;
- tests and commands run;
- screenshots only when UI changed and no private content is visible;
- migration/permission/security impact;
- performance evidence for hot paths;
- known residual risks.

By contributing, you agree that your contributions are provided under the project's Apache-2.0 license.
