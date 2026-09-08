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

@MainActor
@Observable
public final class LibraryModel {
  public private(set) var section: LibrarySection = .history
  public private(set) var density: LibraryDensity = .list
  public private(set) var items: [ClipSummary] = []
  public private(set) var selectedID: UUID?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

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
    selectedID = nil
    await refresh()
  }

  public func setDensity(_ density: LibraryDensity) {
    self.density = density
  }

  public func refresh() async {
    await runQuery(text: [], filters: section.baseFilters)
  }

  public func search(_ input: String) async {
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

  private func runQuery(text: [SearchTextClause], filters: [SearchFilter]) async {
    requestGeneration &+= 1
    let generation = requestGeneration
    isLoading = true
    errorMessage = nil
    do {
      let newItems = try await repository.search(
        SearchQuery(text: text, filters: filters), limit: 200)
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
