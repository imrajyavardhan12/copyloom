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
  private weak var targetApplication: NSRunningApplication?

  init(
    copier: PasteboardClipCopier = PasteboardClipCopier(),
    onBeforePaste: @escaping @MainActor () -> Void,
    onStatus: @escaping StatusHandler
  ) {
    self.copier = copier
    self.onBeforePaste = onBeforePaste
    self.onStatus = onStatus
  }

  func prepare(targetApplication: NSRunningApplication?) {
    guard targetApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
      self.targetApplication = nil
      return
    }
    self.targetApplication = targetApplication
  }

  func deliver(_ clip: ClipSummary, mode: ClipDeliveryMode) async throws {
    try copier.copy(clip, plainText: mode == .plainText)

    guard mode != .copyOnly else {
      onStatus("Copied to the clipboard.")
      return
    }
    guard let targetApplication, !targetApplication.isTerminated else {
      onStatus("Copied; the original application is no longer available.")
      return
    }
    guard ensurePostEventAccess() else {
      onBeforePaste()
      onStatus("Copied. Accessibility is required for automatic paste.")
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
    guard CGPreflightPostEventAccess() else {
      onStatus("Copied; Accessibility permission is no longer available.")
      return
    }

    try postPasteKeystroke()
    onStatus(mode == .plainText ? "Pasted as plain text." : "Pasted into the original application.")
  }

  private func ensurePostEventAccess() -> Bool {
    guard !CGPreflightPostEventAccess() else { return true }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Enable Automatic Paste?"
    alert.informativeText = """
      Copyloom can copy without permission. To paste the selected clip into the application you were using, macOS requires Accessibility permission so Copyloom can send Command-V.

      Copyloom does not use this permission to monitor your keyboard. You can continue using Command-Return for copy-only behavior.
      """
    alert.addButton(withTitle: "Open Accessibility Settings")
    alert.addButton(withTitle: "Copy Only")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    return CGRequestPostEventAccess()
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
