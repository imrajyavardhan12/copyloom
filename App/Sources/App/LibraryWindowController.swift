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
///
/// The window is created on first use, not in `init`. `AppModel` is built
/// inside the App's own state graph, and `setFrameAutosaveName` restores a
/// saved frame that differs from the default, which forces a SwiftUI layout.
/// Doing that mid-`init` is a nested graph update and aborts the process
/// (reproduced whenever the saved size differed from the default).
@MainActor
final class LibraryWindowController {
  private let model: LibraryModel
  private var window: NSWindow?

  init(model: LibraryModel) {
    self.model = model
  }

  var isVisible: Bool { window?.isVisible ?? false }

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    // A library summon is a destination switch, unlike Quick Paste's
    // focus-preserving panel: activation is intended here.
    NSApp.activate()
    ensureWindow().makeKeyAndOrderFront(nil)
  }

  func hide() {
    window?.orderOut(nil)
  }

  private func ensureWindow() -> NSWindow {
    if let window { return window }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Copyloom Library"
    window.contentView = NSHostingView(rootView: LibraryView(model: model))
    window.minSize = NSSize(width: 880, height: 520)
    window.center()
    window.setFrameAutosaveName("CopyloomLibrary")
    window.isReleasedWhenClosed = false
    self.window = window
    return window
  }
}
