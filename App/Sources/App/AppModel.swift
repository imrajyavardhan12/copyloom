import AppKit
import Carbon.HIToolbox
import ClipDomain
import ClipStore
import ClipboardCapture
import Foundation
import LibraryFeature
import Observation

@MainActor
@Observable
final class AppModel {
  private(set) var captureEnabled: Bool
  private(set) var capturePaused: Bool
  private(set) var clipCount = 0
  private(set) var automaticPasteEnabled = false
  private(set) var statusText: String
  private(set) var lastEventText: String?
  private(set) var retentionDays: Int = CaptureSettings.defaultRetentionDays
  private(set) var ignoredAppCount = 0
  private(set) var ignoredBundleIdentifiers: [String] = []

  @ObservationIgnored private let settingsStore: CaptureSettingsStore
  @ObservationIgnored private var settings: CaptureSettings
  @ObservationIgnored private var database: AppDatabase?
  @ObservationIgnored private var captureService: ClipboardCaptureService?
  @ObservationIgnored private var monitor: PasteboardPollingMonitor?
  @ObservationIgnored private var quickPasteController: QuickPastePanelController?
  @ObservationIgnored private var libraryWindowController: LibraryWindowController?
  @ObservationIgnored private var globalHotKey: GlobalHotKey?
  @ObservationIgnored private var libraryHotKey: GlobalHotKey?
  private(set) var libraryModel: LibraryModel?

  init(defaults: UserDefaults = .standard) {
    let store = CaptureSettingsStore(defaults: defaults)
    let loaded = store.load()
    settingsStore = store
    settings = loaded.settings
    retentionDays = loaded.settings.retentionDays
    ignoredAppCount = loaded.settings.ignoredBundleIdentifiers.count
    ignoredBundleIdentifiers = loaded.settings.ignoredBundleIdentifiers.sorted()

    let initialCaptureEnabled = loaded.settings.captureEnabled
    let initialCapturePaused = initialCaptureEnabled && loaded.settings.capturePaused
    captureEnabled = initialCaptureEnabled
    capturePaused = initialCapturePaused
    if loaded.didFailClosed {
      statusText = "Settings invalid — capture is off"
      lastEventText =
        loaded.errorDescription
        ?? "Capture settings were unreadable. Exclusions were restored to safe defaults."
    } else {
      statusText =
        initialCaptureEnabled
        ? (initialCapturePaused ? "Capture is paused" : "Monitoring clipboard")
        : "Capture is off"
    }

    do {
      let database = try AppDatabase.open(at: Self.databaseURL())
      self.database = database
      let service = ClipboardCaptureService(
        pasteboard: NSPasteboardReader(),
        repository: database.repository,
        configuration: captureConfiguration(),
        // Slice 4 activates real image capture: the Vision gate from slice 3
        // replaces the disabled default. Images now persist after screening.
        imagePreflight: VisionImagePreflight()
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
      automaticPasteEnabled = quickPasteController.hasPostEventAccess
      let libraryModel = LibraryModel(repository: database.repository)
      self.libraryModel = libraryModel
      self.libraryWindowController = LibraryWindowController(model: libraryModel)
      do {
        globalHotKey = try GlobalHotKey { [weak self] in
          self?.toggleQuickPaste()
        }
      } catch {
        lastEventText = "The ⌃⌘V shortcut is unavailable; use the Copyloom menu."
      }
      do {
        // Separate registration so a ⌃⌘L conflict degrades to menu-only
        // Library access without disturbing the paste shortcut.
        libraryHotKey = try GlobalHotKey(registrations: [
          GlobalHotKey.Registration(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | controlKey),
            identifier: GlobalHotKey.libraryIdentifier,
            action: { [weak self] in self?.openLibrary() }
          )
        ])
      } catch {
        lastEventText =
          (lastEventText.map { $0 + " " } ?? "")
          + "The ⌃⌘L Library shortcut is unavailable; use the Copyloom menu."
      }
      if captureEnabled && !capturePaused {
        monitor?.start()
      }
      refreshClipCount()
      runRetentionCleanup()
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

    settings.captureEnabled = true
    settings.capturePaused = false
    persistSettings()
    captureEnabled = true
    capturePaused = false
    applyConfiguration()
    captureService?.adoptCurrentChangeCount()
    monitor?.start()
    statusText = "Monitoring clipboard"
    lastEventText = "Waiting for the next copy."
    runRetentionCleanup()
  }

  func disableCapture() {
    monitor?.stop()
    captureService?.adoptCurrentChangeCount()
    settings.captureEnabled = false
    settings.capturePaused = false
    persistSettings()
    captureEnabled = false
    capturePaused = false
    applyConfiguration()
    statusText = "Capture is off"
    lastEventText = nil
  }

  func togglePause() {
    guard captureEnabled else { return }
    capturePaused.toggle()
    settings.capturePaused = capturePaused
    persistSettings()
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

  // MARK: - Privacy settings (M2.6)

  func addIgnoredBundleID(_ bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return }
    settings.ignoredBundleIdentifiers.insert(trimmed)
    settings = settings.normalized()
    persistSettings()
    applyConfiguration()
    lastEventText = "Copies from \(trimmed) will not be saved."
  }

  func removeIgnoredBundleID(_ bundleID: String) {
    settings.ignoredBundleIdentifiers.remove(bundleID.lowercased())
    // Never allow an empty exclusion set to persist silently; restore defaults
    // if the user removes everything so password managers stay excluded.
    if settings.ignoredBundleIdentifiers.isEmpty {
      settings.ignoredBundleIdentifiers = CaptureSettings.defaultIgnoredBundleIdentifiers
      lastEventText = "Ignore list was empty; restored safe defaults."
    }
    settings = settings.normalized()
    persistSettings()
    applyConfiguration()
  }

  func resetIgnoredToDefaults() {
    settings.ignoredBundleIdentifiers = CaptureSettings.defaultIgnoredBundleIdentifiers
    settings = settings.normalized()
    persistSettings()
    applyConfiguration()
    lastEventText = "Ignored applications reset to safe defaults."
  }

  func updateRetentionDays(_ days: Int) {
    settings.retentionDays = days
    settings = settings.normalized()
    persistSettings()
    // Lowering the window should purge immediately, not on next launch.
    runRetentionCleanup()
  }

  func refreshPermissionStatus() {
    automaticPasteEnabled = quickPasteController?.hasPostEventAccess ?? false
  }

  func openAccessibilitySettings() {
    refreshPermissionStatus()
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) {
      NSWorkspace.shared.open(url)
    }
  }

