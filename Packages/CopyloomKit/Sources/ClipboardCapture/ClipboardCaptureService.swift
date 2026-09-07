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
          kind: policy.classifyText(text),
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
    guard snapshot.data.count <= configuration.maximumImageBytes else {
      return .skipped(.tooLarge)
    }

    switch await inspectWithTimeout(data: snapshot.data, uti: snapshot.uti) {
    case .skip(let reason):
      return .skipped(reason)
    case .allow(let width, let height):
      // The service enforces resource ceilings; the preflight judges content.
      // Refusing dimensions-only decodes above the pixel cap without full
      // bitmap residency is the Vision implementation's job (slice 3); this
      // check is the backstop for misbehaving gates.
      guard width > 0, height > 0,
        width * height <= configuration.maximumImagePixels
      else {
        return .skipped(.tooLarge)
      }
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

  private func inspectWithTimeout(data: Data, uti: String) async -> ImagePreflightVerdict {
    let preflight = imagePreflight
    let timeoutNanoseconds = UInt64(
      max(configuration.imagePreflightTimeoutSeconds, 0) * 1_000_000_000)
    return await withTaskGroup(
      of: ImagePreflightVerdict.self,
      returning: ImagePreflightVerdict.self
    ) { group in
      group.addTask { await preflight.inspect(data: data, uti: uti) }
      group.addTask {
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        return .skip(.preflightTimeout)
      }
      guard let first = await group.next() else { return .skip(.preflightTimeout) }
      group.cancelAll()
      return first
    }
  }
}
