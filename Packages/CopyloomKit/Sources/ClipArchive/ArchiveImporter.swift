import Foundation

public enum ArchiveImportError: Error, Equatable, Sendable {
  /// The sink returned a different number of results than it was given.
  case sinkContractViolation
}

/// Brings a verified archive into a library: plan first (no side effects),
/// then apply in batches.
///
/// Plan and apply run the same pipeline: every record is validated, gated and
/// classified by the same code, and the only difference is whether the sink is
/// asked to write. That is what makes the plan the user confirms the plan that
/// runs.
///
/// Nothing in an archive is trusted. Text and images pass the capture gates,
/// kinds are re-derived, hashes are recomputed by the sink, dimensions come
/// from a real decode, counters and timestamps are bounded, and any record
/// that violates a bound is rejected on its own rather than failing a batch.
public struct ArchiveImporter: Sendable {
  public struct Batching: Equatable, Sendable {
    public var maxClips: Int
    /// Bounds the image bytes held in memory per batch. A single image over
    /// the bound is still processed, alone.
    public var maxBytes: Int

    public init(maxClips: Int = 500, maxBytes: Int = 64 << 20) {
      self.maxClips = max(1, maxClips)
      self.maxBytes = max(1, maxBytes)
    }
  }

  private let sink: any ClipArchiveSink
  private let gates: ImportGates
  private let batching: Batching

  /// `gates` is required: it is the privacy boundary, and there must be no
  /// way to build an importer that skips it.
  public init(sink: any ClipArchiveSink, gates: ImportGates, batching: Batching = Batching()) {
    self.sink = sink
    self.gates = gates
    self.batching = batching
  }

  /// What importing would do. Reads the whole archive and asks the sink to
  /// classify, but writes nothing.
  ///
  /// `retentionCutoff` is when retention would delete a clip last seen before
  /// it (nil if history is kept forever).
  public func plan(
    _ archive: VerifiedArchive, retentionCutoff: Date?, now: Date = Date(),
    progress: (@Sendable (ImportProgress) -> Void)? = nil
  ) async throws -> ImportSummary {
    try await run(
      writing: false, archive, retentionCutoff: retentionCutoff, now: now, progress: progress)
  }

  /// Imports in batches. A failure or cancellation leaves a valid partial
  /// import, and running the same archive again completes it. A clip batch is
  /// only written once the records are in hand, and the last partial batch is
  /// only written after the whole clips file has re-verified its digest.
  public func apply(
    _ archive: VerifiedArchive, retentionCutoff: Date?, now: Date = Date(),
    progress: (@Sendable (ImportProgress) -> Void)? = nil
  ) async throws -> ImportSummary {
    try await run(
      writing: true, archive, retentionCutoff: retentionCutoff, now: now, progress: progress)
  }

  // MARK: - Pipeline

  private func run(
    writing: Bool, _ archive: VerifiedArchive, retentionCutoff: Date?, now: Date,
    progress: (@Sendable (ImportProgress) -> Void)?
  ) async throws -> ImportSummary {
    let reader = ArchiveReader(archive: archive)
    var summary = ImportSummary()
    summary.clipsInArchive = archive.manifest.counts.clips
    summary.unlistedFiles = archive.unlistedFiles.count
    summary.skippedAtExport = archive.manifest.skipped

    let library = Prepare.library(try reader.library(), rejected: &summary.libraryEntriesRejected)
    let referenced = Set(library.collections.flatMap(\.clipUuids))

    // Tags first: clip records carry only normalized names, so creating tags
    // from `library.json` before any clip keeps the display names.
    var tagsAdded = 0
    if writing { tagsAdded = try await sink.applyTags(library.tags) }

    let session = Session(
      sink: sink, writing: writing, batching: batching, retentionCutoff: retentionCutoff,
      now: now, referenced: referenced, total: summary.clipsInArchive, progress: progress)
    session.summary = summary

    try await reader.streamClips { line, result in
      try Task.checkCancellation()
      session.processed += 1
      switch result {
      case .failure(let error):
        session.summary.rejections.record(.malformedRecord, line: error.line, detail: error.reason)
      case .success(let record):
        switch try await Prepare.clip(
          record, reader: reader, gates: gates, limits: archive.limits, now: now)
        {
        case .rejected(let reason, let detail):
          session.summary.rejections.record(reason, line: line, detail: detail)
        case .ready(let clip, let dropped):
          session.summary.metadataDropped += dropped
          try await session.add(clip)
        }
      }
    }
    // Reached only if the whole file re-verified, so a tampered archive never
    // gets its final batch written.
    try await session.flush()
    session.reportProgress()

    summary = session.summary
    if writing {
      var counts = try await sink.applyLibrary(library, clipMap: session.clipMap, now: now)
      counts.tagsAdded = tagsAdded
      summary.library = counts
    } else {
      summary.library = try await sink.classifyLibrary(library)
    }
    return summary
  }

