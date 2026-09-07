import ClipDomain
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// OCR engine seam. The production implementation calls Vision; tests inject
/// canned strings or failures so no test depends on ML behavior.
public protocol VisionTextRecognizing: Sendable {
  func recognizeText(in image: CGImage) async throws -> [String]
}

/// Thin Vision wrapper. Runs synchronously inside the caller's task, so the
/// service invokes it from a task-group child off the main actor. A hung
/// request does not observe task cancellation; the service-level timeout race
/// bounds user-visible latency while the request drains in the background.
public struct VisionTextRecognizer: VisionTextRecognizing, Sendable {
  public init() {}

  public func recognizeText(in image: CGImage) async throws -> [String] {
    // Vision can report one failure twice: through the request completion
    // handler and again as a synchronous `perform` throw (observed with
    // undersized images). The box makes double-reporting impossible.
    let box = ResumeBox()
    return try await withCheckedThrowingContinuation { continuation in
      box.continuation = continuation
      let request = VNRecognizeTextRequest { request, error in
        if let error {
          box.resume(throwing: error)
          return
        }
        let texts =
          (request.results as? [VNRecognizedTextObservation])?
          .compactMap { $0.topCandidates(1).first?.string } ?? []
        box.resume(returning: texts)
      }
      // Accurate over fast: a missed secret persists pixels, while slowness
      // only costs latency already bounded by the service timeout.
      // Language correction stays off: secrets and code are not prose, and
      // "correcting" random tokens can only hide them from the detector.
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      } catch {
        box.resume(throwing: error)
      }
    }
  }
}

/// Single-threaded once-guard for the Vision completion contract. The handler
/// callback and the `perform` throw run on the same thread, so no locking is
/// needed; `@unchecked` documents that confinement.
private final class ResumeBox: @unchecked Sendable {
  var continuation: CheckedContinuation<[String], Error>?
  private var resumed = false

  func resume(returning value: [String]) {
    guard !resumed else { return }
    resumed = true
    continuation?.resume(returning: value)
    continuation = nil
  }

  func resume(throwing error: Error) {
    guard !resumed else { return }
    resumed = true
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

/// Fail-closed Vision privacy gate (ADR-0004 slice 3).
///
/// 1. Dimensions-only decode — no full-bitmap residency for the size check.
/// 2. OCR strictly in memory; recognized strings never touch disk.
/// 3. Existing local sensitive-content detector over the OCR text.
///
/// Every failure (undecodable, OCR error, sensitive match) refuses persistence
/// with a content-free reason. OCR text is not stored or indexed here; that
/// stays M3 behind the Vault-aware search design.
public struct VisionImagePreflight: ImagePrivacyPreflight, Sendable {
  private let recognizer: any VisionTextRecognizing
  private let detector: any SensitiveContentDetecting

  public init(
    recognizer: any VisionTextRecognizing = VisionTextRecognizer(),
    detector: any SensitiveContentDetecting = LocalSensitiveContentDetector()
  ) {
    self.recognizer = recognizer
    self.detector = detector
  }

  public func inspect(data: Data, uti: String) async -> ImagePreflightVerdict {
    guard PasteboardTypeIdentifier.imageTypes.contains(uti.lowercased()) else {
      return .skip(.unsupportedType)
    }
    guard let dimensions = Self.dimensions(of: data), dimensions.width > 0,
      dimensions.height > 0
    else {
      return .skip(.unreadableImage)
    }
    let observations: [String]
    do {
      guard let image = Self.makeImage(from: data) else {
        return .skip(.unreadableImage)
      }
      observations = try await recognizer.recognizeText(in: image)
    } catch {
      return .skip(.preflightTimeout)
    }
    guard detector.inspect(observations.joined(separator: "\n")) == .safe else {
      return .skip(.sensitiveContent)
    }
    // OCR mangles dash runs ("•---BEGIN", "----BEGIN…-...." seen live),
    // so the exact-match PEM pattern in the text detector never fires on
    // screenshots. This OCR-specific pre-check tolerates dash/whitespace
    // mangling around the header. It runs only on OCR output — the text
    // path keeps its exact patterns — and refusing header-bearing images is
    // consistent: the text path refuses the same headers.
    guard !Self.looksLikePEMHeader(observations.joined(separator: "\n")) else {
      return .skip(.sensitiveContent)
    }
    return .allow(width: dimensions.width, height: dimensions.height)
  }

  private static func dimensions(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      return nil
    }
    return (width, height)
  }

  private static func makeImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func looksLikePEMHeader(_ text: String) -> Bool {
    pemHeaderPattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
      != nil
  }

  private static let pemHeaderPattern: NSRegularExpression = {
    // Hardcoded valid pattern; compiled once at first use.
    try! NSRegularExpression(
      pattern: #"-{2,}\s*BEGIN\s+(?:(?:RSA|OPENSSH|DSA|EC)\s+)?PRIVATE\s+KEY"#,
      options: [.caseInsensitive]
    )
  }()
}
