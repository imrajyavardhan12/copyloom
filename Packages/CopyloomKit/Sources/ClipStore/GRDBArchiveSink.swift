import ClipArchive
import ClipDomain
import CryptoKit
import Foundation
import GRDB

/// Writes an import into the database (`ClipArchiveSink`).
///
/// Everything an archive says is re-derived here: dedupe hashes are computed
/// from the content, UUIDs are only kept when free, and nothing that already
/// exists is overwritten. This is deliberately not `saveAcceptedText`: that
/// path is built for capture, where a repeat copy bumps `copy_count` and
/// `last_seen_at` and renames the source application. Importing the same
/// archive twice must change nothing, so merge has its own, much narrower
/// writes.
struct GRDBArchiveSink: ClipArchiveSink {
  let pool: DatabasePool
  let attachments: AttachmentStore

  private static let textUTI = ArchiveFormat.textUTI

  // MARK: - Clips

  private struct Content {
    let dedupeHash: Data
    let representationSetHash: Data
    let byteCount: Int
  }

  private static func content(of clip: PreparedClip) -> Content {
    switch clip.content {
    case .text(let text):
      let hashes = TextHasher.hash(text)
      return Content(
        dedupeHash: hashes.dedupeHash, representationSetHash: hashes.representationSetHash,
        byteCount: text.utf8.count)
    case .image(let image):
      return Content(
        dedupeHash: ImageHasher.dedupeHash(data: image.data, uti: image.uti),
        representationSetHash: ImageHasher.contentDigest(data: image.data),
        byteCount: image.data.count)
    }
  }

  private struct ExistingClip {
    let rowID: Int64
    let uuid: UUID
    let lastSeenAt: Int64
    let isProtected: Bool
  }

