public protocol ClipRepository: Sendable {
  @discardableResult
  func saveAcceptedText(_ clip: AcceptedTextClip) async throws -> ClipSummary

  func count() async throws -> Int

  func recent(limit: Int) async throws -> [ClipSummary]

  func search(_ query: SearchQuery, limit: Int) async throws -> [ClipSummary]
}
