import ClipDomain
import Foundation

/// The capture pipeline's text acceptance rules, for text that did not come
/// from the pasteboard (e.g. a transform result the user wants to save).
///
/// Persisting such text must be no easier than persisting the same text
/// copied from another app: a Base64 decode can turn an innocuous clip into
/// a credential. Same order as `ClipboardCaptureService.captureText`:
/// non-empty, size ceiling, sensitive detector, then kind classification.
public struct TextOutputGate: Sendable {
  private let detector: any SensitiveContentDetecting
  private let policy: CapturePolicy
  private let maximumBytes: Int

  public init(
    detector: any SensitiveContentDetecting = LocalSensitiveContentDetector(),
    policy: CapturePolicy = CapturePolicy(),
    maximumBytes: Int = CaptureConfiguration().maximumTextBytes
  ) {
    self.detector = detector
    self.policy = policy
    self.maximumBytes = maximumBytes
  }

  /// The kind to store the text under, or nil when it must not be persisted.
  public func kind(for text: String) -> ClipKind? {
    guard !text.isEmpty, text.utf8.count <= maximumBytes else { return nil }
    guard detector.inspect(text) == .safe else { return nil }
    return policy.classifyKind(text)
  }
}
