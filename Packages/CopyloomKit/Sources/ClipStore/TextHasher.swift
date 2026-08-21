import CryptoKit
import Foundation

struct TextHashes: Sendable {
  static let version = 1

  let dedupeHash: Data
  let representationSetHash: Data
}

enum TextHasher {
  static func hash(_ text: String) -> TextHashes {
    let normalized =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .precomposedStringWithCanonicalMapping
    let payload = Data(normalized.utf8)

    return TextHashes(
      dedupeHash: digest(domain: "copyloom.dedupe.text.v1", payload: payload),
      representationSetHash: digest(
        domain: "copyloom.representations.text.v1",
        payload: Data(text.utf8)
      )
    )
  }

  private static func digest(domain: String, payload: Data) -> Data {
    var input = Data(domain.utf8)
    input.append(0)
    var length = UInt64(payload.count).bigEndian
    withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
    input.append(payload)
    return Data(SHA256.hash(data: input))
  }
}
