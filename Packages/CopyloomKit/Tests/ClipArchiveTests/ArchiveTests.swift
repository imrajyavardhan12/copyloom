import Foundation
import Testing

@testable import ClipArchive

// MARK: - Fixtures

/// A throwaway directory removed when the test ends.
private final class Scratch {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "archive-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var archiveURL: URL { root.appending(path: "Library.copyloom", directoryHint: .isDirectory) }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let createdBy = ArchiveManifest.CreatedBy(
  app: "Copyloom", appVersion: "0.0.0-test", schemaVersion: 6)

private func textClip(_ text: String, uuid: UUID = UUID(), tags: [String] = []) -> ClipRecord {
  ClipRecord(
    uuid: uuid, kind: .text, createdAt: epoch, lastSeenAt: epoch.addingTimeInterval(60),
    lastUsedAt: nil, copyCount: 2, useCount: 1, isPinned: true, isFavorite: false,
    representations: [RepresentationRecord(uti: "public.utf8-plain-text", text: text)],
    sources: [
      SourceRecord(
        bundleId: "com.apple.Safari", name: "Safari", provenance: .declared,
        firstSeenAt: epoch, lastSeenAt: epoch.addingTimeInterval(60), copyCount: 2)
    ],
    tags: tags)
}

private func imageClip(_ ref: ArchiveAttachmentRef) -> ClipRecord {
  ClipRecord(
    uuid: UUID(), kind: .image, createdAt: epoch, lastSeenAt: epoch, lastUsedAt: nil,
    copyCount: 1, useCount: 0, isPinned: false, isFavorite: true,
    representations: [
      RepresentationRecord(
        uti: "public.png", attachment: ref.path, sha256: ref.sha256, bytes: ref.bytes,
        width: 4, height: 3)
    ],
    sources: [], tags: [])
}

private let library = LibraryRecord(
  collections: [
    CollectionRecord(
      uuid: UUID(), name: "Atlas", parentUuid: nil, createdAt: epoch, updatedAt: epoch,
      clipUuids: [])
  ],
  tags: [TagRecord(name: "Project", normalized: "project")],
  savedQueries: [
    SavedQueryRecord(uuid: UUID(), name: "Code", queryVersion: 1, queryText: "type:code")
  ]
)

private struct Built {
  let url: URL
  let manifest: ArchiveManifest
  let clips: [ClipRecord]
  let attachment: ArchiveAttachmentRef
  let attachmentData: Data
}

/// Writes a small but complete archive: two text clips, one image, library.
private func build(in scratch: Scratch, extraClips: Int = 0) throws -> Built {
  let writer = try ArchiveWriter(destination: scratch.archiveURL)
  let data = Data((0..<64).map { UInt8($0) })
  let ref = try writer.addAttachment(data: data, fileExtension: "png")
  var clips = [
    textClip("hello world", tags: ["project"]),
    textClip("second\nclip with \"quotes\" and / slashes"),
    imageClip(ref),
  ]
  for index in 0..<extraClips { clips.append(textClip("extra \(index)")) }
  for clip in clips { try writer.addClip(clip) }
  let manifest = try writer.finish(library: library, createdBy: createdBy, now: epoch)
  return Built(
    url: scratch.archiveURL, manifest: manifest, clips: clips, attachment: ref,
    attachmentData: data)
}

private func rewriteManifest(
  at archive: URL, _ mutate: (inout [String: Any]) -> Void
) throws {
  let url = archive.appending(path: "manifest.json")
  var object = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  mutate(&object)
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    .write(to: url)
}

private func flipFirstByte(of url: URL) throws {
  var data = try Data(contentsOf: url)
  data[0] ^= 0xFF
  try data.write(to: url)
}

// MARK: - Round trip

