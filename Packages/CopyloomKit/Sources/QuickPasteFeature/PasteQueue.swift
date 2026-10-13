import ClipDomain
import Foundation
import Observation

/// The ordered clips still to paste, by ID only (ADR 0007 §1). Content is
/// never held here: each ID is re-read at paste time, so a queued clip that
/// was deleted or expired since can never be delivered.
public struct PasteQueue: Equatable, Sendable {
  public private(set) var remaining: [UUID] = []

  public init() {}

  public var isEmpty: Bool { remaining.isEmpty }
  public var count: Int { remaining.count }
  public var next: UUID? { remaining.first }

  /// Appends; the same clip may be queued more than once.
  public mutating func add(_ id: UUID) {
    remaining.append(id)
  }

  /// Drops the item at the head, whether it was pasted or skipped.
  public mutating func advance() {
    guard !remaining.isEmpty else { return }
    remaining.removeFirst()
  }

  public mutating func clear() {
    remaining.removeAll()
  }
}

public enum PasteQueueDeliveryResult: Equatable, Sendable {
  /// Written to the pasteboard and ⌘V was posted to the frontmost app.
  case pasted
  /// Written to the pasteboard only (no Accessibility permission); the
  /// user's own ⌘V pastes it, so the queue still advances.
  case copied
  /// The clip exists but cannot be delivered and never will be (its image
  /// file is gone). Skipped like a deleted clip, so it cannot block the queue.
  case unavailable
  /// Nothing was written; the item stays next in the queue.
  case refused(PasteQueueRefusal)
}

public enum PasteQueueRefusal: Equatable, Sendable {
  /// The shortcut's keys were still held after the release timeout. Without
  /// this, a held (auto-repeating) shortcut would use up several items.
  case keysHeld
  /// Copyloom itself is frontmost: there is no target app, and advancing
  /// would lose the item.
  case copyloomFrontmost
}

/// Delivers one queued clip into whatever app is frontmost now. Unlike Quick
/// Paste it never re-activates a remembered app: the user is already there.
@MainActor
public protocol PasteQueueDelivering: AnyObject {
  func deliverQueued(_ clip: ClipSummary) async throws -> PasteQueueDeliveryResult
}

public enum PasteNextOutcome: Equatable, Sendable {
  case empty
  /// A paste is already running; this press was ignored.
  case busy
  case delivered(PasteQueueDeliveryResult, kind: ClipKind, remaining: Int, skipped: Int)
  /// Every remaining item had been deleted or expired.
  case exhausted(skipped: Int)
  /// Delivery declined before writing anything; the item stays next.
  case refused(PasteQueueRefusal, remaining: Int, skipped: Int)
  /// Delivery failed; the item stays at the head so the next press retries.
  case failed(remaining: Int, skipped: Int)
}

/// Session-only Paste Queue (ADR 0007): add, paste next, clear. Nothing is
/// persisted; quitting the app ends the queue.
@MainActor
@Observable
public final class PasteQueueModel {
  public private(set) var queue = PasteQueue()
  public private(set) var isPasting = false

  @ObservationIgnored private let repository: any ClipRepository
  @ObservationIgnored private let delivery: any PasteQueueDelivering
  @ObservationIgnored private let now: @MainActor @Sendable () -> Date
  /// Bumped by `clear`, so a paste that was in flight when the user cleared
  /// (and maybe queued new items) never drops one of the new items.
  @ObservationIgnored private var generation = 0

  public init(
    repository: any ClipRepository,
    delivery: any PasteQueueDelivering,
    now: @escaping @MainActor @Sendable () -> Date = { .now }
  ) {
    self.repository = repository
    self.delivery = delivery
    self.now = now
  }

  public var count: Int { queue.count }

  public func add(_ id: UUID) {
    queue.add(id)
  }

  public func clear() {
    queue.clear()
    generation &+= 1
  }

  /// Pastes the head of the queue. Deleted, expired and undeliverable clips
  /// are dropped (counted in `skipped`) until a live one is found; a failed
  /// delivery keeps the item for the next press.
  public func pasteNext() async -> PasteNextOutcome {
    guard !isPasting else { return .busy }
    guard !queue.isEmpty else { return .empty }
    isPasting = true
    defer { isPasting = false }

    var skipped = 0
    let startGeneration = generation
    while let id = queue.next {
      let clip: ClipSummary?
      do {
        clip = try await repository.clip(id: id)
      } catch {
        return .failed(remaining: queue.count, skipped: skipped)
      }
      guard generation == startGeneration else { return .empty }
      guard let clip else {
        queue.advance()
        skipped += 1
        continue
      }
      let result: PasteQueueDeliveryResult
      do {
        result = try await delivery.deliverQueued(clip)
      } catch {
        return .failed(remaining: queue.count, skipped: skipped)
      }
      // Cleared while delivering: the clip was still delivered, but the
      // queue now holds other items, so it is not advanced.
      let wasCleared = generation != startGeneration
      if result == .unavailable {
        guard !wasCleared else { return .empty }
        queue.advance()
        skipped += 1
        continue
      }
      if case .refused(let reason) = result {
        return .refused(reason, remaining: queue.count, skipped: skipped)
      }
      // A copy counts as delivered: without Accessibility the user's own ⌘V
      // pastes it, so the next press must offer the next item.
      if !wasCleared { queue.advance() }
      try? await repository.recordUse(id: clip.id, at: now())
      return .delivered(result, kind: clip.kind, remaining: queue.count, skipped: skipped)
    }
    return .exhausted(skipped: skipped)
  }
}
