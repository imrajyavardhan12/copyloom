import ClipDomain
import Foundation

public enum CaptureFailure: Equatable, Sendable {
  case storage
}

public enum CaptureOutcome: Equatable, Sendable {
  case noChange
  case skipped(CaptureSkipReason)
  case captured(ClipSummary)
  case failed(CaptureFailure)
}

@MainActor
public final class ClipboardCaptureService {
  private let pasteboard: any PasteboardReading
  private let repository: any ClipRepository
  private let policy: CapturePolicy
  private let sensitiveContentDetector: any SensitiveContentDetecting
  private let imagePreflight: any ImagePrivacyPreflight
  private let now: @MainActor @Sendable () -> Date
  private let makeUUID: @MainActor @Sendable () -> UUID

  private var configuration: CaptureConfiguration
  private var lastChangeCount: Int
  private var shouldIgnoreNextCopy = false

  public init(
    pasteboard: any PasteboardReading,
    repository: any ClipRepository,
    configuration: CaptureConfiguration,
    policy: CapturePolicy = CapturePolicy(),
    sensitiveContentDetector: any SensitiveContentDetecting = LocalSensitiveContentDetector(),
    imagePreflight: any ImagePrivacyPreflight = DisabledImagePreflight(),
    now: @escaping @MainActor @Sendable () -> Date = { .now },
    makeUUID: @escaping @MainActor @Sendable () -> UUID = { UUID() }
  ) {
    self.pasteboard = pasteboard
    self.repository = repository
    self.configuration = configuration
    self.policy = policy
    self.sensitiveContentDetector = sensitiveContentDetector
    self.imagePreflight = imagePreflight
    self.now = now
    self.makeUUID = makeUUID
    lastChangeCount = pasteboard.changeCount
  }

  public func updateConfiguration(_ configuration: CaptureConfiguration) {
    self.configuration = configuration
  }

  public func ignoreNextCopy() {
    shouldIgnoreNextCopy = true
  }

  public func adoptCurrentChangeCount() {
    lastChangeCount = pasteboard.changeCount
  }

  public func pollOnce() async -> CaptureOutcome {
    let observedChangeCount = pasteboard.changeCount
    guard observedChangeCount != lastChangeCount else { return .noChange }
    lastChangeCount = observedChangeCount

    if shouldIgnoreNextCopy {
      shouldIgnoreNextCopy = false
      return .skipped(.ignoredNextCopy)
    }

    let metadata = pasteboard.metadata()
    guard metadata.changeCount == observedChangeCount,
      pasteboard.changeCount == observedChangeCount
    else {
      return .skipped(.inconsistentSnapshot)
    }
    switch policy.preflight(metadata: metadata, configuration: configuration) {
    case .skip(let reason):
      return .skipped(reason)
    case .allowText(let source):
      return await captureText(source: source, observedChangeCount: observedChangeCount)
    case .allowImage(let source):
      return await captureImage(source: source, observedChangeCount: observedChangeCount)
    case .allowFile(let source):
      return await captureFile(source: source, observedChangeCount: observedChangeCount)
    }
  }

  private func captureText(source: ClipSource?, observedChangeCount: Int) async -> CaptureOutcome {
    guard let text = pasteboard.readPlainText(), !text.isEmpty else {
      return .skipped(.emptyText)
    }
    guard pasteboard.changeCount == observedChangeCount else {
      return .skipped(.inconsistentSnapshot)
    }
    guard text.utf8.count <= configuration.maximumTextBytes else {
      return .skipped(.tooLarge)
    }
    guard sensitiveContentDetector.inspect(text) == .safe else {
      return .skipped(.sensitiveContent)
    }

    do {
      let summary = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: makeUUID(),
          kind: policy.classifyKind(text),
          text: text,
          capturedAt: now(),
          source: source
        )
      )
      return .captured(summary)
    } catch {
      return .failed(.storage)
    }
  }

  private func captureImage(source: ClipSource?, observedChangeCount: Int) async -> CaptureOutcome {
    guard let snapshot = pasteboard.readImageData(), !snapshot.data.isEmpty else {
      return .skipped(.emptyImage)
    }
    guard pasteboard.changeCount == observedChangeCount else {
      return .skipped(.inconsistentSnapshot)
    }
    let gate = ImageAcceptanceGate(preflight: imagePreflight, configuration: configuration)
    switch await gate.evaluate(data: snapshot.data, uti: snapshot.uti) {
    case .skip(let reason):
      return .skipped(reason)
    case .allow(let width, let height):
      do {
        let summary = try await repository.saveAcceptedImage(
          AcceptedImageClip(
            id: makeUUID(),
            data: snapshot.data,
            uti: snapshot.uti,
            width: width,
            height: height,
            capturedAt: now(),
            source: source
          )
        )
        return .captured(summary)
      } catch {
        return .failed(.storage)
      }
    }
  }

  /// File references are stored as newline-joined POSIX paths, never as
  /// copied bytes. When the flavor is advertised but unreadable, the text
  /// branch runs instead so long-standing filename capture is preserved.
  private func captureFile(source: ClipSource?, observedChangeCount: Int) async -> CaptureOutcome {
    let urls = pasteboard.readFileURLs()
    guard !urls.isEmpty else {
      return await captureText(source: source, observedChangeCount: observedChangeCount)
    }
    guard pasteboard.changeCount == observedChangeCount else {
      return .skipped(.inconsistentSnapshot)
    }
    let text = urls.map(\.path).joined(separator: "\n")
    guard sensitiveContentDetector.inspect(text) == .safe else {
      return .skipped(.sensitiveContent)
    }
    do {
      let summary = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: makeUUID(),
          kind: .file,
          text: text,
          capturedAt: now(),
          source: source
        )
      )
      return .captured(summary)
    } catch {
      return .failed(.storage)
    }
  }
}
