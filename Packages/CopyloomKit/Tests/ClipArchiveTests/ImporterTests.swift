import Foundation
import Testing

@testable import ClipArchive

// MARK: - Fixtures

private final class Scratch {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "importer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var archiveURL: URL { root.appending(path: "Library.copyloom", directoryHint: .isDirectory) }
}

private enum FakeFailure: Error { case boom }

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let now = epoch.addingTimeInterval(86_400)
private let createdBy = ArchiveManifest.CreatedBy(
  app: "Copyloom", appVersion: "0.0.0-test", schemaVersion: 6)
private let textUTI = "public.utf8-plain-text"

/// Builds an archive on disk from records, so every test goes through the
/// real verifier and reader.
private struct Fixture {
  var clips: [ClipRecord] = []
  var attachments: [Data] = []
  var rawLines: [String] = []
  var library = LibraryRecord.empty
  var skipped = ArchiveManifest.Skipped.none

  @discardableResult
  mutating func text(
    _ text: String, kind: ArchiveClipKind = .text, uuid: UUID = UUID(), seen: Date = epoch,
    pinned: Bool = false, favorite: Bool = false, tags: [String] = [],
    sources: [SourceRecord] = []
  ) -> ClipRecord {
    let record = ClipRecord(
      uuid: uuid, kind: kind, createdAt: epoch, lastSeenAt: seen, lastUsedAt: nil, copyCount: 1,
      useCount: 0, isPinned: pinned, isFavorite: favorite,
      representations: [RepresentationRecord(uti: textUTI, text: text)],
      sources: sources, tags: tags)
    clips.append(record)
    return record
  }

  @discardableResult
  mutating func image(
    _ data: Data, kind: ArchiveClipKind = .image, uti: String = "public.png",
    fileExtension: String = "png", uuid: UUID = UUID()
  ) -> ClipRecord {
    let digest = ArchiveHashing.sha256Hex(data)
    attachments.append(data)
    let record = ClipRecord(
      uuid: uuid, kind: kind, createdAt: epoch, lastSeenAt: epoch, lastUsedAt: nil, copyCount: 1,
      useCount: 0, isPinned: false, isFavorite: false,
      representations: [
        RepresentationRecord(
          uti: uti,
          attachment: ArchivePath.attachmentPath(sha256: digest, fileExtension: fileExtension),
          sha256: digest, bytes: data.count, width: 4, height: 3)
      ],
      sources: [], tags: [])
    clips.append(record)
    return record
  }

  func build(in scratch: Scratch) throws -> VerifiedArchive {
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    for data in attachments {
      _ = try writer.addAttachment(data: data, fileExtension: "png")
    }
    // Clips whose attachment uses another extension are written raw: the
    // writer only accepts attachments it stored itself.
    for clip in clips {
      if let path = clip.representations.first?.attachment,
        case .attachment(_, let ext)? = ArchivePath.parse(path), ext != "png"
      {
        let data = attachments.first {
          ArchiveHashing.sha256Hex($0) == clip.representations.first?.sha256
        }!
        _ = try writer.addAttachment(data: data, fileExtension: ext)
      }
      try writer.addClip(clip)
    }
    try writer.injectRawClipLines(rawLines)
    try writer.finish(library: library, createdBy: createdBy, skipped: skipped, now: epoch)
    return try ArchiveVerifier().verify(at: scratch.archiveURL)
  }
}

private func png(_ seed: UInt8, count: Int = 48) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) })
}

/// Text containing "SECRET" is refused; text starting with "https://" is a
/// link; everything else is plain text. Images starting with 0xBA are refused;
/// the rest decode as 7x5 whatever the archive claims.
private let gates = ImportGates(
  acceptText: { text in
    if text.contains("SECRET") { return nil }
    return text.hasPrefix("https://") ? .link : .text
  },
  inspectImage: { data, _ in
    data.first == 0xBA ? nil : ImageInspection(width: 7, height: 5)
  })

// MARK: - Fake sink