  /// Mutable state of one run, confined to the importing task.
  private final class Session {
    let sink: any ClipArchiveSink
    let writing: Bool
    let batching: Batching
    let retentionCutoff: Date?
    let now: Date
    let referenced: Set<UUID>
    let total: Int
    let progress: (@Sendable (ImportProgress) -> Void)?

    var summary = ImportSummary()
    var processed = 0
    var clipMap: [UUID: UUID] = [:]
    private var batch: [PreparedClip] = []
    private var batchBytes = 0

    init(
      sink: any ClipArchiveSink, writing: Bool, batching: Batching, retentionCutoff: Date?,
      now: Date, referenced: Set<UUID>, total: Int,
      progress: (@Sendable (ImportProgress) -> Void)?
    ) {
      self.sink = sink
      self.writing = writing
      self.batching = batching
      self.retentionCutoff = retentionCutoff
      self.now = now
      self.referenced = referenced
      self.total = total
      self.progress = progress
    }

    func add(_ clip: PreparedClip) async throws {
      let size = Self.size(of: clip)
      if !batch.isEmpty, batchBytes + size > batching.maxBytes { try await flush() }
      batch.append(clip)
      batchBytes += size
      if batch.count >= batching.maxClips { try await flush() }
    }

    func flush() async throws {
      guard !batch.isEmpty else { return }
      try Task.checkCancellation()
      let clips = batch
      batch.removeAll(keepingCapacity: true)
      batchBytes = 0

      if writing {
        let applied = try await sink.applyClips(clips, now: now)
        guard applied.count == clips.count else { throw ArchiveImportError.sinkContractViolation }
        for (clip, result) in zip(clips, applied) {
          tally(clip, result.disposition)
          if referenced.contains(clip.uuid) { clipMap[clip.uuid] = result.localUUID }
        }
      } else {
        let dispositions = try await sink.classifyClips(clips)
        guard dispositions.count == clips.count else {
          throw ArchiveImportError.sinkContractViolation
        }
        for (clip, disposition) in zip(clips, dispositions) { tally(clip, disposition) }
      }
      reportProgress()
    }

    func reportProgress() {
      progress?(ImportProgress(processed: processed, total: total))
    }

    private func tally(_ clip: PreparedClip, _ disposition: ClipDisposition) {
      switch disposition.action {
      case .add: summary.clipsAdded += 1
      case .addWithNewUUID: summary.clipsAddedWithNewUUID += 1
      case .merge: summary.clipsMerged += 1
      }
      if disposition.action != .merge, case .image = clip.content {
        summary.imagesQueuedForOCR += 1
      }

      guard let cutoff = retentionCutoff else { return }
      // The state the clip will be in after the merge: an existing clip keeps
      // its own last-seen time, and gains protection from either side.
      var lastSeen = clip.lastSeenAt
      var isProtected = clip.isPinned || clip.isFavorite
      if disposition.action == .merge, let existing = disposition.existing {
        lastSeen = existing.lastSeenAt
        isProtected = isProtected || existing.isProtected
      }
      if lastSeen < cutoff, !isProtected { summary.retentionAtRisk += 1 }
    }

    private static func size(of clip: PreparedClip) -> Int {
      switch clip.content {
      case .text(let text): text.utf8.count
      case .image(let image): image.data.count
      }
    }
  }
}

// MARK: - Validation

