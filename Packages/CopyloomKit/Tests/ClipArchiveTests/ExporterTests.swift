import Foundation
import Testing

@testable import ClipArchive

// MARK: - Fake source

/// An in-memory library. Records exactly what the exporter asked for so tests
/// can prove that skipped clips' data was never even fetched.
private final class FakeSource: ClipArchiveSource, @unchecked Sendable {
  var candidates: [ExportCandidate] = []
  var attachments: [String: Data] = [:]
  var library = LibraryRecord.empty
  var failAfter: Int?

  private(set) var fetchedAttachmentDigests: [String] = []

  func forEachLiveClip(_ body: (ExportCandidate) async throws -> Void) async throws {
    for (index, candidate) in candidates.enumerated() {
      if let failAfter, index >= failAfter { throw FakeFailure.boom }
      try await body(candidate)
    }
  }

  func libraryRecord() async throws -> LibraryRecord { library }

  func attachmentData(sha256: String) async throws -> Data? {
    fetchedAttachmentDigests.append(sha256)
    return attachments[sha256]
  }
}

private enum FakeFailure: Error { case boom }

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let createdBy = ArchiveManifest.CreatedBy(
  app: "Copyloom", appVersion: "0.0.0-test", schemaVersion: 6)

private func clip(
  _ text: String, kind: ArchiveClipKind = .text, uuid: UUID = UUID(), at offset: TimeInterval = 0
) -> ExportCandidate {
  ExportCandidate(
    clip: ClipRecord(
      uuid: uuid, kind: kind, createdAt: epoch.addingTimeInterval(offset),
      lastSeenAt: epoch.addingTimeInterval(offset), lastUsedAt: nil, copyCount: 1, useCount: 0,
      isPinned: false, isFavorite: false,
      representations: [RepresentationRecord(uti: "public.utf8-plain-text", text: text)],
      sources: [], tags: []),
    isQuarantinedImage: false)
}

private func image(
  _ data: Data, in source: FakeSource, quarantined: Bool = false, storeBytes: Bool = true
) -> ExportCandidate {
  let digest = ArchiveHashing.sha256Hex(data)
  if storeBytes { source.attachments[digest] = data }
  return ExportCandidate(
    clip: ClipRecord(
      uuid: UUID(), kind: .image, createdAt: epoch, lastSeenAt: epoch, lastUsedAt: nil,
      copyCount: 1, useCount: 0, isPinned: false, isFavorite: false,
      representations: [
        RepresentationRecord(
          uti: "public.png",
          attachment: ArchivePath.attachmentPath(sha256: digest, fileExtension: "png"),
          sha256: digest, bytes: data.count, width: 4, height: 3)
      ],
      sources: [], tags: []),
    isQuarantinedImage: quarantined)
}

private final class Scratch {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "exporter-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  var destination: URL { root.appending(path: "Library.copyloom", directoryHint: .isDirectory) }
}

/// A gate that refuses any text containing "SECRET".
private let gate: @Sendable (String) -> Bool = { !$0.contains("SECRET") }

private func exporter(_ source: FakeSource) -> ArchiveExporter {
  ArchiveExporter(source: source, isExportable: gate, createdBy: createdBy)
}

private func readBack(_ url: URL) throws -> (VerifiedArchive, [ClipRecord]) {
  let verified = try ArchiveVerifier().verify(at: url)
  var clips: [ClipRecord] = []
  try ArchiveReader(archive: verified).forEachClip { _, result in clips.append(try result.get()) }
  return (verified, clips)
}

// MARK: - Tests

@Suite("Archive exporter")
struct ArchiveExporterTests {
  @Test("exports clips and images into a verifiable archive, in source order")
  func roundTrip() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    let png = Data((0..<32).map { UInt8($0) })
    source.candidates = [clip("first"), image(png, in: source), clip("third")]

    let manifest = try await exporter(source).export(to: scratch.destination, now: epoch)

