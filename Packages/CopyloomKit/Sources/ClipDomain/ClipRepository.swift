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

  // MARK: - Collections

  @discardableResult
  func createCollection(name: String, at date: Date) async throws -> ClipCollection
  func renameCollection(id: UUID, name: String, at date: Date) async throws
  func deleteCollection(id: UUID) async throws
  func listCollections() async throws -> [ClipCollection]
  func addToCollection(collectionID: UUID, clipID: UUID, at date: Date) async throws
  func removeFromCollection(collectionID: UUID, clipID: UUID) async throws
  func collectionClips(collectionID: UUID, limit: Int) async throws -> [ClipSummary]

  // MARK: - Tags

  @discardableResult
  func getOrCreateTag(name: String) async throws -> ClipTag
  func tagClip(id: UUID, tag: String) async throws
  func untagClip(id: UUID, tag: String) async throws
  func tags(for id: UUID) async throws -> [ClipTag]
  func deleteTag(id: UUID) async throws

  // MARK: - Saved queries

  @discardableResult
  func saveQuery(name: String, queryText: String, at date: Date) async throws -> SavedQuery
  func renameQuery(id: UUID, name: String, at date: Date) async throws
  func deleteQuery(id: UUID) async throws
  func listQueries() async throws -> [SavedQuery]

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

  // MARK: - Searchable OCR (M3 slice 4)

  /// Queue state for one clip, or nil when the clip has no OCR job
  /// (every non-image clip, or a clip whose job was cleaned up on delete).
  func ocrJob(for id: UUID) async throws -> OCRJobInfo?

  /// Oldest pending job over live clips, or nil when the queue is drained.
  /// Crash-resumable: unclaimed rows stay pending across restarts.
  func claimNextPendingOCRJob() async throws -> ClaimedOCRJob?

  /// Pending-job depth over live clips. Powers queue telemetry, not search.
  func pendingOCRJobCount() async throws -> Int

  /// Safe path: stores OCR text in `search_documents.ocr` (FTS follows via
  /// triggers) and marks the job indexed.
  func markOCRIndexed(clipID: UUID, text: String, at date: Date) async throws

  /// Quarantine path: OCR text is withheld entirely (any indexed text is
  /// cleared), pixels stay, job marked withheld.
  func markOCRWithheld(clipID: UUID, at date: Date) async throws

  /// Error path: bumps the attempt count, keeps the job pending.
  /// Returns the new attempt count so the caller can bound retries.
  @discardableResult
  func recordOCRAttempt(clipID: UUID, at date: Date) async throws -> Int

  /// Full FTS rebuild (`INSERT INTO clip_fts(clip_fts) VALUES('rebuild')`).
  /// Repair path and the bench-measured rebuild behind migration 006.
  func rebuildSearchIndex() async throws
}

// Default OCR behavior for in-memory fakes and spies: no jobs, no-ops.
// The GRDB repository overrides every method below with real storage.
extension ClipRepository {
  public func ocrJob(for id: UUID) async throws -> OCRJobInfo? { nil }
  public func claimNextPendingOCRJob() async throws -> ClaimedOCRJob? { nil }
  public func pendingOCRJobCount() async throws -> Int { 0 }
  public func markOCRIndexed(clipID: UUID, text: String, at date: Date) async throws {}
  public func markOCRWithheld(clipID: UUID, at date: Date) async throws {}
  @discardableResult
  public func recordOCRAttempt(clipID: UUID, at date: Date) async throws -> Int { 0 }
  public func rebuildSearchIndex() async throws {}
}
