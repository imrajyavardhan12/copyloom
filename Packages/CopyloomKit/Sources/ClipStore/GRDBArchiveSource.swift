import ClipArchive
import ClipDomain
import Foundation
import GRDB

enum ArchiveSourceError: Error, Equatable {
  /// A stored row could not be mapped to the archive format (unknown kind,
  /// malformed UUID, unsupported attachment type). Export fails loudly
  /// instead of guessing, because a wrong guess would silently mislabel data.
  case corruptRow
}

/// Reads the library for export (`ClipArchiveSource`).
///
/// Clips stream from one `DatabaseSnapshot`, so counts and relationships are
/// consistent even while capture keeps writing, and are fetched in keyset
/// pages (`created_at`, `id`), so memory stays bounded at any library size.
struct GRDBArchiveSource: ClipArchiveSource {
  let pool: DatabasePool
  let attachments: AttachmentStore

  private static let pageSize = 500

  // MARK: - Clips

  func forEachLiveClip(_ body: (ExportCandidate) async throws -> Void) async throws {
    let snapshot = try pool.makeSnapshot()
    var afterCreated = Int64.min
    var afterID = Int64.min
    while true {
      let (createdCursor, idCursor) = (afterCreated, afterID)
      let (candidates, next) = try await snapshot.read { database in
        try Self.page(afterCreated: createdCursor, afterID: idCursor, database: database)
      }
      for candidate in candidates { try await body(candidate) }
      guard let next else { return }
      (afterCreated, afterID) = next
    }
  }

