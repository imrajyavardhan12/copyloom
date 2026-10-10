import CryptoKit
import Foundation

/// Pulls the lines of `clips.jsonl` one chunk at a time, re-checking the file
/// as it goes (see `ArchiveReader.forEachClip`).
///
/// Each call returns the complete lines found in the next 1 MiB chunk, so
/// memory stays bounded by one chunk plus one unfinished line. The final call
/// flushes the unterminated tail, then verifies the total size and the digest
/// and throws on any mismatch; it returns nil once the stream is done.
struct ClipLineSource: ~Copyable {
  private let handle: FileHandle
  private let entry: ArchiveManifest.FileEntry
  private let maxLineBytes: Int
  private var hasher = SHA256()
  private var buffer = Data()
  private var lineNumber = 0
  private var totalRead = 0
  private var finished = false

  init(root: URL, entry: ArchiveManifest.FileEntry, maxLineBytes: Int) throws {
    let opened = try ArchiveFileAccess.open(root: root, relativePath: entry.path)
    guard opened.size == entry.bytes else {
      try? opened.handle.close()
      throw ArchiveError.sizeMismatch(entry.path)
    }
    handle = opened.handle
    self.entry = entry
    self.maxLineBytes = maxLineBytes
  }

  func close() { try? handle.close() }

  mutating func nextLines() throws -> [(number: Int, line: Data)]? {
    guard !finished else { return nil }
    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
      finished = true
      var lines: [(number: Int, line: Data)] = []
      if !buffer.isEmpty { lines.append(try take(buffer)) }
      buffer = Data()
      guard totalRead == entry.bytes else { throw ArchiveError.sizeMismatch(entry.path) }
      guard ArchiveHashing.hex(hasher.finalize()) == entry.sha256 else {
        throw ArchiveError.digestMismatch(entry.path)
      }
      return lines.isEmpty ? nil : lines
    }
    totalRead += chunk.count
    guard totalRead <= entry.bytes else { throw ArchiveError.sizeMismatch(entry.path) }
    hasher.update(data: chunk)
    buffer.append(chunk)

    // Walk the chunk by offset and keep only the unfinished tail once per
    // chunk. Re-slicing `buffer` after every line copies the remainder each
    // time, which is quadratic in lines per chunk.
    var lines: [(number: Int, line: Data)] = []
    var start = buffer.startIndex
    while let newline = buffer[start...].firstIndex(of: 0x0A) {
      lines.append(try take(buffer[start..<newline]))
      start = buffer.index(after: newline)
    }
    buffer = Data(buffer[start...])
    guard buffer.count <= maxLineBytes else { throw ArchiveError.lineTooLong }
    return lines
  }

  /// Enforced here too, not only at verification: a line is untrusted input
  /// to the JSON decoder until proven otherwise.
  private mutating func take(_ line: Data) throws -> (number: Int, line: Data) {
    guard line.count <= maxLineBytes else { throw ArchiveError.lineTooLong }
    lineNumber += 1
    return (lineNumber, Data(line))
  }
}
