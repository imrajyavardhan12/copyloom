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
}

@MainActor
private final class FakePasteboard: PasteboardReading {
  var changeCount = 0
  var metadataValue = PasteboardMetadata(changeCount: 0, typeIdentifiers: [])
  var text: String?
  var onMetadata: (() -> Void)?
  private(set) var readCount = 0

  func metadata() -> PasteboardMetadata {
    onMetadata?()
    return metadataValue
  }

  func readPlainText() -> String? {
    readCount += 1
    return text
  }
}

private actor RepositorySpy: ClipRepository {
  private var clips: [AcceptedTextClip] = []

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

  func count() async throws -> Int {
    clips.count
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
}
