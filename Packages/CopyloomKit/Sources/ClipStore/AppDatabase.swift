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

  private let pool: DatabasePool

  private init(pool: DatabasePool) {
    self.pool = pool
    repository = GRDBClipRepository(pool: pool)
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
      return AppDatabase(pool: pool)
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
}
