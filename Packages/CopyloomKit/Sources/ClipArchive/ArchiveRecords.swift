import Foundation

public enum ArchiveClipKind: String, Codable, Sendable {
  case text, link, image, code, color, file
}

public enum ArchiveProvenance: String, Codable, Sendable {
  case unknown, declared, frontmost
}

/// One stored representation of a clip: inline text, or an attachment
/// (image bytes in `attachments/`) with its digest.
public struct RepresentationRecord: Codable, Equatable, Sendable {
  public var uti: String
  public var text: String?
  public var attachment: String?
  public var sha256: String?
  public var bytes: Int?
  public var width: Int?
  public var height: Int?

  public init(
    uti: String, text: String? = nil, attachment: String? = nil, sha256: String? = nil,
    bytes: Int? = nil, width: Int? = nil, height: Int? = nil
  ) {
    self.uti = uti
    self.text = text
    self.attachment = attachment
    self.sha256 = sha256
    self.bytes = bytes
    self.width = width
    self.height = height
  }
}

public struct SourceRecord: Codable, Equatable, Sendable {
  public var bundleId: String
  public var name: String?
  public var provenance: ArchiveProvenance
  public var firstSeenAt: Date
  public var lastSeenAt: Date
  public var copyCount: Int

  public init(
    bundleId: String, name: String?, provenance: ArchiveProvenance, firstSeenAt: Date,
    lastSeenAt: Date, copyCount: Int
  ) {
    self.bundleId = bundleId
    self.name = name
    self.provenance = provenance
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
    self.copyCount = copyCount
  }
}

/// One line of `clips.jsonl`.
public struct ClipRecord: Codable, Equatable, Sendable {
  public var uuid: UUID
  public var kind: ArchiveClipKind
  public var createdAt: Date
  public var lastSeenAt: Date
  public var lastUsedAt: Date?
  public var copyCount: Int
  public var useCount: Int
  public var isPinned: Bool
  public var isFavorite: Bool
  public var representations: [RepresentationRecord]
  public var sources: [SourceRecord]
  public var tags: [String]

  public init(
    uuid: UUID, kind: ArchiveClipKind, createdAt: Date, lastSeenAt: Date, lastUsedAt: Date?,
    copyCount: Int, useCount: Int, isPinned: Bool, isFavorite: Bool,
    representations: [RepresentationRecord], sources: [SourceRecord], tags: [String]
  ) {
    self.uuid = uuid
    self.kind = kind
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.lastUsedAt = lastUsedAt
    self.copyCount = copyCount
    self.useCount = useCount
    self.isPinned = isPinned
    self.isFavorite = isFavorite
    self.representations = representations
    self.sources = sources
    self.tags = tags
  }
}

public struct CollectionRecord: Codable, Equatable, Sendable {
  public var uuid: UUID
  public var name: String
  public var parentUuid: UUID?
  public var createdAt: Date
  public var updatedAt: Date
  /// Ordered clip UUIDs. Membership by identity; no payload is duplicated.
  public var clipUuids: [UUID]

  public init(
    uuid: UUID, name: String, parentUuid: UUID?, createdAt: Date, updatedAt: Date,
    clipUuids: [UUID]
  ) {
    self.uuid = uuid
    self.name = name
    self.parentUuid = parentUuid
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.clipUuids = clipUuids
  }
}

public struct TagRecord: Codable, Equatable, Sendable {
  public var name: String
  public var normalized: String

  public init(name: String, normalized: String) {
    self.name = name
    self.normalized = normalized
  }
}

/// A saved query: canonical text plus parser version, never generated SQL.
public struct SavedQueryRecord: Codable, Equatable, Sendable {
  public var uuid: UUID
  public var name: String
  public var queryVersion: Int
  public var queryText: String

  public init(uuid: UUID, name: String, queryVersion: Int, queryText: String) {
    self.uuid = uuid
    self.name = name
    self.queryVersion = queryVersion
    self.queryText = queryText
  }
}

/// `library.json`.
public struct LibraryRecord: Codable, Equatable, Sendable {
  public var collections: [CollectionRecord]
  public var tags: [TagRecord]
  public var savedQueries: [SavedQueryRecord]

  public init(
    collections: [CollectionRecord], tags: [TagRecord], savedQueries: [SavedQueryRecord]
  ) {
    self.collections = collections
    self.tags = tags
    self.savedQueries = savedQueries
  }

  public static let empty = LibraryRecord(collections: [], tags: [], savedQueries: [])
}

/// A stored attachment as the writer reports it.
public struct ArchiveAttachmentRef: Equatable, Sendable {
  public let path: String
  public let sha256: String
  public let bytes: Int

  public init(path: String, sha256: String, bytes: Int) {
    self.path = path
    self.sha256 = sha256
    self.bytes = bytes
  }
}
