import ClipDomain
import Foundation
import Testing

@testable import QuickPasteFeature

@Suite("Paste Queue value")
struct PasteQueueValueTests {
  @Test("adds in order, allows duplicates, advances and clears")
  func basics() {
    let a = UUID()
    let b = UUID()
    var queue = PasteQueue()
    #expect(queue.isEmpty)
    #expect(queue.next == nil)

    queue.add(a)
    queue.add(b)
    queue.add(a)
    #expect(queue.remaining == [a, b, a])
    #expect(queue.next == a)

    queue.advance()
    #expect(queue.remaining == [b, a])

    queue.clear()
    #expect(queue.isEmpty)
    queue.advance()
    #expect(queue.isEmpty)
  }
}

@MainActor
@Suite("Paste Queue model")
struct PasteQueueModelTests {
  @Test("pastes the head, records use, advances, and reports what is left")
  func pastesInOrder() async {
    let first = fixture("first")
    let second = fixture("second")
    let repository = QuickPasteRepositorySpy(clips: [first, second])
    let delivery = QueueDeliverySpy(result: .pasted)
    let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let model = PasteQueueModel(repository: repository, delivery: delivery, now: { usedAt })
    model.add(first.id)
    model.add(second.id)

    #expect(await model.pasteNext() == .delivered(.pasted, kind: .text, remaining: 1, skipped: 0))
    #expect(await model.pasteNext() == .delivered(.pasted, kind: .text, remaining: 0, skipped: 0))
    #expect(await model.pasteNext() == .empty)

    #expect(delivery.delivered.map(\.id) == [first.id, second.id])
    #expect(
      await repository.recordedUses() == [
        .init(id: first.id, date: usedAt), .init(id: second.id, date: usedAt),
      ])
  }

  @Test("a copy-only delivery still advances, so the next press offers the next item")
  func copyOnlyAdvances() async {
    let first = fixture("first")
    let second = fixture("second")
    let delivery = QueueDeliverySpy(result: .copied)
    let model = PasteQueueModel(
      repository: QuickPasteRepositorySpy(clips: [first, second]), delivery: delivery)
    model.add(first.id)
    model.add(second.id)

    #expect(
      await model.pasteNext()
        == .delivered(.copied, kind: .text, remaining: 1, skipped: 0))
    #expect(model.queue.next == second.id)
  }

  @Test("a clip deleted after it was queued is skipped and never delivered")
  func skipsDeletedClips() async throws {
    let gone = fixture("deleted after queueing")
    let kept = fixture("still here")
    let repository = QuickPasteRepositorySpy(clips: [gone, kept])
    let delivery = QueueDeliverySpy(result: .pasted)
    let model = PasteQueueModel(repository: repository, delivery: delivery)
    model.add(gone.id)
    model.add(kept.id)
    try await repository.delete(id: gone.id, at: .now)

    #expect(await model.pasteNext() == .delivered(.pasted, kind: .text, remaining: 0, skipped: 1))
    #expect(delivery.delivered.map(\.id) == [kept.id])
  }

  @Test("a queue whose clips were all deleted ends empty without delivering")
  func exhaustsDeletedClips() async throws {
    let gone = fixture("gone")
    let repository = QuickPasteRepositorySpy(clips: [gone])
    let delivery = QueueDeliverySpy(result: .pasted)
    let model = PasteQueueModel(repository: repository, delivery: delivery)
    model.add(gone.id)
    model.add(gone.id)
    try await repository.delete(id: gone.id, at: .now)

    #expect(await model.pasteNext() == .exhausted(skipped: 2))
    #expect(model.queue.isEmpty)
    #expect(delivery.delivered.isEmpty)
  }

  @Test("an undeliverable clip (image file gone) is skipped instead of blocking the queue")
  func skipsUnavailable() async {
    let broken = fixture("image whose file is gone")
    let next = fixture("next")
    let delivery = QueueDeliverySpy(result: .pasted, unavailable: [broken.id])
    let model = PasteQueueModel(
      repository: QuickPasteRepositorySpy(clips: [broken, next]), delivery: delivery)
    model.add(broken.id)
    model.add(next.id)

    #expect(await model.pasteNext() == .delivered(.pasted, kind: .text, remaining: 0, skipped: 1))
    #expect(delivery.delivered.map(\.id) == [next.id])
  }

  @Test(
    "a refused delivery (keys held, Copyloom frontmost) keeps the item and records no use",
    arguments: [PasteQueueRefusal.keysHeld, .copyloomFrontmost])
  func refusalKeepsItem(reason: PasteQueueRefusal) async {
    let clip = fixture("not yet")
    let repository = QuickPasteRepositorySpy(clips: [clip])
    let model = PasteQueueModel(
      repository: repository, delivery: QueueDeliverySpy(result: .refused(reason)))
    model.add(clip.id)

    #expect(await model.pasteNext() == .refused(reason, remaining: 1, skipped: 0))
    #expect(await model.pasteNext() == .refused(reason, remaining: 1, skipped: 0))
    #expect(model.queue.next == clip.id)
    #expect(await repository.recordedUses().isEmpty)
  }

  @Test("a failed delivery keeps the item at the head for a retry")
  func failureKeepsItem() async {
    let clip = fixture("retry me")
    let delivery = QueueDeliverySpy(result: .pasted, fails: true)
    let model = PasteQueueModel(
      repository: QuickPasteRepositorySpy(clips: [clip]), delivery: delivery)
    model.add(clip.id)

    #expect(await model.pasteNext() == .failed(remaining: 1, skipped: 0))
    #expect(model.queue.next == clip.id)

    delivery.fails = false
    #expect(await model.pasteNext() == .delivered(.pasted, kind: .text, remaining: 0, skipped: 0))
  }

  @Test("an unwired repository lookup fails closed: nothing is delivered")
  func unknownLookupDeliversNothing() async {
    let delivery = QueueDeliverySpy(result: .pasted)
    let model = PasteQueueModel(repository: LookuplessRepository(), delivery: delivery)
    model.add(UUID())

    #expect(await model.pasteNext() == .exhausted(skipped: 1))
    #expect(delivery.delivered.isEmpty)
  }

  @Test("a second press while a paste is running is ignored")
  func ignoresReentrantPress() async {
    let first = fixture("first")
    let second = fixture("second")
    let delivery = QueueDeliverySpy(result: .pasted, suspends: true)
    let model = PasteQueueModel(
      repository: QuickPasteRepositorySpy(clips: [first, second]), delivery: delivery)
    model.add(first.id)
    model.add(second.id)

    let running = Task { await model.pasteNext() }
    await delivery.waitUntilSuspended()
    #expect(await model.pasteNext() == .busy)
    delivery.resume()
    #expect(await running.value == .delivered(.pasted, kind: .text, remaining: 1, skipped: 0))
    #expect(delivery.delivered.map(\.id) == [first.id])
  }

  @Test("clearing during a paste does not drop an item queued after the clear")
  func clearDuringPasteKeepsNewItems() async {
    let first = fixture("first")
    let fresh = fixture("queued after clear")
    let delivery = QueueDeliverySpy(result: .pasted, suspends: true)
    let model = PasteQueueModel(
      repository: QuickPasteRepositorySpy(clips: [first, fresh]), delivery: delivery)
    model.add(first.id)

    let running = Task { await model.pasteNext() }
    await delivery.waitUntilSuspended()
    model.clear()
    model.add(fresh.id)
    delivery.resume()

    // The in-flight clip was still delivered; only the queue was replaced.
    #expect(await running.value == .delivered(.pasted, kind: .text, remaining: 1, skipped: 0))
    #expect(model.queue.remaining == [fresh.id])
  }

  @Test("Quick Paste adds the selected clip to the queue without dismissing")
  func quickPasteAddsSelection() async {
    let clip = fixture("queue me")
    let repository = QuickPasteRepositorySpy(clips: [clip])
    let queue = PasteQueueModel(repository: repository, delivery: QueueDeliverySpy(result: .pasted))
    var dismissed = false
    let quickPaste = QuickPasteModel(
      repository: repository, delivery: NoDelivery(), pasteQueue: queue,
      onDismiss: { dismissed = true })

    await quickPaste.loadRecent()
    quickPaste.addSelectedToQueue()
    quickPaste.addSelectedToQueue()

    #expect(queue.queue.remaining == [clip.id, clip.id])
    #expect(!dismissed)
  }

  private func fixture(_ text: String) -> ClipSummary {
    ClipSummary(
      id: UUID(), kind: .text, text: text, createdAt: .now, lastSeenAt: .now, copyCount: 1,
      isPinned: false, isFavorite: false, source: nil)
  }
}

