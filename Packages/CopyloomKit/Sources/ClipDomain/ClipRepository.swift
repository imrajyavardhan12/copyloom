import Foundation

public protocol ClipRepository: Sendable {
  @discardableResult
  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary

  @discardableResult
  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary

  /// File metadata for an image clip's attachment, if present.
  func attachment(for id: UUID) async throws -> ClipAttachment?

  /// Raw bytes for an image clip's attachment, or nil when the clip has no
  /// attachment or its file is gone. Nil never throws: callers degrade to a
  /// graceful status message instead of failing delivery.
  func attachmentData(for id: UUID) async throws -> Data?

  func count() async throws -> Int

  func setPinned(id: UUID, isPinned: Bool) async throws

  func setFavorite(id: UUID, isFavorite: Bool) async throws

  func recordUse(id: UUID, at date: Date) async throws

  func delete(id: UUID, at date: Date) async throws

  /// Soft-deletes unpinned/unfavorited clips with `lastSeenAt` before `cutoff`.
  /// Returns the number of clips newly expired. Idempotent. Expired rows are
  /// kept as tombstones (see `purgeDeleted`) so a later sync design has
  /// deletion markers; retention counts from when each clip was last copied.
  @discardableResult
  func deleteExpired(before cutoff: Date) async throws -> Int

  /// Hard-deletes tombstoned rows (`deletedAt` before `cutoff`) and, through
  /// `ON DELETE CASCADE`, their representations, source links and search
  /// documents. Bounds database disk use; returns purged row count.
  @discardableResult
  func purgeDeleted(before cutoff: Date) async throws -> Int

  func recent(limit: Int) async throws -> [ClipSummary]

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary]
}
