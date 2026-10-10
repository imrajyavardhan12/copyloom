import ClipArchive
import ClipDomain
import ClipboardCapture
import Foundation
import GRDB
import Testing

@testable import ClipStore

@Suite("Archive import into the database")
struct ArchiveSinkTests {
  private static let createdBy = ArchiveManifest.CreatedBy(
    app: "Copyloom", appVersion: "0.0.0-test", schemaVersion: 6)
  private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
  private static let now = epoch.addingTimeInterval(86_400)

  /// The production text gate; images decode as 8x6 whatever the archive says.
  private static let textGate = TextOutputGate()
  private static let gates = ImportGates(
    acceptText: { text in
      switch textGate.kind(for: text) {
      case .text: .text
      case .link: .link
      case .image: .image
      case .code: .code
      case .color: .color
      case .file: .file
      case nil: nil
      }
    },
    inspectImage: { _, _ in ImageInspection(width: 8, height: 6) })

  private struct Env {
    let root: URL
    let database: AppDatabase
    let directory: URL
  }

  private func environment() throws -> Env {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return try database(in: root, named: "main")
  }

  private func database(in root: URL, named name: String) throws -> Env {
    let directory = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Env(
      root: root, database: try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite")),
      directory: directory)
  }

  private func cleanUp(_ env: Env...) {
    for item in env { try? item.database.close() }
    if let first = env.first { try? FileManager.default.removeItem(at: first.root) }
  }

  private func export(_ env: Env, as name: String = "Export") async throws -> VerifiedArchive {
    let destination = env.root.appending(path: "\(name).copyloom", directoryHint: .isDirectory)
    try await ArchiveExporter(
      source: env.database.archiveSource(),
      isExportable: { Self.textGate.kind(for: $0) != nil },
      createdBy: Self.createdBy
    ).export(to: destination, now: Self.epoch)
    return try ArchiveVerifier().verify(at: destination)
  }

  private func importer(
    _ env: Env, gates: ImportGates = ArchiveSinkTests.gates,
    batching: ArchiveImporter.Batching = .init()
  ) -> ArchiveImporter {
    ArchiveImporter(sink: env.database.archiveSink(), gates: gates, batching: batching)
  }

  private func apply(_ archive: VerifiedArchive, into env: Env, cutoff: Date? = nil)
    async throws -> ImportSummary
  {
    try await importer(env).apply(archive, retentionCutoff: cutoff, now: Self.now)
  }

