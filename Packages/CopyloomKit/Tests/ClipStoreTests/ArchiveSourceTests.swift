import ClipArchive
import ClipDomain
import Foundation
import Testing

@testable import ClipStore

@Suite("Archive export from the database")
struct ArchiveSourceTests {
  private static let createdBy = ArchiveManifest.CreatedBy(
    app: "Copyloom", appVersion: "0.0.0-test", schemaVersion: 6)

  private func isolatedDatabase() throws -> (AppDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite")), directory)
  }

  private func close(_ database: AppDatabase, _ directory: URL) {
    try? database.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private func export(
    _ database: AppDatabase, to directory: URL,
    allow: @escaping @Sendable (String) -> Bool = { _ in true }
  ) async throws -> (ArchiveManifest, URL) {
    let destination = directory.appending(path: "Export.copyloom", directoryHint: .isDirectory)
    let manifest = try await ArchiveExporter(
      source: database.archiveSource(), isExportable: allow, createdBy: Self.createdBy
    ).export(to: destination)
    return (manifest, destination)
  }

  private func clips(in archive: URL) throws -> (VerifiedArchive, [ClipRecord]) {
    let verified = try ArchiveVerifier().verify(at: archive)
    var records: [ClipRecord] = []
    try ArchiveReader(archive: verified).forEachClip { _, result in records.append(try result.get())
    }
    return (verified, records)
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private let safari = ClipSource(
    bundleIdentifier: "com.apple.Safari", applicationName: "Safari", provenance: .declared)

  // MARK: - Fidelity

  @Test("every stored field survives export and read-back")
  func fullFidelity() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let repository = database.repository
    let first = Date(timeIntervalSince1970: 1_800_000_000.123)
    let again = Date(timeIntervalSince1970: 1_800_000_500.456)
    let textID = UUID()

    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(
        id: textID, kind: .code, text: "let x = 1", capturedAt: first, source: safari))
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(
        id: UUID(), kind: .code, text: "let x = 1", capturedAt: again, source: safari))
    try await repository.setPinned(id: textID, isPinned: true)
    try await repository.setFavorite(id: textID, isFavorite: true)
    try await repository.recordUse(id: textID, at: again)
    try await repository.tagClip(id: textID, tag: "Project")

    let png = Data((0..<48).map { UInt8($0 &* 3) })
    let imageID = UUID()
    _ = try await repository.saveAcceptedImage(
      AcceptedImageClip(
        id: imageID, data: png, uti: "public.png", width: 8, height: 6,
        capturedAt: first.addingTimeInterval(10), source: nil))

    let collection = try await repository.createCollection(name: "Atlas", at: first)
    try await repository.addToCollection(collectionID: collection.id, clipID: textID, at: first)
    try await repository.addToCollection(collectionID: collection.id, clipID: imageID, at: first)
    _ = try await repository.saveQuery(name: "Code", queryText: "type:code", at: first)

    let (manifest, archive) = try await export(database, to: directory)
    #expect(manifest.counts.clips == 2)
    #expect(manifest.skipped == .none)