  struct RunningAppCandidate: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    var id: String { bundleIdentifier }
  }

  func runningAppCandidates() -> [RunningAppCandidate] {
    let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()
    let ignored = Set(settings.ignoredBundleIdentifiers.map { $0.lowercased() })
    return NSWorkspace.shared.runningApplications.compactMap { app in
      guard let bundleID = app.bundleIdentifier?.lowercased(), !bundleID.isEmpty else {
        return nil
      }
      guard bundleID != ownBundleID, !ignored.contains(bundleID) else { return nil }
      let name = app.localizedName ?? bundleID
      return RunningAppCandidate(bundleIdentifier: bundleID, displayName: name)
    }
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  /// Deletes clips older than the retention window. Pinned/favorite exempt.
  /// Tombstones older than the window are hard-purged in the same pass so
  /// disk stays bounded to roughly two retention windows.
  func deleteExpiredNow() {
    guard let repository = database?.repository else { return }
    let days = settings.retentionDays
    Task { [weak self] in
      do {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3_600))
        let expired = try await repository.deleteExpired(before: cutoff)
        let purged = try await repository.purgeDeleted(before: cutoff)
        guard !Task.isCancelled else { return }
        self?.refreshClipCount()
        if expired > 0 {
          let noun = expired == 1 ? "clip" : "clips"
          var message = "Deleted \(expired) expired \(noun) older than \(days) days."
          if purged > 0 {
            message += " Purged \(purged) old deletions."
          }
          self?.lastEventText = message
        } else if purged > 0 {
          self?.lastEventText = "Purged \(purged) old deletions."
        } else {
          self?.lastEventText = "No clips older than \(days) days."
        }
      } catch {
        self?.lastEventText = "Retention cleanup failed; history was left untouched."
      }
    }
  }

  func toggleQuickPaste() {
    automaticPasteEnabled = quickPasteController?.hasPostEventAccess ?? false
    quickPasteController?.toggle(
      targetApplication: NSWorkspace.shared.frontmostApplication
    )
  }

  func openLibrary() {
    libraryWindowController?.toggle()
  }

  func requestAutomaticPastePermission() {
    // Let the status-menu click finish before presenting a modal alert. Without
    // this handoff, the originating click can activate the alert's default
    // button before the user has a chance to read the explanation.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard let self else { return }
      automaticPasteEnabled = quickPasteController?.requestPostEventAccess() ?? false
    }
  }

  /// Exact app bundle path for the running process. Ad-hoc dev builds change
  /// identity on every rebuild, so the TCC entry must match this binary.
  var runningAppPath: String {
    Bundle.main.bundlePath
  }

  func revealRunningAppInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runningAppPath)])
  }

  func shutdown() {
    monitor?.stop()
    quickPasteController?.hide()
    libraryWindowController?.hide()
    globalHotKey = nil
    libraryHotKey = nil
    try? database?.close()
  }

  private func captureConfiguration() -> CaptureConfiguration {
    CaptureConfiguration(
      isEnabled: settings.captureEnabled,
      isPaused: settings.capturePaused,
      ignoredBundleIdentifiers: settings.ignoredBundleIdentifiers
    )
  }

  private func persistSettings() {
    settingsStore.save(settings)
    retentionDays = settings.retentionDays
    ignoredAppCount = settings.ignoredBundleIdentifiers.count
    ignoredBundleIdentifiers = settings.ignoredBundleIdentifiers.sorted()
  }

  private func applyConfiguration() {
    captureService?.updateConfiguration(captureConfiguration())
  }

  private func runRetentionCleanup() {
    guard database != nil else { return }
    let days = settings.retentionDays
    Task { [weak self] in
      guard let self else { return }
      do {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3_600))
        let expired = try await self.database?.repository.deleteExpired(before: cutoff) ?? 0
        _ = try await self.database?.repository.purgeDeleted(before: cutoff)
        // Reclaim crash-orphaned attachment files on every launch-cycle pass.
        _ = try await self.database?.reconcileAttachments()
        guard !Task.isCancelled else { return }
        if expired > 0 {
          self.refreshClipCount()
        }
      } catch {
        // Leave history untouched; surface only on manual cleanup.
      }
    }
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
    case .skipped(.preflightTimeout):
      lastEventText = "An image was not saved during safety screening."
    case .skipped(.unreadableImage):
      lastEventText = "An image could not be read and was not saved."
    case .skipped(.ignoredApplication):
      lastEventText = "A copy from an ignored application was not saved."
    case .skipped(.tooLarge):
      lastEventText = "Clipboard text exceeded the safety limit and was not saved."
    case .skipped(.ignoredNextCopy):
      lastEventText = "Clipboard change ignored."
    case .skipped(.emptyText), .skipped(.emptyImage), .skipped(.unsupportedType),
      .skipped(.ownWrite),
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

extension ClipKind {
  fileprivate var label: String {
    switch self {
    case .text: "text"
    case .link: "link"
    case .image: "image"
    }
  }
}
