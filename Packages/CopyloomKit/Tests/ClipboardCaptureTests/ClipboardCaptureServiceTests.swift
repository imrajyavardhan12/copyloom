import ClipDomain
import Foundation
import Testing

@testable import ClipboardCapture

@MainActor
@Suite("Clipboard capture service")
struct ClipboardCaptureServiceTests {
  @Test("rejects concealed marker metadata before reading clipboard payload")
  func rejectsConcealedBeforeRead() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.concealed, PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "should never be read"

    let outcome = await service.pollOnce()

    #expect(outcome == .skipped(.concealed))
    #expect(pasteboard.readCount == 0)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("rejects an ignored source application before reading clipboard payload")
  func rejectsIgnoredApplicationBeforeRead() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(
        isEnabled: true,
        ignoredBundleIdentifiers: ["com.example.password-manager"]
      )
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText],
      declaredSourceBundleIdentifier: "com.example.spoofed-source",
      frontmostApplication: ClipSource(
        bundleIdentifier: "com.example.password-manager",
        applicationName: "Password Manager",
        provenance: .frontmostApplication
      )
    )
    pasteboard.changeCount = 1
    pasteboard.text = "should never be read"

    let outcome = await service.pollOnce()

    #expect(outcome == .skipped(.ignoredApplication))
    #expect(pasteboard.readCount == 0)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("discards an inconsistent snapshot when the pasteboard changes during metadata read")
  func discardsInconsistentSnapshot() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "stale"
    pasteboard.onMetadata = { pasteboard.changeCount = 2 }

    let outcome = await service.pollOnce()

    #expect(outcome == .skipped(.inconsistentSnapshot))
    #expect(pasteboard.readCount == 0)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("does not persist sensitive text after local inspection")
  func rejectsSensitiveTextBeforeStorage() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "-----BEGIN " + "PRIVATE KEY-----\nsynthetic-fixture"

    let outcome = await service.pollOnce()

    #expect(outcome == .skipped(.sensitiveContent))
    #expect(pasteboard.readCount == 1)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("rejects text beyond the configured byte limit before storage")
  func rejectsOversizeText() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true, maximumTextBytes: 3)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "four"

    #expect(await service.pollOnce() == .skipped(.tooLarge))
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("captures a safe URL with declared source provenance")
  func capturesSafeURL() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let clipID = try #require(UUID(uuidString: "018F6E54-4B93-7D42-8A7B-35C14D7A3001"))
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true),
      now: { capturedAt },
      makeUUID: { clipID }
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText],
      declaredSourceBundleIdentifier: "com.apple.Safari",
      frontmostApplication: ClipSource(
        bundleIdentifier: "com.example.WrongForegroundApp",
        applicationName: "Wrong Foreground App",
        provenance: .frontmostApplication
      )
    )
    pasteboard.changeCount = 1
    pasteboard.text = "https://example.com/docs"

    let outcome = await service.pollOnce()
    let saved = await repository.savedClips()

    guard case .captured(let summary) = outcome else {
      Issue.record("Expected a captured result, received \(outcome)")
      return
    }
    #expect(summary.id == clipID)
    #expect(saved.count == 1)
    #expect(saved.first?.kind == .link)
    #expect(saved.first?.source?.bundleIdentifier == "com.apple.Safari")
    #expect(saved.first?.source?.provenance == .declared)
  }

  @Test("adopting the current change count discards copies made while paused")
  func discardsCopiesMadeWhilePaused() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.changeCount = 1
    pasteboard.text = "copied while paused"

    service.adoptCurrentChangeCount()

    #expect(await service.pollOnce() == .noChange)
    #expect(pasteboard.readCount == 0)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("ignore next copy is consumed exactly once")
  func ignoresOneCopy() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    service.ignoreNextCopy()

    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "first"
    #expect(await service.pollOnce() == .skipped(.ignoredNextCopy))

    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 2,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText]
    )
    pasteboard.changeCount = 2
    pasteboard.text = "second"
    guard case .captured = await service.pollOnce() else {
      Issue.record("The copy after ignore-next should be captured")
      return
    }

    #expect(await repository.savedClips().map(\.text) == ["second"])
  }

  @Test("captures an image through the privacy gate")
  func capturesImage() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.allow(width: 4, height: 4))
    let clipID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true),
      imagePreflight: gate,
      now: { capturedAt },
      makeUUID: { clipID }
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.tiff],
      declaredSourceBundleIdentifier: "com.apple.Preview",
      frontmostApplication: ClipSource(
        bundleIdentifier: "com.example.WrongForegroundApp",
        applicationName: "Wrong Foreground App",
        provenance: .frontmostApplication
      )
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x49, 0x49, 0x2A]), PasteboardTypeIdentifier.tiff)

    let outcome = await service.pollOnce()
    let saved = await repository.savedImages()

    guard case .captured(let summary) = outcome else {
      Issue.record("Expected a captured result, received \(outcome)")
      return
    }
    #expect(summary.id == clipID)
    #expect(summary.kind == .image)
    #expect(saved.count == 1)
    #expect(saved.first?.uti == PasteboardTypeIdentifier.tiff)
    #expect(saved.first?.width == 4)
    #expect(saved.first?.source?.bundleIdentifier == "com.apple.Preview")
    #expect(pasteboard.readCount == 0)
    #expect(pasteboard.imageReadCount == 1)
    #expect(await gate.callCount() == 1)
  }

  @Test("prefers text when a snapshot declares both text and image")
  func prefersTextOnMixedSnapshots() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.allow(width: 4, height: 4))
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true),
      imagePreflight: gate
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [
        PasteboardTypeIdentifier.plainText, PasteboardTypeIdentifier.png,
      ]
    )
    pasteboard.changeCount = 1
    pasteboard.text = "https://example.com/image.png"
    pasteboard.image = (Data([0x89, 0x50]), PasteboardTypeIdentifier.png)

    guard case .captured(let summary) = await service.pollOnce() else {
      Issue.record("Expected the text flavor to win")
      return
    }
    #expect(summary.kind == .link)
    #expect(pasteboard.imageReadCount == 0)
    #expect(await gate.callCount() == 0)
    #expect(await repository.savedImages().isEmpty)
  }

  @Test("refuses images while the Vision gate is unavailable")
  func refusesImagesByDefault() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x89, 0x50]), PasteboardTypeIdentifier.png)

    #expect(await service.pollOnce() == .skipped(.preflightTimeout))
    #expect(await repository.savedImages().isEmpty)
    #expect(await repository.savedClips().isEmpty)
  }

  @Test("drops denied images without persistence")
  func deniesImageAtGate() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.deny(.sensitiveContent))
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true),
      imagePreflight: gate
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x89, 0x50]), PasteboardTypeIdentifier.png)

    #expect(await service.pollOnce() == .skipped(.sensitiveContent))
    #expect(await repository.savedImages().isEmpty)
  }

  @Test("rejects oversize images before consulting the gate")
  func rejectsOversizeImage() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.allow(width: 1, height: 1))
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true, maximumImageBytes: 2),
      imagePreflight: gate
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x01, 0x02, 0x03]), PasteboardTypeIdentifier.png)

    #expect(await service.pollOnce() == .skipped(.tooLarge))
    #expect(await gate.callCount() == 0)
    #expect(await repository.savedImages().isEmpty)
  }

  @Test("rejects images beyond the pixel cap")
  func rejectsOversizePixels() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.allow(width: 100_000, height: 100_000))
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true),
      imagePreflight: gate
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x89, 0x50]), PasteboardTypeIdentifier.png)

    #expect(await service.pollOnce() == .skipped(.tooLarge))
    #expect(await repository.savedImages().isEmpty)
  }

  @Test("times out a stalled privacy gate")
  func timesOutSlowGate() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let gate = StubPreflight(.hang)
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true, imagePreflightTimeoutSeconds: 0.05),
      imagePreflight: gate
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = (Data([0x89, 0x50]), PasteboardTypeIdentifier.png)

    #expect(await service.pollOnce() == .skipped(.preflightTimeout))
    #expect(await repository.savedImages().isEmpty)
  }

  @Test("reports missing image payloads without storage")
  func reportsEmptyImage() async throws {
    let pasteboard = FakePasteboard()
    let repository = RepositorySpy()
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: repository,
      configuration: .init(isEnabled: true)
    )
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.png]
    )
    pasteboard.changeCount = 1
    pasteboard.image = nil

    #expect(await service.pollOnce() == .skipped(.emptyImage))
  }
}

