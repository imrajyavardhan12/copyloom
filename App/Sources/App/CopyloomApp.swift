import AppKit
import SwiftUI

@main
struct CopyloomApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      Label(model.statusText, systemImage: model.capturePaused ? "pause.circle" : "clipboard")
        .accessibilityLabel(model.statusText)

      Text("\(model.clipCount) clips stored locally")

      if let lastEvent = model.lastEventText {
        Text(lastEvent)
      }

      Divider()

      Button("Open Quick Paste") {
        model.toggleQuickPaste()
      }
      .keyboardShortcut("v", modifiers: [.control, .command])

      Divider()

      if model.captureEnabled {
        Button(model.capturePaused ? "Resume Capture" : "Pause Capture") {
          model.togglePause()
        }

        Button("Ignore Next Copy") {
          model.ignoreNextCopy()
        }
        .disabled(model.capturePaused)

        Button("Turn Off Capture") {
          model.disableCapture()
        }
      } else {
        Button("Enable Clipboard Capture…") {
          model.enableCapture()
        }
      }

      Divider()

      Button("Quit Copyloom") {
        model.shutdown()
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      Label("Copyloom", systemImage: "clipboard")
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Copyloom")
    }
    .menuBarExtraStyle(.menu)
  }
}
