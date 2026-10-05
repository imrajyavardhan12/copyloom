import Foundation

/// The only paths an archive may contain.
///
/// Instead of sanitizing arbitrary paths (strip `..`, resolve symlinks, ...)
/// the format whitelists exactly three shapes, so traversal, absolute paths,
/// odd separators and Unicode tricks are rejected structurally rather than by
/// a list of known-bad patterns:
///
///     clips.jsonl
///     library.json
///     attachments/<aa>/<bb>/<64 lowercase hex>.<png|tiff|jpg>   (aa, bb = first 4 hex digits)
///
/// `manifest.json` is deliberately not parseable: it never lists itself.
public enum ArchivePath: Equatable, Sendable {
  case clips
  case library
  case attachment(sha256: String, fileExtension: String)

  public static func parse(_ path: String) -> ArchivePath? {
    switch path {
    case "clips.jsonl": return .clips
    case "library.json": return .library
    default: break
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "attachments" else { return nil }
    let nameParts = parts[3].split(separator: ".", omittingEmptySubsequences: false)
    guard nameParts.count == 2 else { return nil }
    let hex = nameParts[0]
    let fileExtension = String(nameParts[1])
    guard hex.count == 64, isLowerHex(hex),
      ArchiveFormat.attachmentExtensions.contains(fileExtension),
      parts[1] == hex.prefix(2), parts[2] == hex.dropFirst(2).prefix(2)
    else {
      return nil
    }
    return .attachment(sha256: String(hex), fileExtension: fileExtension)
  }

  public static func attachmentPath(sha256: String, fileExtension: String) -> String {
    "attachments/\(sha256.prefix(2))/\(sha256.dropFirst(2).prefix(2))/\(sha256).\(fileExtension)"
  }

  private static func isLowerHex(_ text: Substring) -> Bool {
    text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }
}
