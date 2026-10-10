import ClipDomain
import Foundation
import Testing

@testable import LibraryFeature

private let summary = LibraryExportSummary(
  clips: 12, attachments: 3, skippedSensitive: 2, skippedQuarantinedImages: 1,
  skippedMissingAttachments: 0)

actor Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
@Suite("Library export")
struct LibraryExportTests {
  private let destination = URL(fileURLWithPath: "/tmp/Copyloom Export")

  private func model(
    _ exporter: (@Sendable (URL) async throws -> LibraryExportSummary)?
  ) -> LibraryModel {
    LibraryModel(repository: ExportRepositoryStub(), libraryExporter: exporter)
  }

  @Test("a successful export reports its summary and the destination name")
  func success() async {
    let model = model { _ in summary }

    await model.exportLibrary(to: destination)

    #expect(model.exportState == .finished(summary, name: "Copyloom Export"))
  }

  @Test("the exporter receives the chosen destination")
  func destinationPassed() async {
    let received = Box<URL?>(nil)
    let model = model { url in
      received.value = url
      return summary
    }

    await model.exportLibrary(to: destination)

    #expect(received.value == destination)
  }

  @Test("a model with no exporter refuses (fail closed)")
  func unwired() async {
    let model = model(nil)

    await model.exportLibrary(to: destination)

    #expect(model.exportState == .failed("Export is unavailable"))
  }

  @Test("an existing destination gets a specific message")
  func destinationExists() async {
    let model = model { _ in throw LibraryExportFailure.destinationExists }

    await model.exportLibrary(to: destination)

    #expect(model.exportState == .failed("An item with that name already exists"))
  }

  @Test("an unexpected error shows a fixed message and never the error text")
  func unexpectedError() async {
    struct Leaky: Error, CustomStringConvertible { var description: String { "secret clip text" } }
    let model = model { _ in throw Leaky() }

    await model.exportLibrary(to: destination)

    #expect(model.exportState == .failed("The export could not be completed"))
  }

  @Test("cancelling an export in flight ends in the cancelled state")
  func cancel() async {
    let gate = Gate()
    let model = model { _ in
      await gate.wait()
      try Task.checkCancellation()
      return summary
    }

    let running = Task { await model.exportLibrary(to: destination) }
    while model.exportState != .running { await Task.yield() }
    model.cancelExport()
    await gate.open()
    await running.value

    #expect(model.exportState == .cancelled)
  }

  @Test("a second export while one is running is ignored")
  func notReentrant() async {
    let gate = Gate()
    let calls = Box(0)
    let model = model { _ in
      calls.value += 1
      await gate.wait()
      return summary
    }

    let first = Task { await model.exportLibrary(to: destination) }
    while model.exportState != .running { await Task.yield() }
    await model.exportLibrary(to: destination)  // returns immediately
    await gate.open()
    await first.value

    #expect(calls.value == 1)
    #expect(model.exportState == .finished(summary, name: "Copyloom Export"))
  }

  @Test("dismissing a result returns to idle, but never interrupts a running export")
  func dismiss() async {
    let gate = Gate()
    let model = model { _ in
      await gate.wait()
      return summary
    }
    await gate.open()
    await model.exportLibrary(to: destination)
    model.dismissExportResult()
    #expect(model.exportState == .idle)

    let slowGate = Gate()
    let slow = self.model { _ in
      await slowGate.wait()
      return summary
    }
    let task = Task { await slow.exportLibrary(to: destination) }
    while slow.exportState != .running { await Task.yield() }
    slow.dismissExportResult()
    #expect(slow.exportState == .running)
    await slowGate.open()
    await task.value
  }
}

/// Minimal mutable box for capturing results from `@Sendable` closures in tests.
final class Box<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

actor ExportRepositoryStub: ClipRepository {
  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    throw TestError.unexpected
  }
  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary {
    throw TestError.unexpected
  }
  func attachment(for id: UUID) async throws -> ClipAttachment? { nil }
  func attachmentData(for id: UUID) async throws -> Data? { nil }
  func createCollection(name: String, at date: Date) async throws -> ClipCollection {
    throw TestError.unexpected
  }
  func renameCollection(id: UUID, name: String, at date: Date) async throws {}
  func deleteCollection(id: UUID) async throws {}
  func listCollections() async throws -> [ClipCollection] { [] }
  func addToCollection(collectionID: UUID, clipID: UUID, at date: Date) async throws {}
  func removeFromCollection(collectionID: UUID, clipID: UUID) async throws {}
  func collectionClips(collectionID: UUID, limit: Int) async throws -> [ClipSummary] { [] }
  func getOrCreateTag(name: String) async throws -> ClipTag { throw TestError.unexpected }
  func tagClip(id: UUID, tag: String) async throws {}
  func untagClip(id: UUID, tag: String) async throws {}
  func tags(for id: UUID) async throws -> [ClipTag] { [] }
  func deleteTag(id: UUID) async throws {}
  func saveQuery(name: String, queryText: String, at date: Date) async throws -> SavedQuery {
    throw TestError.unexpected
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

private enum TestError: Error { case unexpected }
