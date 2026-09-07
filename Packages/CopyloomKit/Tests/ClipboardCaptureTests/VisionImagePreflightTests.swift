import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ClipboardCapture

@Suite("Vision image preflight")
struct VisionImagePreflightTests {
  static let blankPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  )!

  @Test("allows a clean image with decoder dimensions")
  func allowsCleanImage() async {
    let recognizer = StubRecognizer(.strings(["hello world"]))
    let preflight = VisionImagePreflight(recognizer: recognizer)

    let verdict = await preflight.inspect(data: Self.blankPNG, uti: "public.png")

    #expect(verdict == .allow(width: 1, height: 1))
    #expect(await recognizer.calls == 1)
  }

  @Test("refuses an image whose OCR text looks like a secret")
  func refusesSecretBearingImage() async {
    // Concatenated (not one literal) so repository secret scanning never
    // sees a reassembled fake key block, mirroring the service tests.
    let keyText = "-----BEGIN " + "PRIVATE KEY-----\nsynthetic-fixture-body"
    let recognizer = StubRecognizer(.strings([keyText]))
    let preflight = VisionImagePreflight(recognizer: recognizer)

    let verdict = await preflight.inspect(data: Self.blankPNG, uti: "public.png")

    #expect(verdict == .skip(.sensitiveContent))
  }

  @Test("refuses OCR-mangled PEM headers that exact patterns miss")
  func refusesMangledPEMHeaders() async {
    // Live OCR observations for the same on-screen header. The text
    // detector's exact five-dash pattern matches neither.
    for mangled in ["•---BEGIN PRIVATE KEY...", "----BEGIN PRIVATE KEY-...."] {
      let preflight = VisionImagePreflight(recognizer: StubRecognizer(.strings([mangled])))
      #expect(
        await preflight.inspect(data: Self.blankPNG, uti: "public.png")
          == .skip(.sensitiveContent))
    }
  }

  @Test("allows prose that merely mentions private keys")
  func allowsKeyProse() async {
    let preflight = VisionImagePreflight(
      recognizer: StubRecognizer(.strings(["how do private keys work?"])))

    let verdict = await preflight.inspect(data: Self.blankPNG, uti: "public.png")

    #expect(verdict == .allow(width: 1, height: 1))
  }

  @Test("refuses undecodable bytes without consulting OCR")
  func refusesUndecodableData() async {
    let recognizer = StubRecognizer(.strings(["hello"]))
    let preflight = VisionImagePreflight(recognizer: recognizer)

    let verdict = await preflight.inspect(
      data: Data([0x00, 0x01, 0x02, 0x03]), uti: "public.png")

    #expect(verdict == .skip(.unreadableImage))
    #expect(await recognizer.calls == 0)
  }

  @Test("fails closed when recognition throws")
  func failsClosedOnRecognizerError() async {
    let preflight = VisionImagePreflight(recognizer: StubRecognizer(.failure))

    let verdict = await preflight.inspect(data: Self.blankPNG, uti: "public.png")

    #expect(verdict == .skip(.preflightTimeout))
  }

  @Test("rejects unsupported flavors before decoding")
  func rejectsUnsupportedFlavor() async {
    let recognizer = StubRecognizer(.strings(["hello"]))
    let preflight = VisionImagePreflight(recognizer: recognizer)

    let verdict = await preflight.inspect(data: Self.blankPNG, uti: "com.compuserve.gif")

    #expect(verdict == .skip(.unsupportedType))
    #expect(await recognizer.calls == 0)
  }

  @Test("real recognizer finds no text in a blank image")
  func realRecognizerBlankImage() async throws {
    // Vision refuses images at or below 2 px per side, so the blank fixture
    // is rendered at 64 px rather than reusing the 1 px decode fixture.
    let data = try #require(makeBlankPNG(width: 64, height: 64))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

    let texts = try await VisionTextRecognizer().recognizeText(in: image)

    #expect(texts.isEmpty)
  }
}

/// Renders a solid-white PNG with no text. Deterministic, asset-free, and
/// large enough for Vision's minimum-dimension requirement.
private func makeBlankPNG(width: Int, height: Int) -> Data? {
  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ),
    let image = context.makeImage()
  else {
    return nil
  }
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data as CFMutableData, "public.png" as CFString, 1, nil)
  else {
    return nil
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { return nil }
  return data as Data
}

private actor StubRecognizer: VisionTextRecognizing {
  enum Behavior {
    case strings([String])
    case failure
  }

  enum StubError: Error {
    case boom
  }

  let behavior: Behavior
  private(set) var calls = 0

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  func recognizeText(in image: CGImage) async throws -> [String] {
    calls += 1
    switch behavior {
    case .strings(let strings):
      return strings
    case .failure:
      throw StubError.boom
    }
  }
}
