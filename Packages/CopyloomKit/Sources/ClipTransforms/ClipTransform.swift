import ClipDomain
import Foundation

/// A pure, user-invoked text transformation (ADR-0005 §5).
///
/// Transforms never touch storage, the pasteboard or the UI: they map one
/// string to another or throw. Callers preview the result and decide whether
/// to copy it or save it as a new clip, so a failing transform can never
/// replace or corrupt the original clip.
public protocol ClipTransform: Sendable {
  /// Stable identifier, e.g. `json.pretty`. Never shown to the user.
  var id: String { get }
  var title: String { get }
  /// Whether this transform is worth offering for the clip. Cheap by design:
  /// it runs on every selection change.
  func applies(to clip: ClipSummary) -> Bool
  func apply(_ input: String) throws -> String
}

/// Why a transform refused its input. Messages are fixed strings and never
/// echo clip content, so they are safe to show in the UI and logs.
public struct TransformError: Error, Equatable, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}

public struct TransformRegistry: Sendable {
  public let all: [any ClipTransform]

  public init(_ transforms: [any ClipTransform]) {
    self.all = transforms
  }

  /// The M3 built-ins, in the order they are offered.
  public static let builtIn = TransformRegistry(
    JSONTransforms.all + TextTransforms.all + EncodingTransforms.all + ColorTransforms.all)

  /// Transforms to offer for a clip, in registry order.
  public func transforms(for clip: ClipSummary) -> [any ClipTransform] {
    all.filter { $0.applies(to: clip) }
  }

  public func transform(id: String) -> (any ClipTransform)? {
    all.first { $0.id == id }
  }
}
