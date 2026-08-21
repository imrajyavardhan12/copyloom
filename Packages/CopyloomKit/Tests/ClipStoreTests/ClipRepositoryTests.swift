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

    #expect(duplicate.id == firstID)
    #expect(duplicate.copyCount == 2)
    #expect(duplicate.createdAt == firstDate)
    #expect(duplicate.lastSeenAt == secondDate)
    #expect(duplicate.text == "Cafe\u{301}\r\nstatus")
    #expect(recent.map(\.id) == [firstID])
    #expect(recent.first?.text == "Cafe\u{301}\r\nstatus")
  }
}