@Suite("Archive round trip")
struct ArchiveRoundTripTests {
  @Test("a written archive verifies and reads back identically")
  func roundTrip() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)

    let verified = try ArchiveVerifier().verify(at: built.url)
    #expect(verified.manifest == built.manifest)
    #expect(verified.unlistedFiles.isEmpty)

    let reader = ArchiveReader(archive: verified)
    var read: [ClipRecord] = []
    try reader.forEachClip { _, result in read.append(try result.get()) }
    #expect(read == built.clips)
    #expect(try reader.library() == library)
    #expect(try reader.attachmentData(at: built.attachment.path) == built.attachmentData)
  }

  @Test("manifest counts and file list describe exactly what was written")
  func manifestContents() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let manifest = built.manifest

    #expect(manifest.format == ArchiveFormat.identifier)
    #expect(manifest.formatVersion == 1)
    #expect(manifest.counts.clips == 3)
    #expect(manifest.counts.attachments == 1)
    #expect(manifest.counts.collections == 1)
    #expect(manifest.counts.tags == 1)
    #expect(manifest.counts.savedQueries == 1)
    let paths = manifest.files.map(\.path)
    #expect(paths == paths.sorted())
    #expect(paths.contains("clips.jsonl"))
    #expect(paths.contains("library.json"))
    #expect(paths.contains(built.attachment.path))
    #expect(paths.contains("manifest.json") == false)
  }

  @Test("identical attachment bytes are stored once")
  func attachmentDeduplicated() throws {
    let scratch = try Scratch()
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    let first = try writer.addAttachment(data: Data([1, 2, 3]), fileExtension: "png")
    let second = try writer.addAttachment(data: Data([1, 2, 3]), fileExtension: "png")
    #expect(first == second)
    let manifest = try writer.finish(library: .empty, createdBy: createdBy, now: epoch)
    #expect(manifest.counts.attachments == 1)
  }

  @Test("archiveDigest depends on every file entry")
  func digestCoversEntries() {
    let a = ArchiveManifest.FileEntry(
      path: "clips.jsonl", bytes: 1, sha256: String(repeating: "a", count: 64))
    let b = ArchiveManifest.FileEntry(
      path: "library.json", bytes: 2, sha256: String(repeating: "b", count: 64))
    let base = ArchiveManifest.digest(of: [a, b])
    #expect(base == ArchiveManifest.digest(of: [b, a]))  // order independent
    var changed = b
    changed.sha256 = String(repeating: "c", count: 64)
    #expect(base != ArchiveManifest.digest(of: [a, changed]))
  }
}

// MARK: - Writer behavior

@Suite("Archive writer")
struct ArchiveWriterTests {
  @Test("an unfinished archive never appears at the destination")
  func incompleteIsInvisible() throws {
    let scratch = try Scratch()
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    try writer.addClip(textClip("x"))
    #expect(!FileManager.default.fileExists(atPath: scratch.archiveURL.path))

    writer.cancel()
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path)
    #expect(leftovers.isEmpty)
  }

  @Test("an existing destination is never overwritten")
  func destinationExists() throws {
    let scratch = try Scratch()
    try FileManager.default.createDirectory(
      at: scratch.archiveURL, withIntermediateDirectories: true)
    #expect(throws: ArchiveError.destinationExists) {
      _ = try ArchiveWriter(destination: scratch.archiveURL)
    }
  }

  @Test("only supported image types and sizes are accepted")
  func attachmentRules() throws {
    let scratch = try Scratch()
    let writer = try ArchiveWriter(
      destination: scratch.archiveURL, limits: ArchiveLimits(maxAttachmentBytes: 8))
    #expect(throws: ArchiveError.unsupportedAttachmentType("exe")) {
      _ = try writer.addAttachment(data: Data([1]), fileExtension: "exe")
    }
    #expect(throws: ArchiveError.self) {
      _ = try writer.addAttachment(data: Data(count: 9), fileExtension: "png")
    }
    #expect(throws: ArchiveError.self) {
      _ = try writer.addAttachment(data: Data(), fileExtension: "png")
    }
    writer.cancel()
  }
}

