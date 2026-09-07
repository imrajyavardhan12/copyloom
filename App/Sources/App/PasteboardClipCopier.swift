import AppKit
import ClipDomain
import ClipboardCapture

@MainActor
final class PasteboardClipCopier {
  enum CopyError: Error {
    case writeFailed
  }

  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func copy(_ clip: ClipSummary, plainText: Bool = false) throws {
    let item = NSPasteboardItem()
    item.setString(clip.text, forType: .string)
    Self.mark(item, sourceBundleID: clip.source?.bundleIdentifier)

    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      throw CopyError.writeFailed
    }
  }

  /// Writes image bytes with the same loop-suppression and provenance
  /// markers as text, so pasting an image never re-captures it.
  func copyImage(_ data: Data, uti: String, sourceBundleID: String?) throws {
    let item = NSPasteboardItem()
    item.setData(data, forType: NSPasteboard.PasteboardType(uti))
    Self.mark(item, sourceBundleID: sourceBundleID)

    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      throw CopyError.writeFailed
    }
  }

  private static func mark(_ item: NSPasteboardItem, sourceBundleID: String?) {
    item.setData(
      Data(),
      forType: NSPasteboard.PasteboardType(PasteboardTypeIdentifier.ownWrite)
    )
    item.setString(
      sourceBundleID ?? "",
      forType: NSPasteboard.PasteboardType(PasteboardTypeIdentifier.source)
    )
  }
}
