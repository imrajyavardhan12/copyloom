import AppKit
import ClipDomain
import ClipSearch
import Foundation
import ImageIO
import Observation

/// Sidebar sections with real query backing. Files/Code/Colors are absent on
/// purpose: no detection backs them yet, and this model never shows a section
/// it cannot fill (slice 2).
public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
  case history
  case favorites
  case pinned
  case images
  case links
  case files
  case code
  case colors

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .history: "History"
    case .favorites: "Favorites"
    case .pinned: "Pinned"
    case .images: "Images"
    case .links: "Links"
    case .files: "Files"
    case .code: "Code"
    case .colors: "Colors"
    }
  }

  public var systemImage: String {
    switch self {
    case .history: "clock"
    case .favorites: "star"
    case .pinned: "pin"
    case .images: "photo"
    case .links: "link"
    case .files: "folder"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .colors: "swatchbook"
    }
  }

  var baseFilters: [SearchFilter] {
    switch self {
    case .history: []
    case .favorites: [.favorite]
    case .pinned: [.pinned]
    case .images: [.contentType(.image)]
    case .links: [.contentType(.link)]
    case .files: [.contentType(.file)]
    case .code: [.contentType(.code)]
    case .colors: [.contentType(.color)]
    }
  }
}

public enum LibraryDensity: String, CaseIterable, Sendable {
  case list
  case cards
}

/// What the content pane shows: a static section, a user collection, or a
/// re-parsed saved query. Smart queries execute as-is; section filters do
/// not combine into them.
public enum LibraryTarget: Hashable, Sendable {
  case section(LibrarySection)
  case collection(UUID)
  case smart(UUID)
}

@MainActor
@Observable
public final class LibraryModel {
  public private(set) var section: LibrarySection = .history
  public private(set) var density: LibraryDensity = .list
  public private(set) var items: [ClipSummary] = []
  public private(set) var selectedID: UUID?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public private(set) var collections: [ClipCollection] = []
  public private(set) var smartQueries: [SavedQuery] = []
  public private(set) var activeCollectionID: UUID?
  public private(set) var activeSmartQueryID: UUID?

  @ObservationIgnored private let repository: any ClipRepository
  @ObservationIgnored private let parser: SearchQueryParser
  @ObservationIgnored private let now: @MainActor @Sendable () -> Date
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private var requestGeneration = 0
  // Same lazy-thumbnail shape as Quick Paste's model; the two converge when
  // a shared integration module lands (see ADR-0005).
  @ObservationIgnored private let thumbnails = NSCache<NSUUID, NSImage>()

  public init(
    repository: any ClipRepository,
    parser: SearchQueryParser = SearchQueryParser(),
    now: @escaping @MainActor @Sendable () -> Date = { .now },
    calendar: Calendar = .current
  ) {
    self.repository = repository
    self.parser = parser
    self.now = now
    self.calendar = calendar
  }

  public var selectedClip: ClipSummary? {
    guard let selectedID else { return nil }
    return items.first(where: { $0.id == selectedID })
  }

  public func select(section: LibrarySection) async {
    self.section = section
    activeCollectionID = nil
    activeSmartQueryID = nil
    selectedID = nil
    await refresh()
  }

  public var title: String {
    if let activeCollectionID {
      return collections.first(where: { $0.id == activeCollectionID })?.name
        ?? "Collection"
    }
    if let activeSmartQueryID {
      return smartQueries.first(where: { $0.id == activeSmartQueryID })?.name
        ?? "Smart Collection"
    }
    return section.title
  }

  public func selectCollection(id: UUID) async {
    activeCollectionID = id
    activeSmartQueryID = nil
    selectedID = nil
    await runCollectionListing(id: id)
  }

  public func selectSmart(id: UUID) async {
    activeSmartQueryID = id
    activeCollectionID = nil
    selectedID = nil
    await runSmartListing(id: id)
  }

  public func refreshCollections() async {
    do {
      collections = try await repository.listCollections()
      smartQueries = try await repository.listQueries()
    } catch {
      errorMessage = "Unable to load collections"
    }
  }

  public func createCollection(name: String) async {
    do {
      let collection = try await repository.createCollection(
        name: name, at: now())
      await refreshCollections()
      await selectCollection(id: collection.id)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to create the collection"
    }
  }

  public func renameCollection(id: UUID, name: String) async {
    do {
      try await repository.renameCollection(id: id, name: name, at: now())
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to rename the collection"
    }
  }

  public func deleteCollection(id: UUID) async {
    do {
      try await repository.deleteCollection(id: id)
      if activeCollectionID == id {
        activeCollectionID = nil
        await refresh()
      }
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the collection"
    }
  }