    #expect(manifest.counts.clips == 3)
    #expect(manifest.counts.attachments == 1)
    #expect(manifest.skipped == .none)
    let (verified, clips) = try readBack(scratch.destination)
    #expect(clips.map(\.uuid) == source.candidates.map(\.clip.uuid))
    let path = try #require(clips[1].representations.first?.attachment)
    #expect(try ArchiveReader(archive: verified).attachmentData(at: path) == png)
  }

  @Test("text the gate refuses is skipped and counted, never written")
  func sensitiveSkipped() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    source.candidates = [clip("fine"), clip("API SECRET value"), clip("also fine")]

    let manifest = try await exporter(source).export(to: scratch.destination, now: epoch)

    #expect(manifest.skipped.sensitive == 1)
    #expect(manifest.counts.clips == 2)
    let (_, clips) = try readBack(scratch.destination)
    #expect(clips.compactMap { $0.representations.first?.text } == ["fine", "also fine"])
    // The refused text appears nowhere in the package, not even the manifest.
    let all = try FileManager.default.subpathsOfDirectory(atPath: scratch.destination.path)
    for path in all {
      let url = scratch.destination.appending(path: path)
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        continue
      }
      #expect(!(try Data(contentsOf: url)).contains(Data("SECRET".utf8)))
    }
  }

  @Test("a quarantined image is skipped and its pixels are never fetched or written")
  func quarantinedImageSkipped() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    let secretPixels = Data(repeating: 0xAB, count: 40)
    source.candidates = [image(secretPixels, in: source, quarantined: true), clip("ok")]

    let manifest = try await exporter(source).export(to: scratch.destination, now: epoch)

    #expect(manifest.skipped.quarantinedImage == 1)
    #expect(manifest.counts.attachments == 0)
    #expect(source.fetchedAttachmentDigests.isEmpty)
    #expect(manifest.files.allSatisfy { !$0.path.hasPrefix("attachments/") })
  }

  @Test("a missing or corrupt attachment skips that clip only")
  func missingAttachment() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    let good = Data(repeating: 1, count: 16)
    let corrupt = Data(repeating: 2, count: 16)
    let missing = Data(repeating: 3, count: 16)
    source.candidates = [
      image(good, in: source), image(corrupt, in: source),
      image(missing, in: source, storeBytes: false), clip("text survives"),
    ]
    source.attachments[ArchiveHashing.sha256Hex(corrupt)] = Data(repeating: 9, count: 16)

    let manifest = try await exporter(source).export(to: scratch.destination, now: epoch)

    #expect(manifest.skipped.missingAttachment == 2)
    #expect(manifest.counts.clips == 2)
    #expect(manifest.counts.attachments == 1)
    _ = try readBack(scratch.destination)
  }

  @Test("collections list only clips that were actually exported")
  func collectionsFiltered() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    let kept = clip("kept")
    let dropped = clip("SECRET dropped")
    source.candidates = [kept, dropped]
    source.library = LibraryRecord(
      collections: [
        CollectionRecord(
          uuid: UUID(), name: "Mixed", parentUuid: nil, createdAt: epoch, updatedAt: epoch,
          clipUuids: [kept.clip.uuid, dropped.clip.uuid, UUID()])
      ],
      tags: [], savedQueries: [])

    _ = try await exporter(source).export(to: scratch.destination, now: epoch)

    let (verified, _) = try readBack(scratch.destination)
    let library = try ArchiveReader(archive: verified).library()
    #expect(library.collections.first?.clipUuids == [kept.clip.uuid])
  }

  @Test("a failure mid-export leaves no archive and no partial folder")
  func failureCleansUp() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    source.candidates = [clip("a"), clip("b"), clip("c")]
    source.failAfter = 2

    await #expect(throws: FakeFailure.self) {
      _ = try await exporter(source).export(to: scratch.destination, now: epoch)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root.path).isEmpty)
  }

  @Test("cancellation stops the export and cleans up")
  func cancellation() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    source.candidates = (0..<50).map { clip("clip \($0)") }
    let destination = scratch.destination

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await exporter(source).export(to: destination, now: epoch)
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root.path).isEmpty)
  }

  @Test("an existing destination is refused before any clip is read")
  func destinationExists() async throws {
    let scratch = try Scratch()
    try FileManager.default.createDirectory(
      at: scratch.destination, withIntermediateDirectories: true)
    let source = FakeSource()
    source.candidates = [clip("x")]

    await #expect(throws: ArchiveError.destinationExists) {
      _ = try await exporter(source).export(to: scratch.destination, now: epoch)
    }
    #expect(source.fetchedAttachmentDigests.isEmpty)
  }

  @Test("the skip report carries counts only, never content")
  func reportHasNoContent() async throws {
    let scratch = try Scratch()
    let source = FakeSource()
    source.candidates = [clip("TOP SECRET plan")]

    let manifest = try await exporter(source).export(to: scratch.destination, now: epoch)

    let encoded = String(decoding: try ArchiveCoding.encoder().encode(manifest), as: UTF8.self)
    #expect(!encoded.contains("SECRET"))
    #expect(manifest.skipped.sensitive == 1)
  }
}