private final class FakeSink: ClipArchiveSink, @unchecked Sendable {
  struct Stored: Equatable {
    var uuid: UUID
    var kind: ArchiveClipKind
    var createdAt: Date
    var lastSeenAt: Date
    var isPinned: Bool
    var isFavorite: Bool
    var copyCount: Int
    var tags: Set<String>
  }

  private(set) var clips: [String: Stored] = [:]
  var retiredUUIDs: Set<UUID> = []
  private(set) var tagNames: [String: String] = [:]
  private(set) var log: [String] = []
  private(set) var batchSizes: [Int] = []
  private(set) var classified: [PreparedClip] = []
  private(set) var applied: [PreparedClip] = []
  private(set) var lastClipMap: [UUID: UUID] = [:]
  private(set) var appliedLibrary: PreparedLibrary?
  private(set) var classifiedLibrary: PreparedLibrary?
  var failOnBatch: Int?
  var afterBatch: ((Int) -> Void)?

  private static func key(_ clip: PreparedClip) -> String {
    switch clip.content {
    case .text(let text): "t:\(text)"
    case .image(let image): "i:\(image.uti):\(image.data.base64EncodedString())"
    }
  }

  private func disposition(for clip: PreparedClip, taken: Set<UUID>) -> ClipDisposition {
    if let existing = clips[Self.key(clip)] {
      return ClipDisposition(
        action: .merge,
        existing: .init(
          uuid: existing.uuid, lastSeenAt: existing.lastSeenAt,
          isProtected: existing.isPinned || existing.isFavorite))
    }
    let used = taken.union(clips.values.map(\.uuid)).union(retiredUUIDs)
    return ClipDisposition(action: used.contains(clip.uuid) ? .addWithNewUUID : .add)
  }

  func classifyClips(_ batch: [PreparedClip]) async throws -> [ClipDisposition] {
    log.append("classifyClips")
    classified += batch
    return batch.map { disposition(for: $0, taken: []) }
  }

  func applyClips(_ batch: [PreparedClip], now: Date) async throws -> [AppliedClip] {
    log.append("applyClips")
    batchSizes.append(batch.count)
    if failOnBatch == batchSizes.count { throw FakeFailure.boom }
    applied += batch
    var results: [AppliedClip] = []
    for clip in batch {
      let disposition = disposition(for: clip, taken: [])
      let key = Self.key(clip)
      switch disposition.action {
      case .merge:
        var stored = clips[key]!
        stored.isPinned = stored.isPinned || clip.isPinned
        stored.isFavorite = stored.isFavorite || clip.isFavorite
        stored.createdAt = min(stored.createdAt, clip.createdAt)
        stored.tags.formUnion(clip.tags.map { $0.lowercased() })
        clips[key] = stored
        results.append(AppliedClip(disposition: disposition, localUUID: stored.uuid))
      case .add, .addWithNewUUID:
        let uuid = disposition.action == .add ? clip.uuid : UUID()
        clips[key] = Stored(
          uuid: uuid, kind: clip.kind, createdAt: clip.createdAt, lastSeenAt: clip.lastSeenAt,
          isPinned: clip.isPinned, isFavorite: clip.isFavorite, copyCount: clip.copyCount,
          tags: Set(clip.tags.map { $0.lowercased() }))
        results.append(AppliedClip(disposition: disposition, localUUID: uuid))
      }
    }
    afterBatch?(batchSizes.count)
    return results
  }

  func applyTags(_ tags: [TagRecord]) async throws -> Int {
    log.append("applyTags")
    var added = 0
    for tag in tags where tagNames[tag.normalized] == nil {
      tagNames[tag.normalized] = tag.name
      added += 1
    }
    return added
  }

  func classifyLibrary(_ library: PreparedLibrary) async throws -> LibraryCounts {
    log.append("classifyLibrary")
    classifiedLibrary = library
    var counts = LibraryCounts()
    counts.collectionsAdded = library.collections.count
    counts.tagsAdded = library.tags.filter { tagNames[$0.normalized] == nil }.count
    counts.queriesAdded = library.savedQueries.count
    return counts
  }

