import ClipDomain
import Foundation
import GRDB
import Testing

@testable import ClipStore

@Suite("App database")
struct AppDatabaseTests {
  @Test("reports the migrated WAL and FTS5 storage capabilities")
  func reportsHealth() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }

    let health = try await database.health()

    #expect(health.sqliteVersion.hasPrefix("3."))
    #expect(health.journalMode == "wal")
    #expect(health.fts5IntegrityCheckPassed)
    #expect(
      health.appliedMigrations == [
        "001_accepted_text_and_fts",
        "002_application_sources_and_search",
        "003_clip_lifecycle_actions",
        "004_image_attachments",
      ]
    )
  }

  @Test("migrates an existing version-one FTS index without losing searchable text")
  func migratesVersionOneData() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "copyloom.sqlite")
    let clipID = UUID()
    let text = "existing searchable migration tracer"
    let timestamp: Int64 = 1_700_000_000_000
    let hashes = TextHasher.hash(text)

    let versionOnePool = try DatabasePool(path: databaseURL.path)
    try Migrations.makeMigrator().migrate(
      versionOnePool,
      upTo: "001_accepted_text_and_fts"
    )
    try await versionOnePool.write { database in
      try database.execute(
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count
          ) VALUES (?, 0, ?, ?, ?, ?, ?, ?, 1)
          """,
        arguments: [
          clipID.uuidString.lowercased(),
          TextHashes.version,
          hashes.dedupeHash,
          hashes.representationSetHash,
          text.utf8.count,
          timestamp,
          timestamp,
        ]
      )
      let rowID = database.lastInsertedRowID
      try database.execute(
        sql: """
          INSERT INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256, created_at
          ) VALUES (?, 0, 'public.utf8-plain-text', ?, ?, ?, ?)
          """,
        arguments: [
          rowID,
          text,
          text.utf8.count,
          hashes.representationSetHash,
          timestamp,
        ]
      )
      try database.execute(
        sql: "INSERT INTO search_documents (clip_id, body, updated_at) VALUES (?, ?, ?)",
        arguments: [rowID, text, timestamp]
      )
    }
    try versionOnePool.close()

    let upgraded = try AppDatabase.open(at: databaseURL)
    defer { try? upgraded.close() }
    let results = try await upgraded.repository.search(
      SearchQuery(text: [.term("migration")], filters: []),
      limit: 20
    )

    #expect(results.map(\.id) == [clipID])
    #expect(
      try await upgraded.health().appliedMigrations == [
        "001_accepted_text_and_fts",
        "002_application_sources_and_search",
        "003_clip_lifecycle_actions",
        "004_image_attachments",
      ]
    )
  }

  @Test("migrates version three to image attachments without losing clips")
  func migratesVersionThreeData() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "copyloom.sqlite")

    let versionThreePool = try DatabasePool(path: databaseURL.path)
    try Migrations.makeMigrator().migrate(
      versionThreePool,
      upTo: "003_clip_lifecycle_actions"
    )
    try await versionThreePool.write { database in
      try database.execute(
        sql:
          "INSERT INTO clips (uuid, kind, hash_version, dedupe_hash, representation_set_hash, byte_count, created_at, last_seen_at, copy_count) VALUES (?, 0, 1, randomblob(32), randomblob(32), 5, 1700000000000, 1700000000000, 1)",
        arguments: [UUID().uuidString.lowercased()]
      )
    }
    try versionThreePool.close()

    let upgraded = try AppDatabase.open(at: databaseURL)
    defer { try? upgraded.close() }
    #expect(try await upgraded.repository.count() == 1)
    #expect(
      try await upgraded.health().appliedMigrations == [
        "001_accepted_text_and_fts",
        "002_application_sources_and_search",
        "003_clip_lifecycle_actions",
        "004_image_attachments",
      ]
    )
  }

  @Test("does not replace a corrupt database when open fails") func preservesCorruptDatabase()
    throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appending(path: "copyloom.sqlite")
    let original = Data("this is intentionally not a SQLite database".utf8)
    try original.write(to: databaseURL)

    do {
      _ = try AppDatabase.open(at: databaseURL)
      Issue.record("Opening corrupt data unexpectedly succeeded")
    } catch {
      #expect(try Data(contentsOf: databaseURL) == original)
    }
  }
}
