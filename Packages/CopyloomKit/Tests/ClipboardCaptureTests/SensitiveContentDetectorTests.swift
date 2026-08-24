import Testing

@testable import ClipboardCapture

@Suite("Sensitive content detector")
struct SensitiveContentDetectorTests {
  private let detector = LocalSensitiveContentDetector()

  @Test(
    "detects high-confidence private keys, credentials, tokens, and payment cards",
    arguments: [
      "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nsynthetic-fixture",
      "DATABASE_PASSWORD=correct-horse-battery-staple",
      "github" + "_pat_11AA0syntheticfixturetokenvalue000000000000000000000000",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.synthetic_signature_value",
      "4111 1111 1111 1111",
    ])
  func detectsSensitiveText(text: String) {
    guard case .sensitive = detector.inspect(text) else {
      Issue.record("Expected a sensitive verdict")
      return
    }
  }

  @Test(
    "does not classify ordinary developer text as a secret",
    arguments: [
      "let tokenCount = tokenizer.tokens.count",
      "PASSWORD requirements should include at least 12 characters",
      "https://example.com/docs?section=api-key",
      "postgres connection refused on localhost",
      "build 4111 completed with 16 tests",
    ])
  func acceptsOrdinaryText(text: String) {
    #expect(detector.inspect(text) == .safe)
  }
}