  func applyLibrary(
    _ library: PreparedLibrary, clipMap: [UUID: UUID], now: Date
  ) async throws -> LibraryCounts {
    log.append("applyLibrary")
    appliedLibrary = library
    lastClipMap = clipMap
    var counts = LibraryCounts()
    counts.collectionsAdded = library.collections.count
    counts.queriesAdded = library.savedQueries.count
    let members = library.collections.flatMap(\.clipUuids)
    counts.membershipsAdded = members.filter { clipMap[$0] != nil }.count
    return counts
  }

  /// Everything an observer could see, for idempotency comparisons.
  var snapshot: [String: Stored] { clips }
}

private func importer(
  _ sink: FakeSink, gates: ImportGates = gates,
  batching: ArchiveImporter.Batching = .init()
) -> ArchiveImporter {
  ArchiveImporter(sink: sink, gates: gates, batching: batching)
}

// MARK: - Planning

@Suite("Import plan and apply")
struct ImportPlanTests {
  @Test("planning reads and classifies but never writes")
  func planIsReadOnly() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one")
    fixture.text("two")
    fixture.image(png(1))
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let plan = try await importer(sink).plan(archive, retentionCutoff: nil, now: now)

    #expect(plan.clipsInArchive == 3)
    #expect(plan.clipsAdded == 3)
    #expect(plan.imagesQueuedForOCR == 1)
    #expect(sink.applied.isEmpty && sink.clips.isEmpty)
    #expect(!sink.log.contains("applyClips") && !sink.log.contains("applyTags"))
    #expect(!sink.log.contains("applyLibrary"))
  }

  @Test("on an unchanged library the plan is exactly what the import then does")
  func planEqualsReport() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one", tags: ["a"])
    fixture.text("SECRET two")
    fixture.text("https://example.com")
    fixture.image(png(1))
    fixture.image(Data([0xBA, 0xD0]))
    fixture.library = LibraryRecord(
      collections: [
        CollectionRecord(
          uuid: UUID(), name: "Atlas", parentUuid: nil, createdAt: epoch, updatedAt: epoch,
          clipUuids: [])
      ],
      tags: [TagRecord(name: "A", normalized: "a")],
      savedQueries: [SavedQueryRecord(uuid: UUID(), name: "Code", queryVersion: 1, queryText: "x")])
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let plan = try await importer(sink).plan(archive, retentionCutoff: nil, now: now)
    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(plan == report)
    #expect(report.clipsAdded == 3 && report.rejections.total == 2)
  }

  @Test("importing the same archive twice changes nothing the second time")
  func idempotent() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one", pinned: true, tags: ["a"])
    fixture.text("two")
    fixture.image(png(1))
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let first = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)
    let afterFirst = sink.snapshot
    let second = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(first.clipsAdded == 3 && first.clipsMerged == 0)
    #expect(second.clipsAdded == 0 && second.clipsMerged == 3)
    #expect(second.imagesQueuedForOCR == 0)
    #expect(sink.snapshot == afterFirst)
  }

  @Test("tags are created first, then clips, then collections and queries")
  func phaseOrder() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one")
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(sink.log == ["applyTags", "applyClips", "applyLibrary"])
  }

  @Test("progress is monotonic and ends at the total")
  func progress() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<5 { fixture.text("clip \(index)") }
    let archive = try fixture.build(in: scratch)
    let seen = ProgressLog()

    _ = try await importer(FakeSink(), batching: .init(maxClips: 2)).apply(
      archive, retentionCutoff: nil, now: now, progress: { seen.add($0) })

    let values = seen.values
    #expect(values.map(\.processed) == values.map(\.processed).sorted())
    #expect(values.last == ImportProgress(processed: 5, total: 5))
  }

  @Test("files the manifest does not list, and export-time skips, are reported")
  func archiveFacts() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one")
    fixture.skipped = ArchiveManifest.Skipped(sensitive: 3, quarantinedImage: 1)
    _ = try fixture.build(in: scratch)
    try Data("notes".utf8).write(to: scratch.archiveURL.appending(path: "notes.txt"))
    let archive = try ArchiveVerifier().verify(at: scratch.archiveURL)

    let report = try await importer(FakeSink()).apply(archive, retentionCutoff: nil, now: now)

    #expect(report.unlistedFiles == 1)
    #expect(report.skippedAtExport == ArchiveManifest.Skipped(sensitive: 3, quarantinedImage: 1))
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ImportProgress] = []
  func add(_ value: ImportProgress) {
    lock.lock()
    stored.append(value)
    lock.unlock()
  }
  var values: [ImportProgress] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

