# Changelog

All notable changes to Copyloom will be documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases will use semantic versioning once public compatibility begins.

## [Unreleased]

### Added

- Phase 0 product, architecture, database, permission and threat-model research.
- Copyloom project identity and Apache-2.0 license.
- Native sandboxed macOS menu-bar host with no clipboard access at launch.
- Swift package modules for domain types, structured search parsing and GRDB-backed storage.
- Minimal accepted-text migration with versioned hashing and external-content FTS5.
- On-disk persistence/search integration tests.
- Explicit opt-in text/link clipboard monitoring with pause and ignore-next-copy controls.
- Pre-persistence concealed/transient/vendor marker checks, ignored-app checks, size limits, and local sensitive-content detection.
- Source application provenance aggregation and source-aware FTS/filter search.
- A labeled, accessibility-identifiable Copyloom menu-bar item and diagnostic script.
- Native Quick Paste panel with global `⌃⌘V`, live FTS5 search, keyboard navigation, copy, pin, delete, use-count tracking, and copy-loop suppression.
- Reproducible local/CI scripts and open-source contribution files.

[Unreleased]: https://github.com/imrajyavardhan12/copyloom/commits/main
