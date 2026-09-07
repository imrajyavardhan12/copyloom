import ClipDomain
import CryptoKit
import Foundation
import GRDB

public enum ClipStoreError: Error, Equatable, Sendable {
  case emptyText
  case emptyAttachment
  case unsupportedAttachmentType(String)
  case invalidImageDimensions
  case invalidLimit(Int)
  case unsupportedFilter(SearchFilter)
  case corruptClipIdentifier(String)
  case corruptClipKind(Int)
  case corruptSourceProvenance(Int)
  case clipNotFound(UUID)
  case missingSavedClip
  case missingStoredRepresentation
}

struct GRDBClipRepository: ClipRepository, Sendable {
  private static let maximumPageSize = 200
  private static let textUTI = "public.utf8-plain-text"

  let pool: DatabasePool
  let attachments: AttachmentStore

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    guard !clip.text.isEmpty else { throw ClipStoreError.emptyText }

    let hashes = TextHasher.hash(clip.text)
    let capturedAt = clip.capturedAt.millisecondsSince1970
    let byteCount = clip.text.utf8.count
    let representationHash = Data(SHA256.hash(data: Data(clip.text.utf8)))

    return try await pool.write { database in
      let applicationID = try Self.upsertApplication(
        clip.source,
        capturedAt: capturedAt,
        database: database
      )
      let provenance = clip.source?.provenance ?? .unknown

      let clipRowID = try Int64.fetchOne(
        database,
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count,
              latest_application_id, latest_source_provenance
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
          ON CONFLICT(hash_version, dedupe_hash) WHERE deleted_at IS NULL
          DO UPDATE SET
              last_seen_at = excluded.last_seen_at,
              copy_count = clips.copy_count + 1,
              latest_application_id = excluded.latest_application_id,
              latest_source_provenance = excluded.latest_source_provenance
          RETURNING id
          """,
        arguments: [
          clip.id.uuidString.lowercased(),
          clip.kind.rawValue,
          TextHashes.version,
          hashes.dedupeHash,
          hashes.representationSetHash,
          byteCount,
          capturedAt,
          capturedAt,
          applicationID,
          provenance.rawValue,
        ]
      )
      guard let clipRowID else { throw ClipStoreError.missingSavedClip }

      try database.execute(
        sql: """
          INSERT OR IGNORE INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256, created_at
          ) VALUES (?, 0, ?, ?, ?, ?, ?)
          """,
        arguments: [
          clipRowID,
          Self.textUTI,
          clip.text,
          byteCount,
          representationHash,
          capturedAt,
        ]
      )

      if let applicationID {
        try database.execute(
          sql: """
            INSERT INTO clip_application_sources (
                clip_id, application_id, provenance,
                first_seen_at, last_seen_at, copy_count
            ) VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(clip_id, application_id, provenance) DO UPDATE SET
                last_seen_at = excluded.last_seen_at,
                copy_count = clip_application_sources.copy_count + 1
            """,
          arguments: [
            clipRowID,
            applicationID,
            provenance.rawValue,
            capturedAt,
            capturedAt,
          ]
        )
      }

      guard
        let storedText = try String.fetchOne(
          database,
          sql: """
            SELECT inline_text
            FROM clip_representations
            WHERE clip_id = ? AND item_index = 0 AND uti = ?
            """,
          arguments: [clipRowID, Self.textUTI]
        )
      else {
        throw ClipStoreError.missingStoredRepresentation
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
          arguments: [clipRowID]
        ) ?? ""

      try database.execute(
        sql: """
          INSERT INTO search_documents (clip_id, body, updated_at, applications)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(clip_id) DO UPDATE SET
              body = excluded.body,
              updated_at = excluded.updated_at,
              applications = excluded.applications
          """,
        arguments: [clipRowID, storedText, capturedAt, applicationSearchText]
      )

      return try Self.fetchSummary(clipRowID: clipRowID, database: database)
    }
  }

  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary {
    guard !clip.data.isEmpty else { throw ClipStoreError.emptyAttachment }
    guard AttachmentStore.supportedUTIs.contains(clip.uti.lowercased()) else {
      throw ClipStoreError.unsupportedAttachmentType(clip.uti)
    }
    guard clip.width > 0, clip.height > 0 else {
      throw ClipStoreError.invalidImageDimensions
    }

    // File first: a crash before the DB commit leaves an orphan file, which
    // the startup reconciler reclaims. The reverse order would leave a
    // database row pointing at bytes that do not exist.
    let stored = try attachments.store(data: clip.data, uti: clip.uti)
    let dedupeHash = ImageHasher.dedupeHash(data: clip.data, uti: clip.uti)
    let capturedAt = clip.capturedAt.millisecondsSince1970
    let byteCount = clip.data.count

    return try await pool.write { database in
      let attachmentID = try Self.upsertAttachment(
        digest: stored.sha256,
        uti: clip.uti.lowercased(),
        byteCount: byteCount,
        width: clip.width,
        height: clip.height,
        relativePath: stored.relativePath,
        capturedAt: capturedAt,
        database: database
      )
      let applicationID = try Self.upsertApplication(
        clip.source,
        capturedAt: capturedAt,
        database: database
      )
      let provenance = clip.source?.provenance ?? .unknown

      let clipRowID = try Int64.fetchOne(
        database,
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count,
              latest_application_id, latest_source_provenance
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
          ON CONFLICT(hash_version, dedupe_hash) WHERE deleted_at IS NULL
          DO UPDATE SET
              last_seen_at = excluded.last_seen_at,
              copy_count = clips.copy_count + 1,
              latest_application_id = excluded.latest_application_id,
              latest_source_provenance = excluded.latest_source_provenance
          RETURNING id
          """,
        arguments: [
          clip.id.uuidString.lowercased(),
          ClipKind.image.rawValue,
          TextHashes.version,
          dedupeHash,
          stored.sha256,
          byteCount,
          capturedAt,
          capturedAt,
          applicationID,
          provenance.rawValue,
        ]
      )
      guard let clipRowID else { throw ClipStoreError.missingSavedClip }