// MARK: - Gates

@Suite("Import privacy gates")
struct ImportGateTests {
  @Test("text the gate refuses never reaches the sink and is only counted")
  func refusedText() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("fine")
    fixture.text("my SECRET token")
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let plan = try await importer(sink).plan(archive, retentionCutoff: nil, now: now)
    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    for summary in [plan, report] {
      #expect(summary.rejections.count(.refusedByPrivacyGate) == 1)
      #expect(summary.clipsAdded == 1)
    }
    let seen = (sink.classified + sink.applied).compactMap { clip -> String? in
      if case .text(let text) = clip.content { return text }
      return nil
    }
    #expect(!seen.contains { $0.contains("SECRET") })
  }

  @Test("an importer with unwired gates persists nothing")
  func refusingEverything() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one")
    fixture.image(png(1))
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let report = try await importer(sink, gates: .refusingEverything).apply(
      archive, retentionCutoff: nil, now: now)

    #expect(sink.clips.isEmpty && sink.applied.isEmpty)
    #expect(report.clipsAdded == 0)
    #expect(report.rejections.count(.refusedByPrivacyGate) == 1)
    #expect(report.rejections.count(.refusedImage) == 1)
  }

  @Test("the stored kind comes from the gate, not from the record")
  func kindIsDerived() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("just words", kind: .link)
    fixture.text("https://example.com", kind: .text)
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    let kinds = Dictionary(
      uniqueKeysWithValues: sink.applied.compactMap { clip -> (String, ArchiveClipKind)? in
        if case .text(let text) = clip.content { return (text, clip.kind) }
        return nil
      })
    #expect(kinds["just words"] == .text)
    #expect(kinds["https://example.com"] == .link)
  }

  @Test("a file reference keeps its kind, as capture stores it without classifying")
  func fileKindPreserved() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("/Users/me/a.txt\n/Users/me/b.txt", kind: .file)
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(sink.applied.first?.kind == .file)
  }

  @Test("a file-kind record still has to pass the text gate")
  func fileKindStillGated() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("/Users/me/SECRET.txt", kind: .file)
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(sink.applied.isEmpty)
    #expect(report.rejections.count(.refusedByPrivacyGate) == 1)
  }

  @Test("image dimensions come from the gate's decode, not from the record")
  func dimensionsFromGate() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.image(png(1))  // the record claims 4x3
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    guard case .image(let image)? = sink.applied.first?.content else {
      Issue.record("expected an image")
      return
    }
    #expect(image.width == 7 && image.height == 5)
    #expect(image.data == png(1) && image.uti == "public.png")
  }

  @Test("an image the gate refuses is counted and never stored")
  func refusedImage() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.image(Data([0xBA, 0xD0, 0x01]))
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(sink.applied.isEmpty)
    #expect(report.rejections.count(.refusedImage) == 1)
    #expect(report.imagesQueuedForOCR == 0)
  }

  @Test("an attachment edited after verification aborts the import")
  func attachmentChangedAfterVerification() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    let record = fixture.image(png(1))
    let archive = try fixture.build(in: scratch)
    let path = try #require(record.representations.first?.attachment)
    var bytes = try Data(contentsOf: archive.root.appending(path: path))
    bytes[0] ^= 0x01
    try bytes.write(to: archive.root.appending(path: path))
    let sink = FakeSink()

    await #expect(throws: ArchiveError.digestMismatch(path)) {
      _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)
    }
    #expect(sink.applied.isEmpty)
  }
}

