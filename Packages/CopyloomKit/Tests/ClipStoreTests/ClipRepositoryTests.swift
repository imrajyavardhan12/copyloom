import ClipDomain
import Foundation
import Testing

@testable import ClipStore

@Suite("Clip repository")
struct ClipRepositoryTests {
  @Test("an accepted text clip survives reopen and is found through FTS5")
  func persistsAndSearchesAcceptedText() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let databaseURL = temporaryDirectory.appending(path: "copyloom.sqlite")
    let clipID = try #require(UUID(uuidString: "018F6E54-4B93-7D42-8A7B-35C14D7A1001"))
    let capturedAt = try #require(
      ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")
    )

    var database: AppDatabase? = try AppDatabase.open(at: databaseURL)
    let saved = try await database?.repository.saveAcceptedText(
      AcceptedTextClip(
        id: clipID,
        text: "Postgres connection refused from the local container",
        capturedAt: capturedAt
      )
    )
    #expect(saved?.id == clipID)
    #expect(saved?.copyCount == 1)
    try database?.close()
    database = nil

    let reopened = try AppDatabase.open(at: databaseURL)
    defer { try? reopened.close() }
    let results = try await reopened.repository.search(
      SearchQuery(text: [.term("postgres")], filters: []),
      limit: 20
    )

    #expect(results.map(\.id) == [clipID])
    #expect(results.first?.text == "Postgres connection refused from the local container")
    #expect(results.first?.createdAt == capturedAt)
  }

  @Test("aggregates source applications and exposes latest provenance after deduplication")
  func storesSourceProvenance() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let originalID = UUID()
    let text = "Copyloom source metadata tracer"

    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: originalID,
        text: text,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: ClipSource(
          bundleIdentifier: "com.apple.Safari",
          applicationName: "Safari",
          provenance: .declared
        )
      )
    )
    let duplicate = try await database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: UUID(),
        text: text,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
        source: ClipSource(
          bundleIdentifier: "com.mitchellh.ghostty",
          applicationName: "Ghostty",
          provenance: .frontmostApplication
        )
      )
    )

    let safariResults = try await database.repository.search(
      SearchQuery(text: [], filters: [.application("Safari")]),
      limit: 20
    )
    let ghosttyAsText = try await database.repository.search(
      SearchQuery(text: [.term("Ghostty")], filters: []),
      limit: 20
    )

    #expect(duplicate.id == originalID)
    #expect(duplicate.source?.bundleIdentifier == "com.mitchellh.ghostty")
    #expect(duplicate.source?.provenance == .frontmostApplication)
    #expect(safariResults.map(\.id) == [originalID])
    #expect(ghosttyAsText.map(\.id) == [originalID])
  }

  @Test("pins, records use, and soft-deletes through repository actions")
  func mutatesClipLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let firstID = UUID()
    let secondID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: firstID, text: "first lifecycle clip", capturedAt: .now)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: secondID, text: "second lifecycle clip", capturedAt: .now)
    )

    try await database.repository.setPinned(id: firstID, isPinned: true)
    let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await database.repository.recordUse(id: firstID, at: usedAt)
    var recent = try await database.repository.recent(limit: 20)

    #expect(recent.first?.id == firstID)
    #expect(recent.first?.isPinned == true)
    #expect(recent.first?.useCount == 1)
    #expect(recent.first?.lastUsedAt == usedAt)

    try await database.repository.delete(id: firstID, at: usedAt)
    recent = try await database.repository.recent(limit: 20)
    let deletedSearch = try await database.repository.search(
      SearchQuery(text: [.term("first")], filters: []),
      limit: 20
    )

    #expect(recent.map(\.id) == [secondID])
    #expect(deletedSearch.isEmpty)
    #expect(try await database.repository.count() == 1)
    #expect(try await database.health().fts5IntegrityCheckPassed)
  }

  @Test("treats FTS operators and quotes as text rather than executable query syntax")
  func escapesFTSSyntax() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "postgres only", capturedAt: .now)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "private only", capturedAt: .now)
    )

    let results = try await database.repository.search(
      SearchQuery(text: [.term(#"postgres" OR private"#)], filters: []),
      limit: 20
    )

    #expect(results.isEmpty)
  }

  @Test("deduplicates normalized text while preserving first identity and creation time")
  func deduplicatesNormalizedText() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let firstID = try #require(UUID(uuidString: "018F6E54-4B93-7D42-8A7B-35C14D7A2001"))
    let duplicateID = try #require(UUID(uuidString: "018F6E54-4B93-7D42-8A7B-35C14D7A2002"))
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondDate = firstDate.addingTimeInterval(60)

    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: firstID, text: "Cafe\u{301}\r\nstatus", capturedAt: firstDate)
    )
    let duplicate = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: duplicateID, text: "Café\nstatus", capturedAt: secondDate)
    )
    let recent = try await database.repository.recent(limit: 20)
    let count = try await database.repository.count()

    #expect(count == 1)
    #expect(duplicate.id == firstID)
    #expect(duplicate.copyCount == 2)
    #expect(duplicate.createdAt == firstDate)
    #expect(duplicate.lastSeenAt == secondDate)
    #expect(duplicate.text == "Cafe\u{301}\r\nstatus")
    #expect(recent.map(\.id) == [firstID])
    #expect(recent.first?.text == "Cafe\u{301}\r\nstatus")
  }

  @Test("expires old unpinned history while keeping pinned, favorite and recent clips")
  func expiresOldHistory() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let cutoff = oldDate.addingTimeInterval(30 * 24 * 3_600)
    let recentDate = cutoff.addingTimeInterval(3_600)

    let expiredID = UUID()
    let pinnedID = UUID()
    let favoriteID = UUID()
    let recentID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: expiredID, text: "expired old clip", capturedAt: oldDate)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: pinnedID, text: "pinned old clip", capturedAt: oldDate)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: favoriteID, text: "favorite old clip", capturedAt: oldDate)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: recentID, text: "recent clip", capturedAt: recentDate)
    )
    try await database.repository.setPinned(id: pinnedID, isPinned: true)
    try await database.repository.setFavorite(id: favoriteID, isFavorite: true)

    let expired = try await database.repository.deleteExpired(before: cutoff)
    #expect(expired == 1)

    let remaining = try await database.repository.recent(limit: 20)
    #expect(remaining.map(\.id).contains(recentID))
    #expect(remaining.map(\.id).contains(pinnedID))
    #expect(remaining.map(\.id).contains(favoriteID))
    #expect(!remaining.map(\.id).contains(expiredID))

    let expiredSearch = try await database.repository.search(
      SearchQuery(text: [.term("expired")], filters: []),
      limit: 20
    )
    #expect(expiredSearch.isEmpty)
    #expect(try await database.health().fts5IntegrityCheckPassed)

    let secondRun = try await database.repository.deleteExpired(before: cutoff)
    #expect(secondRun == 0)
  }
}