  /// Every table, every column, in a stable order, plus the attachment files
  /// with their modification times: anything an import could change.
  private func dump(_ env: Env) throws -> String {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(
      path: env.directory.appending(path: "copyloom.sqlite").path, configuration: configuration)
    let tables = [
      "clips", "clip_representations", "applications", "clip_application_sources",
      "attachments", "search_documents", "collections", "collection_items", "tags", "clip_tags",
      "saved_queries", "image_ocr_jobs",
    ]
    var out = try queue.read { database in
      try tables.map { table in
        let rows = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY rowid")
        return "\(table)\n" + rows.map { "\($0)" }.joined(separator: "\n")
      }
    }
    let attachments = env.directory.appending(path: "Attachments/v1")
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    let files =
      (FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: keys)?
        .allObjects as? [URL]) ?? []
    out += files.compactMap { url -> String? in
      let values = try? url.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { return nil }
      let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
      return "\(url.lastPathComponent) \(modified)"
    }.sorted()
    return out.joined(separator: "\n--\n")
  }

  /// Raw SQL for arranging a state the public API cannot produce.
  private func rawSQL(_ env: Env, _ sql: String) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(
      path: env.directory.appending(path: "copyloom.sqlite").path, configuration: configuration)
    try queue.write { try $0.execute(sql: sql) }
  }

  private func fileDigest(_ archive: VerifiedArchive, _ path: String) throws -> String {
    try #require(archive.manifest.files.first { $0.path == path }).sha256
  }

  private let safari = ClipSource(
    bundleIdentifier: "com.apple.Safari", applicationName: "Safari", provenance: .declared)

  /// A library with every kind of content and relationship.
  private func populate(_ env: Env) async throws -> (text: UUID, image: UUID) {
    let repository = env.database.repository
    let first = Self.epoch.addingTimeInterval(-3_600)
    let later = Self.epoch.addingTimeInterval(-1_800)
    let textID = UUID()
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: textID, text: "hello world", capturedAt: first, source: safari))
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "hello world", capturedAt: later, source: safari))
    try await repository.setPinned(id: textID, isPinned: true)
    try await repository.recordUse(id: textID, at: later)
    try await repository.tagClip(id: textID, tag: "Project")
    for (text, kind, offset) in [
      ("https://example.com/a", ClipKind.link, 10.0), ("#ff8800", .color, 20),
      ("{\"a\": 1}", .code, 30), ("/Users/me/a.txt\n/Users/me/b.txt", .file, 40),
    ] {
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: UUID(), kind: kind, text: text, capturedAt: first.addingTimeInterval(offset),
          source: nil))
    }
    let imageID = UUID()
    _ = try await repository.saveAcceptedImage(
      AcceptedImageClip(
        id: imageID, data: Data((0..<64).map { UInt8($0) }), uti: "public.png", width: 8,
        height: 6, capturedAt: first.addingTimeInterval(50), source: nil))
    try await repository.setFavorite(id: imageID, isFavorite: true)

    let collection = try await repository.createCollection(name: "Atlas", at: first)
    try await repository.addToCollection(collectionID: collection.id, clipID: textID, at: first)
    try await repository.addToCollection(
      collectionID: collection.id, clipID: imageID, at: first.addingTimeInterval(1))
    _ = try await repository.saveQuery(name: "Code", queryText: "type:code", at: first)
    return (textID, imageID)
  }

  // MARK: - Fidelity

  @Test("export, import, export again: the archive content is identical")
  func lossless() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    _ = try await populate(source)
    let original = try await export(source, as: "A")

    let report = try await apply(original, into: target)
    let again = try await export(target, as: "B")

    #expect(report.clipsAdded == 6 && report.rejections.total == 0)
    #expect(report.imagesQueuedForOCR == 1)
    #expect(try fileDigest(original, "clips.jsonl") == fileDigest(again, "clips.jsonl"))
    #expect(try fileDigest(original, "library.json") == fileDigest(again, "library.json"))
    #expect(original.manifest.counts == again.manifest.counts)
  }

  @Test("imported text is searchable, and an imported image waits in the OCR queue")
  func searchableAndQueued() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let ids = try await populate(source)

    _ = try await apply(try await export(source), into: target)

    let hits = try await target.database.repository.search(
      SearchQuery(text: [.term("hello")], filters: []), limit: 10)
    #expect(hits.map(\.id) == [ids.text])
    #expect(hits.first?.source?.applicationName == "Safari")
    let job = try await target.database.repository.ocrJob(for: ids.image)
    #expect(job?.status == .pending)
    let data = try await target.database.repository.attachmentData(for: ids.image)
    #expect(data == Data((0..<64).map { UInt8($0) }))
  }

  // MARK: - Idempotency

  @Test("importing the same archive twice leaves every table and file untouched")
  func idempotent() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    _ = try await populate(source)
    let archive = try await export(source)

    _ = try await apply(archive, into: target)
    let afterFirst = try dump(target)
    let second = try await apply(archive, into: target)

    #expect(try dump(target) == afterFirst)
    #expect(second.clipsAdded == 0 && second.clipsMerged == 6)
    #expect(second.library.collectionsAdded == 0 && second.library.membershipsAdded == 0)
    #expect(second.library.tagsAdded == 0 && second.library.queriesAdded == 0)
    #expect(second.imagesQueuedForOCR == 0)
  }

  @Test("importing into the library an archive came from changes nothing")
  func idempotentIntoSource() async throws {
    let source = try environment()
    defer { cleanUp(source) }
    _ = try await populate(source)
    let archive = try await export(source)
    let before = try dump(source)

    let report = try await apply(archive, into: source)

    #expect(try dump(source) == before)
    #expect(report.clipsAdded == 0 && report.clipsMerged == 6)
  }

  @Test("planning does not write anything, and equals the import on a fresh library")
  func planReadOnly() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    _ = try await populate(source)
    let archive = try await export(source)
    let empty = try dump(target)

    let plan = try await importer(target).plan(archive, retentionCutoff: nil, now: Self.now)

    #expect(try dump(target) == empty)
    let report = try await apply(archive, into: target)
    var expected = report
    expected.library.membershipsAdded = 0  // memberships depend on what the import maps
    #expect(plan == expected)
  }

  @Test("a plan against a library that already holds some of it equals the import")
  func planOnPopulatedLibrary() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let ids = try await populate(source)
    let archive = try await export(source)
    let local = target.database.repository
    // Same text under another UUID, plus a different clip holding an archive UUID.
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "hello world", capturedAt: Self.epoch))
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: ids.image, text: "squatter", capturedAt: Self.epoch))
    let before = try dump(target)

    let plan = try await importer(target).plan(archive, retentionCutoff: nil, now: Self.now)

    #expect(try dump(target) == before)
    #expect(plan.clipsMerged == 1 && plan.clipsAddedWithNewUUID == 1 && plan.clipsAdded == 4)
    let report = try await apply(archive, into: target)
    var expected = report
    expected.library.membershipsAdded = 0
    #expect(plan == expected)
  }

  // MARK: - Merge rules

  @Test("an existing clip is never overwritten; only flags, earliest creation and tags merge")
  func mergeMonotonic() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let repository = source.database.repository
    let early = Self.epoch.addingTimeInterval(-7_200)
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(
        id: UUID(), text: "shared text", capturedAt: early,
        source: ClipSource(
          bundleIdentifier: "com.apple.Safari", applicationName: "Hijacked", provenance: .declared)
      ))
    let id = try await repository.recent(limit: 1)[0].id
    try await repository.setPinned(id: id, isPinned: true)
    try await repository.setFavorite(id: id, isFavorite: true)
    try await repository.tagClip(id: id, tag: "imported")
    let archive = try await export(source)

    // The target already has the same text, copied later and more often.
    let local = target.database.repository
    let localFirst = Self.epoch.addingTimeInterval(-600)
    let localID = UUID()
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: localID, text: "shared text", capturedAt: localFirst, source: safari))
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(
        id: UUID(), text: "shared text", capturedAt: Self.epoch, source: safari))
    try await local.recordUse(id: localID, at: Self.epoch)
    let before = try await local.recent(limit: 10)

    let report = try await apply(archive, into: target)

    let after = try await local.recent(limit: 10)
    #expect(report.clipsMerged == 1 && report.clipsAdded == 0)
    #expect(after.count == 1 && before.count == 1)
    let merged = try #require(after.first)
    #expect(merged.id == localID)
    #expect(merged.copyCount == 2 && merged.useCount == 1)  // counters not added
    #expect(merged.lastSeenAt == Self.epoch)
    #expect(merged.isPinned && merged.isFavorite)  // flags only become true
    #expect(merged.createdAt == early)  // earliest creation wins
    #expect(try await local.tags(for: localID).map(\.name) == ["imported"])
    // The application keeps the name the library knew it by.
    #expect(merged.source?.applicationName == "Safari")
  }

  @Test("a flag already set in the library is never cleared by the archive")
  func flagsNeverCleared() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    _ = try await source.database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "same", capturedAt: Self.epoch))
    let archive = try await export(source)
    let local = target.database.repository
    let localID = UUID()
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: localID, text: "same", capturedAt: Self.epoch))
    try await local.setPinned(id: localID, isPinned: true)
    try await local.setFavorite(id: localID, isFavorite: true)

    _ = try await apply(archive, into: target)

    let clip = try #require(try await local.recent(limit: 1).first)
    #expect(clip.isPinned && clip.isFavorite)
  }

  @Test("a UUID held by different content, live or deleted, gets a fresh UUID")
  func uuidCollisions() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let liveClash = UUID()
    let deletedClash = UUID()
    let repository = source.database.repository
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: liveClash, text: "archive one", capturedAt: Self.epoch))
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(
        id: deletedClash, text: "archive two", capturedAt: Self.epoch.addingTimeInterval(1)))
    let archive = try await export(source)

    let local = target.database.repository
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: liveClash, text: "local live", capturedAt: Self.epoch))
    _ = try await local.saveAcceptedText(
      AcceptedTextClip(id: deletedClash, text: "local gone", capturedAt: Self.epoch))
    try await local.delete(id: deletedClash, at: Self.epoch)

    let first = try await apply(archive, into: target)
    let afterFirst = try dump(target)
    let second = try await apply(archive, into: target)

    #expect(first.clipsAddedWithNewUUID == 2 && first.clipsAdded == 0)
    let texts = Set(try await local.recent(limit: 10).map(\.text))
    #expect(texts == ["archive one", "archive two", "local live"])
    let clash = try await local.recent(limit: 10).filter { $0.id == liveClash }
    #expect(clash.map(\.text) == ["local live"])
    // Converges: the second run recognises the content under its new UUID.
    #expect(second.clipsMerged == 2 && second.clipsAddedWithNewUUID == 0)
    #expect(try dump(target) == afterFirst)
  }

  @Test("an archive cannot rename an application the library already knows")
  func applicationNotRenamed() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    _ = try await source.database.repository.saveAcceptedText(
      AcceptedTextClip(
        id: UUID(), text: "from elsewhere", capturedAt: Self.epoch,
        source: ClipSource(
          bundleIdentifier: "com.apple.Safari", applicationName: "Totally Not Safari",
          provenance: .declared)))
    let archive = try await export(source)
    _ = try await target.database.repository.saveAcceptedText(
      AcceptedTextClip(id: UUID(), text: "local", capturedAt: Self.epoch, source: safari))

    _ = try await apply(archive, into: target)

    let imported = try await target.database.repository.recent(limit: 10)
      .first { $0.text == "from elsewhere" }
    #expect(imported?.source?.applicationName == "Safari")
  }

  // MARK: - Hostile content

  @Test("text the production gate refuses is not stored or indexed")
  func sensitiveTextRefused() async throws {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let target = try database(in: scratch, named: "target")
    defer { cleanUp(target) }
    let secret = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nsynthetic-fixture"
    let writer = try ArchiveWriter(
      destination: scratch.appending(path: "Hostile.copyloom", directoryHint: .isDirectory))
    for text in ["innocent note", secret] {
      try writer.addClip(
        ClipRecord(
          uuid: UUID(), kind: .text, createdAt: Self.epoch, lastSeenAt: Self.epoch,
          lastUsedAt: nil, copyCount: 1, useCount: 0, isPinned: false, isFavorite: false,
          representations: [RepresentationRecord(uti: ArchiveFormat.textUTI, text: text)],
          sources: [], tags: []))
    }
    try writer.finish(library: .empty, createdBy: Self.createdBy, now: Self.epoch)
    let archive = try ArchiveVerifier().verify(
      at: scratch.appending(path: "Hostile.copyloom", directoryHint: .isDirectory))

    let report = try await apply(archive, into: target)

    #expect(report.clipsAdded == 1)
    #expect(report.rejections.count(.refusedByPrivacyGate) == 1)
    #expect(try await target.database.repository.recent(limit: 10).map(\.text) == ["innocent note"])
    #expect(!(try dump(target)).contains("synthetic-fixture"))
  }

  @Test("a failed batch is rolled back whole")
  func batchAtomic() async throws {
    let env = try environment()
    defer { cleanUp(env) }
    func clip(_ text: String, copyCount: Int) -> PreparedClip {
      PreparedClip(
        uuid: UUID(), kind: .text, content: .text(text), createdAt: Self.epoch,
        lastSeenAt: Self.epoch, lastUsedAt: nil, copyCount: copyCount, useCount: 0,
        isPinned: false, isFavorite: false, sources: [], tags: ["half"])
    }
    let sink = env.database.archiveSink()

    // The second clip violates a schema CHECK; the first must not survive.
    await #expect(throws: (any Error).self) {
      _ = try await sink.applyClips(
        [clip("good", copyCount: 1), clip("bad", copyCount: 0)], now: Self.now)
    }

    #expect(try await env.database.repository.count() == 0)
    #expect(try dump(env).contains("half") == false)
  }

  // MARK: - Images

  @Test("an image is stored from its verified bytes with dimensions from the decode")
  func importedImage() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let bytes = Data((0..<80).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let id = UUID()
    _ = try await source.database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: id, data: bytes, uti: "public.png", width: 99, height: 99,
        capturedAt: Self.epoch))
    let archive = try await export(source)

    _ = try await apply(archive, into: target)

    let attachment = try #require(try await target.database.repository.attachment(for: id))
    #expect(attachment.width == 8 && attachment.height == 6)  // the gate's decode, not the record
    #expect(attachment.byteCount == bytes.count && attachment.uti == "public.png")
    #expect(try await target.database.repository.attachmentData(for: id) == bytes)
  }

  @Test("re-importing restores an attachment file the library lost")
  func missingFileRestored() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let id = UUID()
    _ = try await source.database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: id, data: Data(repeating: 9, count: 40), uti: "public.png", width: 4, height: 4,
        capturedAt: Self.epoch))
    let archive = try await export(source)
    _ = try await apply(archive, into: target)
    let attachment = try #require(try await target.database.repository.attachment(for: id))
    target.database.attachments.remove(relativePaths: [attachment.relativePath])
    #expect(try await target.database.repository.attachmentData(for: id) == nil)

    _ = try await apply(archive, into: target)

    let restored = try await target.database.repository.attachmentData(for: id)
    #expect(restored == Data(repeating: 9, count: 40))
  }

  // MARK: - Library data

  @Test("tags keep the display names from library.json, and existing tags keep theirs")
  func tagNames() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let id = UUID()
    _ = try await source.database.repository.saveAcceptedText(
      AcceptedTextClip(id: id, text: "tagged", capturedAt: Self.epoch))
    try await source.database.repository.tagClip(id: id, tag: "Project X")
    try await source.database.repository.tagClip(id: id, tag: "Work")
    let archive = try await export(source)
    // The target already has a "work" tag spelled its own way.
    _ = try await target.database.repository.getOrCreateTag(name: "WORK")

    _ = try await apply(archive, into: target)

    let names = try await target.database.repository.tags(for: id).map(\.name)
    #expect(names.contains("Project X"))
    #expect(names.contains("WORK") && !names.contains("Work"))
  }

  @Test("an existing collection keeps its name and gains members; saved queries match by UUID")
  func collectionsAndQueries() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let repository = source.database.repository
    let clipID = UUID()
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: clipID, text: "member", capturedAt: Self.epoch))
    let collection = try await repository.createCollection(name: "Archive name", at: Self.epoch)
    try await repository.addToCollection(
      collectionID: collection.id, clipID: clipID, at: Self.epoch)
    let query = try await repository.saveQuery(
      name: "Archive query", queryText: "type:code", at: Self.epoch)
    let archive = try await export(source)

    // The target has the same collection and query UUIDs under local names.
    try rawSQL(
      target,
      """
      INSERT INTO collections (uuid, name, created_at, updated_at) VALUES ('\(collection.id.uuidString.lowercased())', 'Local name', 1, 1);
      INSERT INTO saved_queries (uuid, name, query_version, query_text, created_at, updated_at)
        VALUES ('\(query.id.uuidString.lowercased())', 'Local query', 1, 'type:link', 1, 1);
      """)

    let report = try await apply(archive, into: target)

    let local = target.database.repository
    #expect(try await local.listCollections().map(\.name) == ["Local name"])
    let members = try await local.collectionClips(collectionID: collection.id, limit: 10)
    #expect(members.map(\.id) == [clipID])
    #expect(try await local.listQueries().map(\.name) == ["Local query"])
    #expect(try await local.listQueries().map(\.queryText) == ["type:link"])
    #expect(report.library.collectionsExisting == 1 && report.library.membershipsAdded == 1)
    #expect(report.library.queriesExisting == 1)
  }

  @Test("a saved query written for another parser version is skipped, not imported")
  func staleQueryVersion() async throws {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let target = try database(in: scratch, named: "target")
    defer { cleanUp(target) }
    let destination = scratch.appending(path: "Q.copyloom", directoryHint: .isDirectory)
    let writer = try ArchiveWriter(destination: destination)
    try writer.finish(
      library: LibraryRecord(
        collections: [], tags: [],
        savedQueries: [
          SavedQueryRecord(uuid: UUID(), name: "old", queryVersion: 99, queryText: "x"),
          SavedQueryRecord(uuid: UUID(), name: "current", queryVersion: 1, queryText: "y"),
        ]),
      createdBy: Self.createdBy, now: Self.epoch)

    let report = try await apply(try ArchiveVerifier().verify(at: destination), into: target)

    #expect(report.library.queriesSkippedVersion == 1 && report.library.queriesAdded == 1)
    #expect(try await target.database.repository.listQueries().map(\.name) == ["current"])
  }

  // MARK: - Retention and interruption

  @Test("the retention warning counts exactly the clips the next cleanup deletes")
  func retentionWarningIsTrue() async throws {
    let source = try environment()
    let target = try database(in: source.root, named: "target")
    defer { cleanUp(source, target) }
    let repository = source.database.repository
    let old = Self.epoch.addingTimeInterval(-90 * 86_400)
    for (index, text) in ["old a", "old b", "old pinned", "old favorite", "recent"].enumerated() {
      let id = UUID()
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: id, text: text,
          capturedAt: text == "recent" ? Self.now : old.addingTimeInterval(Double(index))))
      if text == "old pinned" { try await repository.setPinned(id: id, isPinned: true) }
      if text == "old favorite" { try await repository.setFavorite(id: id, isFavorite: true) }
    }
    let archive = try await export(source)
    let cutoff = Self.now.addingTimeInterval(-30 * 86_400)

    let plan = try await importer(target).plan(archive, retentionCutoff: cutoff, now: Self.now)
    _ = try await apply(archive, into: target, cutoff: cutoff)
    let deleted = try await target.database.repository.deleteExpired(before: cutoff)

    #expect(plan.retentionAtRisk == 2)
    #expect(deleted == plan.retentionAtRisk)
  }

  @Test("an interrupted import resumes to the same result as an uninterrupted one")
  func resume() async throws {
    let source = try environment()
    let interrupted = try database(in: source.root, named: "interrupted")
    let whole = try database(in: source.root, named: "whole")
    defer { cleanUp(source, interrupted, whole) }
    for index in 0..<7 {
      _ = try await source.database.repository.saveAcceptedText(
        AcceptedTextClip(
          id: UUID(), text: "clip number \(index)",
          capturedAt: Self.epoch.addingTimeInterval(Double(index))))
    }
    let archive = try await export(source)

    // The text gate runs inside the importing task, so it can cancel it.
    let counter = Counter()
    let cancelling = ImportGates(
      acceptText: { text in
        if counter.increment() == 4 { withUnsafeCurrentTask { $0?.cancel() } }
        return Self.gates.acceptText(text)
      },
      inspectImage: Self.gates.inspectImage)
    let task = Task {
      try await importer(interrupted, gates: cancelling, batching: .init(maxClips: 2)).apply(
        archive, retentionCutoff: nil, now: Self.now)
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    let partial = try await interrupted.database.repository.count()
    #expect(partial > 0 && partial < 7)

    let resumed = try await apply(archive, into: interrupted)
    _ = try await apply(archive, into: whole)

    #expect(resumed.clipsMerged == partial && resumed.clipsAdded == 7 - partial)
    #expect(
      try Set(await interrupted.database.repository.recent(limit: 20).map(\.text))
        == Set(await whole.database.repository.recent(limit: 20).map(\.text)))
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
