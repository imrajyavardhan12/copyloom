import Foundation

/// A package that passed every integrity and safety check. Holding one means
/// the manifest is well-formed, every listed file exists with the declared
/// size and SHA-256, no symlinks are present, and limits hold.
public struct VerifiedArchive: Sendable {
  public let root: URL
  public let manifest: ArchiveManifest
  public let limits: ArchiveLimits
  /// Regular files present on disk but not in the manifest. They are never
  /// read; the importer reports them.
  public let unlistedFiles: [String]
}

/// Read-only verification of an untrusted archive. No clip content is
/// decoded and nothing is written.
public struct ArchiveVerifier: Sendable {
  public let limits: ArchiveLimits

  public init(limits: ArchiveLimits = .standard) {
    self.limits = limits
  }

  private struct Header: Decodable {
    let format: String
    let formatVersion: Int
  }

  public func verify(at root: URL) throws -> VerifiedArchive {
    let fileManager = FileManager.default
    guard Self.itemType(at: root, fileManager) == .typeDirectory else {
      throw ArchiveError.notAnArchive
    }
    let manifest = try loadManifest(root: root, fileManager: fileManager)

    guard manifest.counts.clips <= limits.maxClips else { throw ArchiveError.tooManyClips }
    guard manifest.files.count <= limits.maxFiles else { throw ArchiveError.tooManyFiles }

    let listed = try validateEntries(manifest)
    guard ArchiveManifest.digest(of: manifest.files) == manifest.archiveDigest else {
      throw ArchiveError.archiveDigestMismatch
    }

    for entry in manifest.files {
      try verifyFile(entry, root: root, fileManager: fileManager, clipCount: manifest.counts.clips)
    }
    let unlisted = try findUnlistedFiles(root: root, listed: listed, fileManager: fileManager)
    return VerifiedArchive(
      root: root, manifest: manifest, limits: limits, unlistedFiles: unlisted)
  }

  // MARK: - Manifest

  private func loadManifest(root: URL, fileManager: FileManager) throws -> ArchiveManifest {
    let opened: ArchiveFileAccess.Opened
    do {
      opened = try ArchiveFileAccess.open(root: root, relativePath: "manifest.json")
    } catch ArchiveError.missingFile {
      // Distinguish "no manifest" (an incomplete archive) from other failures.
      throw ArchiveError.missingManifest
    }
    defer { try? opened.handle.close() }
    // Size comes from fstat on the descriptor that is read, so a file
    // swapped in after this check cannot be larger than what was approved.
    guard opened.size <= limits.maxManifestBytes else { throw ArchiveError.manifestTooLarge }
    let data = try ArchiveFileAccess.readExactly(
      opened.handle, count: opened.size, path: "manifest.json")
    let decoder = ArchiveCoding.decoder()
    // Peek at identity before decoding the rest, so a manifest from a newer
    // format reports "unsupported version" instead of a decode failure.
    guard let header = try? decoder.decode(Header.self, from: data) else {
      throw ArchiveError.invalidManifest
    }
    guard header.format == ArchiveFormat.identifier else { throw ArchiveError.notAnArchive }
    guard header.formatVersion >= 1 else { throw ArchiveError.invalidManifest }
    guard header.formatVersion <= ArchiveFormat.version else {
      throw ArchiveError.unsupportedVersion(header.formatVersion)
    }
    guard let manifest = try? decoder.decode(ArchiveManifest.self, from: data) else {
      throw ArchiveError.invalidManifest
    }
    return manifest
  }

