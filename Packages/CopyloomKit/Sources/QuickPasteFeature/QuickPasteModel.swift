import ClipDomain
import ClipSearch
import Foundation
import Observation

@MainActor
public protocol ClipCopying: AnyObject {
  func copy(_ clip: ClipSummary) throws
}

@MainActor
@Observable
public final class QuickPasteModel {
  public private(set) var items: [ClipSummary] = []
  public private(set) var selectedIndex = 0
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  @ObservationIgnored private let repository: any ClipRepository
  @ObservationIgnored private let copier: any ClipCopying
  @ObservationIgnored private let parser: SearchQueryParser
  @ObservationIgnored private let now: @MainActor @Sendable () -> Date
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let onDismiss: @MainActor () -> Void
  @ObservationIgnored private var requestGeneration = 0

  public init(
    repository: any ClipRepository,
    copier: any ClipCopying,
    parser: SearchQueryParser = SearchQueryParser(),
    now: @escaping @MainActor @Sendable () -> Date = { .now },
    calendar: Calendar = .current,
    onDismiss: @escaping @MainActor () -> Void = {}
  ) {
    self.repository = repository
    self.copier = copier
    self.parser = parser
    self.now = now
    self.calendar = calendar
    self.onDismiss = onDismiss
  }

  public var selectedClip: ClipSummary? {
    guard items.indices.contains(selectedIndex) else { return nil }
    return items[selectedIndex]
  }

  public func loadRecent() async {
    await replaceItems {
      try await repository.recent(limit: 100)
    }
  }

  public func search(_ input: String) async {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await loadRecent()
      return
    }

    do {
      let query = try parser.parse(
        input,
        context: SearchParseContext(now: now(), calendar: calendar)
      )
      await replaceItems {
        try await repository.search(query, limit: 100)
      }
    } catch {
      requestGeneration &+= 1
      items = []
      selectedIndex = 0
      isLoading = false
      errorMessage = "Invalid search query"
    }
  }

  public func moveSelection(by offset: Int) {
    guard !items.isEmpty else {
      selectedIndex = 0
      return
    }
    selectedIndex = min(max(selectedIndex + offset, 0), items.count - 1)
  }

  public func select(index: Int) {
    guard items.indices.contains(index) else { return }
    selectedIndex = index
  }

  public func activateSelected() async {
    guard let selectedClip else { return }
    do {
      try copier.copy(selectedClip)
    } catch {
      errorMessage = "Unable to write to the clipboard"
      return
    }

    do {
      try await repository.recordUse(id: selectedClip.id, at: now())
    } catch {
      errorMessage = "Copied, but usage metadata could not be updated"
    }
    onDismiss()
  }

  public func togglePinSelected() async {
    guard let selectedClip else { return }
    let newValue = !selectedClip.isPinned
    do {
      try await repository.setPinned(id: selectedClip.id, isPinned: newValue)
      guard let currentIndex = items.firstIndex(where: { $0.id == selectedClip.id }) else {
        return
      }
      items[currentIndex] = selectedClip.withPinned(newValue)
      selectedIndex = currentIndex
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update the pin"
    }
  }

  public func deleteSelected() async {
    guard let selectedClip else { return }
    do {
      try await repository.delete(id: selectedClip.id, at: now())
      guard let currentIndex = items.firstIndex(where: { $0.id == selectedClip.id }) else {
        return
      }
      items.remove(at: currentIndex)
      selectedIndex = min(currentIndex, max(items.count - 1, 0))
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the clip"
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
      selectedIndex = 0
    } catch {
      guard generation == requestGeneration else { return }
      items = []
      selectedIndex = 0
      errorMessage = "Unable to load local history"
    }
    guard generation == requestGeneration else { return }
    isLoading = false
  }
}

extension ClipSummary {
  fileprivate func withPinned(_ isPinned: Bool) -> ClipSummary {
    ClipSummary(
      id: id,
      kind: kind,
      text: text,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt,
      copyCount: copyCount,
      useCount: useCount,
      lastUsedAt: lastUsedAt,
      isPinned: isPinned,
      isFavorite: isFavorite,
      source: source
    )
  }
}