  /// Returns up to one page of candidates and the cursor for the next, or a
  /// nil cursor when this was the last page.
  private static func page(
    afterCreated: Int64, afterID: Int64, database: Database
  ) throws -> ([ExportCandidate], (Int64, Int64)?) {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, uuid, kind, created_at, last_seen_at, last_used_at,
               copy_count, use_count, is_pinned, is_favorite
        FROM clips
        WHERE deleted_at IS NULL
          AND (created_at > ? OR (created_at = ? AND id > ?))
        ORDER BY created_at, id
        LIMIT ?
        """,
      arguments: [afterCreated, afterCreated, afterID, pageSize]
    )
    guard let last = rows.last else { return ([], nil) }
    let ids: [Int64] = rows.map { $0["id"] }
    let placeholders = databaseQuestionMarks(count: ids.count)
    let arguments = StatementArguments(ids)

    let representations = try Dictionary(
      grouping: Row.fetchAll(
        database,
        sql: """
          SELECT r.clip_id, r.uti, r.inline_text, r.attachment_id,
                 a.sha256 AS attachment_sha, a.uti AS attachment_uti,
                 a.byte_count AS attachment_bytes, a.width, a.height
          FROM clip_representations r
          LEFT JOIN attachments a ON a.id = r.attachment_id
          WHERE r.clip_id IN (\(placeholders))
          ORDER BY r.clip_id, r.item_index, r.id
          """,
        arguments: arguments),
      by: { (row: Row) -> Int64 in row["clip_id"] })

    let sources = try Dictionary(
      grouping: Row.fetchAll(
        database,
        sql: """
          SELECT s.clip_id, a.bundle_id, a.display_name, s.provenance,
                 s.first_seen_at, s.last_seen_at, s.copy_count
          FROM clip_application_sources s
          JOIN applications a ON a.id = s.application_id
          WHERE s.clip_id IN (\(placeholders))
          ORDER BY s.clip_id, a.bundle_id, s.provenance
          """,
        arguments: arguments),
      by: { (row: Row) -> Int64 in row["clip_id"] })

    let tags = try Dictionary(
      grouping: Row.fetchAll(
        database,
        sql: """
          SELECT ct.clip_id, t.normalized
          FROM clip_tags ct JOIN tags t ON t.id = ct.tag_id
          WHERE ct.clip_id IN (\(placeholders))
          ORDER BY ct.clip_id, t.normalized
          """,
        arguments: arguments),
      by: { (row: Row) -> Int64 in row["clip_id"] })

    // OCRJobStatus.withheld == 2: the quarantine state.
    let withheld = Set(
      try Int64.fetchAll(
        database,
        sql: """
          SELECT clip_id FROM image_ocr_jobs
          WHERE status = 2 AND clip_id IN (\(placeholders))
          """,
        arguments: arguments))

    var candidates: [ExportCandidate] = []
    candidates.reserveCapacity(rows.count)
    for row in rows {
      let id: Int64 = row["id"]
      let record = try clipRecord(
        row: row, representations: representations[id] ?? [], sources: sources[id] ?? [],
        tags: (tags[id] ?? []).map { $0["normalized"] })
      candidates.append(
        ExportCandidate(clip: record, isQuarantinedImage: withheld.contains(id)))
    }
    let lastCreated: Int64 = last["created_at"]
    let lastID: Int64 = last["id"]
    return (candidates, rows.count < pageSize ? nil : (lastCreated, lastID))
  }

  private static func clipRecord(
    row: Row, representations: [Row], sources: [Row], tags: [String]
  ) throws -> ClipRecord {
    guard let uuid = UUID(uuidString: row["uuid"] as String),
      let kind = ClipKind(rawValue: row["kind"]).map(archiveKind)
    else {
      throw ArchiveSourceError.corruptRow
    }
    let lastUsed: Int64? = row["last_used_at"]
    return ClipRecord(
      uuid: uuid, kind: kind,
      createdAt: date(row["created_at"]), lastSeenAt: date(row["last_seen_at"]),
      lastUsedAt: lastUsed.map(date),
      copyCount: row["copy_count"], useCount: row["use_count"],
      isPinned: (row["is_pinned"] as Int) != 0, isFavorite: (row["is_favorite"] as Int) != 0,
      representations: try representations.map(representationRecord),
      sources: try sources.map(sourceRecord), tags: tags)
  }

  private static func representationRecord(_ row: Row) throws -> RepresentationRecord {
    guard let digest: Data = row["attachment_sha"] else {
      return RepresentationRecord(uti: row["uti"], text: row["inline_text"])
    }
    let uti: String = row["attachment_uti"]
    guard let fileExtension = AttachmentStore.fileExtension(forUTI: uti) else {
      throw ArchiveSourceError.corruptRow
    }
    let hex = hexString(digest)
    return RepresentationRecord(
      uti: uti,
      attachment: ArchivePath.attachmentPath(sha256: hex, fileExtension: fileExtension),
      sha256: hex, bytes: row["attachment_bytes"], width: row["width"], height: row["height"])
  }

  private static func sourceRecord(_ row: Row) throws -> SourceRecord {
    guard let provenance = ClipSourceProvenance(rawValue: row["provenance"]) else {
      throw ArchiveSourceError.corruptRow
    }
    let archiveProvenance: ArchiveProvenance =
      switch provenance {
      case .unknown: .unknown
      case .declared: .declared
      case .frontmostApplication: .frontmost
      }
    return SourceRecord(
      bundleId: row["bundle_id"], name: row["display_name"], provenance: archiveProvenance,
      firstSeenAt: date(row["first_seen_at"]), lastSeenAt: date(row["last_seen_at"]),
      copyCount: row["copy_count"])
  }

  // MARK: - Library

  func libraryRecord() async throws -> LibraryRecord {
    try await pool.read { database in
      var membership: [Int64: [UUID]] = [:]
      for row in try Row.fetchAll(
        database,
        sql: """
          SELECT ci.collection_id, cl.uuid
          FROM collection_items ci JOIN clips cl ON cl.id = ci.clip_id
          WHERE cl.deleted_at IS NULL
          ORDER BY ci.collection_id, ci.position, ci.added_at, ci.clip_id
          """)
      {
        guard let uuid = UUID(uuidString: row["uuid"] as String) else {
          throw ArchiveSourceError.corruptRow
        }
        membership[row["collection_id"], default: []].append(uuid)
      }

      let collections = try Row.fetchAll(
        database,
        sql: """
          SELECT c.id, c.uuid, c.name, p.uuid AS parent_uuid, c.created_at, c.updated_at
          FROM collections c
          LEFT JOIN collections p ON p.id = c.parent_id AND p.deleted_at IS NULL
          WHERE c.deleted_at IS NULL
          ORDER BY c.position, c.created_at, c.id
          """
      ).map { row -> CollectionRecord in
        let id: Int64 = row["id"]
        return CollectionRecord(
          uuid: UUID(uuidString: row["uuid"] as String) ?? UUID(),
          name: row["name"],
          parentUuid: (row["parent_uuid"] as String?).flatMap { UUID(uuidString: $0) },
          createdAt: Self.date(row["created_at"]), updatedAt: Self.date(row["updated_at"]),
          clipUuids: membership[id] ?? [])
      }

      let tags = try Row.fetchAll(
        database, sql: "SELECT name, normalized FROM tags ORDER BY normalized, id"
      ).map { TagRecord(name: $0["name"], normalized: $0["normalized"]) }

      let queries = try Row.fetchAll(
        database,
        sql: """
          SELECT uuid, name, query_version, query_text FROM saved_queries
          WHERE deleted_at IS NULL ORDER BY created_at, id
          """
      ).map { row -> SavedQueryRecord in
        SavedQueryRecord(
          uuid: UUID(uuidString: row["uuid"] as String) ?? UUID(),
          name: row["name"], queryVersion: row["query_version"], queryText: row["query_text"])
      }
      return LibraryRecord(collections: collections, tags: tags, savedQueries: queries)
    }
  }

  // MARK: - Attachments

  func attachmentData(sha256: String) async throws -> Data? {
    guard let digest = Self.data(fromHex: sha256) else { return nil }
    let relativePath = try await pool.read { database in
      try String.fetchOne(
        database, sql: "SELECT relative_path FROM attachments WHERE sha256 = ?",
        arguments: [digest])
    }
    guard let relativePath else { return nil }
    // A file that cannot be read is reported as missing, not as a failure of
    // the whole export; the exporter skips that clip and counts it.
    return try? attachments.data(at: relativePath)
  }

  // MARK: - Mapping helpers

  private static func archiveKind(_ kind: ClipKind) -> ArchiveClipKind {
    switch kind {
    case .text: .text
    case .link: .link
    case .image: .image
    case .code: .code
    case .color: .color
    case .file: .file
    }
  }

  private static func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
  }

  private static func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func data(fromHex hex: String) -> Data? {
    guard hex.count == 64 else { return nil }
    var bytes = Data(capacity: 32)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}