  public func addToCollection(collectionID: UUID, clipID: UUID) async {
    do {
      try await repository.addToCollection(
        collectionID: collectionID, clipID: clipID, at: now())
      if activeCollectionID == collectionID {
        await runCollectionListing(id: collectionID)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to add to the collection"
    }
  }

  public func removeFromCollection(collectionID: UUID, clipID: UUID) async {
    do {
      try await repository.removeFromCollection(
        collectionID: collectionID, clipID: clipID)
      if activeCollectionID == collectionID {
        await runCollectionListing(id: collectionID)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to remove from the collection"
    }
  }

  public func saveSmartQuery(name: String, queryText: String) async {
    let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      // Validate with the real parser before persisting.
      _ = try parser.parse(
        trimmed, context: SearchParseContext(now: now(), calendar: calendar))
      let query = try await repository.saveQuery(
        name: name, queryText: trimmed, at: now())
      await refreshCollections()
      await selectSmart(id: query.id)
      errorMessage = nil
    } catch {
      errorMessage = "That query does not parse"
    }
  }

  public func renameSmartQuery(id: UUID, name: String) async {
    do {
      try await repository.renameQuery(id: id, name: name, at: now())
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to rename the Smart Collection"
    }
  }

  public func deleteSmartQuery(id: UUID) async {
    do {
      try await repository.deleteQuery(id: id)
      if activeSmartQueryID == id {
        activeSmartQueryID = nil
        await refresh()
      }
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the Smart Collection"
    }
  }

  public func setTags(id: UUID, names: [String]) async {
    do {
      let current = Set(try await repository.tags(for: id).map(\.normalized))
      let desired = Set(
        names.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
      for name in desired.subtracting(current) {
        try await repository.tagClip(id: id, tag: name)
      }
      for name in current.subtracting(desired) {
        try await repository.untagClip(id: id, tag: name)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update tags"
    }
  }

  public func tags(for id: UUID) async -> [ClipTag] {
    (try? await repository.tags(for: id)) ?? []
  }

  public func setDensity(_ density: LibraryDensity) {
    self.density = density
  }

  public func refresh() async {
    await runQuery(text: [], filters: section.baseFilters)
  }

  public func search(_ input: String) async {
    // Search always scopes to the static section library: typing while a
    // collection or Smart Collection is open returns to section scope
    // rather than silently intersecting two scopes.
    activeCollectionID = nil
    activeSmartQueryID = nil
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await refresh()
      return
    }
    do {
      let query = try parser.parse(
        input,
        context: SearchParseContext(now: now(), calendar: calendar)
      )
      await runQuery(
        text: query.text, filters: section.baseFilters + query.filters)
    } catch {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "Invalid search query"
    }
  }

  public func select(id: UUID?) {
    selectedID = id
  }

  public func toggleFavorite(id: UUID) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let newValue = !items[index].isFavorite
    do {
      try await repository.setFavorite(id: id, isFavorite: newValue)
      items[index] = items[index].withFavorite(newValue)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update the favorite"
    }
  }

  public func togglePin(id: UUID) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let newValue = !items[index].isPinned
    do {
      try await repository.setPinned(id: id, isPinned: newValue)
      items[index] = items[index].withPinned(newValue)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update the pin"
    }
  }

  public func delete(id: UUID) async {
    do {
      try await repository.delete(id: id, at: now())
      items.removeAll(where: { $0.id == id })
      if selectedID == id { selectedID = nil }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the clip"
    }
  }

  public func imageData(for id: UUID) async -> Data? {
    try? await repository.attachmentData(for: id)
  }

  public func attachmentMeta(for id: UUID) async throws -> ClipAttachment? {
    try await repository.attachment(for: id)
  }

  public func loadThumbnail(for clip: ClipSummary) async -> NSImage? {
    guard clip.kind == .image else { return nil }
    let key = clip.id as NSUUID
    if let cached = thumbnails.object(forKey: key) { return cached }
    guard let data = try? await repository.attachmentData(for: clip.id),
      let thumbnail = Self.makeThumbnail(from: data)
    else {
      return nil
    }
    thumbnails.setObject(thumbnail, forKey: key)
    return thumbnail
  }

  private static func makeThumbnail(from data: Data) -> NSImage? {
    let options: CFDictionary =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 256,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    else {
      return nil
    }
    return NSImage(cgImage: thumbnail, size: .zero)
  }

  private func runCollectionListing(id: UUID) async {
    await replaceItems {
      try await repository.collectionClips(collectionID: id, limit: 200)
    }
  }

  private func runSmartListing(id: UUID) async {
    guard let saved = smartQueries.first(where: { $0.id == id }) else {
      activeSmartQueryID = nil
      await refresh()
      return
    }
    guard saved.queryVersion == SavedQuery.currentVersion else {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "This saved query needs an update"
      return
    }
    do {
      let query = try parser.parse(
        saved.queryText,
        context: SearchParseContext(now: now(), calendar: calendar)
      )
      await runQuery(text: query.text, filters: query.filters)
    } catch {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "This saved query no longer parses"
    }
  }

  private func runQuery(text: [SearchTextClause], filters: [SearchFilter]) async {
    await replaceItems {
      try await repository.search(
        SearchQuery(text: text, filters: filters), limit: 200)
    }
  }

  private func replaceItems(
    _ operation: () async throws -> [ClipSummary]
  ) async {
    requestGeneration &+= 1
    let generation = requestGeneration
    isLoading = true
    errorMessage = nil
    do {
      let newItems = try await operation()
      guard generation == requestGeneration else { return }
      items = newItems
      if let selectedID, !newItems.contains(where: { $0.id == selectedID }) {
        self.selectedID = nil
      }
    } catch {
      guard generation == requestGeneration else { return }
      items = []
      selectedID = nil
      errorMessage = "Unable to load local history"
    }
    guard generation == requestGeneration else { return }
    isLoading = false
  }
}

extension ClipSummary {
  fileprivate func withPinned(_ isPinned: Bool) -> ClipSummary {
    ClipSummary(
      id: id, kind: kind, text: text, createdAt: createdAt,
      lastSeenAt: lastSeenAt, copyCount: copyCount, useCount: useCount,
      lastUsedAt: lastUsedAt, isPinned: isPinned, isFavorite: isFavorite,
      source: source
    )
  }

  fileprivate func withFavorite(_ isFavorite: Bool) -> ClipSummary {
    ClipSummary(
      id: id, kind: kind, text: text, createdAt: createdAt,
      lastSeenAt: lastSeenAt, copyCount: copyCount, useCount: useCount,
      lastUsedAt: lastUsedAt, isPinned: isPinned, isFavorite: isFavorite,
      source: source
    )
  }
}
