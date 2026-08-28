import ClipDomain
import CryptoKit
import Foundation
import GRDB

public enum ClipStoreError: Error, Equatable, Sendable {
  case emptyText
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
      var arguments: StatementArguments = [Self.textUTI]
      var predicates = ["c.deleted_at IS NULL"]

      if hasTextQuery {
        predicates.append("clip_fts MATCH ?")
        arguments += [pattern]
      }

      for filter in query.filters {
        switch filter {
        case .application(let value):
          predicates.append(
            """
            EXISTS (
                SELECT 1
                FROM clip_application_sources source_filter
                JOIN applications app_filter ON app_filter.id = source_filter.application_id
                WHERE source_filter.clip_id = c.id
                  AND (
                    instr(lower(app_filter.display_name), lower(?)) > 0
                    OR instr(lower(app_filter.bundle_id), lower(?)) > 0
                  )
            )
            """)
          arguments += [value, value]
        case .contentType(.text):
          predicates.append("c.kind = ?")
          arguments += [ClipKind.text.rawValue]
        case .contentType(.link):
          predicates.append("c.kind = ?")
          arguments += [ClipKind.link.rawValue]
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
      let fromClause =
        hasTextQuery
        ? "clip_fts JOIN clips c ON c.id = clip_fts.rowid"
        : "clips c"
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
            ON r.clip_id = c.id AND r.item_index = 0 AND r.uti = ?
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
            ON r.clip_id = c.id AND r.item_index = 0 AND r.uti = ?
          LEFT JOIN applications latest_app ON latest_app.id = c.latest_application_id
          WHERE c.id = ?
          """,
        arguments: [Self.textUTI, clipRowID]
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
