import Foundation

public enum ClipKind: Int, Equatable, Sendable {
  case text = 0
  case link = 1
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
    self.isPinned = isPinned
    self.isFavorite = isFavorite
    self.source = source
  }
}