// MARK: - Incomplete / wrong archives

@Suite("Archive identification")
struct ArchiveIdentificationTests {
  @Test("a folder without a manifest is an incomplete archive")
  func missingManifest() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try FileManager.default.removeItem(at: built.url.appending(path: "manifest.json"))
    #expect(throws: ArchiveError.missingManifest) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("a path that is not a directory is rejected")
  func notADirectory() throws {
    let scratch = try Scratch()
    let file = scratch.root.appending(path: "file.copyloom")
    try Data([1]).write(to: file)
    #expect(throws: ArchiveError.notAnArchive) { try ArchiveVerifier().verify(at: file) }
  }

  @Test("a manifest from a newer format version is rejected, not guessed at")
  func newerVersion() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { $0["formatVersion"] = 99 }
    #expect(throws: ArchiveError.unsupportedVersion(99)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a manifest for some other format is rejected")
  func wrongFormat() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { $0["format"] = "com.example.other" }
    #expect(throws: ArchiveError.notAnArchive) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("garbage manifest bytes are an invalid manifest")
  func garbageManifest() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try Data("not json".utf8).write(to: built.url.appending(path: "manifest.json"))
    #expect(throws: ArchiveError.invalidManifest) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("an oversize manifest is refused before parsing")
  func oversizeManifest() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.manifestTooLarge) {
      try ArchiveVerifier(limits: ArchiveLimits(maxManifestBytes: 16)).verify(at: built.url)
    }
  }
}

// MARK: - Tamper detection

@Suite("Archive tamper detection")
struct ArchiveTamperTests {
  @Test("a changed byte in clips.jsonl is caught")
  func alteredClips() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try flipFirstByte(of: built.url.appending(path: "clips.jsonl"))
    #expect(throws: ArchiveError.digestMismatch("clips.jsonl")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a changed byte in an attachment is caught")
  func alteredAttachment() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try flipFirstByte(of: built.url.appending(path: built.attachment.path))
    #expect(throws: ArchiveError.digestMismatch(built.attachment.path)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a truncated file is caught by size before hashing")
  func truncated() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let file = built.url.appending(path: built.attachment.path)
    try Data(contentsOf: file).prefix(10).write(to: file)
    #expect(throws: ArchiveError.sizeMismatch(built.attachment.path)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a deleted listed file is caught")
  func deletedFile() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try FileManager.default.removeItem(at: built.url.appending(path: "library.json"))
    #expect(throws: ArchiveError.missingFile("library.json")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("editing a digest in the manifest without the archive digest is caught")
  func manifestEntryEdited() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { object in
      var files = object["files"] as! [[String: Any]]
      files[0]["sha256"] = String(repeating: "0", count: 64)
      object["files"] = files
    }
    #expect(throws: ArchiveError.self) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("a forged manifest with a recomputed archive digest still fails the file hash")
  func manifestForged() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { object in
      var files = object["files"] as! [[String: Any]]
      files[0]["sha256"] = String(repeating: "0", count: 64)
      object["files"] = files
      let entries = files.map {
        ArchiveManifest.FileEntry(
          path: $0["path"] as! String, bytes: $0["bytes"] as! Int, sha256: $0["sha256"] as! String)
      }
      object["archiveDigest"] = ArchiveManifest.digest(of: entries)
    }
    #expect(throws: ArchiveError.self) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("an archive digest that does not match the entries is caught")
  func archiveDigestMismatch() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { $0["archiveDigest"] = String(repeating: "f", count: 64) }
    #expect(throws: ArchiveError.archiveDigestMismatch) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("counts that disagree with the data are caught")
  func countMismatch() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { object in
      var counts = object["counts"] as! [String: Any]
      counts["clips"] = 99
      object["counts"] = counts
    }
    #expect(throws: ArchiveError.countMismatch("clips")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("an unlisted regular file is ignored and reported, never read")
  func unlistedFile() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try Data("surprise".utf8).write(to: built.url.appending(path: "notes.txt"))
    let verified = try ArchiveVerifier().verify(at: built.url)
    #expect(verified.unlistedFiles == ["notes.txt"])
  }
}