/// Bounds applied to untrusted values. Generous for real data, small enough
/// that a hostile archive cannot make one record expensive.
enum ImportBounds {
  static let maxCounter = 1_000_000_000
  static let maxSources = 50
  static let maxTags = 100
  static let maxTagLength = 128
  static let maxNameLength = 256
  static let maxBundleIDLength = 255
  static let maxQueryTextLength = 8_192
}

private enum Prepare {
  enum Outcome {
    case ready(PreparedClip, dropped: Int)
    case rejected(ImportRejectionReason, String)
  }

  static func clip(
    _ record: ClipRecord, reader: ArchiveReader, gates: ImportGates, limits: ArchiveLimits,
    now: Date
  ) async throws -> Outcome {
    guard record.representations.count == 1, let representation = record.representations.first
    else {
      return .rejected(.unsupportedContent, "unsupported representation count")
    }
    guard (1...ImportBounds.maxCounter).contains(record.copyCount),
      (0...ImportBounds.maxCounter).contains(record.useCount)
    else {
      return .rejected(.invalidValue, "invalid counter")
    }

    let content: PreparedClip.Content
    let kind: ArchiveClipKind
    if record.kind == .image {
      guard representation.text == nil, let path = representation.attachment,
        let expected = ArchiveFormat.fileExtension(forUTI: representation.uti),
        case .attachment(_, let actual)? = ArchivePath.parse(path), actual == expected
      else {
        return .rejected(.unsupportedContent, "kind and representation disagree")
      }
      // The reader opens without following links and re-hashes: a file
      // changed since verification throws and aborts the whole import.
      let data = try reader.attachmentData(at: path)
      guard data.count <= limits.maxAttachmentBytes,
        let inspection = await gates.inspectImage(data, representation.uti),
        inspection.width > 0, inspection.height > 0
      else {
        return .rejected(.refusedImage, "refused image")
      }
      content = .image(
        PreparedImage(
          data: data, uti: representation.uti.lowercased(), width: inspection.width,
          height: inspection.height))
      kind = .image
    } else {
      guard representation.attachment == nil, let text = representation.text,
        representation.uti == ArchiveFormat.textUTI
      else {
        return .rejected(.unsupportedContent, "kind and representation disagree")
      }
      guard let accepted = gates.acceptText(text), accepted != .image else {
        return .rejected(.refusedByPrivacyGate, "refused by privacy rules")
      }
      content = .text(text)
      // Capture stores file references without classifying them, so a file
      // record keeps its kind (once the text gate has accepted the paths);
      // every other kind is whatever the gate derives from the text.
      kind = record.kind == .file ? .file : accepted
    }

    var dropped = 0
    let sources = sources(record.sources, now: now, dropped: &dropped)
    let tags = tags(record.tags, dropped: &dropped)

    let createdAt = min(record.createdAt, now)
    let lastSeenAt = max(min(record.lastSeenAt, now), createdAt)
    return .ready(
      PreparedClip(
        uuid: record.uuid, kind: kind, content: content, createdAt: createdAt,
        lastSeenAt: lastSeenAt, lastUsedAt: record.lastUsedAt.map { min($0, now) },
        copyCount: record.copyCount, useCount: record.useCount, isPinned: record.isPinned,
        isFavorite: record.isFavorite, sources: sources, tags: tags),
      dropped: dropped)
  }

  private static func sources(
    _ records: [SourceRecord], now: Date, dropped: inout Int
  ) -> [SourceRecord] {
    var kept: [SourceRecord] = []
    var seen = Set<String>()
    for source in records {
      let key = "\(source.bundleId)\u{0}\(source.provenance.rawValue)"
      guard !source.bundleId.isEmpty, source.bundleId.count <= ImportBounds.maxBundleIDLength,
        kept.count < ImportBounds.maxSources, seen.insert(key).inserted
      else {
        dropped += 1
        continue
      }
      let firstSeen = min(source.firstSeenAt, now)
      kept.append(
        SourceRecord(
          bundleId: source.bundleId,
          name: source.name.map { String($0.prefix(ImportBounds.maxNameLength)) },
          provenance: source.provenance, firstSeenAt: firstSeen,
          lastSeenAt: max(min(source.lastSeenAt, now), firstSeen),
          copyCount: min(max(source.copyCount, 1), ImportBounds.maxCounter)))
    }
    return kept
  }

