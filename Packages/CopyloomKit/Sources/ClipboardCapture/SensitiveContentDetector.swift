import Foundation

public enum SensitiveContentCategory: Equatable, Sendable {
  case privateKey
  case credentialAssignment
  case accessToken
  case structuredToken
  case paymentCard
}

public enum SensitiveContentVerdict: Equatable, Sendable {
  case safe
  case sensitive(SensitiveContentCategory)
}

public protocol SensitiveContentDetecting: Sendable {
  func inspect(_ text: String) -> SensitiveContentVerdict
}

public struct LocalSensitiveContentDetector: SensitiveContentDetecting {
  public init() {}

  public func inspect(_ text: String) -> SensitiveContentVerdict {
    if text.range(
      of: #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil {
      return .sensitive(.privateKey)
    }

    if text.range(
      of:
        #"(?im)^\s*[A-Z0-9_]*(?:PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\s*=\s*['\"]?[^'\"\s][^\r\n]*"#,
      options: .regularExpression
    ) != nil {
      return .sensitive(.credentialAssignment)
    }

    if text.range(
      of:
        #"(?i)\b(?:github_pat_[A-Z0-9_]{20,}|gh[pousr]_[A-Z0-9]{20,}|sk-[A-Z0-9]{20,}|xox[baprs]-[A-Z0-9-]{20,}|AKIA[A-Z0-9]{16})\b"#,
      options: .regularExpression
    ) != nil {
      return .sensitive(.accessToken)
    }

    if text.range(
      of: #"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
      options: .regularExpression
    ) != nil {
      return .sensitive(.structuredToken)
    }

    if containsLuhnValidCardCandidate(text) {
      return .sensitive(.paymentCard)
    }

    return .safe
  }

  private func containsLuhnValidCardCandidate(_ text: String) -> Bool {
    var digits: [Int] = []

    func isValidCandidate() -> Bool {
      guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
      var sum = 0
      for (offset, digit) in digits.reversed().enumerated() {
        if offset.isMultiple(of: 2) {
          sum += digit
        } else {
          let doubled = digit * 2
          sum += doubled > 9 ? doubled - 9 : doubled
        }
      }
      return sum.isMultiple(of: 10)
    }

    for character in text {
      if let value = character.wholeNumberValue {
        digits.append(value)
      } else if character == " " || character == "-" {
        continue
      } else {
        if isValidCandidate() { return true }
        digits.removeAll(keepingCapacity: true)
      }
    }
    return isValidCandidate()
  }
}