  private static func existingClip(for content: Content, database: Database) throws
    -> ExistingClip?
  {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT id, uuid, last_seen_at, is_pinned, is_favorite FROM clips
          WHERE hash_version = ? AND dedupe_hash = ? AND deleted_at IS NULL
          """,
        arguments: [TextHashes.version, content.dedupeHash])
    else {
      return nil
    }
    let raw: String = row["uuid"]
    guard let uuid = UUID(uuidString: raw) else { throw ClipStoreError.corruptClipIdentifier(raw) }
    return ExistingClip(
      rowID: row["id"], uuid: uuid, lastSeenAt: row["last_seen_at"],
      isProtected: (row["is_pinned"] as Int) != 0 || (row["is_favorite"] as Int) != 0)
  }

  /// Any row, live or deleted: `uuid` is unique across tombstones too.
  private static func uuidIsTaken(_ uuid: UUID, database: Database) throws -> Bool {
    try Bool.fetchOne(
      database, sql: "SELECT EXISTS(SELECT 1 FROM clips WHERE uuid = ?)",
      arguments: [uuid.uuidString.lowercased()]) ?? false
  }

  func classifyClips(_ clips: [PreparedClip]) async throws -> [ClipDisposition] {
    try await pool.read { database in
      try clips.map { clip in
        if let existing = try Self.existingClip(for: Self.content(of: clip), database: database) {
          return ClipDisposition(
            action: .merge,
            existing: .init(
              uuid: existing.uuid, lastSeenAt: Date(millisecondsSince1970: existing.lastSeenAt),
              isProtected: existing.isProtected))
        }
        let taken = try Self.uuidIsTaken(clip.uuid, database: database)
        return ClipDisposition(action: taken ? .addWithNewUUID : .add)
      }
    }
  }

  func applyClips(_ clips: [PreparedClip], now: Date) async throws -> [AppliedClip] {
    // Files first, as capture does: a crash before the commit leaves an
    // orphan file the startup reconciler reclaims, never a row pointing at
    // missing bytes. Content addressing makes this a no-op for known images.
    var files: [StoredAttachment?] = []
    for clip in clips {
      if case .image(let image) = clip.content {
        files.append(try attachments.store(data: image.data, uti: image.uti))
      } else {
        files.append(nil)
      }
    }
    let stored = files
    let nowMilliseconds = now.millisecondsSince1970

    return try await pool.write { database in
      try clips.enumerated().map { index, clip in
        let content = Self.content(of: clip)
        if let existing = try Self.existingClip(for: content, database: database) {
          try Self.merge(clip, into: existing, database: database)
          return AppliedClip(
            disposition: ClipDisposition(
              action: .merge,
              existing: .init(
                uuid: existing.uuid,
                lastSeenAt: Date(millisecondsSince1970: existing.lastSeenAt),
                isProtected: existing.isProtected)),
            localUUID: existing.uuid)
        }
        let taken = try Self.uuidIsTaken(clip.uuid, database: database)
        let uuid = taken ? UUID() : clip.uuid
        try Self.insert(
          clip, as: uuid, content: content, attachment: stored[index],
          nowMilliseconds: nowMilliseconds, database: database)
        return AppliedClip(
          disposition: ClipDisposition(action: taken ? .addWithNewUUID : .add), localUUID: uuid)
      }
    }
  }

  /// Only monotonic changes: flags can become true, the earliest creation
  /// time wins, tags are unioned. Counters, last-seen, sources, search text
  /// and OCR state are never touched, which is what makes re-importing the
  /// same archive a no-op.
  private static func merge(
    _ clip: PreparedClip, into existing: ExistingClip, database: Database
  ) throws {
    try database.execute(
      sql: """
        UPDATE clips SET
            is_pinned = MAX(is_pinned, ?),
            is_favorite = MAX(is_favorite, ?),
            created_at = MIN(created_at, ?)
        WHERE id = ?
        """,
      arguments: [
        clip.isPinned, clip.isFavorite, clip.createdAt.millisecondsSince1970, existing.rowID,
      ]
    )
    for tag in clip.tags { try link(tag: tag, toClip: existing.rowID, database: database) }
  }

  private static func insert(
    _ clip: PreparedClip, as uuid: UUID, content: Content, attachment: StoredAttachment?,
    nowMilliseconds: Int64, database: Database
  ) throws {
    let created = clip.createdAt.millisecondsSince1970
    let lastSeen = clip.lastSeenAt.millisecondsSince1970

    // Sources first, so the clip row can point at the latest one.
    var sourceRows: [(applicationID: Int64, source: SourceRecord)] = []
    for source in clip.sources {
      let applicationID = try applicationID(for: source, database: database)
      sourceRows.append((applicationID, source))
    }
    let latest = sourceRows.max {
      $0.source.lastSeenAt < $1.source.lastSeenAt
    }

    try database.execute(
      sql: """
        INSERT INTO clips (
            uuid, kind, hash_version, dedupe_hash, representation_set_hash,
            byte_count, created_at, last_seen_at, last_used_at, copy_count, use_count,
            is_pinned, is_favorite, latest_application_id, latest_source_provenance
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        uuid.uuidString.lowercased(), clipKind(clip.kind).rawValue, TextHashes.version,
        content.dedupeHash, content.representationSetHash, content.byteCount, created, lastSeen,
        clip.lastUsedAt?.millisecondsSince1970, clip.copyCount, clip.useCount, clip.isPinned,
        clip.isFavorite, latest?.applicationID,
        latest.map { provenance($0.source.provenance).rawValue }
          ?? ClipSourceProvenance.unknown.rawValue,
      ])
    let clipRowID = database.lastInsertedRowID

    switch clip.content {
    case .text(let text):
      try database.execute(
        sql: """
          INSERT INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256, created_at
          ) VALUES (?, 0, ?, ?, ?, ?, ?)
          """,
        arguments: [
          clipRowID, textUTI, text, content.byteCount,
          Data(SHA256.hash(data: Data(text.utf8))), created,
        ])
    case .image(let image):
      guard let attachment else { throw ClipStoreError.missingStoredRepresentation }
      let attachmentID = try GRDBClipRepository.upsertAttachment(
        digest: attachment.sha256, uti: image.uti, byteCount: image.data.count,
        width: image.width, height: image.height, relativePath: attachment.relativePath,
        capturedAt: nowMilliseconds, database: database)
      try database.execute(
        sql: """
          INSERT INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256,
              attachment_id, created_at
          ) VALUES (?, 0, ?, '', ?, ?, ?, ?)
          """,
        arguments: [
          clipRowID, image.uti, image.data.count, attachment.sha256, attachmentID, created,
        ])
    }

    for row in sourceRows {
      try database.execute(
        sql: """
          INSERT INTO clip_application_sources (
              clip_id, application_id, provenance, first_seen_at, last_seen_at, copy_count
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(clip_id, application_id, provenance) DO NOTHING
          """,
        arguments: [
          clipRowID, row.applicationID, provenance(row.source.provenance).rawValue,
          row.source.firstSeenAt.millisecondsSince1970,
          row.source.lastSeenAt.millisecondsSince1970, row.source.copyCount,
        ])
    }