  private static func tags(_ names: [String], dropped: inout Int) -> [String] {
    var kept: [String] = []
    var seen = Set<String>()
    for name in names {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= ImportBounds.maxTagLength,
        kept.count < ImportBounds.maxTags
      else {
        dropped += 1
        continue
      }
      if seen.insert(trimmed.lowercased()).inserted { kept.append(trimmed) }
    }
    return kept
  }

  // MARK: Library

  static func library(_ library: LibraryRecord, rejected: inout Int) -> PreparedLibrary {
    PreparedLibrary(
      collections: collections(library.collections, rejected: &rejected),
      tags: tags(library.tags, rejected: &rejected),
      savedQueries: queries(library.savedQueries, rejected: &rejected))
  }

  private static func trimmed(_ text: String, max: Int) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || value.count > max ? nil : value
  }

  private static func collections(
    _ records: [CollectionRecord], rejected: inout Int
  ) -> [CollectionRecord] {
    var valid: [CollectionRecord] = []
    var seen = Set<UUID>()
    for var record in records {
      guard let name = trimmed(record.name, max: ImportBounds.maxNameLength),
        seen.insert(record.uuid).inserted
      else {
        rejected += 1
        continue
      }
      record.name = name
      valid.append(record)
    }

    // A parent link survives only if it names another collection in the
    // archive and its owner is not on a cycle. Cycles are cut at every
    // member, so none can remain.
    let parentOf = Dictionary(uniqueKeysWithValues: valid.map { ($0.uuid, $0.parentUuid) })
    func isOnCycle(_ start: UUID) -> Bool {
      var current = parentOf[start] ?? nil
      var steps = 0
      while let node = current, steps <= valid.count {
        if node == start { return true }
        current = parentOf[node] ?? nil
        steps += 1
      }
      return false
    }
    for index in valid.indices {
      guard let parent = valid[index].parentUuid else { continue }
      if parent == valid[index].uuid || parentOf[parent] == nil || isOnCycle(valid[index].uuid) {
        valid[index].parentUuid = nil
      }
    }

    // Parents first, otherwise stable.
    let fixed = Dictionary(uniqueKeysWithValues: valid.map { ($0.uuid, $0.parentUuid) })
    func depth(_ uuid: UUID) -> Int {
      var depth = 0
      var current = fixed[uuid] ?? nil
      // Bounded even though cycles were cut above: ordering must terminate
      // whatever the data looks like.
      while let node = current, depth <= fixed.count {
        depth += 1
        current = fixed[node] ?? nil
      }
      return depth
    }
    return valid.enumerated()
      .sorted { (depth($0.element.uuid), $0.offset) < (depth($1.element.uuid), $1.offset) }
      .map(\.element)
  }

  private static func tags(_ records: [TagRecord], rejected: inout Int) -> [TagRecord] {
    var kept: [TagRecord] = []
    var seen = Set<String>()
    for record in records {
      guard let name = trimmed(record.name, max: ImportBounds.maxTagLength) else {
        rejected += 1
        continue
      }
      // Identity is the normalized form, recomputed here; the archive's own
      // `normalized` is only a cross-check and is never used.
      let normalized = name.lowercased()
      if seen.insert(normalized).inserted {
        kept.append(TagRecord(name: name, normalized: normalized))
      }
    }
    return kept
  }

  private static func queries(
    _ records: [SavedQueryRecord], rejected: inout Int
  ) -> [SavedQueryRecord] {
    var kept: [SavedQueryRecord] = []
    var seen = Set<UUID>()
    for var record in records {
      guard let name = trimmed(record.name, max: ImportBounds.maxNameLength),
        let text = trimmed(record.queryText, max: ImportBounds.maxQueryTextLength),
        seen.insert(record.uuid).inserted
      else {
        rejected += 1
        continue
      }
      record.name = name
      record.queryText = text
      kept.append(record)
    }
    return kept
  }
}
