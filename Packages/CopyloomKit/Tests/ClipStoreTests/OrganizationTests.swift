import ClipDomain
import Foundation
import Testing

@testable import ClipStore

@Suite("Organization repository")
struct OrganizationTests {
  private func isolatedDatabase() throws -> (AppDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    return (database, directory)
  }

  @Test("collections hold references without copying payloads")
  func collectionMembership() async throws {
    let (database, directory) = try isolatedDatabase()
    defer {
      try? database.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let firstID = UUID()
    let secondID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: firstID, text: "first member", capturedAt: .now))
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: secondID, text: "second member", capturedAt: .now))
    let collection = try await database.repository.createCollection(
      name: "Work", at: .now)

    try await database.repository.addToCollection(
      collectionID: collection.id, clipID: firstID, at: .now)
    try await database.repository.addToCollection(
      collectionID: collection.id, clipID: secondID, at: .now)
    // Duplicate adds are idempotent.
    try await database.repository.addToCollection(
      collectionID: collection.id, clipID: firstID, at: .now)

    var members = try await database.repository.collectionClips(
      collectionID: collection.id, limit: 20)
    #expect(Set(members.map(\.id)) == Set([firstID, secondID]))

    try await database.repository.removeFromCollection(
      collectionID: collection.id, clipID: firstID)
    members = try await database.repository.collectionClips(
      collectionID: collection.id, limit: 20)
    #expect(members.map(\.id) == [secondID])

    // Deleting the collection keeps the clips.
    try await database.repository.deleteCollection(id: collection.id)
    #expect(try await database.repository.listCollections().isEmpty)
    #expect(try await database.repository.count() == 2)

    await #expect(throws: ClipStoreError.invalidName) {
      try await database.repository.createCollection(name: "   ", at: .now)
    }
  }

  @Test("collection rename and missing membership fail safely")
  func collectionEdgeCases() async throws {
    let (database, directory) = try isolatedDatabase()
    defer {
      try? database.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let collection = try await database.repository.createCollection(
      name: "Work", at: .now)
    try await database.repository.renameCollection(
      id: collection.id, name: "Play", at: .now)
    #expect(try await database.repository.listCollections().map(\.name) == ["Play"])

    await #expect(throws: ClipStoreError.invalidName) {
      try await database.repository.renameCollection(
        id: collection.id, name: "", at: .now)
    }
    let missingClip = UUID()
    await #expect(throws: ClipStoreError.clipNotFound(missingClip)) {
      try await database.repository.addToCollection(
        collectionID: collection.id, clipID: missingClip, at: .now)
    }
    let missingCollection = UUID()
    await #expect(throws: ClipStoreError.collectionNotFound(missingCollection)) {
      try await database.repository.addToCollection(
        collectionID: missingCollection, clipID: UUID(), at: .now)
    }
    // Removing a non-member is a no-op, never an error.
    try await database.repository.removeFromCollection(
      collectionID: collection.id, clipID: UUID())
  }

  @Test("tags attach, filter and detach case-insensitively")
  func tagLifecycle() async throws {
    let (database, directory) = try isolatedDatabase()
    defer {
      try? database.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let clipID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: clipID, text: "tagged words", capturedAt: .now))

    try await database.repository.tagClip(id: clipID, tag: "Project-X")
    try await database.repository.tagClip(id: clipID, tag: "project-x")
    #expect(
      try await database.repository.tags(for: clipID).map(\.normalized) == ["project-x"])

    let filtered = try await database.repository.search(
      SearchQuery(text: [], filters: [.tag("PROJECT-x")]), limit: 20)
    #expect(filtered.map(\.id) == [clipID])

    try await database.repository.untagClip(id: clipID, tag: "project-X")
    #expect(try await database.repository.tags(for: clipID).isEmpty)
    let refiltered = try await database.repository.search(
      SearchQuery(text: [], filters: [.tag("project-x")]), limit: 20)
    #expect(refiltered.isEmpty)

    await #expect(throws: ClipStoreError.invalidName) {
      try await database.repository.tagClip(id: clipID, tag: "  ")
    }
  }

  @Test("saved queries persist and round-trip")
  func savedQueryLifecycle() async throws {
    let (database, directory) = try isolatedDatabase()
    defer {
      try? database.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let saved = try await database.repository.saveQuery(
      name: "Safari links", queryText: "app:Safari type:link", at: .now)
    #expect(saved.queryVersion == SavedQuery.currentVersion)

    try await database.repository.renameQuery(
      id: saved.id, name: "Web", at: .now)
    #expect(try await database.repository.listQueries().map(\.name) == ["Web"])

    try await database.repository.deleteQuery(id: saved.id)
    #expect(try await database.repository.listQueries().isEmpty)

    await #expect(throws: ClipStoreError.invalidName) {
      try await database.repository.saveQuery(name: "", queryText: "x", at: .now)
    }
    await #expect(throws: ClipStoreError.invalidName) {
      try await database.repository.saveQuery(name: "x", queryText: "  ", at: .now)
    }
  }

  @Test("deleting a clip cascades its memberships and tags")
  func clipDeletionCascades() async throws {
    let (database, directory) = try isolatedDatabase()
    defer {
      try? database.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let clipID = UUID()
    _ = try await database.repository.saveAcceptedText(
      AcceptedTextClip(id: clipID, text: "doomed member", capturedAt: .now))
    let collection = try await database.repository.createCollection(
      name: "Work", at: .now)
    try await database.repository.addToCollection(
      collectionID: collection.id, clipID: clipID, at: .now)
    try await database.repository.tagClip(id: clipID, tag: "temp")

    // Hard-purge the tombstone to exercise the cascade path end to end.
    try await database.repository.delete(id: clipID, at: .now)
    _ = try await database.repository.purgeDeleted(
      before: Date().addingTimeInterval(3_600))

    #expect(
      try await database.repository.collectionClips(
        collectionID: collection.id, limit: 20
      ).isEmpty)
    #expect(try await database.repository.tags(for: clipID).isEmpty)
  }
}
