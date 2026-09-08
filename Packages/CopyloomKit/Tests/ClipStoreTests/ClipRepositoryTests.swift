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
    // Survivors must stay fully searchable: the broad tombstone cleanup in
    // deleteExpired must not claim live rows' search documents.
    let survivorSearch = try await database.repository.search(
      SearchQuery(text: [.term("pinned")], filters: []),
      limit: 20
    )
    #expect(survivorSearch.map(\.id) == [pinnedID])
    #expect(try await database.health().fts5IntegrityCheckPassed)

    let secondRun = try await database.repository.deleteExpired(before: cutoff)
    #expect(secondRun == 0)
  }

  @Test("persists an image clip with attachment metadata")
  func persistsImageClip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let png = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      )
    )
    let clipID = UUID()
    let saved = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: clipID,
        data: png,
        uti: "public.png",
        width: 1,
        height: 1,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: ClipSource(
          bundleIdentifier: "com.apple.Preview",
          applicationName: "Preview",
          provenance: .frontmostApplication
        )
      )
    )

    #expect(saved.id == clipID)
    #expect(saved.kind == .image)
    #expect(saved.copyCount == 1)

    let attachment = try #require(await database.repository.attachment(for: clipID))
    #expect(attachment.uti == "public.png")
    #expect(attachment.byteCount == png.count)
    #expect(attachment.width == 1)
    #expect(attachment.height == 1)
    #expect(
      FileManager.default.fileExists(
        atPath: database.attachments.url(for: attachment.relativePath).path))
    #expect(try await database.repository.attachment(for: UUID()) == nil)

    let images = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.image)]),
      limit: 20
    )
    #expect(images.map(\.id) == [clipID])
    let texts = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.text)]),
      limit: 20
    )
    #expect(texts.isEmpty)
    #expect(try await database.health().fts5IntegrityCheckPassed)
  }

  @Test("filters code, color and file clips by type")
  func filtersNewKinds() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let codeID = UUID()
    let colorID = UUID()
    let fileID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: codeID, kind: .code, text: "def f():\n    pass",
        capturedAt: .now)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: colorID, kind: .color, text: "#ff00aa", capturedAt: .now)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: fileID, kind: .file, text: "/tmp/a.txt", capturedAt: .now)
    )

    for (filter, expected) in [
      (SearchContentType.code, codeID),
      (SearchContentType.color, colorID),
      (SearchContentType.file, fileID),
    ] {
      let results = try await database.repository.search(
        SearchQuery(text: [], filters: [.contentType(filter)]),
        limit: 20
      )
      #expect(results.map(\.id) == [expected])
    }
  }

  @Test("deduplicates identical image bytes")
  func deduplicatesImages() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    let firstID = UUID()
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: firstID, data: png, uti: "public.png", width: 4, height: 4,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )
    let duplicate = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: UUID(), data: png, uti: "public.png", width: 4, height: 4,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100))
    )

    #expect(duplicate.id == firstID)
    #expect(duplicate.copyCount == 2)
    #expect(try await database.repository.count() == 1)
    let attachment = try #require(await database.repository.attachment(for: firstID))
    let duplicateAttachment = try #require(
      await database.repository.attachment(for: duplicate.id))
    #expect(attachment == duplicateAttachment)
  }

  @Test("rejects invalid image clips before touching storage")
  func rejectsInvalidImages() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let png = Data([0x01, 0x02])

    await #expect(throws: ClipStoreError.emptyAttachment) {
      try await database.repository.saveAcceptedImage(
        AcceptedImageClip(
          id: UUID(), data: Data(), uti: "public.png", width: 1, height: 1,
          capturedAt: .now)
      )
    }
    await #expect(throws: ClipStoreError.unsupportedAttachmentType("com.example.weird")) {
      try await database.repository.saveAcceptedImage(
        AcceptedImageClip(
          id: UUID(), data: png, uti: "com.example.weird", width: 1, height: 1,
          capturedAt: .now)
      )
    }
    await #expect(throws: ClipStoreError.invalidImageDimensions) {
      try await database.repository.saveAcceptedImage(
        AcceptedImageClip(
          id: UUID(), data: png, uti: "public.png", width: 0, height: 1,
          capturedAt: .now)
      )
    }
    #expect(try await database.repository.count() == 0)
  }

  @Test("expiry keeps the tombstone file until purge reclaims it")
  func imageExpiryThenPurge() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let clipID = UUID()
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let cutoff = oldDate.addingTimeInterval(30 * 24 * 3_600)
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: clipID, data: png, uti: "public.png", width: 2, height: 2,
        capturedAt: oldDate)
    )
    let attachment = try #require(await database.repository.attachment(for: clipID))
    let filePath = database.attachments.url(for: attachment.relativePath).path

    #expect(try await database.repository.deleteExpired(before: cutoff) == 1)
    // Tombstone grace: bytes stay until the deletion itself ages out.
    #expect(FileManager.default.fileExists(atPath: filePath))
    #expect(try await database.repository.attachment(for: clipID) == nil)

    #expect(
      try await database.repository.purgeDeleted(
        before: cutoff.addingTimeInterval(3_600)) == 1)
    #expect(!FileManager.default.fileExists(atPath: filePath))
    #expect(try await database.health().fts5IntegrityCheckPassed)
  }

  @Test("reads back attachment bytes and reports missing files as nil")
  func readsAttachmentData() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let clipID = UUID()
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: clipID, data: png, uti: "public.png", width: 2, height: 2,
        capturedAt: .now)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "plain words", capturedAt: .now)
    )

    #expect(try await database.repository.attachmentData(for: clipID) == png)
    #expect(try await database.repository.attachmentData(for: UUID()) == nil)
  }

  @Test("reconciles crash-orphaned attachment files")
  func reconcilesOrphanedFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let orphanURL = database.attachments.url(for: "zz/zz/orphan.png")
    try FileManager.default.createDirectory(
      at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("orphan".utf8).write(to: orphanURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
      ofItemAtPath: orphanURL.path
    )

    #expect(try await database.reconcileAttachments(now: Date()) == 1)
    #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    #expect(try await database.reconcileAttachments(now: Date()) == 0)
  }

  @Test("purges aged tombstones while keeping recent deletions and live clips")
  func purgesAgedTombstones() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    defer { try? database.close() }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let oldDelete = base.addingTimeInterval(100)
    let cutoff = base.addingTimeInterval(150)
    let emergLive = base.addingTimeInterval(250)

    let agedID = UUID()
    let freshID = UUID()
    let liveID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: agedID, text: "aged tombstone clip", capturedAt: base)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: freshID, text: "fresh tombstone clip", capturedAt: base)
    )
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: liveID, text: "live survivor clip", capturedAt: emergLive)
    )
    try await database.repository.delete(id: agedID, at: oldDelete)
    // Fresh tombstone deleted after the cutoff: grace period must protect it.
    try await database.repository.delete(id: freshID, at: cutoff.addingTimeInterval(100))

    #expect(try await database.repository.purgeDeleted(before: cutoff) == 1)
    #expect(try await database.repository.purgeDeleted(before: cutoff) == 0)
    #expect(
      try await database.repository.purgeDeleted(before: emergLive.addingTimeInterval(60)) == 1)

    let remaining = try await database.repository.recent(limit: 20)
    #expect(remaining.map(\.id) == [liveID])
    let liveSearch = try await database.repository.search(
      SearchQuery(text: [.term("survivor")], filters: []),
      limit: 20
    )
    #expect(liveSearch.map(\.id) == [liveID])
    #expect(try await database.health().fts5IntegrityCheckPassed)
  }
}
