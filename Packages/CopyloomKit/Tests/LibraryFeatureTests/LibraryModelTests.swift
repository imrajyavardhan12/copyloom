import ClipDomain
import Foundation
import Testing

@testable import LibraryFeature

@MainActor
@Suite("Library model")
struct LibraryModelTests {
  @Test("sections route to their backing filters")
  func sectionsRoute() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    for section in LibrarySection.allCases {
      await model.select(section: section)
      #expect(model.section == section)
    }

    let queries = await repository.searchQueries()
    #expect(queries.count == LibrarySection.allCases.count)
    #expect(queries[0].filters == [])
    #expect(queries[1].filters == [.favorite])
    #expect(queries[2].filters == [.pinned])
    #expect(queries[3].filters == [.contentType(.image)])
    #expect(queries[4].filters == [.contentType(.link)])
  }

  @Test("search combines section filters with parsed input")
  func searchCombines() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.select(section: .favorites)
    await model.search("hello app:Safari")

    let queries = await repository.searchQueries()
    #expect(queries.last?.text == [.term("hello")])
    #expect(queries.last?.filters == [.favorite, .application("Safari")])
  }

  @Test("empty search restores the section listing")
  func emptySearchRestores() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.select(section: .pinned)
    await model.search("   ")

    #expect(await repository.searchQueries().last?.filters == [.pinned])
  }

  @Test("invalid queries surface an error without storage calls")
  func invalidQueryErrors() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.search("app:")

    #expect(model.errorMessage == "Invalid search query")
    #expect(model.items.isEmpty)
  }

  @Test("favorite toggle flips state and persists")
  func togglesFavorite() async throws {
    let clip = summary(kind: .text, isFavorite: false)
    let repository = LibraryRepositorySpy(results: [clip])
    let model = LibraryModel(repository: repository)

    await model.refresh()
    await model.toggleFavorite(id: clip.id)

    let firstPass = await repository.favoriteMutations()
    #expect(firstPass.count == 1 && firstPass[0].0 == clip.id && firstPass[0].1 == true)
    #expect(model.items.first?.isFavorite == true)

    await model.toggleFavorite(id: clip.id)
    let secondPass = await repository.favoriteMutations()
    #expect(
      secondPass.count == 2 && secondPass[1].0 == clip.id && secondPass[1].1 == false)
    #expect(model.items.first?.isFavorite == false)
  }

  @Test("pin toggle and delete maintain selection")
  func pinsAndDeletes() async throws {
    let first = summary(kind: .text, isPinned: false)
    let second = summary(kind: .link, isPinned: false)
    let repository = LibraryRepositorySpy(results: [first, second])
    let model = LibraryModel(repository: repository)

    await model.refresh()
    model.select(id: first.id)
    await model.togglePin(id: first.id)
    let pins = await repository.pinMutations()
    #expect(pins.count == 1 && pins[0].0 == first.id && pins[0].1 == true)
    #expect(model.items.first?.isPinned == true)

    await model.delete(id: first.id)
    #expect(await repository.deletedIDs() == [first.id])
    #expect(model.items.map(\.id) == [second.id])
    #expect(model.selectedID == nil)
  }

  @Test("unknown favorite and pin identifiers are ignored")
  func ignoresUnknownIdentifiers() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.refresh()
    await model.toggleFavorite(id: UUID())
    await model.togglePin(id: UUID())

    #expect(await repository.favoriteMutations().isEmpty)
    #expect(await repository.pinMutations().isEmpty)
    #expect(model.errorMessage == nil)
  }

  private func summary(kind: ClipKind, isFavorite: Bool = false, isPinned: Bool = false)
    -> ClipSummary
  {
    ClipSummary(
      id: UUID(), kind: kind, text: "fixture", createdAt: .now,
      lastSeenAt: .now, copyCount: 1, isPinned: isPinned,
      isFavorite: isFavorite, source: nil
    )
  }
}

private actor LibraryRepositorySpy: ClipRepository {
  private let results: [ClipSummary]
  private var queries: [SearchQuery] = []
  private var pins: [(UUID, Bool)] = []
  private var favorites: [(UUID, Bool)] = []
  private var deleted: [UUID] = []

  init(results: [ClipSummary]) {
    self.results = results
  }

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    throw TestError.unexpectedCall
  }

  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary {
    throw TestError.unexpectedCall
  }

  func attachment(for id: UUID) async throws -> ClipAttachment? { nil }

  func attachmentData(for id: UUID) async throws -> Data? { nil }

  func count() async throws -> Int { results.count }

  func setPinned(id: UUID, isPinned: Bool) async throws {
    pins.append((id, isPinned))
  }

  func setFavorite(id: UUID, isFavorite: Bool) async throws {
    favorites.append((id, isFavorite))
  }

  func deleteExpired(before cutoff: Date) async throws -> Int { 0 }

  func purgeDeleted(before cutoff: Date) async throws -> Int { 0 }

  func recordUse(id: UUID, at date: Date) async throws {}

  func delete(id: UUID, at date: Date) async throws {
    deleted.append(id)
  }

  func recent(limit: Int) async throws -> [ClipSummary] {
    Array(results.prefix(limit))
  }

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    queries.append(query)
    return Array(results.prefix(limit))
  }

  func searchQueries() -> [SearchQuery] { queries }

  func pinMutations() -> [(UUID, Bool)] { pins }

  func favoriteMutations() -> [(UUID, Bool)] { favorites }

  func deletedIDs() -> [UUID] { deleted }
}

private enum TestError: Error {
  case unexpectedCall
}
