import Foundation
import Testing

@testable import ClipStore

@Suite("Attachment store")
struct AttachmentStoreTests {
  static let pngData = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  )!

  private func isolatedStore() throws -> (AttachmentStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = directory.appending(path: "Attachments/v1", directoryHint: .isDirectory)
    let store = AttachmentStore(root: root)
    try store.prepare()
    return (store, directory)
  }

  @Test("round-trips bytes through a content-addressed path")
  func roundTrips() throws {
    let (store, directory) = try isolatedStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let stored = try store.store(data: Self.pngData, uti: "public.png")

    #expect(stored.byteCount == Self.pngData.count)
    #expect(stored.relativePath.hasSuffix(".png"))
    #expect(try store.data(at: stored.relativePath) == Self.pngData)
    #expect(
      FileManager.default.fileExists(
        atPath: store.url(for: stored.relativePath).path))
  }

  @Test("deduplicates identical bytes to the same path")
  func deduplicates() throws {
    let (store, directory) = try isolatedStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try store.store(data: Self.pngData, uti: "public.png")
    let second = try store.store(data: Self.pngData, uti: "public.png")

    #expect(first == second)
  }

  @Test("rejects empty data and unknown flavors")
  func rejectsInvalidInput() throws {
    let (store, directory) = try isolatedStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: AttachmentStoreError.emptyData) {
      try store.store(data: Data(), uti: "public.png")
    }
    #expect(throws: AttachmentStoreError.unsupportedUTI("com.example.weird")) {
      try store.store(data: Self.pngData, uti: "com.example.weird")
    }
  }

  @Test("removal ignores missing files")
  func removalIsIdempotent() throws {
    let (store, directory) = try isolatedStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let stored = try store.store(data: Self.pngData, uti: "public.png")
    store.remove(relativePaths: [stored.relativePath])
    store.remove(relativePaths: [stored.relativePath])
    #expect(
      !FileManager.default.fileExists(atPath: store.url(for: stored.relativePath).path))
  }

  @Test("reconciles only old unreferenced files")
  func reconcilesOrphans() throws {
    let (store, directory) = try isolatedStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let known = try store.store(data: Self.pngData, uti: "public.png")
    let oldUnknownURL = store.url(for: "aa/bb/oldunknown.png")
    let freshUnknownURL = store.url(for: "aa/bb/freshunknown.png")
    try FileManager.default.createDirectory(
      at: oldUnknownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: oldUnknownURL)
    try Data("fresh".utf8).write(to: freshUnknownURL)
    // Age the known file too: references protect it regardless of mtime.
    // The fresh file gets a future mtime so it is unambiguously newer than
    // the cutoff (a file created just now would compare older by nanoseconds).
    let ancient = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: ancient],
      ofItemAtPath: store.url(for: known.relativePath).path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: ancient], ofItemAtPath: oldUnknownURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(3_600)],
      ofItemAtPath: freshUnknownURL.path
    )

    let removed = try store.reconcile(
      knownPaths: [known.relativePath], olderThan: Date())

    #expect(removed == 1)
    #expect(
      FileManager.default.fileExists(
        atPath: store.url(for: known.relativePath).path))
    #expect(FileManager.default.fileExists(atPath: freshUnknownURL.path))
    #expect(!FileManager.default.fileExists(atPath: oldUnknownURL.path))
  }
}
