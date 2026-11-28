import ClipArchive
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

  /// How many matches a search ranks by relevance at most; past it, matches list
  /// like the history (ARCHITECTURE.md § Search architecture). Ranking that
  /// many is estimated at about 10 ms at 100k clips, from the 7.7k-match class
  /// at 14.7 ms p95 (docs/validation/m2-benchmarks.md).
  public static let defaultRelevanceRankingLimit = 5_000

  private init(pool: DatabasePool, attachments: AttachmentStore, relevanceRankingLimit: Int) {
    self.pool = pool
    self.attachments = attachments
    repository = GRDBClipRepository(
      pool: pool, attachments: attachments, relevanceRankingLimit: relevanceRankingLimit)
  }

  /// - Parameter relevanceRankingLimit: the app keeps the default; tests lower
  ///   it to reach the limit with a few clips. A negative limit counts as 0.
  public static func open(
    at url: URL,
    relevanceRankingLimit: Int = defaultRelevanceRankingLimit
  ) throws -> AppDatabase {
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
      return AppDatabase(
        pool: pool, attachments: attachments, relevanceRankingLimit: relevanceRankingLimit)
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

  /// Number of schema migrations this build knows; recorded in exports.
  public static var schemaVersion: Int { Migrations.makeMigrator().migrations.count }

  /// The library as an export source (see `ArchiveExporter`).
  public func archiveSource() -> any ClipArchiveSource {
    GRDBArchiveSource(pool: pool, attachments: attachments)
  }

  /// The library as an import sink (see `ArchiveImporter`).
  public func archiveSink() -> any ClipArchiveSink {
    GRDBArchiveSink(pool: pool, attachments: attachments)
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
