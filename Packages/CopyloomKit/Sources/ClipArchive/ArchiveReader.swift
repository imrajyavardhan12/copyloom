import Foundation

/// Reads a `VerifiedArchive`. Record-level problems are returned per line;
/// they never abort the read, so one bad clip cannot hide the rest.
public struct ArchiveReader: Sendable {
  private let archive: VerifiedArchive
  private let attachmentEntries: [String: ArchiveManifest.FileEntry]

  public init(archive: VerifiedArchive) {
    self.archive = archive
    var entries: [String: ArchiveManifest.FileEntry] = [:]
    for entry in archive.manifest.files {
      if case .attachment = ArchivePath.parse(entry.path) { entries[entry.path] = entry }
    }
    attachmentEntries = entries
  }

  public func library() throws -> LibraryRecord {
    let data = try Data(contentsOf: archive.root.appending(path: "library.json"))
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

  /// Streams `clips.jsonl` line by line in bounded memory (verification
  /// already guaranteed no line exceeds `limits.maxLineBytes`).
  public func forEachClip(
    _ body: (_ line: Int, _ result: Result<ClipRecord, ArchiveRecordError>) throws -> Void
  ) throws {
    let handle = try FileHandle(forReadingFrom: archive.root.appending(path: "clips.jsonl"))
    defer { try? handle.close() }
    let decoder = ArchiveCoding.decoder()
    var buffer = Data()
    var lineNumber = 0

    func process(_ line: Data) throws {
      lineNumber += 1
      try body(lineNumber, decode(line, number: lineNumber, decoder: decoder))
    }

    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      buffer.append(chunk)
      // Walk the chunk by offset and keep only the unfinished tail once per
      // chunk. Re-slicing `buffer` after every line copies the remainder
      // each time, which is quadratic in lines per chunk.
      var start = buffer.startIndex
      while let newline = buffer[start...].firstIndex(of: 0x0A) {
        try process(buffer[start..<newline])
        start = buffer.index(after: newline)
      }
      buffer = Data(buffer[start...])
    }
    if !buffer.isEmpty { try process(buffer) }
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

  /// Reads one attachment. Re-hashes the bytes: the files were verified at
  /// open time, but they can change on disk before they are read.
  public func attachmentData(at path: String) throws -> Data {
    guard let entry = attachmentEntries[path] else { throw ArchiveError.invalidPath(path) }
    let data = try Data(contentsOf: archive.root.appending(path: path))
    guard data.count == entry.bytes else { throw ArchiveError.sizeMismatch(path) }
    guard ArchiveHashing.sha256Hex(data) == entry.sha256 else {
      throw ArchiveError.digestMismatch(path)
    }
    return data
  }
}
