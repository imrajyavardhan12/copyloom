import Foundation

enum TextTransforms {
  static let all: [FunctionTransform] = [
    FunctionTransform(
      id: "text.uppercase", title: "UPPERCASE", kinds: .editableText
    ) { $0.uppercased() },
    FunctionTransform(
      id: "text.lowercase", title: "lowercase", kinds: .editableText
    ) { $0.lowercased() },
    FunctionTransform(
      id: "text.titlecase", title: "Title Case", kinds: .editableText
    ) { titleCase($0) },
    FunctionTransform(
      id: "text.trim", title: "Trim whitespace", kinds: .editableText
    ) { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
    FunctionTransform(
      id: "text.collapse-whitespace", title: "Collapse whitespace", kinds: .editableText
    ) { collapseWhitespace($0) },
  ]

  /// Capitalizes the first character of each whitespace-separated word and
  /// lowercases the rest, leaving the whitespace itself untouched.
  /// `String.capitalized` is avoided: it also capitalizes after apostrophes
  /// ("don't" → "Don'T").
  private static func titleCase(_ input: String) -> String {
    var result = ""
    var atWordStart = true
    for character in input {
      if character.isWhitespace {
        result.append(character)
        atWordStart = true
      } else if atWordStart {
        result.append(contentsOf: character.uppercased())
        atWordStart = false
      } else {
        result.append(contentsOf: character.lowercased())
      }
    }
    return result
  }

  private static func collapseWhitespace(_ input: String) -> String {
    input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
