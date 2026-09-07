import ClipDomain
import Foundation

/// Judgment on one image snapshot. The gate judges *content* (sensitive or
/// not); resource ceilings (bytes, pixels, time) stay the service's job.
public enum ImagePreflightVerdict: Equatable, Sendable {
  case allow(width: Int, height: Int)
  case skip(CaptureSkipReason)
}

public protocol ImagePrivacyPreflight: Sendable {
  func inspect(data: Data, uti: String) async -> ImagePreflightVerdict
}

/// Fail-closed placeholder until the Vision implementation lands (slice 3).
/// Every image is refused with a content-free reason, so wiring the capture
/// path early can never silently persist uninspected pixels.
public struct DisabledImagePreflight: ImagePrivacyPreflight, Sendable {
  public init() {}

  public func inspect(data: Data, uti: String) async -> ImagePreflightVerdict {
    .skip(.preflightTimeout)
  }
}
