import ClipDomain
import Foundation
import Testing

@testable import ClipSearch

@Suite("Search query parser")
struct SearchQueryParserTests {
  @Test("parses text, a quoted phrase, and structured filters")
  func parsesMixedQuery() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(
      ISO8601DateFormatter().date(from: "2026-08-21T15:30:00Z")
    )
    let context = SearchParseContext(now: now, calendar: calendar)

    let query = try SearchQueryParser().parse(
      #"postgres "connection refused" app:Ghostty is:pinned after:today"#,
      context: context
    )

    #expect(
      query.text == [
        .term("postgres"),
        .phrase("connection refused"),
      ]
    )
    #expect(
      query.filters == [
        .application("Ghostty"),
        .pinned,
        .after(try #require(ISO8601DateFormatter().date(from: "2026-08-21T00:00:00Z"))),
      ]
    )
  }

  @Test("keeps a URL as searchable text instead of treating its scheme as a filter")
  func keepsURLAsText() throws {
    let query = try SearchQueryParser().parse(
      "https://example.com/docs",
      context: SearchParseContext(now: .distantPast, calendar: .current)
    )

    #expect(query.text == [.term("https://example.com/docs")])
    #expect(query.filters.isEmpty)
  }

  @Test(
    "a colon after a word that is not a filter name is text: a URL being typed, a time, code"
  )
  func keepsUnregisteredNamesAsText() throws {
    let context = SearchParseContext(now: .distantPast, calendar: .current)

    for input in ["https:", "https:/", "HTTPS:", "10:30", "std::vector", "note:", "mailto:x"] {
      let query = try SearchQueryParser().parse(input, context: context)
      #expect(query.text == [.term(input)])
      #expect(query.filters.isEmpty)
    }
    #expect(
      try SearchQueryParser().parse("https: app:Safari", context: context)
        == SearchQuery(text: [.term("https:")], filters: [.application("Safari")]))
  }

  @Test("a filter name still needs a value it understands")
  func reportsBadValuesOfRegisteredFilters() throws {
    let context = SearchParseContext(now: .distantPast, calendar: .current)

    #expect(throws: SearchQueryError.missingFilterValue("app")) {
      try SearchQueryParser().parse("app:", context: context)
    }
    #expect(throws: SearchQueryError.unsupportedContentType("movie")) {
      try SearchQueryParser().parse("type:movie", context: context)
    }
    #expect(throws: SearchQueryError.unsupportedFilter(name: "is", value: "archived")) {
      try SearchQueryParser().parse("IS:archived", context: context)
    }
    #expect(throws: SearchQueryError.unsupportedFilter(name: "has", value: "audio")) {
      try SearchQueryParser().parse("has:audio", context: context)
    }
  }

  @Test("reports malformed quotes and dates with typed errors")
  func reportsMalformedInput() throws {
    #expect(throws: SearchQueryError.unterminatedQuote) {
      try SearchQueryParser().parse(
        #""unfinished"#,
        context: SearchParseContext(now: .distantPast, calendar: .current)
      )
    }
    #expect(throws: SearchQueryError.invalidDate(filter: "before", value: "2026-02-30")) {
      try SearchQueryParser().parse(
        "before:2026-02-30",
        context: SearchParseContext(now: .distantPast, calendar: .current)
      )
    }
  }

  @Test("parses every initial filter and a quoted filter value")
  func parsesInitialFilters() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(
      ISO8601DateFormatter().date(from: "2026-08-21T15:30:00Z")
    )

    let query = try SearchQueryParser().parse(
      #"app:"Visual Studio Code" type:code is:favorite before:2026-08-22 tag:project-x has:ocr"#,
      context: SearchParseContext(now: now, calendar: calendar)
    )

    #expect(query.text.isEmpty)
    #expect(
      query.filters == [
        .application("Visual Studio Code"),
        .contentType(.code),
        .favorite,
        .before(try #require(ISO8601DateFormatter().date(from: "2026-08-22T00:00:00Z"))),
        .tag("project-x"),
        .hasOCR,
      ]
    )
  }
}
