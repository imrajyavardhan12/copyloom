import ClipDomain
import Foundation
import Testing

@testable import ClipStore

/// How typed text matches and orders clips: from its second letter, each word
/// matches the words it begins, as the person types; a quoted phrase matches
/// only whole words. A search ranks by relevance unless it matches much of the
/// history; then it lists like the history (ARCHITECTURE.md § Search
/// architecture).
@Suite("Search matching")
struct SearchMatchingTests {
  @Test("a word matches clips containing a word that starts with it")
  func matchesWordPrefixes() async throws {
    try await withDatabase { repository in
      let deployment = try await save("synthetic kubernetes deployment notes", in: repository)
      _ = try await save("synthetic cube render notes", in: repository)

      #expect(try await search([.term("kube")], in: repository) == [deployment])
      #expect(try await search([.term("deploy")], in: repository) == [deployment])
    }
  }

  @Test("each word of a query narrows the results while the last one is still being typed")
  func narrowsWithEveryWord() async throws {
    try await withDatabase { repository in
      let deployment = try await save("synthetic kubernetes deployment notes", in: repository)
      _ = try await save("synthetic kubernetes service notes", in: repository)

      #expect(try await search([.term("kube"), .term("dep")], in: repository) == [deployment])
    }
  }

  @Test(
    "of two comparable clips, the one with the exact word ranks above one where it only begins a longer word"
  )
  func ranksExactWordsFirst() async throws {
    try await withDatabase { repository in
      // The exact match is the longer and older text, which bm25 alone or
      // recency would rank lower.
      let exact = try await save(
        "we should log the synthetic build output again tonight", in: repository,
        at: Date(timeIntervalSince1970: 1_800_000_000))
      let longer = try await save(
        "logging tooling", in: repository, at: Date(timeIntervalSince1970: 1_800_000_100))

      #expect(try await search([.term("log")], in: repository) == [exact, longer])
    }
  }

  @Test("a single letter matches only that whole word; matching the words it begins starts at two")
  func singleLetterMatchesWholeWord() async throws {
    try await withDatabase { repository in
      // A one-letter prefix has no prefix index and begins most words, so it
      // would cost a scan that says almost nothing.
      let plan = try await save("synthetic plan g notes", in: repository)
      let golang = try await save("synthetic golang notes", in: repository)

      #expect(try await search([.term("g")], in: repository) == [plan])
      #expect(Set(try await search([.term("go")], in: repository)) == [golang])
      #expect(try await search([.term("synthetic"), .term("g")], in: repository) == [plan])
    }
  }

  @Test("one CJK character finds the run it begins, which the tokenizer keeps as one word")
  func singleCJKCharacterMatchesItsRun() async throws {
    try await withDatabase { repository in
      let tower = try await save("synthetic 東京タワー notes", in: repository)

      #expect(try await search([.term("東")], in: repository) == [tower])
    }
  }

  @Test("results that list like the history put pinned clips first, then the newest")
  func historyOrderPutsPinnedFirst() async throws {
    try await withDatabase(relevanceRankingLimit: 1) { repository in
      let oldest = try await save(
        "synthetic golang notes", in: repository, at: Date(timeIntervalSince1970: 1_800_000_000))
      let pinned = try await save(
        "synthetic gopher notes", in: repository, at: Date(timeIntervalSince1970: 1_800_000_100))
      let newest = try await save(
        "synthetic goroutine notes", in: repository, at: Date(timeIntervalSince1970: 1_800_000_200))
      try await repository.setPinned(id: pinned, isPinned: true)

      #expect(try await search([.term("go")], in: repository) == [pinned, newest, oldest])
    }
  }

  @Test("a word that matches more clips than are ranked lists them newest first")
  func broadMatchesListNewestFirst() async throws {
    // Ranking every match by relevance costs a sort of the whole match set; past
    // the limit the results list like the history, which says as much.
    let exact = Date(timeIntervalSince1970: 1_800_000_000)
    let longer = Date(timeIntervalSince1970: 1_800_000_100)
    try await withDatabase(relevanceRankingLimit: 1) { repository in
      let exactID = try await save(
        "we should log the synthetic build output again tonight", in: repository, at: exact)
      let longerID = try await save("logging tooling", in: repository, at: longer)

      #expect(try await search([.term("log")], in: repository) == [longerID, exactID])
    }
    try await withDatabase(relevanceRankingLimit: 2) { repository in
      let exactID = try await save(
        "we should log the synthetic build output again tonight", in: repository, at: exact)
      let longerID = try await save("logging tooling", in: repository, at: longer)

      #expect(try await search([.term("log")], in: repository) == [exactID, longerID])
    }
  }

  @Test("a word that ends in punctuation is finished: c++ doesn't match every word starting with c")
  func trailingPunctuationEndsTheWord() async throws {
    try await withDatabase { repository in
      let cpp = try await save("synthetic c++ notes", in: repository)
      _ = try await save("synthetic cube notes", in: repository)

      #expect(try await search([.term("c++")], in: repository) == [cpp])
      #expect(try await search([.term("cub.")], in: repository).isEmpty)
    }
  }

  @Test("a word of punctuation only beside other words is ignored")
  func punctuationBesideWordsIsIgnored() async throws {
    try await withDatabase { repository in
      let kube = try await save("synthetic kube config", in: repository)

      #expect(try await search([.term("kube"), .term("-")], in: repository) == [kube])
      #expect(try await search([.term("&"), .phrase("kube config")], in: repository) == [kube])
    }
  }

  @Test("accents and case don't matter in a word being typed")
  func foldsAccentsAndCaseInPrefixes() async throws {
    try await withDatabase { repository in
      let menu = try await save("synthetic Café menu", in: repository)

      #expect(try await search([.term("CAF")], in: repository) == [menu])
    }
  }

  @Test("a quoted phrase matches whole words only")
  func phrasesStayExact() async throws {
    try await withDatabase { repository in
      let exact = try await save("synthetic kube config", in: repository)
      _ = try await save("synthetic kubernetes config", in: repository)

      #expect(try await search([.phrase("kube config")], in: repository) == [exact])
    }
  }

  @Test("a search of punctuation only matches nothing instead of failing")
  func punctuationOnlyWordMatchesNothing() async throws {
    try await withDatabase { repository in
      _ = try await save("synthetic punctuation notes", in: repository)

      #expect(try await search([.term("!!!")], in: repository).isEmpty)
      #expect(try await search([.term("*"), .phrase("-")], in: repository).isEmpty)
    }
  }

  // MARK: - Helpers

  private func withDatabase(
    relevanceRankingLimit: Int = AppDatabase.defaultRelevanceRankingLimit,
    _ body: (any ClipRepository) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try AppDatabase.open(
      at: directory.appending(path: "copyloom.sqlite"),
      relevanceRankingLimit: relevanceRankingLimit)
    defer { try? database.close() }
    try await body(database.repository)
  }

  private func save(
    _ text: String, in repository: any ClipRepository, at date: Date = Date()
  ) async throws -> UUID {
    let id = UUID()
    _ = try await repository.saveAcceptedText(
      AcceptedTextClip(id: id, text: text, capturedAt: date))
    return id
  }

  private func search(
    _ text: [SearchTextClause], in repository: any ClipRepository
  ) async throws -> [UUID] {
    try await repository.search(SearchQuery(text: text, filters: []), limit: 20).map(\.id)
  }
}
