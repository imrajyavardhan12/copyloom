import ClipDomain
import Foundation

public struct SearchParseContext: Sendable {
  public let now: Date
  public let calendar: Calendar

  public init(now: Date, calendar: Calendar) {
    self.now = now
    self.calendar = calendar
  }
}

public enum SearchQueryError: Error, Equatable, Sendable {
  case unterminatedQuote
  case missingFilterValue(String)
  case invalidDate(filter: String, value: String)
  case unsupportedContentType(String)
  case unsupportedFilter(name: String, value: String)
}

public struct SearchQueryParser: Sendable {
  public init() {}

  public func parse(_ input: String, context: SearchParseContext) throws -> SearchQuery {
    let tokens = try tokenize(input)
    var text: [SearchTextClause] = []
    var filters: [SearchFilter] = []

    for token in tokens {
      if token.isPhrase {
        text.append(.phrase(token.value))
        continue
      }

      guard let separator = token.value.firstIndex(of: ":") else {
        text.append(.term(token.value))
        continue
      }

      let name = String(token.value[..<separator]).lowercased()
      let value = String(token.value[token.value.index(after: separator)...])

      if value.hasPrefix("//") {
        text.append(.term(token.value))
        continue
      }

      guard !value.isEmpty else {
        throw SearchQueryError.missingFilterValue(name)
      }

      switch name {
      case "app":
        filters.append(.application(value))
      case "type":
        guard let contentType = SearchContentType(rawValue: value.lowercased()) else {
          throw SearchQueryError.unsupportedContentType(value)
        }
        filters.append(.contentType(contentType))
      case "is":
        switch value.lowercased() {
        case "pinned": filters.append(.pinned)
        case "favorite": filters.append(.favorite)
        default:
          throw SearchQueryError.unsupportedFilter(name: name, value: value)
        }
      case "after":
        filters.append(.after(try parseDate(value, filter: name, context: context)))
      case "before":
        filters.append(.before(try parseDate(value, filter: name, context: context)))
      case "tag":
        filters.append(.tag(value))
      case "has" where value.lowercased() == "ocr":
        filters.append(.hasOCR)
      default:
        throw SearchQueryError.unsupportedFilter(name: name, value: value)
      }
    }

    return SearchQuery(text: text, filters: filters)
  }

  private func parseDate(
    _ value: String,
    filter: String,
    context: SearchParseContext
  ) throws -> Date {
    if value.lowercased() == "today" {
      return context.calendar.startOfDay(for: context.now)
    }

    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else {
      throw SearchQueryError.invalidDate(filter: filter, value: value)
    }

    var components = DateComponents()
    components.calendar = context.calendar
    components.timeZone = context.calendar.timeZone
    components.year = year
    components.month = month
    components.day = day

    guard let date = context.calendar.date(from: components) else {
      throw SearchQueryError.invalidDate(filter: filter, value: value)
    }
    let result = context.calendar.dateComponents([.year, .month, .day], from: date)
    guard result.year == year, result.month == month, result.day == day else {
      throw SearchQueryError.invalidDate(filter: filter, value: value)
    }
    return date
  }

  private func tokenize(_ input: String) throws -> [Token] {
    var tokens: [Token] = []
    var value = ""
    var isInsideQuote = false
    var quoteStartedAtTokenStart = false
    var isEscaping = false

    func appendToken() {
      guard !value.isEmpty else { return }
      tokens.append(Token(value: value, isPhrase: quoteStartedAtTokenStart))
      value.removeAll(keepingCapacity: true)
      quoteStartedAtTokenStart = false
    }

    for character in input {
      if isEscaping {
        value.append(character)
        isEscaping = false
      } else if character == "\\" && isInsideQuote {
        isEscaping = true
      } else if character == "\"" {
        if !isInsideQuote {
          quoteStartedAtTokenStart = value.isEmpty
        }
        isInsideQuote.toggle()
      } else if character.isWhitespace && !isInsideQuote {
        appendToken()
      } else {
        value.append(character)
      }
    }

    guard !isInsideQuote else {
      throw SearchQueryError.unterminatedQuote
    }
    if isEscaping {
      value.append("\\")
    }
    appendToken()
    return tokens
  }
}

private struct Token {
  let value: String
  let isPhrase: Bool
}
