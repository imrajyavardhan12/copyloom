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
    #expect(queries[5].filters == [.contentType(.file)])
    #expect(queries[6].filters == [.contentType(.code)])
    #expect(queries[7].filters == [.contentType(.color)])
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

  @Test("collections create, fill, rename and delete")
  func collectionsFlow() async throws {
    let clip = summary(kind: .text)
    let repository = LibraryRepositorySpy(results: [clip])
    let model = LibraryModel(repository: repository)

    await model.refreshCollections()
    #expect(model.collections.isEmpty)

    await model.createCollection(name: "  Work  ")
    #expect(model.collections.map(\.name) == ["Work"])
    let collectionID = try #require(model.collections.first?.id)
    #expect(model.activeCollectionID == collectionID)
    #expect(model.title == "Work")

    await model.addToCollection(collectionID: collectionID, clipID: clip.id)
    let reads = await repository.collectionReadsMade()
    #expect(reads.last == collectionID)
    #expect(model.items.map(\.id) == [clip.id])

    await model.removeFromCollection(collectionID: collectionID, clipID: clip.id)
    #expect(model.items.isEmpty)

    await model.renameCollection(id: collectionID, name: "Play")
    #expect(model.collections.map(\.name) == ["Play"])
    #expect(model.title == "Play")

    await model.deleteCollection(id: collectionID)
    #expect(model.collections.isEmpty)
    #expect(model.activeCollectionID == nil)
  }

  @Test("smart queries validate, execute and report stale versions")
  func smartFlow() async throws {
    let clip = summary(kind: .text)
    let repository = LibraryRepositorySpy(results: [clip])
    let model = LibraryModel(repository: repository)

    await model.saveSmartQuery(name: "Safari", queryText: "hello app:Safari")
    let savedID = try #require(model.smartQueries.first?.id)
    #expect(model.activeSmartQueryID == savedID)
    #expect(model.title == "Safari")
    let queries = await repository.searchQueries()
    #expect(queries.last?.text == [.term("hello")])
    #expect(queries.last?.filters == [.application("Safari")])

    await model.saveSmartQuery(name: "Broken", queryText: "app:")
    #expect(model.errorMessage == "That query does not parse")
    #expect(model.smartQueries.count == 1)

    await model.renameSmartQuery(id: savedID, name: "Web")
    #expect(model.smartQueries.map(\.name) == ["Web"])

    await model.deleteSmartQuery(id: savedID)
    #expect(model.smartQueries.isEmpty)
    #expect(model.activeSmartQueryID == nil)
  }

  @Test("stale saved-query versions refuse with guidance")
  func staleSmartVersion() async throws {
    let stale = SavedQuery(
      id: UUID(), name: "Old", queryVersion: 99, queryText: "hello",
      createdAt: .now, updatedAt: .now
    )
    let repository = LibraryRepositorySpy(results: [], presetQueries: [stale])
    let model = LibraryModel(repository: repository)

    await model.refreshCollections()
    await model.selectSmart(id: stale.id)

    #expect(model.items.isEmpty)
    #expect(model.errorMessage == "This saved query needs an update")
  }

  @Test("unknown smart identifiers fall back to the section")
  func unknownSmartFallsBack() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.selectSmart(id: UUID())

    #expect(model.activeSmartQueryID == nil)
    #expect(await repository.searchQueries().last?.filters == [])
  }

  @Test("tag edits diff against current tags")
  func tagDiffing() async throws {
    let clip = summary(kind: .text)
    let repository = LibraryRepositorySpy(results: [clip])
    let model = LibraryModel(repository: repository)
    await repository.seedTags(id: clip.id, names: ["a", "b"])

    await model.setTags(id: clip.id, names: ["B", " c ", ""])

    let calls = await repository.tagCalls()
    #expect(calls.tagged.map(\.1) == ["c"])
    #expect(calls.untagged.map(\.1) == ["a"])
    #expect(await model.tags(for: clip.id).map(\.normalized).sorted() == ["b", "c"])
  }

  @Test("searching returns to section scope from collections")
  func searchClearsActives() async throws {
    let repository = LibraryRepositorySpy(results: [])
    let model = LibraryModel(repository: repository)

    await model.createCollection(name: "Work")
    let collectionID = try #require(model.activeCollectionID)
    _ = collectionID
    await model.search("hello")

    #expect(model.activeCollectionID == nil)
    #expect(model.activeSmartQueryID == nil)
    #expect(await repository.searchQueries().last?.text == [.term("hello")])
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
  private var collections: [ClipCollection]
  private var members: [UUID: Set<UUID>] = [:]
  private var tagMap: [UUID: Set<String>] = [:]
  private var saved: [SavedQuery]
  private var tagged: [(UUID, String)] = []
  private var untagged: [(UUID, String)] = []
  private var collectionReads: [UUID] = []

  init(results: [ClipSummary], presetQueries: [SavedQuery] = []) {
    self.results = results
    self.collections = []
    self.saved = presetQueries
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

  func createCollection(name: String, at date: Date) async throws -> ClipCollection {
    // Mirrors the repository contract: surrounding whitespace is trimmed.
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let collection = ClipCollection(
      id: UUID(), name: trimmed, createdAt: date, updatedAt: date)
    collections.append(collection)
    return collection
  }

  func renameCollection(id: UUID, name: String, at date: Date) async throws {
    guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
    collections[index] = ClipCollection(
      id: id, name: name, createdAt: collections[index].createdAt, updatedAt: date)
  }

  func deleteCollection(id: UUID) async throws {
    collections.removeAll(where: { $0.id == id })
    members[id] = nil
  }

  func listCollections() async throws -> [ClipCollection] { collections }

  func addToCollection(collectionID: UUID, clipID: UUID, at date: Date) async throws {
    members[collectionID, default: []].insert(clipID)
  }

  func removeFromCollection(collectionID: UUID, clipID: UUID) async throws {
    members[collectionID]?.remove(clipID)
  }

  func collectionClips(collectionID: UUID, limit: Int) async throws -> [ClipSummary] {
    collectionReads.append(collectionID)
    let allowed = members[collectionID] ?? []
    return results.filter { allowed.contains($0.id) }.prefix(limit).map { $0 }
  }

  func collectionReadsMade() -> [UUID] { collectionReads }

  func getOrCreateTag(name: String) async throws -> ClipTag {
    ClipTag(id: UUID(), name: name)
  }

  func tagClip(id: UUID, tag: String) async throws {
    tagged.append((id, tag))
    tagMap[id, default: []].insert(tag)
  }

  func untagClip(id: UUID, tag: String) async throws {
    untagged.append((id, tag))
    tagMap[id]?.remove(tag)
  }

  func tags(for id: UUID) async throws -> [ClipTag] {
    (tagMap[id] ?? []).sorted().map { ClipTag(id: UUID(), name: $0) }
  }

  func tagCalls() -> (tagged: [(UUID, String)], untagged: [(UUID, String)]) {
    (tagged, untagged)
  }

  func seedTags(id: UUID, names: Set<String>) {
    tagMap[id] = names
  }

  func deleteTag(id: UUID) async throws {}

  func saveQuery(name: String, queryText: String, at date: Date) async throws -> SavedQuery {
    let query = SavedQuery(
      id: UUID(), name: name, queryText: queryText, createdAt: date, updatedAt: date)
    saved.append(query)
    return query
  }

  func renameQuery(id: UUID, name: String, at date: Date) async throws {
    guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
    saved[index] = SavedQuery(
      id: id, name: name, queryVersion: saved[index].queryVersion,
      queryText: saved[index].queryText, createdAt: saved[index].createdAt,
      updatedAt: date)
  }

  func deleteQuery(id: UUID) async throws {
    saved.removeAll(where: { $0.id == id })
  }

  func listQueries() async throws -> [SavedQuery] { saved }
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