// MARK: - Path and symlink safety

@Suite("Archive path safety")
struct ArchivePathSafetyTests {
  private static let sha = String(repeating: "ab", count: 32)

  @Test("only the three known path shapes parse")
  func acceptedShapes() {
    #expect(ArchivePath.parse("clips.jsonl") == .clips)
    #expect(ArchivePath.parse("library.json") == .library)
    let path = "attachments/ab/ab/\(Self.sha).png"
    #expect(ArchivePath.parse(path) == .attachment(sha256: Self.sha, fileExtension: "png"))
    #expect(
      ArchivePath.attachmentPath(sha256: Self.sha, fileExtension: "tiff")
        == "attachments/ab/ab/\(Self.sha).tiff")
  }

  @Test(
    "traversal, absolute, malformed and mismatched paths are all rejected",
    arguments: [
      "../clips.jsonl",
      "/etc/passwd",
      "attachments/../clips.jsonl",
      "attachments//ab/\(sha).png",
      "attachments/ab/ab/../\(sha).png",
      "clips.jsonl/",
      "clips.jsonl/../clips.jsonl",
      "./clips.jsonl",
      "attachments\\ab\\ab\\\(sha).png",
      "attachments/ab/ab/\(sha).exe",
      "attachments/cd/ab/\(sha).png",  // shard does not match the digest
      "attachments/ab/cd/\(sha).png",
      "attachments/AB/AB/\(String(repeating: "AB", count: 32)).png",  // uppercase hex
      "attachments/ab/ab/\(String(sha.dropLast())).png",  // 63 hex digits
      "attachments/ab/ab/\(sha)",
      "manifest.json",  // the manifest never lists itself
      "clips.jsonl\u{0}.png",
      "",
    ])
  func rejected(path: String) {
    #expect(ArchivePath.parse(path) == nil)
  }

  @Test("a manifest entry with a traversal path rejects the whole archive")
  func traversalInManifest() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { object in
      var files = object["files"] as! [[String: Any]]
      files.append([
        "path": "../outside.txt", "bytes": 1, "sha256": String(repeating: "0", count: 64),
      ])
      object["files"] = files
    }
    #expect(throws: ArchiveError.invalidPath("../outside.txt")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("duplicate manifest entries are rejected")
  func duplicateEntries() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try rewriteManifest(at: built.url) { object in
      var files = object["files"] as! [[String: Any]]
      files.append(files[0])
      object["files"] = files
    }
    #expect(throws: ArchiveError.duplicatePath(built.attachment.path)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a symlinked attachment is rejected")
  func symlinkedAttachment() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let file = built.url.appending(path: built.attachment.path)
    let target = scratch.root.appending(path: "elsewhere.png")
    try built.attachmentData.write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: ArchiveError.symlinkNotAllowed(built.attachment.path)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a symlinked directory in the tree is rejected")
  func symlinkedDirectory() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let real = scratch.root.appending(path: "real-attachments", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: built.url.appending(path: "attachments"), to: real)
    try FileManager.default.createSymbolicLink(
      at: built.url.appending(path: "attachments"), withDestinationURL: real)
    #expect(throws: ArchiveError.self) { try ArchiveVerifier().verify(at: built.url) }
  }

  @Test("an unlisted symlink anywhere fails closed")
  func unlistedSymlink() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try FileManager.default.createSymbolicLink(
      at: built.url.appending(path: "link.txt"),
      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(throws: ArchiveError.symlinkNotAllowed("link.txt")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a symlinked archive root is rejected")
  func symlinkedRoot() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let link = scratch.root.appending(path: "Link.copyloom")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: built.url)
    #expect(throws: ArchiveError.notAnArchive) { try ArchiveVerifier().verify(at: link) }
  }
}

