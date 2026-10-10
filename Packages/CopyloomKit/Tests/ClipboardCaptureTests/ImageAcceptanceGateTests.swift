import ClipDomain
import Foundation
import Testing

@testable import ClipboardCapture

private actor CountingPreflight: ImagePrivacyPreflight {
  private(set) var calls = 0
  let verdict: ImagePreflightVerdict
  let delay: Duration?

  init(_ verdict: ImagePreflightVerdict, delay: Duration? = nil) {
    self.verdict = verdict
    self.delay = delay
  }

  func inspect(data: Data, uti: String) async -> ImagePreflightVerdict {
    calls += 1
    if let delay { try? await Task.sleep(for: delay) }
    return verdict
  }
}

@Suite("Image acceptance gate")
struct ImageAcceptanceGateTests {
  private func gate(
    _ preflight: any ImagePrivacyPreflight, bytes: Int = 100, pixels: Int = 1_000,
    timeout: Double = 5
  ) -> ImageAcceptanceGate {
    ImageAcceptanceGate(
      preflight: preflight, maximumBytes: bytes, maximumPixels: pixels,
      timeoutSeconds: timeout)
  }

  @Test("an image within every ceiling is allowed with the decoded dimensions")
  func allowed() async {
    let verdict = await gate(CountingPreflight(.allow(width: 10, height: 20))).evaluate(
      data: Data(repeating: 1, count: 50), uti: "public.png")
    #expect(verdict == .allow(width: 10, height: 20))
  }

  @Test("too many bytes is refused without running the preflight")
  func byteCeiling() async {
    let preflight = CountingPreflight(.allow(width: 1, height: 1))
    let verdict = await gate(preflight).evaluate(
      data: Data(repeating: 1, count: 101), uti: "public.png")
    #expect(verdict == .skip(.tooLarge))
    #expect(await preflight.calls == 0)
  }

  @Test("too many pixels is refused even if the preflight allowed it")
  func pixelCeiling() async {
    let verdict = await gate(CountingPreflight(.allow(width: 100, height: 11))).evaluate(
      data: Data([1]), uti: "public.png")
    #expect(verdict == .skip(.tooLarge))
  }

  @Test("a degenerate size is refused")
  func zeroSize() async {
    let verdict = await gate(CountingPreflight(.allow(width: 0, height: 5))).evaluate(
      data: Data([1]), uti: "public.png")
    #expect(verdict == .skip(.tooLarge))
  }

  @Test("the preflight's own refusal passes through")
  func refusal() async {
    let verdict = await gate(CountingPreflight(.skip(.sensitiveContent))).evaluate(
      data: Data([1]), uti: "public.png")
    #expect(verdict == .skip(.sensitiveContent))
  }

  @Test("a preflight that overruns the timeout is refused, not waited on")
  func timeout() async {
    let slow = CountingPreflight(.allow(width: 1, height: 1), delay: .seconds(300))
    let started = ContinuousClock.now
    let verdict = await gate(slow, timeout: 0.05).evaluate(data: Data([1]), uti: "public.png")
    #expect(verdict == .skip(.preflightTimeout))
    // Far below the preflight's delay, far above a slow traced runner (hosted
    // CodeQL took 8.7 s against an earlier 5 s bound).
    #expect(ContinuousClock.now - started < .seconds(100))
  }
}
