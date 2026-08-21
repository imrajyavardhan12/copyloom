import ClipDomain
import CryptoKit
import Foundation
import GRDB

public enum ClipStoreError: Error, Equatable, Sendable {
  case emptyText
  case invalidLimit(Int)
  case unsupportedFilter(SearchFilter)
  case corruptClipIdentifier(String)
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
      let row = try Row.fetchOne(
        database,
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count
          ) VALUES (?, 0, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT(hash_version, dedupe_hash) WHERE deleted_at IS NULL
          DO UPDATE SET
              last_seen_at = excluded.last_seen_at,
              copy_count = clips.copy_count + 1
          RETURNING id, uuid, created_at, last_seen_at, copy_count,
                    is_pinned, is_favorite
          """,
        arguments: [
          clip.id.uuidString.lowercased(),
          TextHashes.version,
          hashes.dedupeHash,
          hashes.representationSetHash,
          byteCount,
          capturedAt,
          capturedAt,
        ]
      )
      guard let row else { throw ClipStoreError.missingSavedClip }
      let clipRowID: Int64 = row["id"]

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

      try database.execute(
        sql: """
          INSERT INTO search_documents (clip_id, body, updated_at)
          VALUES (?, ?, ?)
          ON CONFLICT(clip_id) DO UPDATE SET
              body = excluded.body,
              updated_at = excluded.updated_at
          """,
        arguments: [clipRowID, storedText, capturedAt]
      )

      return try Self.summary(from: row, text: storedText)
    }
  }

  func recent(limit: Int) async throws -> [ClipSummary] {
    try validate(limit: limit)
    return try await pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT c.uuid, r.inline_text AS text, c.created_at, c.last_seen_at,
                 c.copy_count, c.is_pinned, c.is_favorite
          FROM clips c
          JOIN clip_representations r
            ON r.clip_id = c.id AND r.item_index = 0 AND r.uti = ?
          WHERE c.deleted_at IS NULL
          ORDER BY c.is_pinned DESC, c.last_seen_at DESC, c.id DESC
          LIMIT ?
          """,
        arguments: [Self.textUTI, limit]
      )
      return try rows.map { try Self.summary(from: $0, text: $0["text"]) }
    }
  }

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    try validate(limit: limit)
    if let unsupportedFilter = query.filters.first {
      throw ClipStoreError.unsupportedFilter(unsupportedFilter)
    }
    guard !query.text.isEmpty else { return try await recent(limit: limit) }

    let pattern = query.text.map(Self.ftsClause).joined(separator: " AND ")
    return try await pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT c.uuid, r.inline_text AS text, c.created_at, c.last_seen_at,
                 c.copy_count, c.is_pinned, c.is_favorite,
                 bm25(clip_fts) AS rank
          FROM clip_fts
          JOIN clips c ON c.id = clip_fts.rowid
          JOIN clip_representations r
            ON r.clip_id = c.id AND r.item_index = 0 AND r.uti = ?
          WHERE clip_fts MATCH ? AND c.deleted_at IS NULL
          ORDER BY rank, c.last_seen_at DESC, c.id DESC
          LIMIT ?
          """,
        arguments: [Self.textUTI, pattern, limit]
      )
      return try rows.map { try Self.summary(from: $0, text: $0["text"]) }
    }
  }

  private func validate(limit: Int) throws {
    guard (1...Self.maximumPageSize).contains(limit) else {
      throw ClipStoreError.invalidLimit(limit)
    }
  }

  private static func ftsClause(_ clause: SearchTextClause) -> String {
    let value: String
    switch clause {
    case .term(let term): value = term
    case .phrase(let phrase): value = phrase
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func summary(from row: Row, text: String) throws -> ClipSummary {
    let rawID: String = row["uuid"]
    guard let id = UUID(uuidString: rawID) else {
      throw ClipStoreError.corruptClipIdentifier(rawID)
    }
    let createdAt: Int64 = row["created_at"]
    let lastSeenAt: Int64 = row["last_seen_at"]
    let copyCount: Int = row["copy_count"]
    let isPinned: Bool = row["is_pinned"]
    let isFavorite: Bool = row["is_favorite"]

    return ClipSummary(
      id: id,
      text: text,
      createdAt: Date(millisecondsSince1970: createdAt),
      lastSeenAt: Date(millisecondsSince1970: lastSeenAt),
      copyCount: copyCount,
      isPinned: isPinned,
      isFavorite: isFavorite
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