// MARK: - Limits

@Suite("Archive limits")
struct ArchiveLimitTests {
  @Test("an attachment over the limit is rejected from its declared size")
  func attachmentTooLarge() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.attachmentTooLarge(built.attachment.path)) {
      try ArchiveVerifier(limits: ArchiveLimits(maxAttachmentBytes: 10)).verify(at: built.url)
    }
  }

  @Test("a clips.jsonl line over the limit fails verification")
  func lineTooLong() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.lineTooLong) {
      try ArchiveVerifier(limits: ArchiveLimits(maxLineBytes: 50)).verify(at: built.url)
    }
  }

  @Test("more clips than the limit fails verification")
  func tooManyClips() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.tooManyClips) {
      try ArchiveVerifier(limits: ArchiveLimits(maxClips: 2)).verify(at: built.url)
    }
  }

  @Test("more listed files than the limit fails verification")
  func tooManyFiles() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.tooManyFiles) {
      try ArchiveVerifier(limits: ArchiveLimits(maxFiles: 2)).verify(at: built.url)
    }
  }
}

// MARK: - Reader record handling

@Suite("Archive reader")
struct ArchiveReaderTests {
  /// Builds a verified archive whose clips.jsonl is exactly `lines`.
  private func archive(lines: [String], in scratch: Scratch) throws -> VerifiedArchive {
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    try writer.injectRawClipLines(lines)
    _ = try writer.finish(library: .empty, createdBy: createdBy, now: epoch)
    return try ArchiveVerifier().verify(at: scratch.archiveURL)
  }

  private func results(of verified: VerifiedArchive) throws -> [(
    Int, Result<ClipRecord, ArchiveRecordError>
  )] {
    var out: [(Int, Result<ClipRecord, ArchiveRecordError>)] = []
    try ArchiveReader(archive: verified).forEachClip { line, result in out.append((line, result)) }
    return out
  }

  private func encoded(_ clip: ClipRecord) throws -> String {
    String(decoding: try ArchiveCoding.encoder().encode(clip), as: UTF8.self)
  }

  @Test("a bad record is reported with its line number and good records still arrive")
  func badRecordsIsolated() throws {
    let scratch = try Scratch()
    let good = try encoded(textClip("ok"))
    let verified = try archive(lines: [good, "{not json", good], in: scratch)
    let all = try results(of: verified)
    #expect(all.count == 3)
    #expect(all[1].0 == 2)
    guard case .failure(let error) = all[1].1 else {
      Issue.record("expected a failure on line 2")
      return
    }
    #expect(error.line == 2)
    if case .success = all[0].1, case .success = all[2].1 {
    } else {
      Issue.record("good lines lost")
    }
  }

