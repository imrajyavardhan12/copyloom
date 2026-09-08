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

  @Test("toggles the favorite on the selected clip")
  func togglesFavorite() async throws {
    let clip = fixture("star me")
    let repository = QuickPasteRepositorySpy(clips: [clip])
    let model = QuickPasteModel(repository: repository, delivery: QuickPasteDeliverySpy())

    await model.loadRecent()
    await model.toggleFavoriteSelected()

    #expect(await repository.favoriteMutation() == .init(id: clip.id, isFavorite: true))
    #expect(model.items.first?.isFavorite == true)

    await model.toggleFavoriteSelected()
    #expect(await repository.favoriteMutation() == .init(id: clip.id, isFavorite: false))
    #expect(model.items.first?.isFavorite == false)
  }

  @Test("loads thumbnails for image clips only")
  func loadsThumbnails() async throws {
    let png = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      )
    )
    let image = imageFixture(id: UUID())
    let text = fixture("plain words")
    let missing = imageFixture(id: UUID())
    let repository = QuickPasteRepositorySpy(
      clips: [image, text, missing], imageData: [image.id: png])
    let model = QuickPasteModel(repository: repository, delivery: QuickPasteDeliverySpy())

    #expect(await model.loadThumbnail(for: image) != nil)
    // Cached second load does not consult the repository again.
    #expect(await model.loadThumbnail(for: image) != nil)
    #expect(await model.loadThumbnail(for: text) == nil)
    #expect(await model.loadThumbnail(for: missing) == nil)
  }

  private func imageFixture(id: UUID) -> ClipSummary {
    ClipSummary(
      id: id,
      kind: .image,
      text: "",
      createdAt: .now,
      lastSeenAt: .now,
      copyCount: 1,
      isPinned: false,
      isFavorite: false,
      source: nil
    )
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

  struct Favorite: Equatable, Sendable {
    let id: UUID
    let isFavorite: Bool
  }

  private var clips: [ClipSummary]
  private let searchResults: [ClipSummary]
  private let imageData: [UUID: Data]
  private var searchQuery: SearchQuery?
  private var use: Use?
  private var pin: Pin?
  private var favorite: Favorite?
  private var deleted: UUID?

  init(
    clips: [ClipSummary],
    searchResults: [ClipSummary] = [],
    imageData: [UUID: Data] = [:]
  ) {
    self.clips = clips
    self.searchResults = searchResults
    self.imageData = imageData
  }

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    throw TestError.unexpectedCall
  }

  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary {
    throw TestError.unexpectedCall
  }

  func attachment(for id: UUID) async throws -> ClipAttachment? { nil }

  func attachmentData(for id: UUID) async throws -> Data? { imageData[id] }

  func count() async throws -> Int { clips.count }

  func setPinned(id: UUID, isPinned: Bool) async throws {
    pin = Pin(id: id, isPinned: isPinned)
  }

  func setFavorite(id: UUID, isFavorite: Bool) async throws {
    favorite = Favorite(id: id, isFavorite: isFavorite)
  }

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
  func favoriteMutation() -> Favorite? { favorite }
  func deletedID() -> UUID? { deleted }
}

private enum TestError: Error {
  case unexpectedCall
}
