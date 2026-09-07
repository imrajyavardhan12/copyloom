import Foundation

public protocol ClipRepository: Sendable {
  @discardableResult
  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary

  func count() async throws -> Int

  func setPinned(id: UUID, isPinned: Bool) async throws

  func setFavorite(id: UUID, isFavorite: Bool) async throws

  func recordUse(id: UUID, at date: Date) async throws

  func delete(id: UUID, at date: Date) async throws

  /// Soft-deletes unpinned/unfavorited clips with `lastSeenAt` before `cutoff`.
  /// Returns the number of clips newly expired. Idempotent.
  @discardableResult
  func deleteExpired(before cutoff: Date) async throws -> Int

  func recent(limit: Int) async throws -> [ClipSummary]

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary]
}
