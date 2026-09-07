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
- Previous-application automatic paste with contextual Accessibility explanation, target validation, activation confirmation, and copy-only fallback.
- Fixed retained-target loss caused by weak `NSRunningApplication` storage and added an explicit menu action for automatic-paste permission setup.
- Development launcher now terminates every stale Copyloom process and verifies exactly one instance, preventing duplicate menu icons and old-process hotkey ownership.
- Compact icon-only menu-bar presentation retaining the `Copyloom` accessibility label.
- Explicit Quick Paste footer labels distinguishing Return paste and Command-Return copy-only; the non-distinct plain-paste hint is hidden until rich representations exist.
- Versioned capture settings stored outside history with fail-closed unknown/corrupt handling and legacy migration.
- Time-based retention deleting unpinned/unfavorited clips older than 30 days with FTS cleanup, automatic on launch plus manual menu action.
- Clip favorite action supporting retention exemption and future Library Favorites.
- Menu-bar diagnostics showing ignored-app count, retention window, running app path, and Reveal in Finder to disambiguate ad-hoc development TCC identity.
- Native Settings window with Ignored Apps (add/remove/reset plus running-app picker), History retention stepper with manual cleanup, and Permissions status with running-app identity.
- Reproducible local/CI scripts and open-source contribution files.

[Unreleased]: https://github.com/imrajyavardhan12/copyloom/commits/main