  @Test("an unknown kind is a record error, not an archive error")
  func unknownKind() throws {
    let scratch = try Scratch()
    var object = try #require(
      try JSONSerialization.jsonObject(with: ArchiveCoding.encoder().encode(textClip("x")))
        as? [String: Any])
    object["kind"] = "hologram"
    let line = String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
    let verified = try archive(lines: [line], in: scratch)
    guard case .failure = try results(of: verified)[0].1 else {
      Issue.record("expected a record failure")
      return
    }
  }

  @Test("an attachment the manifest does not list is a record error")
  func unlistedAttachmentReference() throws {
    let scratch = try Scratch()
    let phantom = ArchiveAttachmentRef(
      path: ArchivePath.attachmentPath(
        sha256: String(repeating: "ab", count: 32), fileExtension: "png"),
      sha256: String(repeating: "ab", count: 32), bytes: 10)
    let verified = try archive(lines: [try encoded(imageClip(phantom))], in: scratch)
    guard case .failure = try results(of: verified)[0].1 else {
      Issue.record("expected a record failure")
      return
    }
  }

  @Test("reading an attachment that is not in the manifest throws")
  func attachmentNotListed() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let reader = ArchiveReader(archive: try ArchiveVerifier().verify(at: built.url))
    #expect(throws: ArchiveError.self) {
      _ = try reader.attachmentData(
        at: ArchivePath.attachmentPath(
          sha256: String(repeating: "cd", count: 32), fileExtension: "png"))
    }
    #expect(throws: ArchiveError.self) { _ = try reader.attachmentData(at: "../../etc/hosts") }
  }

  @Test("reading scales linearly with the number of lines")
  func readerScales() throws {
    // Regression guard: re-slicing the remaining buffer after every line made
    // reading quadratic in lines-per-chunk. One million one-byte lines put
    // ~500k lines in each 1 MiB chunk. Measured: the quadratic reader took
    // 9.1 s (debug) and 9.5 s (release); the linear one takes 0.4 s (debug)
    // and 0.08 s (release). The 3 s bound fails the old behavior and leaves
    // ~8x headroom for slow CI. Blank lines keep this about the reader's
    // loop, not JSON decoding.
    let scratch = try Scratch()
    let count = 1_000_000
    let verified = try archive(lines: Array(repeating: " ", count: count), in: scratch)
    let start = ContinuousClock.now

    var seen = 0
    try ArchiveReader(archive: verified).forEachClip { _, result in
      if case .failure = result { seen += 1 }
    }

    #expect(seen == count)
    #expect(ContinuousClock.now - start < .seconds(3))
  }

  @Test("every millisecond value the database can hold survives the round trip")
  func millisecondsAreExact() throws {
    // The database stores integer milliseconds; `Date` is a binary float of
    // seconds. A naive format/parse can land one millisecond off, which would
    // make a re-import look like a different timestamp.
    struct Wrapper: Codable, Equatable { var at: Date }
    let encoder = ArchiveCoding.encoder()
    let decoder = ArchiveCoding.decoder()
    var generator = SystemRandomNumberGenerator()
    var samples: [Int64] = [0, 1, 999, 1_000, 1_800_000_000_123, 1_800_000_000_999]
    for _ in 0..<20_000 {
      samples.append(Int64.random(in: 1_500_000_000_000...2_500_000_000_000, using: &generator))
    }
    for milliseconds in samples {
      let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
      let data = try encoder.encode(Wrapper(at: date))
      let back = try decoder.decode(Wrapper.self, from: data).at
      let backMilliseconds = Int64((back.timeIntervalSince1970 * 1_000).rounded())
      #expect(
        backMilliseconds == milliseconds, "ms \(milliseconds) came back as \(backMilliseconds)")
    }
  }

  @Test("timestamps round-trip with millisecond precision in UTC")
  func dates() throws {
    let clip = textClip("t")
    let json = String(decoding: try ArchiveCoding.encoder().encode(clip), as: UTF8.self)
    #expect(json.contains("\"createdAt\":\"2027-01-15T08:00:00.000Z\""))
    #expect(try ArchiveCoding.decoder().decode(ClipRecord.self, from: Data(json.utf8)) == clip)
  }
}

// MARK: - Changes after verification (time-of-check / time-of-use)

/// Verification proves the archive was sound at one instant. Files can change
/// before they are read, so the reader must re-check what it opens and bound
/// what it reads, rather than trusting the earlier pass.
@Suite("Archive changes after verification")
struct ArchiveChangeAfterVerifyTests {
  private func verified(_ scratch: Scratch) throws -> (Built, VerifiedArchive) {
    let built = try build(in: scratch)
    return (built, try ArchiveVerifier().verify(at: built.url))
  }

