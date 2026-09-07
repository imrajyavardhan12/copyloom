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

      if model.automaticPasteEnabled {
        Label("Automatic Paste Enabled", systemImage: "checkmark.circle")
      } else {
        Button("Enable Automatic Paste…") {
          model.requestAutomaticPastePermission()
        }
      }

      Divider()

      if model.captureEnabled {
        Button(model.capturePaused ? "Resume Capture" : "Pause Capture") {
          model.togglePause()
        }

        Button("Ignore Next Copy") {
          model.ignoreNextCopy()
        }
        .disabled(model.capturePaused)

        Button("Delete Expired History (\(model.retentionDays)d, keeps pinned/favorites)…") {
          model.deleteExpiredNow()
        }

        Button("Turn Off Capture") {
          model.disableCapture()
        }
      } else {
        Button("Enable Clipboard Capture…") {
          model.enableCapture()
        }
      }

      Divider()

      Text("Ignoring \(model.ignoredAppCount) apps · keeps history \(model.retentionDays) days")
        .foregroundStyle(.secondary)

      Button("Reveal Running App in Finder") {
        model.revealRunningAppInFinder()
      }
      .help(model.runningAppPath)

      Text(model.runningAppPath)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)

      Divider()

      Button("Quit Copyloom") {
        model.shutdown()
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      Image(systemName: "clipboard")
        .accessibilityLabel("Copyloom")
    }
    .menuBarExtraStyle(.menu)
  }
}
