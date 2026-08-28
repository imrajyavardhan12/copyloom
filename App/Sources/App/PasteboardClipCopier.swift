import AppKit
import ClipDomain
import ClipboardCapture
import QuickPasteFeature

@MainActor
final class PasteboardClipCopier: ClipCopying {
  enum CopyError: Error {
    case writeFailed
  }

  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func copy(_ clip: ClipSummary) throws {
    let item = NSPasteboardItem()
    item.setString(clip.text, forType: .string)
    item.setData(
      Data(),
      forType: NSPasteboard.PasteboardType(PasteboardTypeIdentifier.ownWrite)
    )
    item.setString(
      clip.source?.bundleIdentifier ?? "",
      forType: NSPasteboard.PasteboardType(PasteboardTypeIdentifier.source)
    )

    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      throw CopyError.writeFailed
    }
  }
}
