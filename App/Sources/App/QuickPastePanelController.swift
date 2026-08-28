import AppKit
import Carbon.HIToolbox
import ClipDomain
import QuickPasteFeature
import SwiftUI

@MainActor
final class QuickPastePanelController {
  private let panel: QuickPastePanel
  private let model: QuickPasteModel

  init(repository: any ClipRepository) {
    let panel = QuickPastePanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.panel = panel
    model = QuickPasteModel(
      repository: repository,
      copier: PasteboardClipCopier(),
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

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    panel.contentView = NSHostingView(rootView: QuickPasteView(model: model))
    positionOnActiveScreen()
    panel.orderFrontRegardless()
    panel.makeKey()
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
      Task { await model.activateSelected() }
      return true
    case kVK_Escape:
      hide()
      return true
    case kVK_ANSI_P where modifiers.contains(.command):
      Task { await model.togglePinSelected() }
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