    let applicationSearchText =
      try String.fetchOne(
        database,
        sql: """
          SELECT group_concat(label, ' ')
          FROM (
              SELECT a.display_name || ' ' || a.bundle_id AS label
              FROM clip_application_sources source
              JOIN applications a ON a.id = source.application_id
              WHERE source.clip_id = ?
              ORDER BY a.bundle_id
          )
          """,
        arguments: [clipRowID]) ?? ""
    var body = ""
    if case .text(let text) = clip.content { body = text }
    try database.execute(
      sql: """
        INSERT INTO search_documents (clip_id, body, updated_at, applications)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [clipRowID, body, lastSeen, applicationSearchText])

    // Imported images take the normal route: the background OCR queue scans
    // them under the current privacy policy, quarantining sensitive text.
    if case .image = clip.content {
      try database.execute(
        sql: """
          INSERT INTO image_ocr_jobs (clip_id, status, attempts, updated_at)
          VALUES (?, ?, 0, ?)
          ON CONFLICT(clip_id) DO NOTHING
          """,
        arguments: [clipRowID, OCRJobStatus.pending.rawValue, nowMilliseconds])
    }

    for tag in clip.tags { try link(tag: tag, toClip: clipRowID, database: database) }
  }

  /// Creates the application if it is new and leaves an existing one exactly
  /// as it is: unlike capture, an archive must not be able to rename an
  /// application the library already knows.
  private static func applicationID(for source: SourceRecord, database: Database) throws -> Int64 {
    let trimmed = source.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? source.bundleId
    try database.execute(
      sql: """
        INSERT INTO applications (bundle_id, display_name, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(bundle_id) DO NOTHING
        """,
      arguments: [
        source.bundleId, displayName, source.firstSeenAt.millisecondsSince1970,
        source.lastSeenAt.millisecondsSince1970,
      ])
    guard
      let id = try Int64.fetchOne(
        database, sql: "SELECT id FROM applications WHERE bundle_id = ?",
        arguments: [source.bundleId])
    else {
      throw ClipStoreError.missingStoredRepresentation
    }
    return id
  }

  // MARK: - Tags

  /// Creates a top-level tag if its normalized name is new (an existing tag
  /// keeps its name) and returns its row id and whether it was created.
  @discardableResult
  private static func ensureTag(_ name: String, database: Database) throws -> (
    id: Int64, created: Bool
  ) {
    let normalized = ClipTag(id: UUID(), name: name).normalized
    let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
    try database.execute(
      sql: """
        INSERT INTO tags (uuid, name, normalized, created_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(COALESCE(parent_id, 0), normalized) DO NOTHING
        """,
      arguments: [
        UUID().uuidString.lowercased(), display, normalized, Date.now.millisecondsSince1970,
      ])
    let created = database.changesCount > 0
    guard
      let id = try Int64.fetchOne(
        database, sql: "SELECT id FROM tags WHERE parent_id IS NULL AND normalized = ?",
        arguments: [normalized])
    else {
      throw ClipStoreError.missingSavedClip
    }
    return (id, created)
  }

  private static func link(tag: String, toClip clipRowID: Int64, database: Database) throws {
    let tagID = try ensureTag(tag, database: database).id
    try database.execute(
      sql: "INSERT INTO clip_tags (clip_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING",
      arguments: [clipRowID, tagID])
  }

  func applyTags(_ tags: [TagRecord]) async throws -> Int {
    try await pool.write { database in
      try tags.reduce(0) { added, tag in
        added + (try Self.ensureTag(tag.name, database: database).created ? 1 : 0)
      }
    }
  }

  // MARK: - Library

  func classifyLibrary(_ library: PreparedLibrary) async throws -> LibraryCounts {
    try await pool.read { database in
      var counts = LibraryCounts()
      for collection in library.collections {
        let exists = try Self.collectionRow(collection.uuid, database: database) != nil
        if exists { counts.collectionsExisting += 1 } else { counts.collectionsAdded += 1 }
      }
      for tag in library.tags {
        let normalized = ClipTag(id: UUID(), name: tag.name).normalized
        let exists =
          try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM tags WHERE parent_id IS NULL AND normalized = ?)",
            arguments: [normalized]) ?? false
        if !exists { counts.tagsAdded += 1 }
      }
      for query in library.savedQueries {
        switch try Self.queryDisposition(query, database: database) {
        case .existing: counts.queriesExisting += 1
        case .staleVersion: counts.queriesSkippedVersion += 1
        case .new: counts.queriesAdded += 1
        }
      }
      return counts
    }
  }

  func applyLibrary(
    _ library: PreparedLibrary, clipMap: [UUID: UUID], now: Date
  ) async throws -> LibraryCounts {
    let nowMilliseconds = now.millisecondsSince1970
    return try await pool.write { database in
      var counts = LibraryCounts()

      // Collections arrive parents first. An existing collection keeps its
      // name and parent and only gains members.
      var memberTargets: [(UUID, Int64)] = []
      var rowIDs: [UUID: Int64] = [:]
      for collection in library.collections {
        if let row = try Self.collectionRow(collection.uuid, database: database) {
          counts.collectionsExisting += 1
          if row.isLive { rowIDs[collection.uuid] = row.id }
        } else {
          let parentID = collection.parentUuid.flatMap { rowIDs[$0] }
          try database.execute(
            sql: """
              INSERT INTO collections (uuid, name, parent_id, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?)
              """,
            arguments: [
              collection.uuid.uuidString.lowercased(), collection.name, parentID,
              collection.createdAt.millisecondsSince1970,
              collection.updatedAt.millisecondsSince1970,
            ])
          rowIDs[collection.uuid] = database.lastInsertedRowID
          counts.collectionsAdded += 1
        }
        if let id = rowIDs[collection.uuid] { memberTargets.append((collection.uuid, id)) }
      }

      let membersByCollection = Dictionary(
        uniqueKeysWithValues: library.collections.map { ($0.uuid, $0.clipUuids) })
      for (collectionUUID, collectionID) in memberTargets {
        for (index, archiveUUID) in (membersByCollection[collectionUUID] ?? []).enumerated() {
          guard let local = clipMap[archiveUUID],
            let clipID = try Int64.fetchOne(
              database, sql: "SELECT id FROM clips WHERE uuid = ? AND deleted_at IS NULL",
              arguments: [local.uuidString.lowercased()])
          else {
            continue
          }
          try database.execute(
            sql: """
              INSERT INTO collection_items (collection_id, clip_id, position, added_at)
              VALUES (?, ?, ?, ?)
              ON CONFLICT(collection_id, clip_id) DO NOTHING
              """,
            arguments: [collectionID, clipID, nowMilliseconds + Int64(index), nowMilliseconds])
          counts.membershipsAdded += database.changesCount
        }
      }

      for query in library.savedQueries {
        switch try Self.queryDisposition(query, database: database) {
        case .existing: counts.queriesExisting += 1
        case .staleVersion: counts.queriesSkippedVersion += 1
        case .new:
          try database.execute(
            sql: """
              INSERT INTO saved_queries (
                  uuid, name, query_version, query_text, created_at, updated_at
              ) VALUES (?, ?, ?, ?, ?, ?)
              """,
            arguments: [
              query.uuid.uuidString.lowercased(), query.name, query.queryVersion,
              query.queryText, nowMilliseconds, nowMilliseconds,
            ])
          counts.queriesAdded += 1
        }
      }
      return counts
    }
  }

  private static func collectionRow(_ uuid: UUID, database: Database) throws
    -> (id: Int64, isLive: Bool)?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT id, deleted_at IS NULL AS live FROM collections WHERE uuid = ?",
        arguments: [uuid.uuidString.lowercased()])
    else {
      return nil
    }
    return (row["id"], (row["live"] as Int) != 0)
  }

  private enum QueryDisposition { case existing, staleVersion, new }

  private static func queryDisposition(
    _ query: SavedQueryRecord, database: Database
  ) throws -> QueryDisposition {
    let exists =
      try Bool.fetchOne(
        database, sql: "SELECT EXISTS(SELECT 1 FROM saved_queries WHERE uuid = ?)",
        arguments: [query.uuid.uuidString.lowercased()]) ?? false
    if exists { return .existing }
    return query.queryVersion == SavedQuery.currentVersion ? .new : .staleVersion
  }

  // MARK: - Mapping

  private static func clipKind(_ kind: ArchiveClipKind) -> ClipKind {
    switch kind {
    case .text: .text
    case .link: .link
    case .image: .image
    case .code: .code
    case .color: .color
    case .file: .file
    }
  }

  private static func provenance(_ provenance: ArchiveProvenance) -> ClipSourceProvenance {
    switch provenance {
    case .unknown: .unknown
    case .declared: .declared
    case .frontmost: .frontmostApplication
    }
  }
}