  @Test("an attachment swapped for a bigger file is refused by size, not read")
  func attachmentGrew() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    try Data(count: 5_000_000).write(to: built.url.appending(path: built.attachment.path))
    #expect(throws: ArchiveError.sizeMismatch(built.attachment.path)) {
      _ = try ArchiveReader(archive: archive).attachmentData(at: built.attachment.path)
    }
  }

  @Test("an attachment edited in place is caught by its digest")
  func attachmentEdited() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    try flipFirstByte(of: built.url.appending(path: built.attachment.path))
    #expect(throws: ArchiveError.digestMismatch(built.attachment.path)) {
      _ = try ArchiveReader(archive: archive).attachmentData(at: built.attachment.path)
    }
  }

  @Test("an attachment replaced by a symlink after verification is not followed")
  func attachmentBecameSymlink() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    let file = built.url.appending(path: built.attachment.path)
    let target = scratch.root.appending(path: "elsewhere.png")
    try built.attachmentData.write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: ArchiveError.symlinkNotAllowed(built.attachment.path)) {
      _ = try ArchiveReader(archive: archive).attachmentData(at: built.attachment.path)
    }
  }

  @Test("an attachment directory replaced by a symlink after verification is not followed")
  func attachmentDirectoryBecameSymlink() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    let real = scratch.root.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: built.url.appending(path: "attachments"), to: real)
    try FileManager.default.createSymbolicLink(
      at: built.url.appending(path: "attachments"), withDestinationURL: real)
    #expect(throws: ArchiveError.self) {
      _ = try ArchiveReader(archive: archive).attachmentData(at: built.attachment.path)
    }
  }

  @Test("library.json grown after verification is refused by size")
  func libraryGrew() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    try Data(count: 3_000_000).write(to: built.url.appending(path: "library.json"))
    #expect(throws: ArchiveError.sizeMismatch("library.json")) {
      _ = try ArchiveReader(archive: archive).library()
    }
  }

  @Test("library.json replaced by a symlink after verification is not followed")
  func libraryBecameSymlink() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    let file = built.url.appending(path: "library.json")
    let target = scratch.root.appending(path: "other.json")
    try Data(contentsOf: file).write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: ArchiveError.symlinkNotAllowed("library.json")) {
      _ = try ArchiveReader(archive: archive).library()
    }
  }

  @Test("clips.jsonl that grew after verification is refused before streaming it")
  func clipsGrew() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    let handle = try FileHandle(forWritingTo: built.url.appending(path: "clips.jsonl"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x41, count: 4_000_000))  // one endless line
    try handle.close()
    var delivered = 0
    #expect(throws: ArchiveError.sizeMismatch("clips.jsonl")) {
      try ArchiveReader(archive: archive).forEachClip { _, _ in delivered += 1 }
    }
    #expect(delivered == 0)
  }

  @Test("clips.jsonl edited in place is caught by its digest by the end of the stream")
  func clipsEditedInPlace() throws {
    let scratch = try Scratch()
    let (built, archive) = try verified(scratch)
    let url = built.url.appending(path: "clips.jsonl")
    var data = try Data(contentsOf: url)
    data[data.count - 3] ^= 0x01  // same size, different content
    try data.write(to: url)
    #expect(throws: ArchiveError.digestMismatch("clips.jsonl")) {
      try ArchiveReader(archive: archive).forEachClip { _, _ in }
    }
  }

  @Test("a line over the limit stops the stream even if verification used a looser limit")
  func lineBoundEnforcedByReader() throws {
    let scratch = try Scratch()
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    try writer.injectRawClipLines([String(repeating: "a", count: 200)])
    _ = try writer.finish(library: .empty, createdBy: createdBy, now: epoch)
    // Verify with a generous limit, then read with a tight one: the reader
    // must enforce the bound itself, not rely on the earlier pass.
    let verified = try ArchiveVerifier().verify(at: scratch.archiveURL)
    let tight = VerifiedArchive(
      root: verified.root, manifest: verified.manifest,
      limits: ArchiveLimits(maxLineBytes: 50), unlistedFiles: [])
    #expect(throws: ArchiveError.lineTooLong) {
      try ArchiveReader(archive: tight).forEachClip { _, _ in }
    }
  }
}

