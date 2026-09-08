import AppKit
import Carbon.HIToolbox
import ClipDomain
import QuickPasteFeature
import SwiftUI
import os

@MainActor
final class QuickPastePanelController {
  private let panel: QuickPastePanel
  private let model: QuickPasteModel
  private let pasteCoordinator: PasteCoordinator

  init(
    repository: any ClipRepository,
    onDeliveryStatus: @escaping PasteCoordinator.StatusHandler
  ) {
    let panel = QuickPastePanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.panel = panel
    let pasteCoordinator = PasteCoordinator(
      onBeforePaste: { [weak panel] in panel?.orderOut(nil) },
      onStatus: onDeliveryStatus,
      imageLoader: { [repository] id in
        guard let meta = try? await repository.attachment(for: id),
          let data = try? await repository.attachmentData(for: id)
        else {
          return nil
        }
        return (data, meta.uti)
      }
    )
    self.pasteCoordinator = pasteCoordinator
    model = QuickPasteModel(
      repository: repository,
      delivery: pasteCoordinator,
      onDismiss: { [weak panel] in panel?.orderOut(nil) }
    )

    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.animationBehavior = .utilityWindow
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.onKeyEvent = { [weak self] event in
      self?.handleKeyEvent(event) ?? false
    }
  }

  var isVisible: Bool { panel.isVisible }
  var hasPostEventAccess: Bool { pasteCoordinator.hasPostEventAccess }

  @discardableResult
  func requestPostEventAccess() -> Bool {
    pasteCoordinator.requestPostEventAccess()
  }

  func toggle(targetApplication: NSRunningApplication?) {
    isVisible ? hide() : show(targetApplication: targetApplication)
  }

  func show(targetApplication: NSRunningApplication?) {
    let start = CFAbsoluteTimeGetCurrent()
    pasteCoordinator.prepare(targetApplication: targetApplication)
    panel.contentView = NSHostingView(rootView: QuickPasteView(model: model))
    positionOnActiveScreen()
    panel.orderFrontRegardless()
    panel.makeKey()
    // Numeric-only performance telemetry for the M2 warm-open evidence.
    // No clip content, queries, or identifiers are logged.
    os_log(
      "quickpaste panel-show %.2fms", log: .quickPaste, type: .default,
      (CFAbsoluteTimeGetCurrent() - start) * 1_000)
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func positionOnActiveScreen() {
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouseLocation) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let visibleFrame = screen?.visibleFrame else { return }
    let panelFrame = panel.frame
    let origin = NSPoint(
      x: visibleFrame.midX - panelFrame.width / 2,
      y: visibleFrame.maxY - panelFrame.height - 64
    )
    panel.setFrameOrigin(origin)
  }

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if modifiers.contains(.command),
      let characters = event.charactersIgnoringModifiers,
      let number = Int(characters),
      (1...9).contains(number)
    {
      model.select(index: number - 1)
      Task { await model.activateSelected() }
      return true
    }

    switch Int(event.keyCode) {
    case kVK_UpArrow:
      model.moveSelection(by: -1)
      return true
    case kVK_DownArrow:
      model.moveSelection(by: 1)
      return true
    case kVK_Return, kVK_ANSI_KeypadEnter:
      let mode: ClipDeliveryMode
      if modifiers.contains(.command) {
        mode = .copyOnly
      } else if modifiers.contains(.option) {
        mode = .plainText
      } else {
        mode = .primary
      }
      Task { await model.activateSelected(mode: mode) }
      return true
    case kVK_Escape:
      hide()
      return true
    case kVK_ANSI_P where modifiers.contains(.command):
      Task { await model.togglePinSelected() }
      return true
    case kVK_ANSI_F where modifiers.contains(.command):
      Task { await model.toggleFavoriteSelected() }
      return true
    case kVK_Delete where modifiers.contains(.option) || modifiers.contains(.command):
      Task { await model.deleteSelected() }
      return true
    default:
      return false
    }
  }
}

private final class QuickPastePanel: NSPanel {
  var onKeyEvent: ((NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, onKeyEvent?(event) == true {
      return
    }
    super.sendEvent(event)
  }
}

extension OSLog {
  fileprivate static let quickPaste = OSLog(
    subsystem: "io.github.imrajyavardhan12.copyloom", category: "QuickPaste")
}
