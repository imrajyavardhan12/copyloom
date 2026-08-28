import AppKit
import ClipDomain
import ClipStore
import ClipboardCapture
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  private(set) var captureEnabled: Bool
  private(set) var capturePaused: Bool
  private(set) var clipCount = 0
  private(set) var statusText: String
  private(set) var lastEventText: String?

  @ObservationIgnored private let preferences: CapturePreferencesStore
  @ObservationIgnored private var database: AppDatabase?
  @ObservationIgnored private var captureService: ClipboardCaptureService?
  @ObservationIgnored private var monitor: PasteboardPollingMonitor?
  @ObservationIgnored private var quickPasteController: QuickPastePanelController?
  @ObservationIgnored private var globalHotKey: GlobalHotKey?

  init(defaults: UserDefaults = .standard) {
    let preferences = CapturePreferencesStore(defaults: defaults)
    let initialCaptureEnabled = preferences.captureEnabled
    let initialCapturePaused = initialCaptureEnabled && preferences.capturePaused
    self.preferences = preferences
    captureEnabled = initialCaptureEnabled
    capturePaused = initialCapturePaused
    statusText =
      initialCaptureEnabled
      ? (initialCapturePaused ? "Capture is paused" : "Monitoring clipboard")
      : "Capture is off"

    do {
      let database = try AppDatabase.open(at: Self.databaseURL())
      self.database = database
      let service = ClipboardCaptureService(
        pasteboard: NSPasteboardReader(),
        repository: database.repository,
        configuration: preferences.configuration
      )
      captureService = service
      monitor = PasteboardPollingMonitor(service: service) { [weak self] outcome in
        self?.handle(outcome)
      }
      let quickPasteController = QuickPastePanelController(
        repository: database.repository,
        onDeliveryStatus: { [weak self] status in
          self?.lastEventText = status
        }
      )
      self.quickPasteController = quickPasteController
      do {
        globalHotKey = try GlobalHotKey { [weak self] in
          self?.toggleQuickPaste()
        }
      } catch {
        lastEventText = "The ⌃⌘V shortcut is unavailable; use the Copyloom menu."
      }
      if captureEnabled && !capturePaused {
        monitor?.start()
      }
      refreshClipCount()
    } catch {
      captureEnabled = false
      capturePaused = false
      statusText = "Storage unavailable — capture is off"
      lastEventText = "Copyloom preserved the database and did not start capture."
    }
  }

  func enableCapture() {
    guard captureService != nil else { return }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Enable Clipboard Capture?"
    alert.informativeText = """
      Copyloom will read new clipboard changes and save accepted history locally. Protected clipboard markers and high-confidence secrets are skipped before storage. No clipboard content leaves this Mac.

      On newer macOS versions, allow pasteboard access when the system asks. You can pause or disable capture at any time.
      """
    alert.addButton(withTitle: "Enable Capture")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    captureEnabled = true
    capturePaused = false
    preferences.captureEnabled = true
    preferences.capturePaused = false
    applyConfiguration()
    captureService?.adoptCurrentChangeCount()
    monitor?.start()
    statusText = "Monitoring clipboard"
    lastEventText = "Waiting for the next copy."
  }

  func disableCapture() {
    monitor?.stop()
    captureService?.adoptCurrentChangeCount()
    captureEnabled = false
    capturePaused = false
    preferences.captureEnabled = false
    preferences.capturePaused = false
    applyConfiguration()
    statusText = "Capture is off"
    lastEventText = nil
  }

  func togglePause() {
    guard captureEnabled else { return }
    capturePaused.toggle()
    preferences.capturePaused = capturePaused
    applyConfiguration()

    if capturePaused {
      monitor?.stop()
      captureService?.adoptCurrentChangeCount()
      statusText = "Capture is paused"
      lastEventText = nil
    } else {
      captureService?.adoptCurrentChangeCount()
      monitor?.start()
      statusText = "Monitoring clipboard"
      lastEventText = "Copies made while paused were not captured."
    }
  }

  func ignoreNextCopy() {
    guard captureEnabled && !capturePaused else { return }
    captureService?.ignoreNextCopy()
    lastEventText = "The next clipboard change will be ignored."
  }

  func toggleQuickPaste() {
    quickPasteController?.toggle(
      targetApplication: NSWorkspace.shared.frontmostApplication
    )
  }

  func shutdown() {
    monitor?.stop()
    quickPasteController?.hide()
    globalHotKey = nil
    try? database?.close()
  }

  private func applyConfiguration() {
    captureService?.updateConfiguration(preferences.configuration)
  }

  private func handle(_ outcome: CaptureOutcome) {
    switch outcome {
    case .noChange:
      break
    case .captured(let clip):
      statusText = "Monitoring clipboard"
      let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier
      lastEventText =
        source.map { "Captured \(clip.kind.label) from \($0)." }
        ?? "Captured \(clip.kind.label)."
      refreshClipCount()
    case .skipped(.accessDenied):
      statusText = "Clipboard access is denied"
      lastEventText = "Allow Copyloom under Privacy & Security → Paste from Other Apps."
    case .skipped(.concealed), .skipped(.transient), .skipped(.autoGenerated):
      lastEventText = "Protected clipboard content was not saved."
    case .skipped(.sensitiveContent):
      lastEventText = "Sensitive content was not saved."
    case .skipped(.ignoredApplication):
      lastEventText = "A copy from an ignored application was not saved."
    case .skipped(.tooLarge):
      lastEventText = "Clipboard text exceeded the safety limit and was not saved."
    case .skipped(.ignoredNextCopy):
      lastEventText = "Clipboard change ignored."
    case .skipped(.emptyText), .skipped(.unsupportedType), .skipped(.ownWrite),
      .skipped(.inconsistentSnapshot):
      break
    case .skipped(.disabled), .skipped(.paused):
      break
    case .failed(.storage):
      statusText = "Capture encountered a storage error"
      lastEventText = "Capture is still running; no clipboard content was logged."
    }
  }

  private func refreshClipCount() {
    guard let repository = database?.repository else { return }
    Task { [weak self] in
      do {
        let count = try await repository.count()
        guard !Task.isCancelled else { return }
        self?.clipCount = count
      } catch {
        self?.statusText = "Unable to read local history"
      }
    }
  }

  private static func databaseURL() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = applicationSupport.appending(path: "Copyloom", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "history.sqlite")
  }
}

