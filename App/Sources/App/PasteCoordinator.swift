import AppKit
import Carbon.HIToolbox
import ClipDomain
import CoreGraphics
import QuickPasteFeature

@MainActor
final class PasteCoordinator: ClipDelivering {
  typealias StatusHandler = @MainActor (String) -> Void

  private let copier: PasteboardClipCopier
  private let onBeforePaste: @MainActor () -> Void
  private let onStatus: StatusHandler
  private let imageLoader: @MainActor (UUID) async -> (data: Data, uti: String)?
  // Keep a strong reference for the lifetime of the panel. NSWorkspace may
  // return a short-lived wrapper that disappears if retained weakly.
  private var targetApplication: NSRunningApplication?

  init(
    copier: PasteboardClipCopier = PasteboardClipCopier(),
    onBeforePaste: @escaping @MainActor () -> Void,
    onStatus: @escaping StatusHandler,
    imageLoader: @escaping @MainActor (UUID) async -> (data: Data, uti: String)? = { _ in nil }
  ) {
    self.copier = copier
    self.onBeforePaste = onBeforePaste
    self.onStatus = onStatus
    self.imageLoader = imageLoader
  }

  var hasPostEventAccess: Bool {
    CGPreflightPostEventAccess()
  }

  func prepare(targetApplication: NSRunningApplication?) {
    guard targetApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
      self.targetApplication = nil
      return
    }
    self.targetApplication = targetApplication
  }

  func deliver(_ clip: ClipSummary, mode: ClipDeliveryMode) async throws {
    let preparedTarget = targetApplication
    defer { targetApplication = nil }
    if clip.kind == .image {
      // Plain-text mode has no distinct meaning for images; both deliver bytes.
      guard let image = await imageLoader(clip.id) else {
        onStatus("Copied; the image file is no longer available.")
        return
      }
      try copier.copyImage(
        image.data, uti: image.uti, sourceBundleID: clip.source?.bundleIdentifier)
    } else {
      try copier.copy(clip, plainText: mode == .plainText)
    }

    guard mode != .copyOnly else {
      onStatus("Copied to the clipboard.")
      return
    }
    guard let targetApplication = preparedTarget, !targetApplication.isTerminated else {
      onStatus("Copied; the original application is no longer available.")
      return
    }
    guard hasPostEventAccess else {
      onBeforePaste()
      onStatus("Copied. Enable Automatic Paste from the Copyloom menu.")
      return
    }

    onBeforePaste()
    guard targetApplication.activate(options: []) else {
      onStatus("Copied; Copyloom could not reactivate the original application.")
      return
    }
    guard await waitUntilFrontmost(targetApplication) else {
      onStatus("Copied; the original application did not become active in time.")
      return
    }

    // A nonactivating panel can make the target app remain frontmost while its
    // text field is not yet key again. Give AppKit one short focus-settling
    // window before posting Command-V, then verify the target did not change.
    try? await Task.sleep(for: .milliseconds(120))
    guard
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        == targetApplication.processIdentifier
    else {
      onStatus("Copied; focus changed before automatic paste.")
      return
    }
    guard CGPreflightPostEventAccess() else {
      onStatus("Copied; Accessibility permission is no longer available.")
      return
    }

    try postPasteKeystroke()
    onStatus(mode == .plainText ? "Pasted as plain text." : "Pasted into the original application.")
  }

  @discardableResult
  func requestPostEventAccess() -> Bool {
    guard !hasPostEventAccess else {
      onStatus("Automatic paste is enabled.")
      return true
    }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Enable Automatic Paste?"
    alert.informativeText = """
      Copyloom can copy without permission. To paste the selected clip into the application you were using, macOS requires Accessibility permission so Copyloom can send Command-V.

      Copyloom does not use this permission to monitor your keyboard. You can continue using Command-Return for copy-only behavior.
      """
    alert.addButton(withTitle: "Open Accessibility Settings")
    alert.addButton(withTitle: "Copy Only")
    guard alert.runModal() == .alertFirstButtonReturn else {
      onStatus("Automatic paste remains disabled; copy-only still works.")
      return false
    }

    let granted = CGRequestPostEventAccess()
    onStatus(
      granted
        ? "Automatic paste is enabled."
        : "Enable Copyloom in System Settings → Privacy & Security → Accessibility."
    )
    return granted
  }

  private func waitUntilFrontmost(_ target: NSRunningApplication) async -> Bool {
    for _ in 0..<20 {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
      guard !Task.isCancelled else { return false }
    }
    return false
  }

  private func postPasteKeystroke() throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(kVK_ANSI_V),
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(kVK_ANSI_V),
        keyDown: false
      )
    else {
      throw PasteError.unableToCreateEvent
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cgSessionEventTap)
    keyUp.post(tap: .cgSessionEventTap)
  }
}

private enum PasteError: Error {
  case unableToCreateEvent
}