      try database.execute(
        sql: """
          INSERT OR IGNORE INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256,
              attachment_id, created_at
          ) VALUES (?, 0, ?, '', ?, ?, ?, ?)
          """,
        arguments: [
          clipRowID,
          clip.uti.lowercased(),
          byteCount,
          stored.sha256,
          attachmentID,
          capturedAt,
        ]
      )

      if let applicationID {
        try database.execute(
          sql: """
            INSERT INTO clip_application_sources (
                clip_id, application_id, provenance,
                first_seen_at, last_seen_at, copy_count
            ) VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(clip_id, application_id, provenance) DO UPDATE SET
                last_seen_at = excluded.last_seen_at,
                copy_count = clip_application_sources.copy_count + 1
            """,
          arguments: [
            clipRowID,
            applicationID,
            provenance.rawValue,
            capturedAt,
            capturedAt,
          ]
        )
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
          arguments: [clipRowID]
        ) ?? ""

      try database.execute(
        sql: """
          INSERT INTO search_documents (clip_id, body, updated_at, applications)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(clip_id) DO UPDATE SET
              body = excluded.body,
              updated_at = excluded.updated_at,
              applications = excluded.applications
          """,
        arguments: [clipRowID, "", capturedAt, applicationSearchText]
      )

      return try Self.fetchSummary(clipRowID: clipRowID, database: database)
    }
  }

  func attachment(for id: UUID) async throws -> ClipAttachment? {
    try await pool.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: """
            SELECT a.sha256, a.uti, a.byte_count, a.width, a.height,
                   a.relative_path
            FROM clips c
            JOIN clip_representations r
              ON r.clip_id = c.id AND r.item_index = 0
              AND r.attachment_id IS NOT NULL
            JOIN attachments a ON a.id = r.attachment_id
            WHERE c.uuid = ? AND c.deleted_at IS NULL
            """,
          arguments: [id.uuidString.lowercased()]
        )
      else {
        return nil
      }
      return ClipAttachment(
        sha256: row["sha256"],
        uti: row["uti"],
        byteCount: row["byte_count"],
        width: row["width"],
        height: row["height"],
        relativePath: row["relative_path"]
      )
    }
  }

  func attachmentData(for id: UUID) async throws -> Data? {
    guard let meta = try await attachment(for: id) else { return nil }
    return try? attachments.data(at: meta.relativePath)
  }

  func count() async throws -> Int {
    try await pool.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL"
      ) ?? 0
    }
  }

  func setPinned(id: UUID, isPinned: Bool) async throws {
    try await pool.write { database in
      let rowID = try Self.clipRowID(id: id, database: database)
      try database.execute(
        sql: "UPDATE clips SET is_pinned = ? WHERE id = ? AND deleted_at IS NULL",
        arguments: [isPinned, rowID]
      )
    }
  }

  func setFavorite(id: UUID, isFavorite: Bool) async throws {
    try await pool.write { database in
      let rowID = try Self.clipRowID(id: id, database: database)
      try database.execute(
        sql: "UPDATE clips SET is_favorite = ? WHERE id = ? AND deleted_at IS NULL",
        arguments: [isFavorite, rowID]
      )
    }
  }

  func recordUse(id: UUID, at date: Date) async throws {
    try await pool.write { database in
      let rowID = try Self.clipRowID(id: id, database: database)
      try database.execute(
        sql: """
          UPDATE clips
          SET last_used_at = ?, use_count = use_count + 1
          WHERE id = ? AND deleted_at IS NULL
          """,
        arguments: [date.millisecondsSince1970, rowID]
      )
    }
  }

  func delete(id: UUID, at date: Date) async throws {
    try await pool.write { database in
      let rowID = try Self.clipRowID(id: id, database: database)
      try database.execute(
        sql: "UPDATE clips SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
        arguments: [date.millisecondsSince1970, rowID]
      )
      try database.execute(
        sql: "DELETE FROM search_documents WHERE clip_id = ?",
        arguments: [rowID]
      )
    }
  }

  @discardableResult
  func deleteExpired(before cutoff: Date) async throws -> Int {
    let cutoffMilliseconds = cutoff.millisecondsSince1970
    return try await pool.write { database in
      try database.execute(
        sql: """
          UPDATE clips
          SET deleted_at = ?
          WHERE deleted_at IS NULL
            AND is_pinned = 0
            AND is_favorite = 0
            AND last_seen_at < ?
          """,
        arguments: [cutoffMilliseconds, cutoffMilliseconds]
      )
      let expiredCount = database.changesCount
      guard expiredCount > 0 else { return 0 }
      // Keep FTS consistent: search_documents DELETE triggers clip_fts cleanup.
      try database.execute(
        sql: """
          DELETE FROM search_documents
          WHERE clip_id IN (SELECT id FROM clips WHERE deleted_at IS NOT NULL)
          """,
        arguments: []
      )
      return expiredCount
    }
  }

  @discardableResult
  func purgeDeleted(before cutoff: Date) async throws -> Int {
    let cutoffMilliseconds = cutoff.millisecondsSince1970
    // Newly expired tombstones carry deleted_at == now, which is newer than
    // the retention cutoff, so they survive this run and are hard-purged on
    // a later run once the tombstone itself ages out. Total disk stays
    // bounded to roughly two retention windows with no extra setting.
    let (purgedClips, orphanPaths): (Int, [String]) = try await pool.write { database in
      try database.execute(
        sql: """
          DELETE FROM clips
          WHERE deleted_at IS NOT NULL
            AND deleted_at < ?
          """,
        arguments: [cutoffMilliseconds]
      )
      let purgedClips = database.changesCount
      let orphanPaths = try String.fetchAll(
        database,
        sql: """
          SELECT relative_path FROM attachments
          WHERE id NOT IN (
            SELECT attachment_id FROM clip_representations
            WHERE attachment_id IS NOT NULL
          )
          """
      )
      if !orphanPaths.isEmpty {
        try database.execute(
          sql: """
            DELETE FROM attachments
            WHERE id NOT IN (
              SELECT attachment_id FROM clip_representations
              WHERE attachment_id IS NOT NULL
            )
            """
        )
      }
      return (purgedClips, orphanPaths)
    }
    // Best-effort: a crash here leaves files the startup reconciler reclaims.
    attachments.remove(relativePaths: orphanPaths)
    return purgedClips
  }

  func recent(limit: Int) async throws -> [ClipSummary] {
    try await fetch(query: SearchQuery(text: [], filters: []), limit: limit)
  }

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    try await fetch(query: query, limit: limit)
  }

  private func fetch(query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    try validate(limit: limit)
    let hasTextQuery = !query.text.isEmpty
    let pattern = query.text.map(Self.ftsClause).joined(separator: " AND ")

    return try await pool.read { database in
      // Note: the representation join intentionally ignores UTI. Every clip
      // currently keeps exactly one item-0 representation; image rows carry
      // their bytes in the attachment store with '' inline text.
      var arguments: StatementArguments = []
      var predicates = ["c.deleted_at IS NULL"]

      // Resolve application substrings to IDs once up front. The
      // applications table is tiny; the previous per-row EXISTS with
      // instr() string matching ran on every visited clip (measured 87 ms
      // p95 at 100 k rows for a bare app: filter).
      var appFilterIDs: [[Int64]] = []
      for filter in query.filters {
        if case .application(let value) = filter {
          appFilterIDs.append(
            try Int64.fetchAll(
              database,
              sql: """
                SELECT id FROM applications
                WHERE instr(lower(display_name), lower(?)) > 0
                   OR instr(lower(bundle_id), lower(?)) > 0
                """,
              arguments: [value, value]
            ))
        }
      }
      var appFilterIndex = 0

      if hasTextQuery {
        predicates.append("clip_fts MATCH ?")
        arguments += [pattern]
      }

      for filter in query.filters {
        switch filter {
        case .application:
          let ids =
            appFilterIndex < appFilterIDs.count ? appFilterIDs[appFilterIndex] : []
          appFilterIndex += 1
          if ids.isEmpty {
            predicates.append("1 = 0")
          } else {
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            predicates.append(
              """
              EXISTS (
                  SELECT 1
                  FROM clip_application_sources source_filter
                  WHERE source_filter.clip_id = c.id
                    AND source_filter.application_id IN (\(placeholders))
              )
              """)
            for id in ids { arguments += [id] }
          }
        case .contentType(.text):
          predicates.append("c.kind = ?")
          arguments += [ClipKind.text.rawValue]
        case .contentType(.link):
          predicates.append("c.kind = ?")
          arguments += [ClipKind.link.rawValue]
        case .contentType(.image):
          predicates.append("c.kind = ?")
          arguments += [ClipKind.image.rawValue]
        case .pinned:
          predicates.append("c.is_pinned = 1")
        case .favorite:
          predicates.append("c.is_favorite = 1")
        case .after(let date):
          predicates.append("c.created_at >= ?")
          arguments += [date.millisecondsSince1970]
        case .before(let date):
          predicates.append("c.created_at < ?")
          arguments += [date.millisecondsSince1970]
        case .contentType, .tag, .hasOCR:
          throw ClipStoreError.unsupportedFilter(filter)
        }
      }

      arguments += [limit]
      // Non-FTS pages pin the timeline index. Without statistics the planner
      // inverts: the bare timeline query builds a full sort (measured 50 ms
      // p95 at 100 k) while a kind-filtered twin walks the index (0.5 ms) —
      // same EXPLAIN summary, different bytecode. A top-N timeline page must
      // always walk this index, so the force is load-bearing, not a hint.
      // It fails loudly if the index is ever renamed; repository tests cover
      // every path through here. FTS pages keep planner freedom: ranking all
      // matches by bm25 is inherent to the query, not the plan.
      let fromClause =
        hasTextQuery
        ? "clip_fts JOIN clips c ON c.id = clip_fts.rowid"
        : "clips c INDEXED BY clips_timeline"
      let orderClause =
        hasTextQuery
        ? "bm25(clip_fts), c.last_seen_at DESC, c.id DESC"
        : "c.is_pinned DESC, c.last_seen_at DESC, c.id DESC"

      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT c.id, c.uuid, c.kind, r.inline_text AS text, c.created_at, c.last_seen_at,
                 c.copy_count, c.use_count, c.last_used_at, c.is_pinned, c.is_favorite,
                 c.latest_source_provenance,
                 latest_app.bundle_id AS source_bundle_id,
                 latest_app.display_name AS source_application_name
          FROM \(fromClause)
          JOIN clip_representations r
            ON r.clip_id = c.id AND r.item_index = 0
          LEFT JOIN applications latest_app ON latest_app.id = c.latest_application_id
          WHERE \(predicates.joined(separator: " AND "))
          ORDER BY \(orderClause)
          LIMIT ?
          """,
        arguments: arguments
      )
      return try rows.map(Self.summary)
    }
  }

  private func validate(limit: Int) throws {
    guard (1...Self.maximumPageSize).contains(limit) else {
      throw ClipStoreError.invalidLimit(limit)
    }
  }

  private static func upsertAttachment(
    digest: Data,
    uti: String,
    byteCount: Int,
    width: Int,
    height: Int,
    relativePath: String,
    capturedAt: Int64,
    database: Database
  ) throws -> Int64 {
    try database.execute(
      sql: """
        INSERT INTO attachments (
            sha256, uti, byte_count, width, height, relative_path, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(sha256) DO NOTHING
        """,
      arguments: [digest, uti, byteCount, width, height, relativePath, capturedAt]
    )
    // First writer wins on dimensions; identical bytes with conflicting
    // dimensions can only come from a misbehaving caller.
    guard
      let attachmentID = try Int64.fetchOne(
        database,
        sql: "SELECT id FROM attachments WHERE sha256 = ?",
        arguments: [digest]
      )
    else {
      throw ClipStoreError.missingStoredRepresentation
    }
    return attachmentID
  }

  private static func upsertApplication(
    _ source: ClipSource?,
    capturedAt: Int64,
    database: Database
  ) throws -> Int64? {
    guard let source,
      let bundleIdentifier = source.bundleIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !bundleIdentifier.isEmpty
    else {
      return nil
    }
    let displayName = source.applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? bundleIdentifier

    return try Int64.fetchOne(
      database,
      sql: """
        INSERT INTO applications (
            bundle_id, display_name, first_seen_at, last_seen_at
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT(bundle_id) DO UPDATE SET
            display_name = excluded.display_name,
            last_seen_at = excluded.last_seen_at
        RETURNING id
        """,
      arguments: [bundleIdentifier, resolvedName, capturedAt, capturedAt]
    )
  }

  private static func clipRowID(id: UUID, database: Database) throws -> Int64 {
    guard
      let rowID = try Int64.fetchOne(
        database,
        sql: "SELECT id FROM clips WHERE uuid = ? AND deleted_at IS NULL",
        arguments: [id.uuidString.lowercased()]
      )
    else {
      throw ClipStoreError.clipNotFound(id)
    }
    return rowID
  }

  private static func ftsClause(_ clause: SearchTextClause) -> String {
    let value: String
    switch clause {
    case .term(let term): value = term
    case .phrase(let phrase): value = phrase
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func fetchSummary(clipRowID: Int64, database: Database) throws -> ClipSummary {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT c.uuid, c.kind, r.inline_text AS text, c.created_at, c.last_seen_at,
                 c.copy_count, c.use_count, c.last_used_at, c.is_pinned, c.is_favorite,
                 c.latest_source_provenance,
                 latest_app.bundle_id AS source_bundle_id,
                 latest_app.display_name AS source_application_name
          FROM clips c
          JOIN clip_representations r
            ON r.clip_id = c.id AND r.item_index = 0
          LEFT JOIN applications latest_app ON latest_app.id = c.latest_application_id
          WHERE c.id = ?
          """,
        arguments: [clipRowID]
      )
    else {
      throw ClipStoreError.missingSavedClip
    }
    return try summary(row)
  }

  private static func summary(_ row: Row) throws -> ClipSummary {
    let rawID: String = row["uuid"]
    guard let id = UUID(uuidString: rawID) else {
      throw ClipStoreError.corruptClipIdentifier(rawID)
    }
    let kindRaw: Int = row["kind"]
    guard let kind = ClipKind(rawValue: kindRaw) else {
      throw ClipStoreError.corruptClipKind(kindRaw)
    }
    let createdAt: Int64 = row["created_at"]
    let lastSeenAt: Int64 = row["last_seen_at"]
    let useCount: Int = row["use_count"]
    let lastUsedMilliseconds: Int64? = row["last_used_at"]
    let provenanceRaw: Int = row["latest_source_provenance"]
    guard let provenance = ClipSourceProvenance(rawValue: provenanceRaw) else {
      throw ClipStoreError.corruptSourceProvenance(provenanceRaw)
    }
    let sourceBundleIdentifier: String? = row["source_bundle_id"]
    let sourceApplicationName: String? = row["source_application_name"]
    let source: ClipSource? =
      provenance == .unknown && sourceBundleIdentifier == nil && sourceApplicationName == nil
      ? nil
      : ClipSource(
        bundleIdentifier: sourceBundleIdentifier,
        applicationName: sourceApplicationName,
        provenance: provenance
      )

    return ClipSummary(
      id: id,
      kind: kind,
      text: row["text"],
      createdAt: Date(millisecondsSince1970: createdAt),
      lastSeenAt: Date(millisecondsSince1970: lastSeenAt),
      copyCount: row["copy_count"],
      useCount: useCount,
      lastUsedAt: lastUsedMilliseconds.map(Date.init(millisecondsSince1970:)),
      isPinned: row["is_pinned"],
      isFavorite: row["is_favorite"],
      source: source
    )
  }
}

extension Date {
  fileprivate var millisecondsSince1970: Int64 {
    Int64((timeIntervalSince1970 * 1_000).rounded())
  }

  fileprivate init(millisecondsSince1970: Int64) {
    self.init(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1_000)
  }
}
