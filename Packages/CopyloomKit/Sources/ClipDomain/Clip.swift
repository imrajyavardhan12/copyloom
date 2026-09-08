import Foundation

public enum ClipKind: Int, Equatable, Sendable {
  case text = 0
  case link = 1
  case image = 2
  case code = 3
  case color = 4
  case file = 5
}

public enum ClipSourceProvenance: Int, Equatable, Sendable {
  case unknown = 0
  case declared = 1
  case frontmostApplication = 2
}

public struct ClipSource: Equatable, Sendable {
  public let bundleIdentifier: String?
  public let applicationName: String?
  public let provenance: ClipSourceProvenance

  public init(
    bundleIdentifier: String?,
    applicationName: String?,
    provenance: ClipSourceProvenance
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.applicationName = applicationName
    self.provenance = provenance
  }
}

public struct AcceptedTextClip: Equatable, Sendable {
  public let id: UUID
  public let kind: ClipKind
  public let text: String
  public let capturedAt: Date
  public let source: ClipSource?

  public init(
    id: UUID,
    kind: ClipKind = .text,
    text: String,
    capturedAt: Date,
    source: ClipSource? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.capturedAt = capturedAt
    self.source = source
  }
}

public struct ClipSummary: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: ClipKind
  public let text: String
  public let createdAt: Date
  public let lastSeenAt: Date
  public let copyCount: Int
  public let useCount: Int
  public let lastUsedAt: Date?
  public let isPinned: Bool
  public let isFavorite: Bool
  public let source: ClipSource?

  public init(
    id: UUID,
    kind: ClipKind,
    text: String,
    createdAt: Date,
    lastSeenAt: Date,
    copyCount: Int,
    useCount: Int = 0,
    lastUsedAt: Date? = nil,
    isPinned: Bool,
    isFavorite: Bool,
    source: ClipSource?
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.copyCount = copyCount
    self.useCount = useCount
    self.lastUsedAt = lastUsedAt
    self.isPinned = isPinned
    self.isFavorite = isFavorite
    self.source = source
  }
}

/// An accepted image snapshot. `data` holds the canonical bytes that will be
/// content-addressed into the attachment store; `uti` records the kept flavor
/// (`public.png`, `public.tiff` or `public.jpeg`).
public struct AcceptedImageClip: Equatable, Sendable {
  public let id: UUID
  public let data: Data
  public let uti: String
  public let width: Int
  public let height: Int
  public let capturedAt: Date
  public let source: ClipSource?

  public init(
    id: UUID,
    data: Data,
    uti: String,
    width: Int,
    height: Int,
    capturedAt: Date,
    source: ClipSource? = nil
  ) {
    self.id = id
    self.data = data
    self.uti = uti
    self.width = width
    self.height = height
    self.capturedAt = capturedAt
    self.source = source
  }
}

/// File-level metadata for a stored image attachment.
public struct ClipAttachment: Equatable, Sendable {
  public let sha256: Data
  public let uti: String
  public let byteCount: Int
  public let width: Int
  public let height: Int
  public let relativePath: String

  public init(
    sha256: Data,
    uti: String,
    byteCount: Int,
    width: Int,
    height: Int,
    relativePath: String
  ) {
    self.sha256 = sha256
    self.uti = uti
    self.byteCount = byteCount
    self.width = width
    self.height = height
    self.relativePath = relativePath
  }
}
