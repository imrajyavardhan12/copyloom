import ClipDomain
import Foundation
import Testing

@testable import QuickPasteFeature

@MainActor
@Suite("Quick Paste model")
struct QuickPasteModelTests {
  @Test("loads recent clips and navigates selection with bounds")
  func loadsAndNavigates() async throws {
    let repository = QuickPasteRepositorySpy(
      clips: [fixture("first"), fixture("second"), fixture("third")]
    )
    let model = QuickPasteModel(repository: repository, delivery: QuickPasteDeliverySpy())

    await model.loadRecent()
    model.moveSelection(by: 1)
    model.moveSelection(by: 10)

    #expect(model.items.map(\.text) == ["first", "second", "third"])
    #expect(model.selectedIndex == 2)
    #expect(model.selectedClip?.text == "third")
  }

  @Test("parses and executes structured search")
  func searches() async throws {
    let result = fixture("Safari result")
    let repository = QuickPasteRepositorySpy(clips: [], searchResults: [result])
    let model = QuickPasteModel(repository: repository, delivery: QuickPasteDeliverySpy())

    await model.search("postgres app:Safari")
    let query = await repository.lastSearchQuery()

    #expect(model.items.map(\.id) == [result.id])
    #expect(query?.text == [.term("postgres")])
    #expect(query?.filters == [.application("Safari")])
  }

  @Test("copies the selected clip, records use, and dismisses")
  func activatesSelection() async throws {
    let clip = fixture("copy me")
    let repository = QuickPasteRepositorySpy(clips: [clip])
    let delivery = QuickPasteDeliverySpy()
    var dismissed = false
    let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let model = QuickPasteModel(
      repository: repository,
      delivery: delivery,
      now: { usedAt },
      onDismiss: { dismissed = true }
    )

    await model.loadRecent()
    await model.activateSelected()

    #expect(delivery.deliveredClip?.id == clip.id)
    #expect(delivery.mode == .primary)
    #expect(await repository.recordedUse() == .init(id: clip.id, date: usedAt))
    #expect(dismissed)
  }

  @Test("forwards an explicit copy-only delivery mode")
  func copiesWithoutPasting() async throws {
    let clip = fixture("copy only")
    let repository = QuickPasteRepositorySpy(clips: [clip])
    let delivery = QuickPasteDeliverySpy()
    let model = QuickPasteModel(repository: repository, delivery: delivery)

    await model.loadRecent()
    await model.activateSelected(mode: .copyOnly)

    #expect(delivery.deliveredClip?.id == clip.id)
    #expect(delivery.mode == .copyOnly)
  }

  @Test("pins and deletes the selected clip while maintaining selection")
  func pinsAndDeletes() async throws {
    let first = fixture("first")
    let second = fixture("second")
    let repository = QuickPasteRepositorySpy(clips: [first, second])
    let model = QuickPasteModel(repository: repository, delivery: QuickPasteDeliverySpy())

    await model.loadRecent()
    await model.togglePinSelected()
    await model.deleteSelected()

    #expect(await repository.pinnedMutation() == .init(id: first.id, isPinned: true))
    #expect(await repository.deletedID() == first.id)
    #expect(model.items.map(\.id) == [second.id])
    #expect(model.selectedIndex == 0)
  }

  private func fixture(_ text: String) -> ClipSummary {
    ClipSummary(
      id: UUID(),
      kind: text.contains("http") ? .link : .text,
      text: text,
      createdAt: .now,
      lastSeenAt: .now,
      copyCount: 1,
      isPinned: false,
      isFavorite: false,
      source: nil
    )
  }
}

@MainActor
private final class QuickPasteDeliverySpy: ClipDelivering {
  private(set) var deliveredClip: ClipSummary?
  private(set) var mode: ClipDeliveryMode?

  func deliver(_ clip: ClipSummary, mode: ClipDeliveryMode) async throws {
    deliveredClip = clip
    self.mode = mode
  }
}

private actor QuickPasteRepositorySpy: ClipRepository {
  struct Use: Equatable, Sendable {
    let id: UUID
    let date: Date
  }

  struct Pin: Equatable, Sendable {
    let id: UUID
    let isPinned: Bool
  }

  private var clips: [ClipSummary]
  private let searchResults: [ClipSummary]
  private var searchQuery: SearchQuery?
  private var use: Use?
  private var pin: Pin?
  private var deleted: UUID?

  init(clips: [ClipSummary], searchResults: [ClipSummary] = []) {
    self.clips = clips
    self.searchResults = searchResults
  }

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    throw TestError.unexpectedCall
  }

  func count() async throws -> Int { clips.count }

  func setPinned(id: UUID, isPinned: Bool) async throws {
    pin = Pin(id: id, isPinned: isPinned)
  }

  func setFavorite(id: UUID, isFavorite: Bool) async throws {}

  func deleteExpired(before cutoff: Date) async throws -> Int { 0 }

  func purgeDeleted(before cutoff: Date) async throws -> Int { 0 }

  func recordUse(id: UUID, at date: Date) async throws {
    use = Use(id: id, date: date)
  }

  func delete(id: UUID, at date: Date) async throws {
    deleted = id
    clips.removeAll { $0.id == id }
  }

  func recent(limit: Int) async throws -> [ClipSummary] {
    Array(clips.prefix(limit))
  }

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    searchQuery = query
    return Array(searchResults.prefix(limit))
  }

  func lastSearchQuery() -> SearchQuery? { searchQuery }
  func recordedUse() -> Use? { use }
  func pinnedMutation() -> Pin? { pin }
  func deletedID() -> UUID? { deleted }
}

private enum TestError: Error {
  case unexpectedCall
}
