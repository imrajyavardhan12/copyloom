import Foundation

enum EncodingTransforms {
  static let all: [FunctionTransform] = [
    FunctionTransform(
      id: "url.encode", title: "URL-encode", kinds: .encodableText
    ) { urlEncode($0) },
    FunctionTransform(
      id: "url.decode", title: "URL-decode", kinds: .encodableText,
      when: containsPercentEscape
    ) { try urlDecode($0) },
    FunctionTransform(
      id: "base64.encode", title: "Base64-encode", kinds: .encodableText
    ) { Data($0.utf8).base64EncodedString() },
    FunctionTransform(
      id: "base64.decode", title: "Base64-decode", kinds: .encodableText,
      when: looksLikeBase64
    ) { try base64Decode($0) },
  ]

  /// Percent-encodes everything outside RFC 3986 unreserved characters, so
  /// the result is safe in any URL component (query values, path segments).
  private static let unreserved = CharacterSet(
    charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  private static func urlEncode(_ input: String) -> String {
    // Cannot fail for a non-empty allowed set; fall back to the input only
    // to avoid a crash path.
    input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
  }

  private static func containsPercentEscape(_ text: String) -> Bool {
    text.contains("%")
  }

  /// Strict percent-decoding: `+` stays `+`, and malformed escapes or
  /// non-UTF-8 results are errors rather than best-effort output.
  private static func urlDecode(_ input: String) throws -> String {
    guard let decoded = input.removingPercentEncoding else {
      throw TransformError("Not valid percent-encoding")
    }
    return decoded
  }

  private static let base64Alphabet = CharacterSet(
    charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_")

  private static func looksLikeBase64(_ text: String) -> Bool {
    let compact = text.filter { !$0.isWhitespace }
    guard compact.count >= 4 else { return false }
    return compact.unicodeScalars.allSatisfy(base64Alphabet.contains)
  }

  /// Accepts standard and URL-safe alphabets, embedded whitespace and
  /// missing padding. The payload must be valid UTF-8 text.
  private static func base64Decode(_ input: String) throws -> String {
    var compact =
      input.filter { !$0.isWhitespace }
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = compact.count % 4
    if remainder != 0 { compact += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: compact) else {
      throw TransformError("Not valid Base64")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw TransformError("Decoded bytes are not UTF-8 text")
    }
    return text
  }
}
