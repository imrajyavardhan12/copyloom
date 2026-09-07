import CryptoKit
import Foundation

public enum AttachmentStoreError: Error, Equatable, Sendable {
  case emptyData
  case unsupportedUTI(String)
}

public struct StoredAttachment: Equatable, Sendable {
  public let sha256: Data
  public let relativePath: String
  public let byteCount: Int

  public init(sha256: Data, relativePath: String, byteCount: Int) {
    self.sha256 = sha256
    self.relativePath = relativePath
    self.byteCount = byteCount
  }
}

/// Content-addressed image file store rooted at `Attachments/v1`.
///
/// Paths embed the layout version (`v1/` is the store root itself), so a
/// future layout migrates by version prefix instead of a directory walk.
/// Writes are atomic (private temp file + rename); duplicate bytes reuse the
/// existing file. Metadata lives in SQLite; this type only moves bytes.
public struct AttachmentStore: @unchecked Sendable {
  private static let fileExtensionsByUTI = [
    "public.png": "png",
    "public.tiff": "tiff",
    "public.jpeg": "jpg",
  ]

  public static var supportedUTIs: Set<String> {
    Set(fileExtensionsByUTI.keys)
  }

  public static func fileExtension(forUTI uti: String) -> String? {
    fileExtensionsByUTI[uti.lowercased()]
  }

  public static func relativePath(digest: Data, fileExtension: String) -> String {
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let first = hex.prefix(2)
    let second = hex.dropFirst(2).prefix(2)
    return "\(first)/\(second)/\(hex).\(fileExtension)"
  }

  private let root: URL
  private let fileManager: FileManager

  public init(root: URL, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }

  public func prepare() throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  public func url(for relativePath: String) -> URL {
    root.appending(path: relativePath)
  }

  @discardableResult
  public func store(data: Data, uti: String) throws -> StoredAttachment {
    guard !data.isEmpty else { throw AttachmentStoreError.emptyData }
    guard let fileExtension = Self.fileExtension(forUTI: uti) else {
      throw AttachmentStoreError.unsupportedUTI(uti)
    }
    let digest = ImageHasher.contentDigest(data: data)
    let relativePath = Self.relativePath(digest: digest, fileExtension: fileExtension)
    let destination = url(for: relativePath)
    if fileManager.fileExists(atPath: destination.path) {
      return StoredAttachment(
        sha256: digest, relativePath: relativePath, byteCount: data.count)
    }

    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = root.appending(path: "tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
    do {
      try data.write(to: temporary, options: [.atomic])
      do {
        try fileManager.moveItem(at: temporary, to: destination)
      } catch {
        try? fileManager.removeItem(at: temporary)
        // A concurrent writer stored identical bytes first; digests match, so
        // the existing file is exactly what we would have written.
        guard fileManager.fileExists(atPath: destination.path) else { throw error }
      }
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
    return StoredAttachment(
      sha256: digest, relativePath: relativePath, byteCount: data.count)
  }

  public func data(at relativePath: String) throws -> Data {
    try Data(contentsOf: url(for: relativePath))
  }

  /// Best-effort removal; missing files are ignored so crash recovery and
  /// concurrent cleanup never fail the caller.
  public func remove(relativePaths: [String]) {
    for path in relativePaths {
      try? fileManager.removeItem(at: url(for: path))
    }
  }

  /// Deletes files that are neither referenced (`knownPaths`) nor recent.
  /// Returns the number of removed files. Empty shard directories are removed
  /// on a best-effort basis. Paths are compared relative to the store root so
  /// symlinked parents (e.g. `/var` → `/private/var` on macOS) cannot break
  /// the known-path match.
  @discardableResult
  public func reconcile(knownPaths: Set<String>, olderThan cutoff: Date) throws -> Int {
    guard fileManager.fileExists(atPath: root.path) else { return 0 }
    guard let subpaths = fileManager.subpaths(atPath: root.path) else { return 0 }

    var removed = 0
    for subpath in subpaths {
      let fileURL = root.appending(path: subpath)
      let values = try? fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .contentModificationDateKey,
      ])
      guard values?.isRegularFile == true else { continue }
      guard !knownPaths.contains(subpath) else { continue }
      guard let modified = values?.contentModificationDate, modified < cutoff else {
        continue
      }
      try? fileManager.removeItem(at: fileURL)
      removed += 1
    }
    // Best-effort shard cleanup; failures are harmless.
    if let shards = try? fileManager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    {
      for shard in shards {
        guard (try? shard.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { continue }
        let inner =
          (try? fileManager.contentsOfDirectory(
            at: shard, includingPropertiesForKeys: nil)) ?? []
        for second in inner {
          if (try? fileManager.contentsOfDirectory(
            at: second, includingPropertiesForKeys: nil))?.isEmpty == true
          {
            try? fileManager.removeItem(at: second)
          }
        }
        if (try? fileManager.contentsOfDirectory(
          at: shard, includingPropertiesForKeys: nil))?.isEmpty == true
        {
          try? fileManager.removeItem(at: shard)
        }
      }
    }
    return removed
  }
}
