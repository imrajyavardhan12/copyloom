import ClipDomain
import Foundation
import GRDB
import Testing

@testable import ClipStore

@Suite("Searchable OCR storage")
struct OCRSearchTests {
  private func isolatedDatabase() throws -> (AppDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    return (database, directory)
  }

  private func close(_ database: AppDatabase, _ directory: URL) {
    try? database.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private func saveImage(
    _ database: AppDatabase,
    bytes: Data = Data([0x89, 0x50, 0x4E, 0x47]),
    source: ClipSource? = nil
  ) async throws -> UUID {
    let id = UUID()
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: id,
        data: bytes,
        uti: "public.png",
        width: 2,
        height: 2,
        capturedAt: .now,
        source: source
      )
    )
    return id
  }

  @Test("saving an image enqueues one pending job; text clips have none")
  func enqueuesPendingJob() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    let textID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: textID, text: "plain words", capturedAt: .now)
    )

    #expect(
      try await database.repository.ocrJob(for: imageID)
        == OCRJobInfo(
          status: .pending, attempts: 0))
    #expect(try await database.repository.ocrJob(for: textID) == nil)
    #expect(try await database.repository.pendingOCRJobCount() == 1)
    let claimed = try #require(
      try await database.repository.claimNextPendingOCRJob())
    #expect(claimed.clipID == imageID)
    #expect(claimed.attempts == 0)
  }

  @Test("indexed OCR text is searchable and matches has:ocr")
  func indexedTextIsSearchable() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    try await database.repository.markOCRIndexed(
      clipID: imageID, text: "harbor sunset lighthouse", at: .now)

    #expect(try await database.repository.ocrJob(for: imageID)?.status == .indexed)
    #expect(try await database.repository.pendingOCRJobCount() == 0)

    let term = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(term.map(\.id) == [imageID])

    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.map(\.id) == [imageID])
  }

  @Test("quarantine withholds text from search while the clip stays findable")
  func quarantineWithholdsFromSearch() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    let imageID = try await saveImage(
      database,
      bytes: bytes,
      source: ClipSource(
        bundleIdentifier: "com.apple.Preview",
        applicationName: "Preview",
        provenance: .frontmostApplication
      )
    )
    try await database.repository.markOCRWithheld(clipID: imageID, at: .now)

    #expect(try await database.repository.ocrJob(for: imageID)?.status == .withheld)

    // Never by content: the withheld text is not in the index.
    let content = try await database.repository.search(
      SearchQuery(text: [.term("lighthouse")], filters: []), limit: 20)
    #expect(content.isEmpty)
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)

    // Pixels stay, and metadata filters still resolve the clip.
    #expect(try await database.repository.attachmentData(for: imageID) == bytes)
    let byType = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.image)]), limit: 20)
    #expect(byType.map(\.id) == [imageID])
    let byApp = try await database.repository.search(
      SearchQuery(text: [], filters: [.application("Preview")]), limit: 20)
    #expect(byApp.map(\.id) == [imageID])
  }

  @Test("a blank scan indexes empty text and stays out of has:ocr")
  func blankScanIndexesEmpty() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    try await database.repository.markOCRIndexed(clipID: imageID, text: "", at: .now)

    #expect(try await database.repository.ocrJob(for: imageID)?.status == .indexed)
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)
    let byType = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.image)]), limit: 20)
    #expect(byType.map(\.id) == [imageID])
  }

  @Test("withholding clears previously indexed text from FTS")
  func withholdClearsIndexedText() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    try await database.repository.markOCRIndexed(
      clipID: imageID, text: "harbor sunset", at: .now)
    let before = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(before.map(\.id) == [imageID])

    try await database.repository.markOCRWithheld(clipID: imageID, at: .now)
    let after = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(after.isEmpty)
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)
  }

  @Test("duplicate image bytes keep the existing OCR state")
  func duplicatesKeepOCRState() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    let firstID = try await saveImage(database, bytes: bytes)
    try await database.repository.markOCRIndexed(
      clipID: firstID, text: "harbor manifest", at: .now)
    let duplicate = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: UUID(), data: bytes, uti: "public.png", width: 2, height: 2,
        capturedAt: .now)
    )

    #expect(duplicate.id == firstID)
    #expect(try await database.repository.ocrJob(for: firstID)?.status == .indexed)
    let term = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(term.map(\.id) == [firstID])
    #expect(try await database.repository.pendingOCRJobCount() == 0)
  }

  @Test("deleting and expiring shed queue state with the clip")
  func deletesShedJobs() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let deletedID = try await saveImage(database)
    try await database.repository.delete(id: deletedID, at: .now)
    #expect(try await database.repository.ocrJob(for: deletedID) == nil)

    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let expiredID = UUID()
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: expiredID, data: Data([0x89, 0x50, 0x4E, 0x47, 0x03]),
        uti: "public.png", width: 2, height: 2, capturedAt: oldDate)
    )
    _ = try await database.repository.deleteExpired(
      before: oldDate.addingTimeInterval(30 * 24 * 3_600))
    #expect(try await database.repository.ocrJob(for: expiredID) == nil)
    #expect(try await database.repository.pendingOCRJobCount() == 0)
    #expect(try await database.repository.claimNextPendingOCRJob() == nil)
  }

  @Test("attempt counts accumulate until quarantine")
  func attemptsAccumulate() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    #expect(try await database.repository.recordOCRAttempt(clipID: imageID, at: .now) == 1)
    #expect(try await database.repository.recordOCRAttempt(clipID: imageID, at: .now) == 2)
    #expect(
      try await database.repository.ocrJob(for: imageID)
        == OCRJobInfo(
          status: .pending, attempts: 2))
  }

  @Test("a full FTS rebuild keeps OCR text searchable")
  func rebuildKeepsOCR() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let imageID = try await saveImage(database)
    try await database.repository.markOCRIndexed(
      clipID: imageID, text: "harbor rebuild tracer", at: .now)
    try await database.repository.rebuildSearchIndex()

    let term = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(term.map(\.id) == [imageID])
    #expect(try await database.health().fts5IntegrityCheckPassed)
  }

  @Test("migration backfills pending jobs for pre-OCR image clips")
  func migrationBackfillsJobs() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "copyloom.sqlite")
    let imageUUID = UUID().uuidString.lowercased()
    let textUUID = UUID().uuidString.lowercased()

    let versionFivePool = try DatabasePool(path: databaseURL.path)
    try Migrations.makeMigrator().migrate(versionFivePool, upTo: "005_organization")
    try await versionFivePool.write { database in
      try database.execute(
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count
          ) VALUES (?, 2, 1, randomblob(32), randomblob(32), 4, 1700000000000, 1700000000000, 1)
          """,
        arguments: [imageUUID]
      )
      let imageRowID = database.lastInsertedRowID
      try database.execute(
        sql: """
          INSERT INTO attachments (
              sha256, uti, byte_count, width, height, relative_path, created_at
          ) VALUES (randomblob(32), 'public.png', 4, 2, 2, 'backfill/test.png', 1700000000000)
          """
      )
      let attachmentID = database.lastInsertedRowID
      try database.execute(
        sql: """
          INSERT INTO clip_representations (
              clip_id, item_index, uti, inline_text, byte_count, sha256,
              attachment_id, created_at
          ) VALUES (?, 0, 'public.png', '', 4, randomblob(32), ?, 1700000000000)
          """,
        arguments: [imageRowID, attachmentID]
      )
      try database.execute(
        sql: """
          INSERT INTO search_documents (clip_id, body, updated_at, applications)
          VALUES (?, '', 1700000000000, '')
          """,
        arguments: [imageRowID]
      )
      try database.execute(
        sql: """
          INSERT INTO clips (
              uuid, kind, hash_version, dedupe_hash, representation_set_hash,
              byte_count, created_at, last_seen_at, copy_count
          ) VALUES (?, 0, 1, randomblob(32), randomblob(32), 5, 1700000000000, 1700000000000, 1)
          """,
        arguments: [textUUID]
      )
    }
    try versionFivePool.close()

    let upgraded = try AppDatabase.open(at: databaseURL)
    defer { try? upgraded.close() }
    let imageID = try #require(UUID(uuidString: imageUUID))
    let textID = try #require(UUID(uuidString: textUUID))

    #expect(
      try await upgraded.repository.ocrJob(for: imageID)
        == OCRJobInfo(
          status: .pending, attempts: 0))
    #expect(try await upgraded.repository.ocrJob(for: textID) == nil)
    // Pre-OCR text rows survive the FTS rebuild untouched.
    #expect(try await upgraded.health().fts5IntegrityCheckPassed)
  }
}
