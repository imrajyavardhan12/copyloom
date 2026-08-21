import Foundation

public struct AcceptedTextClip: Equatable, Sendable {
  public let id: UUID
  public let text: String
  public let capturedAt: Date

  public init(id: UUID, text: String, capturedAt: Date) {
    self.id = id
    self.text = text
    self.capturedAt = capturedAt
  }
}

public struct ClipSummary: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let text: String
  public let createdAt: Date
  public let lastSeenAt: Date
  public let copyCount: Int
  public let isPinned: Bool
  public let isFavorite: Bool

  public init(
    id: UUID,
    text: String,
    createdAt: Date,
    lastSeenAt: Date,
    copyCount: Int,
    isPinned: Bool,
    isFavorite: Bool
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.copyCount = copyCount
    self.isPinned = isPinned
    self.isFavorite = isFavorite
  }
}