// MARK: - Record validation

@Suite("Import record validation")
struct ImportValidationTests {
  private func run(_ build: (inout Fixture) throws -> Void) async throws -> (
    ImportSummary, FakeSink
  ) {
    let scratch = try Scratch()
    var fixture = Fixture()
    try build(&fixture)
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()
    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)
    return (report, sink)
  }

  @Test("a malformed line is counted with its line number; neighbours still import")
  func malformed() async throws {
    let (report, sink) = try await run { fixture in
      fixture.text("good")
      fixture.rawLines.append("{not json")
    }
    #expect(report.rejections.count(.malformedRecord) == 1)
    #expect(report.rejections.samples.first?.line == 2)
    #expect(sink.applied.count == 1)
  }

  @Test("kind and representation must agree")
  func kindMismatch() async throws {
    let (report, sink) = try await run { fixture in
      let image = fixture.image(png(1))
      fixture.clips.removeAll()
      var asText = image
      asText.kind = .text
      fixture.clips.append(asText)
      var textAsImage = ClipRecord(
        uuid: UUID(), kind: .image, createdAt: epoch, lastSeenAt: epoch, lastUsedAt: nil,
        copyCount: 1, useCount: 0, isPinned: false, isFavorite: false,
        representations: [RepresentationRecord(uti: textUTI, text: "words")], sources: [],
        tags: [])
      textAsImage.kind = .image
      fixture.clips.append(textAsImage)
    }
    #expect(report.rejections.count(.unsupportedContent) == 2)
    #expect(sink.applied.isEmpty)
  }

  @Test("only one plain-text or image representation per clip is imported")
  func representations() async throws {
    let (report, sink) = try await run { fixture in
      var multi = fixture.text("two forms")
      fixture.clips.removeAll()
      multi.representations.append(RepresentationRecord(uti: "public.html", text: "<b>x</b>"))
      fixture.clips.append(multi)
      var html = fixture.text("html only")
      fixture.clips.removeLast()
      html.representations = [RepresentationRecord(uti: "public.html", text: "<b>x</b>")]
      fixture.clips.append(html)
      fixture.text("fine")
    }
    #expect(report.rejections.count(.unsupportedContent) == 2)
    #expect(sink.applied.count == 1)
  }

  @Test("an image whose path extension disagrees with its type is refused")
  func extensionMismatch() async throws {
    let (report, sink) = try await run { fixture in
      fixture.image(png(1), uti: "public.jpeg", fileExtension: "png")
    }
    #expect(report.rejections.count(.unsupportedContent) == 1)
    #expect(sink.applied.isEmpty)
  }

  @Test("counters outside what the schema allows reject the clip, not the batch")
  func counters() async throws {
    let (report, sink) = try await run { fixture in
      let base = fixture.text("base")
      fixture.clips.removeAll()
      for change in [
        { (clip: inout ClipRecord) in clip.copyCount = 0 },
        { (clip: inout ClipRecord) in clip.useCount = -1 },
        { (clip: inout ClipRecord) in clip.copyCount = 2_000_000_000 },
      ] {
        var clip = base
        clip.uuid = UUID()
        clip.representations = [
          RepresentationRecord(uti: textUTI, text: "x\(fixture.clips.count)")
        ]
        change(&clip)
        fixture.clips.append(clip)
      }
      fixture.text("fine")
    }
    #expect(report.rejections.count(.invalidValue) == 3)
    #expect(sink.applied.count == 1)
  }

  @Test("timestamps from the future are clamped and last-seen never precedes created")
  func timestamps() async throws {
    let (_, sink) = try await run { fixture in
      var future = fixture.text("future")
      fixture.clips.removeAll()
      future.createdAt = now.addingTimeInterval(1_000)
      future.lastSeenAt = Date(timeIntervalSince1970: 253_370_000_000)
      future.lastUsedAt = now.addingTimeInterval(5)
      fixture.clips.append(future)
      var backwards = fixture.text("backwards")
      fixture.clips.removeLast()
      backwards.createdAt = epoch
      backwards.lastSeenAt = epoch.addingTimeInterval(-500)
      fixture.clips.append(backwards)
    }
    let byText = Dictionary(
      uniqueKeysWithValues: sink.applied.compactMap { clip -> (String, PreparedClip)? in
        if case .text(let text) = clip.content { return (text, clip) }
        return nil
      })
    let future = try #require(byText["future"])
    #expect(future.createdAt == now && future.lastSeenAt == now && future.lastUsedAt == now)
    let backwards = try #require(byText["backwards"])
    #expect(backwards.lastSeenAt >= backwards.createdAt)
  }

  @Test("invalid or excess sources and tags are dropped while the clip is kept")
  func metadata() async throws {
    let source = { (id: String) in
      SourceRecord(
        bundleId: id, name: "App", provenance: .declared, firstSeenAt: epoch, lastSeenAt: epoch,
        copyCount: 1)
    }
    let (report, sink) = try await run { fixture in
      fixture.text(
        "tagged",
        tags: ["Work", "work", "  ", String(repeating: "t", count: 500), "play"],
        sources: [source("com.good.App"), source(""), source(String(repeating: "b", count: 999))]
          + (0..<60).map { source("com.many.App\($0)") })
    }
    let clip = try #require(sink.applied.first)
    #expect(clip.tags == ["Work", "play"])
    #expect(clip.sources.count == 50)
    #expect(clip.sources.allSatisfy { !$0.bundleId.isEmpty && $0.bundleId.count <= 255 })
    #expect(report.metadataDropped > 0)
    #expect(report.clipsAdded == 1)
  }
}

