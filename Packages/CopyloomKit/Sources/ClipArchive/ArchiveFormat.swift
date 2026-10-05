import Foundation

/// Archive format v1 constants. The format is specified in
/// `docs/archive-format.md`; this module is its pure reference implementation
/// (no storage, no UI, no network).
public enum ArchiveFormat {
  public static let identifier = "io.github.imrajyavardhan12.copyloom.archive"
  public static let version = 1

  /// Image types an archive may carry. Mirrors `AttachmentStore.supportedUTIs`
  /// (png/tiff/jpeg); `ClipStore` tests assert the two stay equal, because
  /// this module deliberately does not depend on `ClipStore`.
  public static let attachmentExtensions: Set<String> = ["png", "tiff", "jpg"]
}

/// Hard bounds applied while verifying and reading untrusted archives.
///
/// The manifest lists every attachment (~250 bytes each), so its cap must
/// scale with `maxFiles`: 64 MiB holds ~250k entries, comfortably more than a
/// large personal library, while still bounding parse time and memory. (A
/// first draft capped it at 1 MiB, which rejected any library with more than
/// ~4,000 images.)
public struct ArchiveLimits: Equatable, Sendable {
  public var maxManifestBytes: Int
  public var maxClips: Int
  /// A text clip is capped at 5 MiB by capture; 32 MiB leaves room for JSON
  /// escaping (worst case ~6x for control characters).
  public var maxLineBytes: Int
  /// The capture image ceiling.
  public var maxAttachmentBytes: Int
  public var maxLibraryBytes: Int
  /// Bounds hashing time: without it a declared multi-terabyte sparse
  /// `clips.jsonl` would keep the verifier busy for hours.
  public var maxClipsFileBytes: Int
  public var maxFiles: Int

  public init(
    maxManifestBytes: Int = 64 << 20,
    maxClips: Int = 1_000_000,
    maxLineBytes: Int = 32 << 20,
    maxAttachmentBytes: Int = 25 << 20,
    maxLibraryBytes: Int = 64 << 20,
    maxClipsFileBytes: Int = 16 << 30,
    maxFiles: Int = 500_000
  ) {
    self.maxManifestBytes = maxManifestBytes
    self.maxClips = maxClips
    self.maxLineBytes = maxLineBytes
    self.maxAttachmentBytes = maxAttachmentBytes
    self.maxLibraryBytes = maxLibraryBytes
    self.maxClipsFileBytes = maxClipsFileBytes
    self.maxFiles = maxFiles
  }

  public static let standard = ArchiveLimits()
}

/// Why an archive was refused. Cases carry archive-relative paths or counts
/// only, never clip content, so they are safe to show or log.
public enum ArchiveError: Error, Equatable, Sendable {
  // Identification
  case notAnArchive
  case missingManifest
  case invalidManifest
  case manifestTooLarge
  case unsupportedVersion(Int)
  // Structure
  case invalidPath(String)
  case duplicatePath(String)
  case missingRequiredFile(String)
  case missingFile(String)
  /// Present but a FIFO, device, directory or socket. Never opened for reading.
  case notARegularFile(String)
  case symlinkNotAllowed(String)
  // Integrity
  case sizeMismatch(String)
  case digestMismatch(String)
  case archiveDigestMismatch
  case countMismatch(String)
  // Limits
  case tooManyClips
  case tooManyFiles
  case attachmentTooLarge(String)
  case fileTooLarge(String)
  case lineTooLong
  // Writing
  case destinationExists
  case unsupportedAttachmentType(String)
  case emptyAttachment
  case unknownAttachment(String)
}

/// A problem with one `clips.jsonl` record. It never fails the archive: good
/// records still arrive and the importer reports the bad ones.
public struct ArchiveRecordError: Error, Equatable, Sendable {
  public let line: Int
  /// Fixed wording plus field names; never record values.
  public let reason: String

  public init(line: Int, reason: String) {
    self.line = line
    self.reason = reason
  }
}
