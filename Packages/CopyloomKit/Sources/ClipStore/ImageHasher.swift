import CryptoKit
import Foundation

/// Exact-bytes image hashing. Unlike text, pixels are never normalized:
/// the same image kept as PNG vs TIFF intentionally produces distinct clips
/// so the original representation is never silently discarded.
enum ImageHasher {
  static func dedupeHash(data: Data, uti: String) -> Data {
    var input = Data("copyloom.dedupe.image.v1".utf8)
    input.append(0)
    input.append(contentsOf: uti.lowercased().utf8)
    input.append(0)
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
    input.append(data)
    return Data(SHA256.hash(data: input))
  }

  static func contentDigest(data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }
}
