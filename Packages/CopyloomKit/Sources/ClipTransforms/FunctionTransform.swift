import ClipDomain
import Foundation

/// Closure-backed transform used by the built-ins, so each one is a few
/// declarative lines instead of a type per action.
struct FunctionTransform: ClipTransform {
  let id: String
  let title: String
  private let isRelevant: @Sendable (ClipSummary) -> Bool
  private let transform: @Sendable (String) throws -> String

  init(
    id: String,
    title: String,
    isRelevant: @escaping @Sendable (ClipSummary) -> Bool,
    transform: @escaping @Sendable (String) throws -> String
  ) {
    self.id = id
    self.title = title
    self.isRelevant = isRelevant
    self.transform = transform
  }

  /// Offered for any of `kinds`, further narrowed by `when`.
  init(
    id: String,
    title: String,
    kinds: Set<ClipKind>,
    when extra: @escaping @Sendable (String) -> Bool = { _ in true },
    transform: @escaping @Sendable (String) throws -> String
  ) {
    self.init(
      id: id, title: title,
      isRelevant: { kinds.contains($0.kind) && extra($0.text) },
      transform: transform)
  }

  func applies(to clip: ClipSummary) -> Bool { isRelevant(clip) }

  func apply(_ input: String) throws -> String { try transform(input) }
}

extension Set where Element == ClipKind {
  /// Kinds whose payload is plain editable text.
  static let editableText: Set<ClipKind> = [.text, .code]
  /// Editable text plus links, for encoding actions that are valid on URLs.
  static let encodableText: Set<ClipKind> = [.text, .code, .link]
}