// MARK: - Special files and size bounds (denial of service)

/// Opening a FIFO for reading blocks until a writer appears, so a folder
/// containing one could freeze the app. Special files must be refused without
/// ever blocking.
@Suite("Archive special files")
struct ArchiveSpecialFileTests {
  /// Replaces `url` with a FIFO. A helper thread opens the write end so that
  /// an implementation that blocks on `open` is released (turning a hang into
  /// a failing assertion) and gives up after a few seconds if nobody reads.
  private func replaceWithFIFO(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    #expect(mkfifo(url.path, 0o600) == 0)
    let path = url.path
    Thread.detachNewThread {
      for _ in 0..<30 {
        let descriptor = open(path, O_WRONLY | O_NONBLOCK)
        if descriptor >= 0 {
          close(descriptor)
          return
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
  }

  @Test("a FIFO in place of a listed file is refused by verification")
  func fifoRefusedByVerifier() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try replaceWithFIFO(built.url.appending(path: "library.json"))
    #expect(throws: ArchiveError.notARegularFile("library.json")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a FIFO in place of an attachment is refused by verification")
  func fifoAttachmentRefusedByVerifier() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try replaceWithFIFO(built.url.appending(path: built.attachment.path))
    #expect(throws: ArchiveError.notARegularFile(built.attachment.path)) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a FIFO swapped in after verification is refused by the reader")
  func fifoRefusedByReader() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    let archive = try ArchiveVerifier().verify(at: built.url)
    try replaceWithFIFO(built.url.appending(path: "clips.jsonl"))
    #expect(throws: ArchiveError.notARegularFile("clips.jsonl")) {
      try ArchiveReader(archive: archive).forEachClip { _, _ in }
    }
  }

  @Test("a FIFO manifest is refused, not waited on")
  func fifoManifest() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    try replaceWithFIFO(built.url.appending(path: "manifest.json"))
    #expect(throws: ArchiveError.notARegularFile("manifest.json")) {
      try ArchiveVerifier().verify(at: built.url)
    }
  }

  @Test("a declared clips.jsonl over the size bound is refused before hashing")
  func clipsFileTooLarge() throws {
    let scratch = try Scratch()
    let built = try build(in: scratch)
    #expect(throws: ArchiveError.fileTooLarge("clips.jsonl")) {
      try ArchiveVerifier(limits: ArchiveLimits(maxClipsFileBytes: 10)).verify(at: built.url)
    }
  }
}

// MARK: - Realistic scale

@Suite("Archive at realistic scale")
struct ArchiveScaleTests {
  @Test("a library with thousands of images produces a manifest the default limits accept")
  func manyAttachments() throws {
    // The manifest lists every attachment (~250 bytes each), so a 1 MiB
    // manifest cap would reject any library with more than ~4,000 images.
    let scratch = try Scratch()
    let writer = try ArchiveWriter(destination: scratch.archiveURL)
    for index in 0..<6_000 {
      var bytes = withUnsafeBytes(of: UInt32(index).littleEndian) { Data($0) }
      bytes.append(contentsOf: [1, 2, 3, 4])
      _ = try writer.addAttachment(data: bytes, fileExtension: "png")
    }
    let manifest = try writer.finish(library: .empty, createdBy: createdBy, now: epoch)
    #expect(manifest.counts.attachments == 6_000)

    let manifestSize = try #require(
      (try FileManager.default.attributesOfItem(
        atPath: scratch.archiveURL.appending(path: "manifest.json").path)[.size] as? NSNumber)?
        .intValue)
    #expect(manifestSize > 1 << 20)  // the case the old cap could not handle

    let verified = try ArchiveVerifier().verify(at: scratch.archiveURL)
    #expect(verified.manifest.counts.attachments == 6_000)
  }
}