@MainActor
private final class CapturePreferencesStore {
  private enum Key {
    static let captureEnabled = "capture.enabled"
    static let capturePaused = "capture.paused"
    static let ignoredBundleIdentifiers = "capture.ignoredBundleIdentifiers"
  }

  private static let defaultIgnoredBundleIdentifiers: Set<String> = [
    "com.1password.1password",
    "com.apple.keychainaccess",
    "com.apple.passwords",
    "com.bitwarden.desktop",
    "in.sinew.enpass-desktop",
    "org.keepassxc.keepassxc",
  ]

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  var captureEnabled: Bool {
    get { defaults.object(forKey: Key.captureEnabled) as? Bool ?? false }
    set { defaults.set(newValue, forKey: Key.captureEnabled) }
  }

  var capturePaused: Bool {
    get { defaults.object(forKey: Key.capturePaused) as? Bool ?? false }
    set { defaults.set(newValue, forKey: Key.capturePaused) }
  }

  var ignoredBundleIdentifiers: Set<String> {
    guard let stored = defaults.array(forKey: Key.ignoredBundleIdentifiers) as? [String] else {
      return Self.defaultIgnoredBundleIdentifiers
    }
    return Set(stored.map { $0.lowercased() })
  }

  var configuration: CaptureConfiguration {
    CaptureConfiguration(
      isEnabled: captureEnabled,
      isPaused: capturePaused,
      ignoredBundleIdentifiers: ignoredBundleIdentifiers
    )
  }
}

extension ClipKind {
  fileprivate var label: String {
    switch self {
    case .text: "text"
    case .link: "link"
    }
  }
}