@MainActor
private final class QueueDeliverySpy: PasteQueueDelivering {
  struct Failure: Error {}

  private(set) var delivered: [ClipSummary] = []
  let result: PasteQueueDeliveryResult
  var fails: Bool
  private let suspends: Bool
  private let unavailable: Set<UUID>
  private var continuation: CheckedContinuation<Void, Never>?
  private var suspendedWaiter: CheckedContinuation<Void, Never>?

  init(
    result: PasteQueueDeliveryResult, fails: Bool = false, suspends: Bool = false,
    unavailable: Set<UUID> = []
  ) {
    self.result = result
    self.fails = fails
    self.suspends = suspends
    self.unavailable = unavailable
  }

  func deliverQueued(_ clip: ClipSummary) async throws -> PasteQueueDeliveryResult {
    if fails { throw Failure() }
    if unavailable.contains(clip.id) { return .unavailable }
    if suspends {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        suspendedWaiter?.resume()
        suspendedWaiter = nil
      }
    }
    delivered.append(clip)
    return result
  }

  func waitUntilSuspended() async {
    guard continuation == nil else { return }
    await withCheckedContinuation { suspendedWaiter = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class NoDelivery: ClipDelivering {
  func deliver(_ clip: ClipSummary, mode: ClipDeliveryMode) async throws {}
}

/// Implements nothing beyond the protocol's defaults for `clip(id:)`, which
/// must fail closed.
private actor LookuplessRepository: ClipRepository {
  struct Unused: Error {}

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary { throw Unused() }
  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary { throw Unused() }
  func attachment(for id: UUID) async throws -> ClipAttachment? { nil }
  func attachmentData(for id: UUID) async throws -> Data? { nil }
  func createCollection(name: String, at date: Date) async throws -> ClipCollection {
    throw Unused()
  }
  func renameCollection(id: UUID, name: String, at date: Date) async throws {}
  func deleteCollection(id: UUID) async throws {}
  func listCollections() async throws -> [ClipCollection] { [] }
  func addToCollection(collectionID: UUID, clipID: UUID, at date: Date) async throws {}
  func removeFromCollection(collectionID: UUID, clipID: UUID) async throws {}
  func collectionClips(collectionID: UUID, limit: Int) async throws -> [ClipSummary] { [] }
  func getOrCreateTag(name: String) async throws -> ClipTag { throw Unused() }
  func tagClip(id: UUID, tag: String) async throws {}
  func untagClip(id: UUID, tag: String) async throws {}
  func tags(for id: UUID) async throws -> [ClipTag] { [] }
  func deleteTag(id: UUID) async throws {}
  func saveQuery(name: String, queryText: String, at date: Date) async throws -> SavedQuery {
    throw Unused()
  }
  func renameQuery(id: UUID, name: String, at date: Date) async throws {}
  func deleteQuery(id: UUID) async throws {}
  func listQueries() async throws -> [SavedQuery] { [] }
  func count() async throws -> Int { 0 }
  func setPinned(id: UUID, isPinned: Bool) async throws {}
  func setFavorite(id: UUID, isFavorite: Bool) async throws {}
  func recordUse(id: UUID, at date: Date) async throws {}
  func delete(id: UUID, at date: Date) async throws {}
  func deleteExpired(before cutoff: Date) async throws -> Int { 0 }
  func purgeDeleted(before cutoff: Date) async throws -> Int { 0 }
  func recent(limit: Int) async throws -> [ClipSummary] { [] }
  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] { [] }
}
