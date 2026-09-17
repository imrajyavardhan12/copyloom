import Foundation

/// Crash-resumable OCR queue state for one image clip. The status is the
/// quarantine tri-state from ADR-0005 §4: no new columns on clips or
/// search_documents track it.
///
/// - pending: awaiting (re)scan, or a recognizer failure under the retry cap.
/// - indexed: OCR text (possibly empty for blank images) is stored in
///   `search_documents.ocr` and searchable. Only this state is content-queryable.
/// - withheld: quarantine. OCR text is withheld entirely; pixels stay, the
///   clip remains findable by `type:`/`app:` but never by content.
public enum OCRJobStatus: Int, Equatable, Sendable, CaseIterable {
  case pending = 0
  case indexed = 1
  case withheld = 2
}

/// One claimed queue entry: the clip to scan plus its current attempt count.
public struct ClaimedOCRJob: Equatable, Sendable {
  public let clipID: UUID
  public let attempts: Int

  public init(clipID: UUID, attempts: Int) {
    self.clipID = clipID
    self.attempts = attempts
  }
}

/// Observable queue state for one clip.
public struct OCRJobInfo: Equatable, Sendable {
  public let status: OCRJobStatus
  public let attempts: Int

  public init(status: OCRJobStatus, attempts: Int) {
    self.status = status
    self.attempts = attempts
  }
}