// MARK: - Batching, tampering, cancellation

@Suite("Import batching and interruption")
struct ImportBatchTests {
  @Test("clips are applied in batches bounded by count")
  func batchByCount() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<5 { fixture.text("clip \(index)") }
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink, batching: .init(maxClips: 2)).apply(
      archive, retentionCutoff: nil, now: now)

    #expect(sink.batchSizes == [2, 2, 1])
  }

  @Test("image batches are bounded by bytes so memory stays bounded")
  func batchByBytes() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<4 { fixture.image(png(UInt8(index), count: 100)) }
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    _ = try await importer(sink, batching: .init(maxClips: 500, maxBytes: 250)).apply(
      archive, retentionCutoff: nil, now: now)

    #expect(sink.batchSizes == [2, 2])
  }

  @Test("a clips file edited after verification applies nothing from the final batch")
  func tamperedMidStream() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<3 { fixture.text("clip \(index)") }
    let archive = try fixture.build(in: scratch)
    let url = archive.root.appending(path: "clips.jsonl")
    var data = try Data(contentsOf: url)
    data[data.count - 3] ^= 0x01
    try data.write(to: url)
    let sink = FakeSink()

    await #expect(throws: ArchiveError.digestMismatch("clips.jsonl")) {
      _ = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)
    }
    #expect(sink.applied.isEmpty)
  }

  @Test("a sink failure stops the import; later batches are not attempted")
  func sinkFailure() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<6 { fixture.text("clip \(index)") }
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()
    sink.failOnBatch = 2

    await #expect(throws: FakeFailure.self) {
      _ = try await importer(sink, batching: .init(maxClips: 2)).apply(
        archive, retentionCutoff: nil, now: now)
    }
    #expect(sink.batchSizes == [2, 2])
    #expect(sink.applied.count == 2)
  }

  @Test("cancelling leaves a valid partial import and re-running completes it")
  func cancelAndResume() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    for index in 0..<5 { fixture.text("clip \(index)") }
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()
    // Runs inside the importing task, so it cancels exactly that task.
    sink.afterBatch = { batch in
      if batch == 1 { withUnsafeCurrentTask { $0?.cancel() } }
    }
    let started = Task {
      try await importer(sink, batching: .init(maxClips: 2)).apply(
        archive, retentionCutoff: nil, now: now)
    }

    await #expect(throws: CancellationError.self) { _ = try await started.value }
    let partial = sink.clips.count
    #expect(partial >= 2 && partial < 5)

    sink.afterBatch = nil
    let resumed = try await importer(sink, batching: .init(maxClips: 2)).apply(
      archive, retentionCutoff: nil, now: now)

    #expect(sink.clips.count == 5)
    #expect(resumed.clipsAdded == 5 - partial && resumed.clipsMerged == partial)
  }

  @Test("the same content twice in one archive is added once and merged once")
  func duplicatesInsideArchive() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("same")
    fixture.text("same", pinned: true)
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(report.clipsAdded == 1 && report.clipsMerged == 1)
    #expect(sink.clips.values.first?.isPinned == true)
  }
}

