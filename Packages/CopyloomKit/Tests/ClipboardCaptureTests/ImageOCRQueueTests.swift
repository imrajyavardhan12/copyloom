import ClipDomain
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ClipStore
@testable import ClipboardCapture

@Suite("Image OCR queue")
struct ImageOCRQueueTests {
  static let tinyPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  )!

  private func isolatedDatabase() throws -> (AppDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase.open(at: directory.appending(path: "copyloom.sqlite"))
    return (database, directory)
  }

  private func close(_ database: AppDatabase, _ directory: URL) {
    try? database.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private func saveImage(_ database: AppDatabase, bytes: Data? = nil) async throws -> UUID {
    let id = UUID()
    _ = try await database.repository.saveAcceptedImage(
      AcceptedImageClip(
        id: id,
        data: bytes ?? Self.tinyPNG,
        uti: "public.png",
        width: 1,
        height: 1,
        capturedAt: .now
      )
    )
    return id
  }

  /// Distinct decodable bytes per clip: identical bytes would dedupe onto
  /// one clip (and one queue job), which is exactly what this helper avoids.
  private func makeSolidPNG(white: CGFloat) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ))
    context.setFillColor(red: white, green: white, blue: white, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        data as CFMutableData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
  }

  @Test("clean OCR text indexes and becomes searchable")
  func indexesCleanText() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["harbor sunset over the pier"]))
    )
    let outcome = await queue.processNext()

    #expect(outcome == .indexed(clipID: clipID, hasText: true))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .indexed)
    let term = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(term.map(\.id) == [clipID])
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.map(\.id) == [clipID])
  }

  @Test("detector findings quarantine the clip but keep its pixels")
  func quarantinesSensitiveText() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["PASSWORD=hunter2"]))
    )
    let outcome = await queue.processNext()

    #expect(outcome == .withheld(clipID: clipID))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .withheld)
    // Withheld text never reaches the index …
    let content = try await database.repository.search(
      SearchQuery(text: [.term("hunter2")], filters: []), limit: 20)
    #expect(content.isEmpty)
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)
    // … while the clip and its pixels stay.
    #expect(try await database.repository.attachmentData(for: clipID) == Self.tinyPNG)
    let byType = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.image)]), limit: 20)
    #expect(byType.map(\.id) == [clipID])
  }

  @Test("OCR-mangled PEM headers quarantine even when exact patterns miss")
  func quarantinesMangledPEMHeader() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    // Live OCR observations for the same on-screen header: dash runs arrive
    // mangled, so the text detector's exact PEM pattern never fires.
    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["•---BEGIN PRIVATE KEY document scan"]))
    )
    let outcome = await queue.processNext()

    #expect(outcome == .withheld(clipID: clipID))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .withheld)
  }

  @Test("recognizer failures retry, then quarantine instead of failing open")
  func retriesThenWithholds() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.failure),
      maxAttempts: 2
    )

    #expect(await queue.processNext() == .retryScheduled(clipID: clipID, attempts: 1))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .pending)
    #expect(await queue.processNext() == .withheld(clipID: clipID))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .withheld)

    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)
  }

  @Test("blank scans index empty text outside has:ocr")
  func indexesBlankScan() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings([]))
    )

    #expect(await queue.processNext() == .indexed(clipID: clipID, hasText: false))
    #expect(try await database.repository.ocrJob(for: clipID)?.status == .indexed)
    let flagged = try await database.repository.search(
      SearchQuery(text: [], filters: [.hasOCR]), limit: 20)
    #expect(flagged.isEmpty)
    let byType = try await database.repository.search(
      SearchQuery(text: [], filters: [.contentType(.image)]), limit: 20)
    #expect(byType.map(\.id) == [clipID])
  }

  @Test("undecodable bytes follow the error path, not the quarantine shortcut")
  func undecodableBytesRetry() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)

    let queue = ImageOCRQueue(
      repository: database.repository,
      imageData: { _ in Data([0x00, 0x01, 0x02, 0x03]) },
      recognizer: OCRStubRecognizer(.strings(["harbor"])),
      maxAttempts: 2
    )

    // Undecodable bytes can never scan clean, but they still must not index.
    #expect(await queue.processNext() == .retryScheduled(clipID: clipID, attempts: 1))
    #expect(await queue.processNext() == .withheld(clipID: clipID))
    let term = try await database.repository.search(
      SearchQuery(text: [.term("harbor")], filters: []), limit: 20)
    #expect(term.isEmpty)
  }

  @Test("drain processes every pending job and empties the queue")
  func drainsQueue() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    _ = try await saveImage(database, bytes: try makeSolidPNG(white: 1))
    _ = try await saveImage(database, bytes: try makeSolidPNG(white: 0))

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["harbor"]))
    )

    #expect(await queue.drain() == 2)
    #expect(try await database.repository.pendingOCRJobCount() == 0)
    #expect(await queue.processNext() == .noWork)
  }

  @Test("deleted clips leave no work behind")
  func deletedClipsHaveNoWork() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }
    let clipID = try await saveImage(database)
    try await database.repository.delete(id: clipID, at: .now)

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["harbor"]))
    )
    #expect(await queue.processNext() == .noWork)
  }

  @Test("a fresh database reports no work")
  func emptyQueueIsNoWork() async throws {
    let (database, directory) = try isolatedDatabase()
    defer { close(database, directory) }

    let queue = ImageOCRQueue(
      repository: database.repository,
      recognizer: OCRStubRecognizer(.strings(["harbor"]))
    )
    #expect(try await database.repository.pendingOCRJobCount() == 0)
    #expect(await queue.processNext() == .noWork)
    #expect(await queue.drain() == 0)
  }
}

private actor OCRStubRecognizer: VisionTextRecognizing {
  enum Behavior: Sendable {
    case strings([String])
    case failure
  }

  private let behavior: Behavior

  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  func recognizeText(in image: CGImage) async throws -> [String] {
    switch behavior {
    case .strings(let texts):
      return texts
    case .failure:
      throw OCRStubError.recognitionFailed
    }
  }
}

private enum OCRStubError: Error {
  case recognitionFailed
}
