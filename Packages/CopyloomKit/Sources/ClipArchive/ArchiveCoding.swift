import CryptoKit
import Foundation

/// Shared JSON and hashing conventions. Timestamps are ISO 8601 UTC with
/// milliseconds; keys are sorted so output is deterministic and diffable.
enum ArchiveCoding {
  private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(dateStyle))
    }
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      do {
        return try dateStyle.parse(text)
      } catch {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "invalid timestamp")
      }
    }
    return decoder
  }
}

enum ArchiveHashing {
  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  static func sha256Hex(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  /// Result of one streaming pass over a file.
  struct Scan {
    let sha256: String
    let bytes: Int
    let lineCount: Int
    let longestLine: Int
  }

  /// Streams the file once, in 1 MiB chunks, computing its digest and line
  /// statistics without ever holding the whole file in memory.
  static func scan(_ url: URL) throws -> Scan {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try scan(handle: handle)
  }

  /// Scans an already-opened handle, so a caller that opened it safely hashes
  /// exactly the file it checked.
  static func scan(handle: FileHandle) throws -> Scan {
    var hasher = SHA256()
    var bytes = 0
    var lines = 0
    var longest = 0
    var current = 0
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
      bytes += chunk.count
      chunk.withUnsafeBytes { buffer in
        for byte in buffer {
          if byte == 0x0A {
            lines += 1
            longest = max(longest, current)
            current = 0
          } else {
            current += 1
          }
        }
      }
    }
    if current > 0 {
      lines += 1
      longest = max(longest, current)
    }
    return Scan(
      sha256: hex(hasher.finalize()), bytes: bytes, lineCount: lines, longestLine: longest)
  }
}
