import Foundation

// MARK: - Gates

/// Facts about an image that the capture preflight established by decoding it.
public struct ImageInspection: Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

/// The privacy and resource gates every imported record must pass: the same
/// ones capture uses, injected so `ClipArchive` stays free of capture and
/// storage code.
///
/// Both closures are required arguments, not defaults, so there is no way to
/// build an importer that quietly skips them. `refusingEverything` is the safe
/// stand-in for an unwired caller: nothing passes, so nothing is persisted.
public struct ImportGates: Sendable {
  /// The kind to store the text under, or nil when it must not be persisted.
  /// Pass the capture pipeline's text gate (`TextOutputGate`).
  public let acceptText: @Sendable (String) -> ArchiveClipKind?
  /// Decodes and judges image bytes as capture does (size and pixel ceilings,
  /// decode check, sensitive-content preflight). Returns the dimensions the
  /// decoder found, or nil to refuse. Archive-declared dimensions are never
  /// trusted.
  public let inspectImage: @Sendable (Data, String) async -> ImageInspection?

  public init(
    acceptText: @escaping @Sendable (String) -> ArchiveClipKind?,
    inspectImage: @escaping @Sendable (Data, String) async -> ImageInspection?
  ) {
    self.acceptText = acceptText
    self.inspectImage = inspectImage
  }

  public static let refusingEverything = ImportGates(
    acceptText: { _ in nil }, inspectImage: { _, _ in nil })
}

// MARK: - Prepared records

/// A decoded image that passed the image gate. The bytes were re-hashed by the
/// reader; the dimensions come from the gate's decode, not from the archive.
public struct PreparedImage: Sendable {
  public var data: Data
  public var uti: String
  public var width: Int
  public var height: Int

  public init(data: Data, uti: String, width: Int, height: Int) {
    self.data = data
    self.uti = uti
    self.width = width
    self.height = height
  }
}

/// A clip that passed validation and the privacy gates and is ready for the
/// store. Everything here is already bounded, clamped and normalized; the
/// store only has to decide add versus merge. Hashes are deliberately absent:
/// the store recomputes them from the content.
public struct PreparedClip: Sendable {
  public enum Content: Sendable {
    case text(String)
    case image(PreparedImage)
  }

  public var uuid: UUID
  /// Derived from the content by the gate, never taken from the archive
  /// (except `file`, which capture also stores without classifying).
  public var kind: ArchiveClipKind
  public var content: Content
  public var createdAt: Date
  public var lastSeenAt: Date
  public var lastUsedAt: Date?
  public var copyCount: Int
  public var useCount: Int
  public var isPinned: Bool
  public var isFavorite: Bool
  public var sources: [SourceRecord]
  /// Display names, trimmed, non-empty and unique case-insensitively.
  public var tags: [String]

  public init(
    uuid: UUID, kind: ArchiveClipKind, content: Content, createdAt: Date, lastSeenAt: Date,
    lastUsedAt: Date?, copyCount: Int, useCount: Int, isPinned: Bool, isFavorite: Bool,
    sources: [SourceRecord], tags: [String]
  ) {
    self.uuid = uuid
    self.kind = kind
    self.content = content
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.lastUsedAt = lastUsedAt
    self.copyCount = copyCount
    self.useCount = useCount
    self.isPinned = isPinned
    self.isFavorite = isFavorite
    self.sources = sources
    self.tags = tags
  }
}

/// `library.json` after validation: bounded names, collections ordered so a
/// parent always precedes its children, and parent links that name a
/// collection in the archive and cannot form a cycle.
public struct PreparedLibrary: Equatable, Sendable {
  public var collections: [CollectionRecord]
  public var tags: [TagRecord]
  public var savedQueries: [SavedQueryRecord]

  public init(
    collections: [CollectionRecord], tags: [TagRecord], savedQueries: [SavedQueryRecord]
  ) {
    self.collections = collections
    self.tags = tags
    self.savedQueries = savedQueries
  }
}

// MARK: - Sink

/// What the store would do (or did) with one clip.
public struct ClipDisposition: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    /// Content not in the library; the archive's UUID is free.
    case add
    /// Content not in the library, but the archive's UUID belongs to
    /// different content (or a deleted clip), so a fresh UUID is assigned.
    case addWithNewUUID
    /// The content already exists. Only monotonic changes are applied.
    case merge
  }

  /// The library's current copy of a clip whose content already exists.
  public struct Existing: Equatable, Sendable {
    public var uuid: UUID
    public var lastSeenAt: Date
    /// Pinned or favorite, before merging the archive's flags.
    public var isProtected: Bool

    public init(uuid: UUID, lastSeenAt: Date, isProtected: Bool) {
      self.uuid = uuid
      self.lastSeenAt = lastSeenAt
      self.isProtected = isProtected
    }
  }

  public var action: Action
  public var existing: Existing?

  public init(action: Action, existing: Existing? = nil) {
    self.action = action
    self.existing = existing
  }
}

