import CryptoKit
import Foundation

/// Reads a `VerifiedArchive`. Record-level problems are returned per line;
/// they never abort the read, so one bad clip cannot hide the rest.
public struct ArchiveReader: Sendable {
  private let archive: VerifiedArchive
  private let attachmentEntries: [String: ArchiveManifest.FileEntry]
  private let clipsEntry: ArchiveManifest.FileEntry?
  private let libraryEntry: ArchiveManifest.FileEntry?

  public init(archive: VerifiedArchive) {
    self.archive = archive
    var entries: [String: ArchiveManifest.FileEntry] = [:]
    var clips: ArchiveManifest.FileEntry?
    var library: ArchiveManifest.FileEntry?
    for entry in archive.manifest.files {
      switch ArchivePath.parse(entry.path) {
      case .attachment: entries[entry.path] = entry
      case .clips: clips = entry
      case .library: library = entry
      case nil: break
      }
    }
    attachmentEntries = entries
    clipsEntry = clips
    libraryEntry = library
  }

  public func library() throws -> LibraryRecord {
    guard let entry = libraryEntry else { throw ArchiveError.missingRequiredFile("library.json") }
    let data = try readVerified(entry)
    guard let library = try? ArchiveCoding.decoder().decode(LibraryRecord.self, from: data) else {
      throw ArchiveError.invalidManifest
    }
    let counts = archive.manifest.counts
    guard library.collections.count == counts.collections else {
      throw ArchiveError.countMismatch("collections")
    }
    guard library.tags.count == counts.tags else { throw ArchiveError.countMismatch("tags") }
    guard library.savedQueries.count == counts.savedQueries else {
      throw ArchiveError.countMismatch("savedQueries")
    }
    return library
  }

  /// Streams `clips.jsonl` line by line in bounded memory.
  ///
  /// The file was verified earlier but may have changed since, so this
  /// re-checks as it goes: the opened file must still have the declared size,
  /// no more bytes than that are read, an unterminated line cannot grow past
  /// `limits.maxLineBytes`, and the digest is re-computed while streaming and
  /// compared at the end. A mismatch throws; records already delivered must
  /// be treated as untrusted by the caller (the importer applies in batches
  /// for exactly this reason).
  public func forEachClip(
    _ body: (_ line: Int, _ result: Result<ClipRecord, ArchiveRecordError>) throws -> Void
  ) throws {
    var source = try openClipLines()
    defer { source.close() }
    let decoder = ArchiveCoding.decoder()
    while let lines = try source.nextLines() {
      for (number, line) in lines {
        try body(number, decode(line, number: number, decoder: decoder))
      }
    }
  }

  /// The same stream for a consumer that must suspend between records (the
  /// importer awaits storage). Both variants pull from one `ClipLineSource`,
  /// so every size, bound and digest check exists exactly once.
  public func streamClips(
    _ body: (_ line: Int, _ result: Result<ClipRecord, ArchiveRecordError>) async throws -> Void
  ) async throws {
    var source = try openClipLines()
    defer { source.close() }
    let decoder = ArchiveCoding.decoder()
    while let lines = try source.nextLines() {
      for (number, line) in lines {
        try await body(number, decode(line, number: number, decoder: decoder))
      }
    }
  }

  private func openClipLines() throws -> ClipLineSource {
    guard let entry = clipsEntry else { throw ArchiveError.missingRequiredFile("clips.jsonl") }
    return try ClipLineSource(
      root: archive.root, entry: entry, maxLineBytes: archive.limits.maxLineBytes)
  }

  private func decode(
    _ line: Data, number: Int, decoder: JSONDecoder
  ) -> Result<ClipRecord, ArchiveRecordError> {
    guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else {
      return .failure(ArchiveRecordError(line: number, reason: "empty line"))
    }
    let record: ClipRecord
    do {
      record = try decoder.decode(ClipRecord.self, from: line)
    } catch let error as DecodingError {
      return .failure(ArchiveRecordError(line: number, reason: Self.describe(error)))
    } catch {
      return .failure(ArchiveRecordError(line: number, reason: "invalid record"))
    }
    if let reason = validate(record) {
      return .failure(ArchiveRecordError(line: number, reason: reason))
    }
    return .success(record)
  }

  /// Field names only: decode errors can echo values, which may be clip text.
  private static func describe(_ error: DecodingError) -> String {
    let context: DecodingError.Context
    switch error {
    case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c),
      .dataCorrupted(let c):
      context = c
    @unknown default:
      return "invalid record"
    }
    let path = context.codingPath.map(\.stringValue).filter { Int($0) == nil }.joined(
      separator: ".")
    switch error {
    case .keyNotFound(let key, _): return "missing field \(key.stringValue)"
    default: return path.isEmpty ? "invalid record" : "invalid value at \(path)"
    }
  }

  private func validate(_ record: ClipRecord) -> String? {
    guard !record.representations.isEmpty else { return "no representations" }
    for representation in record.representations {
      switch (representation.text, representation.attachment) {
      case (nil, nil): return "empty representation"
      case (.some, .some): return "representation has both text and attachment"
      case (.some, nil): continue
      case (nil, .some(let path)):
        guard let entry = attachmentEntries[path] else { return "unlisted attachment" }
        if let declared = representation.sha256, declared != entry.sha256 {
          return "attachment digest mismatch"
        }
      }
    }
    return nil
  }

  /// Reads one attachment. The file is opened without following links, its
  /// size is checked on the open descriptor *before* any bytes are read, and
  /// the bytes are re-hashed: the files were verified at open time but can
  /// change on disk before they are read.
  public func attachmentData(at path: String) throws -> Data {
    guard let entry = attachmentEntries[path] else { throw ArchiveError.invalidPath(path) }
    return try readVerified(entry)
  }

  /// Opens, size-checks on the descriptor, reads exactly the declared size,
  /// and compares the digest.
  private func readVerified(_ entry: ArchiveManifest.FileEntry) throws -> Data {
    let opened = try ArchiveFileAccess.open(root: archive.root, relativePath: entry.path)
    defer { try? opened.handle.close() }
    guard opened.size == entry.bytes else { throw ArchiveError.sizeMismatch(entry.path) }
    let data = try ArchiveFileAccess.readExactly(
      opened.handle, count: entry.bytes, path: entry.path)
    guard ArchiveHashing.sha256Hex(data) == entry.sha256 else {
      throw ArchiveError.digestMismatch(entry.path)
    }
    return data
  }
}
