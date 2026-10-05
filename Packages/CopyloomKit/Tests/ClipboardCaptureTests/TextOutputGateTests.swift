import ClipDomain
import Testing

@testable import ClipboardCapture

@Suite("Text output gate")
struct TextOutputGateTests {
  private let gate = TextOutputGate()

  @Test("ordinary text is accepted and classified like a real capture")
  func classifies() {
    #expect(gate.kind(for: "hello world") == .text)
    #expect(gate.kind(for: "https://example.com/a") == .link)
    #expect(gate.kind(for: "#ff0000") == .color)
    #expect(gate.kind(for: #"{"a": 1}"#) == .code)
  }

  @Test("empty output is refused")
  func refusesEmpty() {
    #expect(gate.kind(for: "") == nil)
  }

  @Test(
    "sensitive output is refused, e.g. a decode that reveals a secret",
    arguments: [
      "DATABASE_PASSWORD=correct-horse-battery-staple",
      "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nsynthetic-fixture",
      "4111 1111 1111 1111",
    ])
  func refusesSensitive(text: String) {
    #expect(gate.kind(for: text) == nil)
  }

  @Test("output over the capture size ceiling is refused")
  func refusesOversize() {
    let small = TextOutputGate(maximumBytes: 8)
    #expect(small.kind(for: "12345678") == .text)
    #expect(small.kind(for: "123456789") == nil)
  }
}
