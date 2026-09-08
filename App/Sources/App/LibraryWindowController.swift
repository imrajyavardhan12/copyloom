import AppKit
import LibraryFeature
import SwiftUI

/// AppKit-managed Library window hosting the SwiftUI Library view.
///
/// A SwiftUI `Window` scene paired with `openWindow` was tried first and
/// reverted: the only messengers available to a menu-bar app (menu-view
/// observers) exist solely while the menu is open, so a hotkey fired with
/// the menu closed reached nobody. Owning the window here keeps one
/// always-live path, mirroring `QuickPastePanelController`.
@MainActor
final class LibraryWindowController {
  private let window: NSWindow

  init(model: LibraryModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Copyloom Library"
    window.contentView = NSHostingView(rootView: LibraryView(model: model))
    window.center()
    window.setFrameAutosaveName("CopyloomLibrary")
    window.isReleasedWhenClosed = false
    self.window = window
  }

  var isVisible: Bool { window.isVisible }

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    // A library summon is a destination switch, unlike Quick Paste's
    // focus-preserving panel: activation is intended here.
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  func hide() {
    window.orderOut(nil)
  }
}
