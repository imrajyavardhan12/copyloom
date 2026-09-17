import ClipDomain
import CoreGraphics
import Foundation
import ImageIO

/// One serial step through the searchable-OCR queue.
public enum ImageOCRStepOutcome: Equatable, Sendable {
  case noWork
  case indexed(clipID: UUID, hasText: Bool)
  case withheld(clipID: UUID)
  case retryScheduled(clipID: UUID, attempts: Int)
}

/// Background searchable-OCR indexer (M3 slice 4, ADR-0005 §4).
///
/// Serial, idle-priority (the host launches it `.background`), cancellable,
/// and crash-resumable: a job is only ever marked after its scan completes,
/// so an interrupted scan stays pending for the next launch. Every path is
/// fail-closed — recognizer errors and undecodable bytes bump the attempt
/// count and, past the retry cap, quarantine instead of indexing.
///
/// Quarantine reuses the capture gate's judgment (local detector plus the
/// OCR-tolerant PEM pre-check): sensitive findings are withheld entirely,
/// pixels stay, and the clip remains findable by `type:`/`app:` but never
/// by content.
public struct ImageOCRQueue: Sendable {
  /// Bounded retries before an erroring job quarantines with a visible
  /// withheld state instead of failing open into the index.
  public static let defaultMaxAttempts = 3

  private let repository: any ClipRepository
  private let imageData: @Sendable (UUID) async throws -> Data?
  private let recognizer: any VisionTextRecognizing
  private let detector: any SensitiveContentDetecting
  private let now: @Sendable () -> Date
  private let maxAttempts: Int

  public init(
    repository: any ClipRepository,
    imageData: (@Sendable (UUID) async throws -> Data?)? = nil,
    recognizer: any VisionTextRecognizing,
    detector: any SensitiveContentDetecting = LocalSensitiveContentDetector(),
    now: @Sendable @escaping () -> Date = { .now },
    maxAttempts: Int = ImageOCRQueue.defaultMaxAttempts
  ) {
    self.repository = repository
    if let imageData {
      self.imageData = imageData
    } else {
      // Default: bytes flow through the repository seam, so the queue never
      // touches the attachment store or database directly.
      self.imageData = { [repository] id in
        try await repository.attachmentData(for: id)
      }
    }
    self.recognizer = recognizer
    self.detector = detector
    self.now = now
    self.maxAttempts = maxAttempts
  }

  /// Scans at most one pending job. Never throws: storage trouble backs off
  /// as `.noWork` so the host loop sleeps instead of hot-spinning.
  public func processNext() async -> ImageOCRStepOutcome {
    guard !Task.isCancelled else { return .noWork }
    let claimed: ClaimedOCRJob
    do {
      guard let job = try await repository.claimNextPendingOCRJob() else {
        return .noWork
      }
      claimed = job
    } catch {
      return .noWork
    }
    return await process(claimed)
  }

  /// Processes pending jobs serially until the queue drains, the item cap
  /// is reached, or the task is cancelled. Returns completed steps.
  @discardableResult
  public func drain(maxItems: Int? = nil) async -> Int {
    var completed = 0
    while !Task.isCancelled {
      if let maxItems, completed >= maxItems { break }
      switch await processNext() {
      case .noWork:
        return completed
      case .indexed, .withheld, .retryScheduled:
        completed += 1
      }
    }
    return completed
  }

  /// Long-lived host loop: drains, then polls while idle. Returns only on
  /// cancellation.
  public func runUntilCancelled(pollInterval: Duration = .seconds(5)) async {
    while !Task.isCancelled {
      if await processNext() == .noWork {
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  // MARK: - One job

  private func process(_ claimed: ClaimedOCRJob) async -> ImageOCRStepOutcome {
    let id = claimed.clipID
    let data: Data?
    do {
      data = try await imageData(id)
    } catch {
      return await noteError(id)
    }
    guard let data, !data.isEmpty else { return await noteError(id) }
    guard !Task.isCancelled else { return .noWork }
    guard let image = Self.makeImage(from: data) else {
      return await noteError(id)
    }
    let observations: [String]
    do {
      observations = try await recognizer.recognizeText(in: image)
    } catch {
      return await noteError(id)
    }
    // Cancelled mid-scan: mark nothing and leave the job pending so the
    // next launch resumes it.
    guard !Task.isCancelled else { return .noWork }
    let joined = observations.joined(separator: "\n")
    let sensitive =
      detector.inspect(joined) != .safe || Self.looksLikePEMHeader(joined)
    do {
      if sensitive {
        try await repository.markOCRWithheld(clipID: id, at: now())
        return .withheld(clipID: id)
      }
      try await repository.markOCRIndexed(clipID: id, text: joined, at: now())
      return .indexed(
        clipID: id,
        hasText: !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    } catch {
      // Completion race (deleted mid-flight sheds the job inside the
      // repository): nothing to retry, back off quietly.
      return .noWork
    }
  }

  private func noteError(_ id: UUID) async -> ImageOCRStepOutcome {
    guard !Task.isCancelled else { return .noWork }
    do {
      let attempts = try await repository.recordOCRAttempt(clipID: id, at: now())
      if attempts >= maxAttempts {
        // Bounded retries exhausted: quarantine with the same visible
        // withheld state as sensitive findings. Never fail open.
        try? await repository.markOCRWithheld(clipID: id, at: now())
        return .withheld(clipID: id)
      }
      return .retryScheduled(clipID: id, attempts: attempts)
    } catch {
      return .noWork
    }
  }

  private static func makeImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// Mirrors `VisionImagePreflight`'s tolerant header check: live OCR
  /// mangles dash runs (`•---BEGIN`, `----BEGIN…-....`), so the exact-match
  /// PEM pattern in the text detector never fires on screenshots. Kept in
  /// sync by the preflight/queue tests covering the same observations.
  private static func looksLikePEMHeader(_ text: String) -> Bool {
    pemHeaderPattern.firstMatch(
      in: text, options: [], range: NSRange(text.startIndex..., in: text)
    ) != nil
  }

  private static let pemHeaderPattern: NSRegularExpression = {
    try! NSRegularExpression(
      pattern: #"-{2,}\s*BEGIN\s+(?:(?:RSA|OPENSSH|DSA|EC)\s+)?PRIVATE\s+KEY"#,
      options: [.caseInsensitive]
    )
  }()
}