// MARK: - Library

@Suite("Import library data")
struct ImportLibraryTests {
  private func collection(
    _ name: String, uuid: UUID = UUID(), parent: UUID? = nil, clips: [UUID] = []
  ) -> CollectionRecord {
    CollectionRecord(
      uuid: uuid, name: name, parentUuid: parent, createdAt: epoch, updatedAt: epoch,
      clipUuids: clips)
  }

  @Test("invalid entries are rejected, parents resolve or drop, parents come first")
  func libraryValidation() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("one")
    let parent = UUID()
    let child = UUID()
    let loopA = UUID()
    let loopB = UUID()
    let orphan = UUID()
    fixture.library = LibraryRecord(
      collections: [
        collection("Child", uuid: child, parent: parent),
        collection("Parent", uuid: parent),
        collection("   "),
        collection(String(repeating: "n", count: 999)),
        collection("A", uuid: loopA, parent: loopB),
        collection("B", uuid: loopB, parent: loopA),
        collection("Orphan", uuid: orphan, parent: UUID()),
      ],
      tags: [
        TagRecord(name: "Good", normalized: "good"), TagRecord(name: " ", normalized: ""),
        TagRecord(name: String(repeating: "t", count: 500), normalized: "x"),
      ],
      savedQueries: [
        SavedQueryRecord(uuid: UUID(), name: "ok", queryVersion: 1, queryText: "type:code"),
        SavedQueryRecord(uuid: UUID(), name: "", queryVersion: 1, queryText: "x"),
        SavedQueryRecord(uuid: UUID(), name: "empty", queryVersion: 1, queryText: ""),
      ])
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    let library = try #require(sink.appliedLibrary)
    let names = library.collections.map(\.name)
    #expect(names.contains("Parent") && names.contains("Child"))
    #expect(try #require(names.firstIndex(of: "Parent")) < #require(names.firstIndex(of: "Child")))
    #expect(library.collections.first { $0.uuid == child }?.parentUuid == parent)
    #expect(library.collections.first { $0.uuid == orphan }?.parentUuid == nil)
    for uuid in [loopA, loopB] {
      #expect(library.collections.first { $0.uuid == uuid }?.parentUuid == nil)
    }
    #expect(!names.contains("   "))
    #expect(library.tags.map(\.name) == ["Good"])
    #expect(library.savedQueries.map(\.name) == ["ok"])
    #expect(report.libraryEntriesRejected == 2 + 2 + 2)
  }

  @Test("membership follows a clip to the UUID it has in the library")
  func membershipMapping() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    let archiveUUID = UUID()
    let refusedUUID = UUID()
    fixture.text("kept", uuid: archiveUUID)
    fixture.text("SECRET", uuid: refusedUUID)
    fixture.library = LibraryRecord(
      collections: [collection("Atlas", clips: [archiveUUID, refusedUUID, UUID()])],
      tags: [], savedQueries: [])
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()
    // The same content already lives in the library under another UUID.
    let existing = UUID()
    let seed = ClipRecord(
      uuid: existing, kind: .text, createdAt: epoch, lastSeenAt: epoch, lastUsedAt: nil,
      copyCount: 1, useCount: 0, isPinned: false, isFavorite: false,
      representations: [RepresentationRecord(uti: textUTI, text: "kept")], sources: [], tags: [])
    var seedFixture = Fixture()
    seedFixture.clips = [seed]
    let seedScratch = try Scratch()
    _ = try await importer(sink).apply(
      try seedFixture.build(in: seedScratch), retentionCutoff: nil, now: now)

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(sink.lastClipMap == [archiveUUID: existing])
    #expect(report.library.membershipsAdded == 1)
  }

  @Test("a re-assigned UUID is what membership and the map use")
  func reassignedUUID() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    let taken = UUID()
    fixture.text("different content", uuid: taken)
    fixture.library = LibraryRecord(
      collections: [collection("Atlas", clips: [taken])], tags: [], savedQueries: [])
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()
    sink.retiredUUIDs = [taken]

    let report = try await importer(sink).apply(archive, retentionCutoff: nil, now: now)

    #expect(report.clipsAddedWithNewUUID == 1 && report.clipsAdded == 0)
    let mapped = try #require(sink.lastClipMap[taken])
    #expect(mapped != taken)
  }
}

