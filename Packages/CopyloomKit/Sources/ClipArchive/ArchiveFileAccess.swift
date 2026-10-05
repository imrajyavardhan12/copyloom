import Darwin
import Foundation

/// Race-resistant file access for reading an archive *after* it was verified.
///
/// Verification is a point-in-time check; files can be replaced before they
/// are read. Opening by path would follow a symlink swapped in since, and
/// checking size before a separate read leaves a gap. This opens each path
/// component with `openat(..., O_NOFOLLOW)` (no link is ever followed, at any
/// level) and reports the size from `fstat` on the descriptor that will be
/// read, so what is checked is exactly what is opened.
enum ArchiveFileAccess {
  struct Opened {
    let handle: FileHandle
    /// Size of the opened file, from `fstat` on its descriptor.
    let size: Int
  }

  static func open(root: URL, relativePath: String) throws -> Opened {
    let components = relativePath.split(separator: "/").map(String.init)
    guard let last = components.last else { throw ArchiveError.invalidPath(relativePath) }

    var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw failure(errno, relativePath) }

    for component in components.dropLast() {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      let code = errno
      Darwin.close(directory)
      guard next >= 0 else { throw failure(code, relativePath) }
      directory = next
    }

    let descriptor = openat(directory, last, O_RDONLY | O_NOFOLLOW)
    let code = errno
    Darwin.close(directory)
    guard descriptor >= 0 else { throw failure(code, relativePath) }

    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      Darwin.close(descriptor)
      throw ArchiveError.missingFile(relativePath)
    }
    return Opened(
      handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
      size: Int(info.st_size))
  }

  /// Reads exactly `count` bytes, looping because a single read may return
  /// fewer. Fails rather than returning short data.
  static func readExactly(_ handle: FileHandle, count: Int, path: String) throws -> Data {
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
      guard let chunk = try handle.read(upToCount: min(1 << 20, count - data.count)),
        !chunk.isEmpty
      else {
        throw ArchiveError.sizeMismatch(path)
      }
      data.append(chunk)
    }
    return data
  }

  private static func failure(_ code: Int32, _ path: String) -> ArchiveError {
    code == ELOOP ? .symlinkNotAllowed(path) : .missingFile(path)
  }
}