/// A clip as the store applied it: the disposition plus the UUID it now has
/// in the library (the archive's, a fresh one, or the existing clip's).
public struct AppliedClip: Equatable, Sendable {
  public var disposition: ClipDisposition
  public var localUUID: UUID

  public init(disposition: ClipDisposition, localUUID: UUID) {
    self.disposition = disposition
    self.localUUID = localUUID
  }
}

/// Collection, tag and saved-query effects.
public struct LibraryCounts: Equatable, Sendable {
  public var collectionsAdded = 0
  public var collectionsExisting = 0
  public var tagsAdded = 0
  public var queriesAdded = 0
  public var queriesExisting = 0
  /// Saved queries written for a different parser version; never imported.
  public var queriesSkippedVersion = 0
  /// Clips newly placed in a collection (a re-import adds none).
  public var membershipsAdded = 0

  public init() {}
}

/// Where an import writes. `ClipStore` implements this over the database;
/// tests implement it in memory.
///
/// `classify…` methods are read-only and decide exactly as the matching
/// `apply…` method will, so the plan the user confirms is the plan that runs.
/// Merging never overwrites, never adds counters, and never touches anything
/// derived (search text, OCR state) for a clip that already exists.
public protocol ClipArchiveSink: Sendable {
  func classifyClips(_ clips: [PreparedClip]) async throws -> [ClipDisposition]

  /// Applies one batch atomically. Attachment files are written before the
  /// rows that reference them.
  func applyClips(_ clips: [PreparedClip], now: Date) async throws -> [AppliedClip]

  /// Creates tags that do not exist, keeping the display name from the
  /// archive. Runs before any clip so those names win over the bare
  /// normalized names clip records carry. Returns how many were created.
  func applyTags(_ tags: [TagRecord]) async throws -> Int

  func classifyLibrary(_ library: PreparedLibrary) async throws -> LibraryCounts

  /// Collections, memberships and saved queries. `clipMap` maps an archive
  /// clip UUID to the UUID that clip has in the library; memberships naming
  /// anything else are dropped.
  func applyLibrary(
    _ library: PreparedLibrary, clipMap: [UUID: UUID], now: Date
  ) async throws -> LibraryCounts
}

// MARK: - Results

/// Why a record was left out. Fixed wording only, never record values.
public enum ImportRejectionReason: String, CaseIterable, Sendable {
  case malformedRecord
  case refusedByPrivacyGate
  case refusedImage
  case unsupportedContent
  case invalidValue
}

public struct ImportRejections: Equatable, Sendable {
  public static let maxSamples = 10

  public private(set) var counts: [ImportRejectionReason: Int] = [:]
  /// The first few problems with their line numbers, so a user can find them.
  public private(set) var samples: [ArchiveRecordError] = []

  public init() {}

  public var total: Int { counts.values.reduce(0, +) }

  public func count(_ reason: ImportRejectionReason) -> Int { counts[reason, default: 0] }

  mutating func record(_ reason: ImportRejectionReason, line: Int, detail: String) {
    counts[reason, default: 0] += 1
    if samples.count < Self.maxSamples {
      samples.append(ArchiveRecordError(line: line, reason: detail))
    }
  }
}

/// What an import will do (plan) or did (report). Counts only: never content,
/// hashes or paths, so it is safe to show and log. For an unchanged library
/// and archive the plan equals the report.
public struct ImportSummary: Equatable, Sendable {
  public var clipsInArchive = 0
  public var clipsAdded = 0
  public var clipsAddedWithNewUUID = 0
  /// Content that was already in the library.
  public var clipsMerged = 0
  public var imagesQueuedForOCR = 0
  public var rejections = ImportRejections()
  /// Tags or sources a clip carried that were invalid or over the bounds and
  /// were dropped while the clip itself was kept.
  public var metadataDropped = 0
  /// Collection, tag or saved-query entries rejected as invalid.
  public var libraryEntriesRejected = 0
  public var library = LibraryCounts()
  /// Clips that retention would delete at its next run: not pinned or
  /// favorite, last seen before the cutoff. Counted on the state after merge.
  public var retentionAtRisk = 0
  /// Files in the folder that the manifest does not list; never read.
  public var unlistedFiles = 0
  /// What the exporting app left out at export time.
  public var skippedAtExport = ArchiveManifest.Skipped.none

  public init() {}
}

/// Progress through the clips file.
public struct ImportProgress: Equatable, Sendable {
  public var processed: Int
  public var total: Int

  public init(processed: Int, total: Int) {
    self.processed = processed
    self.total = total
  }
}
