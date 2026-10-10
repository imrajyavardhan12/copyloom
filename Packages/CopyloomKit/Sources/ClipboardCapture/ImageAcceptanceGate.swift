import ClipDomain
import Foundation

/// Everything that decides whether image bytes may be stored: the byte
/// ceiling, the content preflight under a timeout, then the pixel ceiling.
///
/// Capture and import share this type so an image arriving from an archive
/// faces exactly the checks an image copied from another app does.
public struct ImageAcceptanceGate: Sendable {
  private let preflight: any ImagePrivacyPreflight
  private let maximumBytes: Int
  private let maximumPixels: Int
  private let timeoutSeconds: Double

  public init(
    preflight: any ImagePrivacyPreflight, maximumBytes: Int, maximumPixels: Int,
    timeoutSeconds: Double
  ) {
    self.preflight = preflight
    self.maximumBytes = maximumBytes
    self.maximumPixels = maximumPixels
    self.timeoutSeconds = timeoutSeconds
  }

  public init(preflight: any ImagePrivacyPreflight, configuration: CaptureConfiguration) {
    self.init(
      preflight: preflight, maximumBytes: configuration.maximumImageBytes,
      maximumPixels: configuration.maximumImagePixels,
      timeoutSeconds: configuration.imagePreflightTimeoutSeconds)
  }

  public func evaluate(data: Data, uti: String) async -> ImagePreflightVerdict {
    guard data.count <= maximumBytes else { return .skip(.tooLarge) }

    switch await inspectWithTimeout(data: data, uti: uti) {
    case .skip(let reason):
      return .skip(reason)
    case .allow(let width, let height):
      // The preflight judges content; this type enforces resource ceilings.
      // Refusing dimensions-only decodes above the pixel cap without full
      // bitmap residency is the Vision implementation's job; this check is
      // the backstop for misbehaving gates.
      guard width > 0, height > 0, width * height <= maximumPixels else {
        return .skip(.tooLarge)
      }
      return .allow(width: width, height: height)
    }
  }

  private func inspectWithTimeout(data: Data, uti: String) async -> ImagePreflightVerdict {
    let preflight = preflight
    let timeoutNanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
    return await withTaskGroup(
      of: ImagePreflightVerdict.self,
      returning: ImagePreflightVerdict.self
    ) { group in
      group.addTask { await preflight.inspect(data: data, uti: uti) }
      group.addTask {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        return .skip(.preflightTimeout)
      }
      guard let first = await group.next() else { return .skip(.preflightTimeout) }
      group.cancelAll()
      return first
    }
  }
}
