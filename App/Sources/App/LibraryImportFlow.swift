import AppKit
import LibraryFeature

/// The user-facing steps around an import: pick the export folder, show what
/// importing would do (nothing is written yet), ask, run, report. The work
/// itself (verification, privacy gates, merge rules) lives in the package.
@MainActor
enum LibraryImportFlow {
  static func start(model: LibraryModel) {
    switch model.importState {
    case .checking, .importing: return
    default: break
    }
    guard let folder = chooseFolder() else { return }
    Task { @MainActor in
      await model.prepareImport(from: folder)
      guard case .confirming(let plan, let name) = model.importState else {
        presentOutcome(model.importState)
        model.dismissImportResult()
        return
      }
      guard confirm(plan, name: name) else {
        model.dismissImportResult()
        return
      }
      await model.confirmImport()
      presentOutcome(model.importState)
      model.dismissImportResult()
    }
  }

  // MARK: - Steps

  private static func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Check Export"
    panel.message = "Choose a Copyloom export folder to import."
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func confirm(_ plan: LibraryImportSummary, name: String) -> Bool {
    let atRisk = plan.retentionAtRisk > 0
    let alert = NSAlert()
    alert.alertStyle = atRisk ? .warning : .informational
    alert.messageText = "Import “\(name)”?"
    alert.informativeText = describePlan(plan)
    if atRisk {
      // The safe choice is the default one.
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Import Anyway")
      return alert.runModal() == .alertSecondButtonReturn
    }
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func presentOutcome(_ state: LibraryImportState) {
    let alert = NSAlert()
    switch state {
    case .finished(let summary, let name):
      alert.alertStyle = .informational
      alert.messageText = "Import Complete"
      alert.informativeText = describeResult(summary, name: name)
    case .cancelled:
      alert.alertStyle = .informational
      alert.messageText = "Import Stopped"
      alert.informativeText =
        "Clips imported before you stopped were kept. Run the import again to finish; clips already imported are not duplicated."
    case .failed(let message):
      alert.alertStyle = .warning
      alert.messageText = "Import Failed"
      alert.informativeText = message
    case .idle, .checking, .confirming, .importing:
      return
    }
    alert.runModal()
  }

  // MARK: - Wording

  private static func describePlan(_ plan: LibraryImportSummary) -> String {
    var lines: [String] = []
    if plan.clipsAdded == 0 {
      lines.append("There are no new clips to add.")
    } else {
      var line = "Adds \(plural(plan.clipsAdded, "clip"))"
      if plan.imagesQueuedForOCR > 0 {
        line += " (\(plural(plan.imagesQueuedForOCR, "image")))"
      }
      lines.append(line + ".")
    }
    if plan.clipsAlreadyPresent > 0 {
      lines.append(
        "\(plural(plan.clipsAlreadyPresent, "clip")) already in your library. Those are never changed, except for a pin, favorite, tag or collection they were missing."
      )
    }
    lines.append(contentsOf: extras(plan))
    if plan.rejectedTotal > 0 {
      var parts: [String] = []
      if plan.rejectedByPrivacy > 0 {
        parts.append("\(plan.rejectedByPrivacy) that Copyloom’s privacy rules would not store")
      }
      if plan.rejectedInvalid > 0 { parts.append("\(plan.rejectedInvalid) that are not valid") }
      lines.append("Left out: " + parts.joined(separator: ", ") + ".")
    }
    if plan.imagesQueuedForOCR > 0 {
      lines.append(
        "Every image is checked with the same privacy screening as a new copy, "
          + "so a large import can take a while.")
    }
    if plan.retentionAtRisk > 0 {
      let window =
        plan.retentionDays.map { "your \($0)-day history window" } ?? "your history window"
      lines.append(
        "Warning: \(plural(plan.retentionAtRisk, "of these clip")) \(plan.retentionAtRisk == 1 ? "is" : "are") older than \(window) and not pinned or favorited. Copyloom’s next cleanup would delete \(plan.retentionAtRisk == 1 ? "it" : "them"). Cancel and raise History Retention in Settings first, or pin them after importing."
      )
    }
    return lines.joined(separator: "\n\n")
  }

  private static func describeResult(_ result: LibraryImportSummary, name: String) -> String {
    var lines = [
      "Added \(plural(result.clipsAdded, "clip")) from “\(name)”; \(result.clipsAlreadyPresent) were already in your library."
    ]
    lines.append(contentsOf: extras(result))
    if result.rejectedTotal > 0 {
      lines.append("Left out: \(result.rejectedTotal) that could not be stored.")
    }
    if result.imagesQueuedForOCR > 0 {
      lines.append("Imported images are being indexed in the background.")
    }
    if result.retentionAtRisk > 0 {
      lines.append(
        "\(plural(result.retentionAtRisk, "imported clip")) \(result.retentionAtRisk == 1 ? "is" : "are") older than your history window; the next cleanup will delete \(result.retentionAtRisk == 1 ? "it" : "them") unless you pin or favorite \(result.retentionAtRisk == 1 ? "it" : "them")."
      )
    }
    return lines.joined(separator: "\n\n")
  }

  private static func extras(_ summary: LibraryImportSummary) -> [String] {
    var parts: [String] = []
    if summary.collectionsAdded > 0 {
      parts.append(plural(summary.collectionsAdded, "collection"))
    }
    if summary.queriesAdded > 0 { parts.append(plural(summary.queriesAdded, "Smart Collection")) }
    var lines: [String] = []
    if !parts.isEmpty { lines.append("Also adds " + parts.joined(separator: " and ") + ".") }
    if summary.queriesSkipped > 0 {
      lines.append(
        "\(plural(summary.queriesSkipped, "Smart Collection")) saved by a different version of the search syntax will be skipped."
      )
    }
    return lines
  }

  private static func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }
}