  /// Structural checks that need no file access.
  private func validateEntries(_ manifest: ArchiveManifest) throws -> Set<String> {
    var seen = Set<String>()
    var attachmentCount = 0
    var hasClips = false
    var hasLibrary = false
    for entry in manifest.files {
      guard let parsed = ArchivePath.parse(entry.path) else {
        throw ArchiveError.invalidPath(entry.path)
      }
      guard seen.insert(entry.path).inserted else { throw ArchiveError.duplicatePath(entry.path) }
      guard entry.bytes >= 0, entry.sha256.count == 64 else {
        throw ArchiveError.invalidPath(entry.path)
      }
      switch parsed {
      case .clips:
        hasClips = true
        guard entry.bytes <= limits.maxClipsFileBytes else {
          throw ArchiveError.fileTooLarge(entry.path)
        }
      case .library:
        hasLibrary = true
        guard entry.bytes <= limits.maxLibraryBytes else {
          throw ArchiveError.fileTooLarge(entry.path)
        }
      case .attachment(let sha256, _):
        // The path commits to the content: it must agree with the digest.
        guard sha256 == entry.sha256 else { throw ArchiveError.invalidPath(entry.path) }
        guard entry.bytes <= limits.maxAttachmentBytes else {
          throw ArchiveError.attachmentTooLarge(entry.path)
        }
        attachmentCount += 1
      }
    }
    guard hasClips else { throw ArchiveError.missingRequiredFile("clips.jsonl") }
    guard hasLibrary else { throw ArchiveError.missingRequiredFile("library.json") }
    guard attachmentCount == manifest.counts.attachments else {
      throw ArchiveError.countMismatch("attachments")
    }
    return seen
  }

  // MARK: - Files

  private func verifyFile(
    _ entry: ArchiveManifest.FileEntry, root: URL, fileManager: FileManager, clipCount: Int
  ) throws {
    // Open without following a link at any level, then check size and hash
    // on the same descriptor: what is verified is exactly what was opened.
    let opened = try ArchiveFileAccess.open(root: root, relativePath: entry.path)
    defer { try? opened.handle.close() }
    guard opened.size == entry.bytes else { throw ArchiveError.sizeMismatch(entry.path) }
    let scan = try ArchiveHashing.scan(handle: opened.handle)
    guard scan.bytes == entry.bytes else { throw ArchiveError.sizeMismatch(entry.path) }
    guard scan.sha256 == entry.sha256 else { throw ArchiveError.digestMismatch(entry.path) }
    if ArchivePath.parse(entry.path) == .clips {
      guard scan.longestLine <= limits.maxLineBytes else { throw ArchiveError.lineTooLong }
      guard scan.lineCount == clipCount else { throw ArchiveError.countMismatch("clips") }
    }
  }

  /// Walks the whole tree without following links. Any symlink fails the
  /// archive; unlisted regular files are only reported.
  ///
  /// Enumerates from the `realpath` of the root: `FileManager` reports
  /// `/private/var/...` for a root given as `/var/...`, and
  /// `resolvingSymlinksInPath()` does not close that gap (it special-cases
  /// `/var`). An entry whose path does not sit under the root is an error,
  /// never skipped, so this check cannot silently turn into a no-op.
  private func findUnlistedFiles(
    root: URL, listed: Set<String>, fileManager: FileManager
  ) throws -> [String] {
    guard let canonicalRoot = Self.canonicalPath(of: root) else { throw ArchiveError.notAnArchive }
    guard
      let enumerator = fileManager.enumerator(
        at: URL(fileURLWithPath: canonicalRoot, isDirectory: true),
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [])
    else {
      throw ArchiveError.notAnArchive
    }
    let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
    var unlisted: [String] = []
    var visited = 0
    for case let url as URL in enumerator {
      visited += 1
      guard visited <= limits.maxFiles * 2 else { throw ArchiveError.tooManyFiles }
      guard url.path.hasPrefix(prefix) else {
        throw ArchiveError.invalidPath(url.lastPathComponent)
      }
      let relative = String(url.path.dropFirst(prefix.count))
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      if values.isSymbolicLink == true { throw ArchiveError.symlinkNotAllowed(relative) }
      if values.isRegularFile == true, relative != "manifest.json", !listed.contains(relative) {
        unlisted.append(relative)
      }
    }
    return unlisted.sorted()
  }

  private static func canonicalPath(of url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  // MARK: - Filesystem helpers (lstat semantics: never follow links)

  static func itemType(at url: URL, _ fileManager: FileManager) -> FileAttributeType? {
    (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
  }
}
