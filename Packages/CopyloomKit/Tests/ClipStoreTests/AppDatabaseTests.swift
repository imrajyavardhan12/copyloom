import Foundation
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
    #expect(health.appliedMigrations == ["001_accepted_text_and_fts"])
  }

  @Test("does not replace a corrupt database when open fails")
  func preservesCorruptDatabase() throws {
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
