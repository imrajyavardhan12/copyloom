import Foundation

/// One live clip as the library sees it, ready to be considered for export.
public struct ExportCandidate: Sendable {
  /// The clip as it would appear in `clips.jsonl`. Image representations
  /// already carry their archive attachment path, digest, size and
  /// dimensions; the bytes are fetched only if the clip is exported.
  public var clip: ClipRecord
  /// An image whose OCR scan withheld its text as sensitive (the library's
  /// quarantine). Its pixels are never fetched or written.
  public var isQuarantinedImage: Bool

  public init(clip: ClipRecord, isQuarantinedImage: Bool) {
    self.clip = clip
    self.isQuarantinedImage = isQuarantinedImage
  }
}

/// Where an export reads from. `ClipStore` implements this over the database;
/// tests implement it in memory. Kept free of storage types so the exporter
/// and its privacy rules are testable without a database.
public protocol ClipArchiveSource: Sendable {
  /// Streams every live (not deleted) clip, ordered by creation time then
  /// UUID, from one consistent snapshot, in bounded memory.
  func forEachLiveClip(_ body: (ExportCandidate) async throws -> Void) async throws

  /// Collections (with membership), tags and saved queries.
  func libraryRecord() async throws -> LibraryRecord

  /// Attachment bytes by SHA-256 (lowercase hex), or nil if the file is gone.
  func attachmentData(sha256: String) async throws -> Data?
}

/// Writes the library to a portable archive.
///
/// An export never contains anything the app itself has quarantined:
/// - text the gate refuses is skipped and counted;
/// - images whose OCR text was withheld are skipped and counted, and their
///   pixels are never even read;
/// - a missing or corrupt attachment skips that clip only.
/// Skips are reported as counts by reason, never as content, hashes or paths.
public struct ArchiveExporter: Sendable {
  private let source: any ClipArchiveSource
  private let isExportable: @Sendable (String) -> Bool
  private let createdBy: ArchiveManifest.CreatedBy

  /// `isExportable` is required, not defaulted: it is the privacy gate, and
  /// there must be no way to build an exporter that quietly skips it. Pass
  /// the same text gate capture uses.
  public init(
    source: any ClipArchiveSource,
    isExportable: @escaping @Sendable (String) -> Bool,
    createdBy: ArchiveManifest.CreatedBy
  ) {
    self.source = source
    self.isExportable = isExportable
    self.createdBy = createdBy
  }

  @discardableResult
  public func export(
    to destination: URL,
    now: Date = Date(),
    limits: ArchiveLimits = .standard
  ) async throws -> ArchiveManifest {
    let writer = try ArchiveWriter(destination: destination, limits: limits)
    var skipped = ArchiveManifest.Skipped()
    var exported = Set<UUID>()

    do {
      try await source.forEachLiveClip { candidate in
        try Task.checkCancellation()

        if candidate.isQuarantinedImage {
          skipped.quarantinedImage += 1
          return
        }
        for representation in candidate.clip.representations {
          if let text = representation.text, !isExportable(text) {
            skipped.sensitive += 1
            return
          }
        }

        // Fetch and validate every attachment before writing any, so a clip
        // that is skipped halfway never leaves an orphan file in the package.
        var pending: [(data: Data, fileExtension: String, path: String)] = []
        for representation in candidate.clip.representations {
          guard let path = representation.attachment else { continue }
          guard let declared = representation.sha256,
            case .attachment(let sha256, let fileExtension)? = ArchivePath.parse(path),
            sha256 == declared,
            let data = try await source.attachmentData(sha256: declared),
            ArchiveHashing.sha256Hex(data) == declared
          else {
            skipped.missingAttachment += 1
            return
          }
          pending.append((data, fileExtension, path))
        }
        for item in pending {
          let reference = try writer.addAttachment(
            data: item.data, fileExtension: item.fileExtension)
          guard reference.path == item.path else {
            throw ArchiveError.invalidPath(item.path)
          }
        }
        try writer.addClip(candidate.clip)
        exported.insert(candidate.clip.uuid)
      }

      var library = try await source.libraryRecord()
      // Membership may only name clips that are in the archive.
      for index in library.collections.indices {
        library.collections[index].clipUuids = library.collections[index].clipUuids
          .filter(exported.contains)
      }
      return try writer.finish(
        library: library, createdBy: createdBy, skipped: skipped, now: now)
    } catch {
      writer.cancel()
      throw error
    }
  }
}
