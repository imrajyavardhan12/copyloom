import Foundation

public struct SearchQuery: Equatable, Sendable {
  public let text: [SearchTextClause]
  public let filters: [SearchFilter]

  public init(text: [SearchTextClause], filters: [SearchFilter]) {
    self.text = text
    self.filters = filters
  }
}

public enum SearchTextClause: Equatable, Sendable {
  case term(String)
  case phrase(String)
}

public enum SearchContentType: String, CaseIterable, Equatable, Sendable {
  case text
  case richText = "rich-text"
  case link
  case email
  case image
  case screenshot
  case file
  case code
  case color
  case json
  case xml
  case yaml
  case markdown
  case html
  case svg
  case filePath = "file-path"
}

public enum SearchFilter: Equatable, Sendable {
  case application(String)
  case contentType(SearchContentType)
  case pinned
  case favorite
  case after(Date)
  case before(Date)
  case tag(String)
  case hasOCR
}
