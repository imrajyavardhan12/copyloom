import Foundation

/// Builds an archive in `<destination>.partial` and renames it into place
/// only after `manifest.json` (written last) is complete, so an interrupted
/// export can never be mistaken for a finished archive. Not thread-safe:
/// drive it from one task.
public final class ArchiveWriter {
  private let destination: URL
  private let partial: URL
  private let limits: ArchiveLimits
  private let fileManager: FileManager
  private var clipsHandle: FileHandle?
  private var clipCount = 0
  private var attachments: [String: ArchiveAttachmentRef] = [:]
  private var finished = false

  public init(
    destination: URL, limits: ArchiveLimits = .standard, fileManager: FileManager = .default
  ) throws {
    self.destination = destination
    self.partial = URL(fileURLWithPath: destination.path + ".partial", isDirectory: true)
    self.limits = limits
    self.fileManager = fileManager
    // lstat-style check: a dangling symlink at the destination also counts.
    if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
      throw ArchiveError.destinationExists
    }
    // A stale `.partial` can only be ours from an interrupted export.
    try? fileManager.removeItem(at: partial)
    try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
    let clipsURL = partial.appending(path: "clips.jsonl")
    guard fileManager.createFile(atPath: clipsURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    clipsHandle = try FileHandle(forWritingTo: clipsURL)
  }

  /// Stores image bytes content-addressed by SHA-256. Identical bytes are
  /// stored once. Add an attachment before any clip that references it.
  public func addAttachment(data: Data, fileExtension: String) throws -> ArchiveAttachmentRef {
    let ext = fileExtension.lowercased()
    guard ArchiveFormat.attachmentExtensions.contains(ext) else {
      throw ArchiveError.unsupportedAttachmentType(ext)
    }
    guard !data.isEmpty else { throw ArchiveError.emptyAttachment }
    let digest = ArchiveHashing.sha256Hex(data)
    let path = ArchivePath.attachmentPath(sha256: digest, fileExtension: ext)
    guard data.count <= limits.maxAttachmentBytes else {
      throw ArchiveError.attachmentTooLarge(path)
    }
    if let existing = attachments[path] { return existing }
    let url = partial.appending(path: path)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
    let ref = ArchiveAttachmentRef(path: path, sha256: digest, bytes: data.count)
    attachments[path] = ref
    return ref
  }

  /// Appends one clip as a JSON line. Every attachment it references must
  /// have been added first, which catches exporter bugs at the source.
  public func addClip(_ record: ClipRecord) throws {
    for representation in record.representations {
      if let path = representation.attachment, attachments[path] == nil {
        throw ArchiveError.unknownAttachment(path)
      }
    }
    let line = try ArchiveCoding.encoder().encode(record)
    try appendLine(line)
  }

  /// Test seam: writes pre-built lines verbatim so reader tests can feed
  /// malformed records through a real, verifiable archive.
  func injectRawClipLines(_ lines: [String]) throws {
    guard let handle = clipsHandle else { throw CocoaError(.fileWriteUnknown) }
    // Batched so tests can write millions of lines without millions of syscalls.
    for batch in stride(from: 0, to: lines.count, by: 10_000) {
      let slice = lines[batch..<min(batch + 10_000, lines.count)]
      guard slice.allSatisfy({ $0.utf8.count <= limits.maxLineBytes }) else {
        throw ArchiveError.lineTooLong
      }
      try handle.write(contentsOf: Data((slice.joined(separator: "\n") + "\n").utf8))
    }
    clipCount += lines.count
  }

  private func appendLine(_ line: Data) throws {
    guard line.count <= limits.maxLineBytes else { throw ArchiveError.lineTooLong }
    guard let handle = clipsHandle else { throw CocoaError(.fileWriteUnknown) }
    try handle.write(contentsOf: line)
    try handle.write(contentsOf: Data([0x0A]))
    clipCount += 1
  }

  /// Writes `library.json` and the manifest (last), then renames the
  /// package into place.
  @discardableResult
  public func finish(
    library: LibraryRecord,
    createdBy: ArchiveManifest.CreatedBy,
    skipped: ArchiveManifest.Skipped = .none,
    now: Date = Date()
  ) throws -> ArchiveManifest {
    try clipsHandle?.close()
    clipsHandle = nil

    let libraryData = try ArchiveCoding.encoder().encode(library)
    try libraryData.write(to: partial.appending(path: "library.json"), options: [.atomic])

    let clipsScan = try ArchiveHashing.scan(partial.appending(path: "clips.jsonl"))
    var entries = [
      ArchiveManifest.FileEntry(
        path: "clips.jsonl", bytes: clipsScan.bytes, sha256: clipsScan.sha256),
      ArchiveManifest.FileEntry(
        path: "library.json", bytes: libraryData.count,
        sha256: ArchiveHashing.sha256Hex(libraryData)),
    ]
    entries += attachments.values.map {
      ArchiveManifest.FileEntry(path: $0.path, bytes: $0.bytes, sha256: $0.sha256)
    }
    entries.sort { $0.path < $1.path }

    let manifest = ArchiveManifest(
      createdAt: now, createdBy: createdBy,
      counts: ArchiveManifest.Counts(
        clips: clipCount, attachments: attachments.count,
        collections: library.collections.count, tags: library.tags.count,
        savedQueries: library.savedQueries.count),
      skipped: skipped, files: entries, archiveDigest: ArchiveManifest.digest(of: entries))
    try ArchiveCoding.encoder(pretty: true).encode(manifest)
      .write(to: partial.appending(path: "manifest.json"), options: [.atomic])

    try fileManager.moveItem(at: partial, to: destination)
    finished = true
    return manifest
  }

  /// Abandons the export and removes the partial package.
  public func cancel() {
    try? clipsHandle?.close()
    clipsHandle = nil
    if !finished { try? fileManager.removeItem(at: partial) }
  }

  deinit { try? clipsHandle?.close() }
}
