import AppKit
import LibraryFeature

/// The user-facing steps around an export: say what will happen, let the
/// user pick a folder, run the export, report the result. The work itself
/// (privacy gates, quarantine skipping, atomic write) lives in the package.
@MainActor
enum LibraryExportFlow {
  static func start(model: LibraryModel) {
    guard model.exportState != .running else { return }
    guard confirm() else { return }
    guard let folder = chooseFolder() else { return }
    let destination = uniqueDestination(in: folder)
    Task { @MainActor in
      await model.exportLibrary(to: destination)
      present(model.exportState, destination: destination)
      model.dismissExportResult()
    }
  }

  // MARK: - Steps

  private static func confirm() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Export Library?"
    alert.informativeText = """
      Copyloom will save your clips, images, collections and tags to a new folder you choose.

      The export is not encrypted. Anyone who can open that folder can read your clips. Clips that look sensitive, and images whose text was withheld, are left out.
      """
    alert.addButton(withTitle: "Choose Folder…")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Export Here"
    panel.message = "Choose where to save the export folder."
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// A fresh name inside `folder`; the exporter never overwrites anything.
  private static func uniqueDestination(in folder: URL) -> URL {
    let stamp = Date.now.formatted(
      .verbatim(
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
        locale: .init(identifier: "en_US_POSIX"), timeZone: .current, calendar: .current))
    let base = "Copyloom Export \(stamp)"
    var candidate = folder.appending(path: base, directoryHint: .isDirectory)
    var counter = 2
    while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
      candidate = folder.appending(path: "\(base) \(counter)", directoryHint: .isDirectory)
      counter += 1
    }
    return candidate
  }

  private static func present(_ state: LibraryExportState, destination: URL) {
    switch state {
    case .finished(let summary, let name):
      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = "Export Complete"
      alert.informativeText = describe(summary, name: name)
      alert.addButton(withTitle: "Reveal in Finder")
      alert.addButton(withTitle: "Done")
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      }
    case .failed(let message):
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Export Failed"
      alert.informativeText = message
      alert.runModal()
    case .idle, .running, .cancelled:
      break
    }
  }

  private static func describe(_ summary: LibraryExportSummary, name: String) -> String {
    var lines = ["Saved \(summary.clips) clips (\(summary.attachments) images) to “\(name)”."]
    if summary.skippedTotal > 0 {
      var skipped: [String] = []
      if summary.skippedSensitive > 0 {
        skipped.append("\(summary.skippedSensitive) that looked sensitive")
      }
      if summary.skippedQuarantinedImages > 0 {
        skipped.append("\(summary.skippedQuarantinedImages) images with withheld text")
      }
      if summary.skippedMissingAttachments > 0 {
        skipped.append("\(summary.skippedMissingAttachments) with a missing image file")
      }
      lines.append("Left out: " + skipped.joined(separator: ", ") + ".")
    }
    return lines.joined(separator: "\n\n")
  }
}
