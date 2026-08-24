import ClipDomain
import ClipStore
import ClipboardCapture
import Foundation
import Testing

@MainActor
@Suite("Clipboard capture integration")
struct ClipboardCaptureIntegrationTests {
  @Test("a captured link survives reopen and is searchable by type and source app")
  func capturesPersistsAndSearchesLink() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "copyloom.sqlite")

    let pasteboard = IntegrationPasteboard()
    let database = try AppDatabase.open(at: databaseURL)
    let service = ClipboardCaptureService(
      pasteboard: pasteboard,
      repository: database.repository,
      configuration: CaptureConfiguration(isEnabled: true)
    )
    pasteboard.changeCount = 1
    pasteboard.metadataValue = PasteboardMetadata(
      changeCount: 1,
      typeIdentifiers: [PasteboardTypeIdentifier.plainText],
      declaredSourceBundleIdentifier: "com.apple.Safari"
    )
    pasteboard.text = "https://example.com/copyloom"

    guard case .captured(let captured) = await service.pollOnce() else {
      Issue.record("Expected the link to be captured")
      return
    }
    #expect(captured.kind == .link)
    try database.close()

    let reopened = try AppDatabase.open(at: databaseURL)
    defer { try? reopened.close() }
    let results = try await reopened.repository.search(
      SearchQuery(
        text: [],
        filters: [.contentType(.link), .application("Safari")]
      ),
      limit: 20
    )

    #expect(results.map(\.id) == [captured.id])
    #expect(results.first?.text == "https://example.com/copyloom")
    #expect(results.first?.source?.provenance == .declared)
  }
}

@MainActor
private final class IntegrationPasteboard: PasteboardReading {
  var changeCount = 0
  var metadataValue = PasteboardMetadata(changeCount: 0, typeIdentifiers: [])
  var text: String?

  func metadata() -> PasteboardMetadata {
    metadataValue
  }

  func readPlainText() -> String? {
    text
  }
}
