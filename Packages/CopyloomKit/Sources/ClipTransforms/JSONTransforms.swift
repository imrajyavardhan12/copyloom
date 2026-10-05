import Foundation

/// JSON actions. Validation uses `JSONSerialization`, but output is produced
/// by a token-level reformatter instead of re-serializing the parsed value:
/// Foundation would reorder keys and rewrite numbers (`1.10` → `1.1`,
/// `12345678901234567890` → a lossy double), silently changing clipboard
/// data. Reformatting only whitespace keeps every lexeme byte-for-byte.
enum JSONTransforms {
  static let all: [FunctionTransform] = [
    FunctionTransform(
      id: "json.pretty", title: "Pretty-print JSON",
      kinds: .editableText, when: looksLikeJSON
    ) { try reformat($0, pretty: true) },
    FunctionTransform(
      id: "json.minify", title: "Minify JSON",
      kinds: .editableText, when: looksLikeJSON
    ) { try reformat($0, pretty: false) },
    FunctionTransform(
      id: "json.validate", title: "Validate JSON",
      kinds: .editableText, when: looksLikeJSON
    ) {
      try validate($0)
      return $0
    },
  ]

  private static func looksLikeJSON(_ text: String) -> Bool {
    guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
    return first == "{" || first == "["
  }

  private static func validate(_ input: String) throws {
    do {
      _ = try JSONSerialization.jsonObject(
        with: Data(input.utf8), options: [.fragmentsAllowed])
    } catch {
      throw TransformError("Not valid JSON")
    }
  }

  /// Rewrites whitespace only. Safe because `validate` has already proven
  /// the input is well-formed, so structural characters outside strings are
  /// exactly the JSON punctuation.
  static func reformat(_ input: String, pretty: Bool) throws -> String {
    try validate(input)
    let scalars = Array(input.unicodeScalars)
    var output = String.UnicodeScalarView()
    var depth = 0
    var index = 0

    func newline() {
      guard pretty else { return }
      output.append("\n")
      output.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars)
    }

    func nextSignificant(after position: Int) -> Unicode.Scalar? {
      var cursor = position + 1
      while cursor < scalars.count {
        if !scalars[cursor].properties.isWhitespace { return scalars[cursor] }
        cursor += 1
      }
      return nil
    }

    while index < scalars.count {
      let scalar = scalars[index]
      switch scalar {
      case "\"":
        output.append(scalar)
        index += 1
        while index < scalars.count {
          let inner = scalars[index]
          output.append(inner)
          if inner == "\\", index + 1 < scalars.count {
            index += 1
            output.append(scalars[index])
          } else if inner == "\"" {
            break
          }
          index += 1
        }
      case "{", "[":
        output.append(scalar)
        let closer: Unicode.Scalar = scalar == "{" ? "}" : "]"
        if nextSignificant(after: index) == closer {
          // Empty container stays on one line: `{}` / `[]`.
          output.append(closer)
          while scalars[index] != closer { index += 1 }
        } else {
          depth += 1
          newline()
        }
      case "}", "]":
        depth -= 1
        newline()
        output.append(scalar)
      case ",":
        output.append(scalar)
        newline()
      case ":":
        output.append(scalar)
        if pretty { output.append(" ") }
      default:
        if !scalar.properties.isWhitespace { output.append(scalar) }
      }
      index += 1
    }
    return String(output)
  }
}