    let (verified, records) = try clips(in: archive)
    let text = try #require(records.first { $0.uuid == textID })
    #expect(text.kind == .code)
    #expect(milliseconds(text.createdAt) == 1_800_000_000_123)
    #expect(milliseconds(text.lastSeenAt) == 1_800_000_500_456)
    #expect(text.copyCount == 2)
    #expect(text.useCount == 1)
    #expect(text.lastUsedAt.map(milliseconds) == 1_800_000_500_456)
    #expect(text.isPinned && text.isFavorite)
    #expect(
      text.representations == [
        RepresentationRecord(uti: "public.utf8-plain-text", text: "let x = 1")
      ])
    #expect(text.tags == ["project"])
    let source = try #require(text.sources.first)
    #expect(source.bundleId == "com.apple.Safari" && source.name == "Safari")
    #expect(source.provenance == .declared && source.copyCount == 2)
    #expect(milliseconds(source.firstSeenAt) == 1_800_000_000_123)

    let image = try #require(records.first { $0.uuid == imageID })
    let representation = try #require(image.representations.first)
    #expect(image.kind == .image)
    #expect(representation.uti == "public.png")
    #expect(
      representation.bytes == png.count && representation.width == 8 && representation.height == 6)
    let path = try #require(representation.attachment)
    #expect(try ArchiveReader(archive: verified).attachmentData(at: path) == png)

    let library = try ArchiveReader(archive: verified).library()
    #expect(library.collections.map(\.name) == ["Atlas"])
    #expect(
      library.collections.first?.clipUuids.sorted { $0.uuidString < $1.uuidString }
        == [textID, imageID].sorted { $0.uuidString < $1.uuidString })
    #expect(library.tags == [TagRecord(name: "Project", normalized: "project")])
    #expect(library.savedQueries.map(\.queryText) == ["type:code"])
  }

  @Test("deleted clips are not exported")
  func deletedExcluded() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let keep = UUID()
    let drop = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: keep, text: "keep", capturedAt: now))
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: drop, text: "drop", capturedAt: now))
    try await database.repository.delete(id: drop, at: now)

    let (_, archive) = try await export(database, to: directory)
    let (_, records) = try clips(in: archive)

    #expect(records.map(\.uuid) == [keep])
  }

  // MARK: - Quarantine and missing data

  @Test("an image whose OCR text was withheld is skipped; pending and indexed images are exported")
  func quarantineRespected() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let repository = database.repository
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func save(_ byte: UInt8, _ offset: TimeInterval) async throws -> UUID {
      let id = UUID()
      _ = try await repository.saveAcceptedImage(
        AcceptedImageClip(
          id: id, data: Data(repeating: byte, count: 32), uti: "public.png", width: 4, height: 4,
          capturedAt: now.addingTimeInterval(offset), source: nil))
      return id
    }
    let pending = try await save(1, 0)
    let indexed = try await save(2, 1)
    let withheld = try await save(3, 2)
    try await repository.markOCRIndexed(clipID: indexed, text: "hello", at: now)
    try await repository.markOCRWithheld(clipID: withheld, at: now)

    let (manifest, archive) = try await export(database, to: directory)

    #expect(manifest.skipped.quarantinedImage == 1)
    let (_, records) = try clips(in: archive)
    #expect(Set(records.map(\.uuid)) == [pending, indexed])
    #expect(manifest.counts.attachments == 2)
  }

  @Test("an attachment file missing from disk skips that clip only")
  func missingFileSkipped() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let repository = database.repository
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gone = UUID()
    _ = try await repository.saveAcceptedImage(
      AcceptedImageClip(
        id: gone, data: Data(repeating: 7, count: 32), uti: "public.png", width: 4, height: 4,
        capturedAt: now, source: nil))
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "text stays", capturedAt: now))
    let attachment = try #require(try await repository.attachment(for: gone))
    try FileManager.default.removeItem(at: database.attachments.url(for: attachment.relativePath))

    let (manifest, archive) = try await export(database, to: directory)

    #expect(manifest.skipped.missingAttachment == 1)
    #expect(manifest.counts.clips == 1)
    _ = try clips(in: archive)
  }

  @Test("the gate is applied to stored text")
  func gateApplied() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "ordinary", capturedAt: now))
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "refuse me", capturedAt: now))

    let (manifest, archive) = try await export(database, to: directory) { !$0.contains("refuse") }

    #expect(manifest.skipped.sensitive == 1)
    let (_, records) = try clips(in: archive)
    #expect(records.compactMap { $0.representations.first?.text } == ["ordinary"])
  }

  // MARK: - Scale and structure

  @Test("more clips than one page are exported exactly once, oldest first")
  func pagination() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let count = 1_250
    var expected: [UUID] = []
    for index in 0..<count {
      let id = UUID()
      expected.append(id)
      // Several clips share a timestamp to exercise the tie-break.
      _ = try await database.repository.saveAcceptedText(
        AcceptedTextClip(
          id: id, text: "clip number \(index)",
          capturedAt: base.addingTimeInterval(Double(index / 3))))
    }

    let (manifest, archive) = try await export(database, to: directory)
    let (_, records) = try clips(in: archive)

    #expect(manifest.counts.clips == count)
    #expect(records.map(\.uuid) == expected)
    #expect(Set(records.map(\.uuid)).count == count)
  }

  @Test("a deleted collection and its membership are not exported")
  func deletedCollection() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clipID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: clipID, text: "member", capturedAt: now))
    let kept = try await database.repository.createCollection(name: "Kept", at: now)
    let removed = try await database.repository.createCollection(name: "Removed", at: now)
    try await database.repository.addToCollection(collectionID: kept.id, clipID: clipID, at: now)
    try await database.repository.addToCollection(collectionID: removed.id, clipID: clipID, at: now)
    try await database.repository.deleteCollection(id: removed.id)

    let (_, archive) = try await export(database, to: directory)
    let verified = try ArchiveVerifier().verify(at: archive)
    let library = try ArchiveReader(archive: verified).library()

    #expect(library.collections.map(\.name) == ["Kept"])
  }

  @Test("archive attachment extensions match what the attachment store can hold")
  func extensionParity() {
    let storeExtensions = Set(
      AttachmentStore.supportedUTIs.compactMap { AttachmentStore.fileExtension(forUTI: $0) })
    #expect(ArchiveFormat.attachmentExtensions == storeExtensions)
  }
}

@Suite("Archive schema version")
struct ArchiveSchemaVersionTests {
  @Test("the schema version recorded in exports is the migration count")
  func schemaVersion() {
    #expect(AppDatabase.schemaVersion == 6)
  }
}
