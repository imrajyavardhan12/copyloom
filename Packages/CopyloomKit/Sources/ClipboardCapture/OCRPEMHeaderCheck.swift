import Foundation

/// OCR-specific private-key header check shared by the capture-time Vision
/// gate and the background OCR rescan, so the two can never disagree about
/// what is sensitive.
///
/// Live OCR mangles dash runs (`•---BEGIN`, `----BEGIN…-....`), so the exact
/// PEM pattern in the text detector never fires on screenshots. This check
/// tolerates dash/whitespace mangling around the header. It runs only on OCR
/// output; the text path keeps its exact patterns.
enum OCRPEMHeaderCheck {
  static func matches(_ text: String) -> Bool {
    pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
      != nil
  }

  private static let pattern: NSRegularExpression = {
    // Hardcoded valid pattern; compiled once at first use.
    try! NSRegularExpression(
      pattern: #"-{2,}\s*BEGIN\s+(?:(?:RSA|OPENSSH|DSA|EC)\s+)?PRIVATE\s+KEY"#,
      options: [.caseInsensitive]
    )
  }()
}