@MainActor
private final class FakePasteboard: PasteboardReading {
  var changeCount = 0
  var metadataValue = PasteboardMetadata(changeCount: 0, typeIdentifiers: [])
  var text: String?
  var image: (data: Data, uti: String)?
  var onMetadata: (() -> Void)?
  private(set) var readCount = 0
  private(set) var imageReadCount = 0

  func metadata() -> PasteboardMetadata {
    onMetadata?()
    return metadataValue
  }

  func readPlainText() -> String? {
    readCount += 1
    return text
  }

  func readImageData() -> (data: Data, uti: String)? {
    imageReadCount += 1
    return image
  }
}

private actor StubPreflight: ImagePrivacyPreflight {
  enum Behavior {
    case allow(width: Int, height: Int)
    case deny(CaptureSkipReason)
    case hang
  }

  let behavior: Behavior
  private var calls = 0

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  func inspect(data: Data, uti: String) async -> ImagePreflightVerdict {
    calls += 1
    switch behavior {
    case .allow(let width, let height):
      return .allow(width: width, height: height)
    case .deny(let reason):
      return .skip(reason)
    case .hang:
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      return .allow(width: 1, height: 1)
    }
  }

  func callCount() -> Int { calls }
}

private actor RepositorySpy: ClipRepository {
  private var clips: [AcceptedTextClip] = []
  private var images: [AcceptedImageClip] = []

  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary {
    clips.append(clip)
    return ClipSummary(
      id: clip.id,
      kind: clip.kind,
      text: clip.text,
      createdAt: clip.capturedAt,
      lastSeenAt: clip.capturedAt,
      copyCount: 1,
      isPinned: false,
      isFavorite: false,
      source: clip.source
    )
  }

  func saveAcceptedImage(_ clip: AcceptedImageClip) async throws -> ClipSummary {
    images.append(clip)
    return ClipSummary(
      id: clip.id,
      kind: .image,
      text: "",
      createdAt: clip.capturedAt,
      lastSeenAt: clip.capturedAt,
      copyCount: 1,
      isPinned: false,
      isFavorite: false,
      source: clip.source
    )
  }

  func attachment(for id: UUID) async throws -> ClipAttachment? { nil }

  func count() async throws -> Int {
    clips.count
  }

  func setPinned(id: UUID, isPinned: Bool) async throws {}

  func setFavorite(id: UUID, isFavorite: Bool) async throws {}

  func deleteExpired(before cutoff: Date) async throws -> Int { 0 }

  func purgeDeleted(before cutoff: Date) async throws -> Int { 0 }

  func recordUse(id: UUID, at date: Date) async throws {}

  func delete(id: UUID, at date: Date) async throws {
    clips.removeAll { $0.id == id }
  }

  func recent(limit: Int) async throws -> [ClipSummary] {
    []
  }

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary] {
    []
  }

  func savedClips() -> [AcceptedTextClip] {
    clips
  }

  func savedImages() -> [AcceptedImageClip] {
    images
  }
}
