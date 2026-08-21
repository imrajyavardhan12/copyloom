import AppKit
import ClipStore
import SwiftUI

@main
struct CopyloomApp: App {
  var body: some Scene {
    MenuBarExtra("Copyloom", systemImage: "clipboard") {
      Label("Capture is not running yet", systemImage: "pause.circle")
        .accessibilityLabel("Clipboard capture is not running yet")

      Divider()

      Button("Quit Copyloom") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .menuBarExtraStyle(.menu)
  }
}
