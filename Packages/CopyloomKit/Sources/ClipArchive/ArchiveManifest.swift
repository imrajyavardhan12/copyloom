import Foundation

/// `manifest.json`: identity, counts and an integrity entry for every other
/// file. It is integrity, not authenticity: anyone who can edit the folder
/// can edit the manifest as well. Signing belongs with Vault.
public struct ArchiveManifest: Codable, Equatable, Sendable {
  public struct CreatedBy: Codable, Equatable, Sendable {
    public var app: String
    public var appVersion: String
    public var schemaVersion: Int

    public init(app: String, appVersion: String, schemaVersion: Int) {
      self.app = app
      self.appVersion = appVersion
      self.schemaVersion = schemaVersion
    }
  }

  public struct Counts: Codable, Equatable, Sendable {
    public var clips: Int
    public var attachments: Int
    public var collections: Int
    public var tags: Int
    public var savedQueries: Int

    public init(clips: Int, attachments: Int, collections: Int, tags: Int, savedQueries: Int) {
      self.clips = clips
      self.attachments = attachments
      self.collections = collections
      self.tags = tags
      self.savedQueries = savedQueries
    }
  }

  /// Clips left out at export time, by reason. Counts only, never content.
  public struct Skipped: Codable, Equatable, Sendable {
    public var sensitive: Int
    public var quarantinedImage: Int
    public var missingAttachment: Int

    public init(sensitive: Int = 0, quarantinedImage: Int = 0, missingAttachment: Int = 0) {
      self.sensitive = sensitive
      self.quarantinedImage = quarantinedImage
      self.missingAttachment = missingAttachment
    }

    public static let none = Skipped()
  }

  public struct FileEntry: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int
    public var sha256: String

    public init(path: String, bytes: Int, sha256: String) {
      self.path = path
      self.bytes = bytes
      self.sha256 = sha256
    }
  }

  public var format: String
  public var formatVersion: Int
  public var createdAt: Date
  public var createdBy: CreatedBy
  public var counts: Counts
  public var skipped: Skipped
  public var files: [FileEntry]
  public var archiveDigest: String

  public init(
    format: String = ArchiveFormat.identifier, formatVersion: Int = ArchiveFormat.version,
    createdAt: Date, createdBy: CreatedBy, counts: Counts, skipped: Skipped,
    files: [FileEntry], archiveDigest: String
  ) {
    self.format = format
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.createdBy = createdBy
    self.counts = counts
    self.skipped = skipped
    self.files = files
    self.archiveDigest = archiveDigest
  }

  /// One short value summarizing the whole archive, comparable out of band:
  /// SHA-256 over `path\0sha256\n` lines sorted by path. Independent of the
  /// order entries are listed in.
  public static func digest(of files: [FileEntry]) -> String {
    let text = files.sorted { $0.path < $1.path }
      .map { "\($0.path)\u{0}\($0.sha256)\n" }
      .joined()
    return ArchiveHashing.sha256Hex(Data(text.utf8))
  }
}