// MARK: - Retention warning

@Suite("Import retention warning")
struct ImportRetentionTests {
  private let cutoff = epoch.addingTimeInterval(3_600)

  @Test("counts unprotected clips that retention would delete at its next run")
  func atRisk() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("old")
    fixture.text("old pinned", pinned: true)
    fixture.text("old favorite", favorite: true)
    fixture.text("recent", seen: now)
    fixture.image(png(1))  // lastSeen = epoch: old
    let archive = try fixture.build(in: scratch)
    let sink = FakeSink()

    let plan = try await importer(sink).plan(archive, retentionCutoff: cutoff, now: now)
    let report = try await importer(sink).apply(archive, retentionCutoff: cutoff, now: now)

    #expect(plan.retentionAtRisk == 2)
    #expect(report.retentionAtRisk == 2)
  }

  @Test("no cutoff means no warning")
  func noCutoff() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("old")
    let archive = try fixture.build(in: scratch)

    let plan = try await importer(FakeSink()).plan(archive, retentionCutoff: nil, now: now)

    #expect(plan.retentionAtRisk == 0)
  }

  @Test("a merged clip is judged on the library's state after the merge")
  func mergedState() async throws {
    let sink = FakeSink()
    // Library already has these: one recent, one old and unprotected.
    let seedScratch = try Scratch()
    var seed = Fixture()
    seed.text("recent here", seen: now)
    seed.text("old here")
    seed.text("old here but pinned in archive")
    _ = try await importer(sink).apply(
      try seed.build(in: seedScratch), retentionCutoff: nil, now: now)

    var fixture = Fixture()
    fixture.text("recent here")  // archive says old; the library's copy is recent
    fixture.text("old here")  // old in both, unprotected: at risk
    fixture.text("old here but pinned in archive", pinned: true)  // the merge protects it
    let scratch = try Scratch()
    let archive = try fixture.build(in: scratch)

    let plan = try await importer(sink).plan(archive, retentionCutoff: cutoff, now: now)

    #expect(plan.retentionAtRisk == 1)
    #expect(plan.clipsMerged == 3)
  }
}

// MARK: - Summaries never carry content

@Suite("Import reporting")
struct ImportReportingTests {
  @Test("a summary contains counts and fixed wording only")
  func noContent() async throws {
    let scratch = try Scratch()
    var fixture = Fixture()
    fixture.text("TOPSECRETNOTE SECRET")
    fixture.text("visible clip text")
    fixture.rawLines.append("{\"uuid\":\"leaky clip text\"")
    let archive = try fixture.build(in: scratch)

    let report = try await importer(FakeSink()).apply(archive, retentionCutoff: nil, now: now)

    let description = String(describing: report)
    #expect(!description.contains("TOPSECRETNOTE"))
    #expect(!description.contains("visible clip text"))
    #expect(!description.contains("leaky"))
    #expect(report.rejections.samples.count == 2)
  }
}
