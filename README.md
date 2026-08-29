# Copyloom

**Copy anything. Find it instantly. Reuse it anywhere.**

Copyloom is an open-source, native macOS clipboard workspace built to become a private local memory layer—not another disposable clipboard-history list.

> [!IMPORTANT]
> Copyloom is in early vertical-slice development. Privacy-gated text/link capture, native Quick Paste, and previous-application automatic paste now work. Images, the full Library, configurable ignored apps, and retention settings are not implemented yet.

## Principles

- local-first, offline-first and privacy-first;
- native Swift, SwiftUI and focused AppKit;
- keyboard-first and accessible;
- no telemetry, advertising, account or mandatory backend;
- useful without AI;
- explicit permission and network boundaries;
- user-owned portable data.

## Current foundation

- macOS 14+ app target with bundle ID `io.github.imrajyavardhan12.copyloom`;
- Swift 6 strict concurrency;
- system SQLite 3 + FTS5 through exact-pinned [GRDB](https://github.com/groue/GRDB.swift);
- versioned, transactional schema migrations;
- typed structured-query parser;
- on-disk accepted-text repository and external-content FTS5 integration tests;
- sandboxed menu-bar host with explicit capture onboarding, pause/resume and ignore-next-copy;
- local sensitive-text detection and concealed/transient/password-manager marker rejection before storage;
- best-effort source application provenance and ignored-app policy;
- native Quick Paste panel with `⌃⌘V`, FTS5 search, keyboard navigation, copy, pin and delete actions;
- Accessibility-gated paste into the retained previous application with copy-only fallback;
- Apache-2.0 project license.

See [ROADMAP.md](ROADMAP.md) for what is and is not implemented.

## Requirements

- macOS 14 or later;
- Xcode 16.3 or later (currently tested with Xcode 26.6);
- no paid Apple Developer membership for local development.

## Build and test

```bash
git clone https://github.com/imrajyavardhan12/copyloom.git
cd copyloom
./scripts/ci.sh
```

Run the locally ad-hoc-signed menu-bar app:

```bash
./scripts/run.sh
```

The menu bar uses a compact clipboard icon with the accessibility label **Copyloom**. Choose **Enable Clipboard Capture…**, read the privacy explanation, and respond to the macOS pasteboard-access prompt. Use only synthetic/non-sensitive text while testing this early build.

If the item is still missing, rerun `./scripts/run.sh`. Maintainers with Accessibility access for Terminal can run `./scripts/check-menu-bar.sh` for a direct status-item diagnostic.

After capturing synthetic text, press `⌃⌘V`, type a query, and use ↑/↓. Enter pastes into the retained previous app when Accessibility is granted; ⌘Enter always copies only. Copyloom explains the permission before requesting it and remains useful without it.

All currently captured clips are already plain text, so a separate plain-paste shortcut would have no visible effect. It will be exposed when rich-text/HTML/RTF representations are implemented.

Or open `Copyloom.xcworkspace` in Xcode. If the shell selects Command Line Tools instead of full Xcode:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The command-line CI build is unsigned. Normal end-user binaries will require Developer ID signing and notarization when project funding permits; asking users to bypass Gatekeeper is not the release plan.

## Architecture and security

- [Architecture](ARCHITECTURE.md)
- [Threat model](THREAT_MODEL.md)
- [Database schema](docs/database-schema.md)
- [Permissions](docs/permissions.md)
- [Research](docs/research.md)
- [Testing seams](docs/testing.md)

Copyloom stores regular accepted history locally. The initial regular-history database is not an encrypted Vault; see the threat model for the exact boundary.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues must follow [SECURITY.md](SECURITY.md), not public bug reports.

## License

Copyloom is licensed under [Apache-2.0](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
