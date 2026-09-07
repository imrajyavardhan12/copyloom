import ClipDomain
import Foundation
import GRDB

public struct DatabaseHealth: Equatable, Sendable {
  public let sqliteVersion: String
  public let journalMode: String
  public let fts5IntegrityCheckPassed: Bool
  public let appliedMigrations: [String]

  public init(
    sqliteVersion: String,
    journalMode: String,
    fts5IntegrityCheckPassed: Bool,
    appliedMigrations: [String]
  ) {
    self.sqliteVersion = sqliteVersion
    self.journalMode = journalMode
    self.fts5IntegrityCheckPassed = fts5IntegrityCheckPassed
    self.appliedMigrations = appliedMigrations
  }
}

public final class AppDatabase: Sendable {
  public let repository: any ClipRepository
  public let attachments: AttachmentStore

  private let pool: DatabasePool

  private init(pool: DatabasePool, attachments: AttachmentStore) {
    self.pool = pool
    self.attachments = attachments
    repository = GRDBClipRepository(pool: pool, attachments: attachments)
  }

  public static func open(at url: URL) throws -> AppDatabase {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA synchronous = FULL")
    }

    let pool = try DatabasePool(path: url.path, configuration: configuration)
    do {
      try Migrations.makeMigrator().migrate(pool)
      let attachments = AttachmentStore(
        root: url.deletingLastPathComponent()
          .appending(path: "Attachments/v1", directoryHint: .isDirectory)
      )
      try attachments.prepare()
      return AppDatabase(pool: pool, attachments: attachments)
    } catch {
      try? pool.close()
      throw error
    }
  }

  public func health() async throws -> DatabaseHealth {
    try await pool.write { database in
      try database.execute(
        sql: "INSERT INTO clip_fts(clip_fts) VALUES ('integrity-check')"
      )
    }

    return try await pool.read { database in
      let sqliteVersion =
        try String.fetchOne(database, sql: "SELECT sqlite_version()") ?? "unknown"
      let journalMode =
        try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? "unknown"
      let appliedMigrations = try String.fetchAll(
        database,
        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
      )
      return DatabaseHealth(
        sqliteVersion: sqliteVersion,
        journalMode: journalMode.lowercased(),
        fts5IntegrityCheckPassed: true,
        appliedMigrations: appliedMigrations
      )
    }
  }

  public func close() throws {
    try pool.close()
  }

  /// Removes attachment files with no referencing representation that are
  /// older than the grace period. Covers crashes between the purge commit
  /// and post-commit unlinking. Returns the number of removed files.
  @discardableResult
  public func reconcileAttachments(
    gracePeriod: TimeInterval = 24 * 3_600,
    now: Date = Date()
  ) async throws -> Int {
    let known = try await pool.read { database in
      Set(
        try String.fetchAll(database, sql: "SELECT relative_path FROM attachments"))
    }
    return try attachments.reconcile(
      knownPaths: known, olderThan: now.addingTimeInterval(-gracePeriod))
  }
}
