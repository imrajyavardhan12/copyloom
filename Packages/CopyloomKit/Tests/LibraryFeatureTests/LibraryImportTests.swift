import ClipDomain
import Foundation
import Testing

@testable import LibraryFeature

private let plan = LibraryImportSummary(
  clipsInArchive: 12, clipsAdded: 9, clipsAlreadyPresent: 3, imagesQueuedForOCR: 2,
  rejectedByPrivacy: 1, rejectedInvalid: 0, collectionsAdded: 1, queriesAdded: 1,
  queriesSkipped: 0, retentionAtRisk: 4, unlistedFiles: 0, skippedAtExport: 2)
private let result = LibraryImportSummary(
  clipsInArchive: 12, clipsAdded: 9, clipsAlreadyPresent: 3, imagesQueuedForOCR: 2,
  rejectedByPrivacy: 1, rejectedInvalid: 0, collectionsAdded: 1, queriesAdded: 1,
  queriesSkipped: 0, retentionAtRisk: 4, unlistedFiles: 0, skippedAtExport: 2)

private let namedFailureMessages: [(LibraryImportFailure, String)] = [
  (.notAnArchive, "That folder is not a Copyloom export."),
  (.incomplete, "That export is incomplete: it has no manifest."),
  (.newerVersion, "That export was made by a newer version of Copyloom."),
  (.damaged, "That export failed its integrity check, so nothing was imported."),
  (
    .changedDuringImport,
    "That export changed while it was being imported. Clips imported before then were kept; "
      + "run the import again to finish."
  ),
]

@MainActor
@Suite("Library import")
struct LibraryImportTests {
  private let folder = URL(fileURLWithPath: "/tmp/Copyloom Export")

  private func model(
    plan planner: LibraryModel.ImportAction? = { _, _ in plan },
    apply importer: LibraryModel.ImportAction? = { _, _ in result }
  ) -> LibraryModel {
    LibraryModel(
      repository: ExportRepositoryStub(), libraryImportPlanner: planner,
      libraryImporter: importer)
  }

  @Test("checking an archive ends at a confirmation that carries the plan")
  func plans() async {
    let model = model()

    await model.prepareImport(from: folder)

    #expect(model.importState == .confirming(plan, name: "Copyloom Export"))
  }

  @Test("confirming imports and reports the result by name")
  func confirms() async {
    let model = model()
    await model.prepareImport(from: folder)

    await model.confirmImport()

    #expect(model.importState == .finished(result, name: "Copyloom Export"))
  }

  @Test("planning writes nothing: the importer is not called until confirmed")
  func planIsSeparate() async {
    let imported = Box(0)
    let model = model(apply: { _, _ in
      imported.value += 1
      return result
    })

    await model.prepareImport(from: folder)

    #expect(imported.value == 0)
  }

  @Test("both steps receive the chosen folder")
  func folderPassed() async {
    let seen = Box<[URL]>([])
    let model = model(
      plan: { url, _ in
        seen.value.append(url)
        return plan
      },
      apply: { url, _ in
        seen.value.append(url)
        return result
      })

    await model.prepareImport(from: folder)
    await model.confirmImport()

    #expect(seen.value == [folder, folder])
  }

  @Test("confirm does nothing unless a plan is waiting")
  func confirmNeedsPlan() async {
    let imported = Box(0)
    let model = model(apply: { _, _ in
      imported.value += 1
      return result
    })

    await model.confirmImport()

    #expect(model.importState == .idle)
    #expect(imported.value == 0)
  }

  @Test("a model with no importer refuses (fail closed)")
  func unwired() async {
    let model = model(plan: nil, apply: nil)

    await model.prepareImport(from: folder)

    #expect(model.importState == .failed("Import is unavailable"))
  }

  @Test("named failures show their fixed messages", arguments: namedFailureMessages)
  func namedFailures(failure: LibraryImportFailure, message: String) async {
    let model = model(plan: { _, _ in throw failure })

    await model.prepareImport(from: folder)

    #expect(model.importState == .failed(message))
  }

  @Test("an unexpected error shows a fixed message and never the error text")
  func unexpected() async {
    struct Leaky: Error, CustomStringConvertible { var description: String { "secret clip text" } }
    let planning = model(plan: { _, _ in throw Leaky() })
    await planning.prepareImport(from: folder)
    #expect(planning.importState == .failed("The import could not be completed"))

    let applying = model(apply: { _, _ in throw Leaky() })
    await applying.prepareImport(from: folder)
    await applying.confirmImport()
    #expect(applying.importState == .failed("The import could not be completed"))
  }

  @Test("progress from the importer is exposed while it runs")
  func progress() async {
    let gate = Gate()
    let model = model(apply: { _, report in
      report(40, 100)
      await gate.wait()
      return result
    })
    await model.prepareImport(from: folder)

    let running = Task { await model.confirmImport() }
    while model.importProgress == nil { await Task.yield() }
    #expect(model.importState == .importing)
    #expect(model.importProgress?.processed == 40 && model.importProgress?.total == 100)
    await gate.open()
    await running.value

    #expect(model.importProgress == nil)
  }

  @Test("cancelling while checking ends cancelled with nothing to confirm")
  func cancelWhileChecking() async {
    let gate = Gate()
    let model = model(plan: { _, _ in
      await gate.wait()
      try Task.checkCancellation()
      return plan
    })

    let running = Task { await model.prepareImport(from: folder) }
    while case .idle = model.importState { await Task.yield() }
    model.cancelImport()
    await gate.open()
    await running.value

    #expect(model.importState == .cancelled)
    await model.confirmImport()
    #expect(model.importState == .cancelled)
  }

  @Test("cancelling a running import ends cancelled")
  func cancelWhileImporting() async {
    let gate = Gate()
    let model = model(apply: { _, _ in
      await gate.wait()
      try Task.checkCancellation()
      return result
    })
    await model.prepareImport(from: folder)

    let running = Task { await model.confirmImport() }
    while model.importState != .importing { await Task.yield() }
    model.cancelImport()
    await gate.open()
    await running.value

    #expect(model.importState == .cancelled)
  }

  @Test("declining at the confirmation returns to idle without importing")
  func decline() async {
    let imported = Box(0)
    let model = model(apply: { _, _ in
      imported.value += 1
      return result
    })
    await model.prepareImport(from: folder)

    model.dismissImportResult()
    await model.confirmImport()

    #expect(model.importState == .idle)
    #expect(imported.value == 0)
  }

  @Test("a second import while one is in progress is ignored")
  func notReentrant() async {
    let gate = Gate()
    let planned = Box(0)
    let model = model(plan: { _, _ in
      planned.value += 1
      await gate.wait()
      return plan
    })

    let first = Task { await model.prepareImport(from: folder) }
    while case .idle = model.importState { await Task.yield() }
    await model.prepareImport(from: folder)  // returns immediately
    await gate.open()
    await first.value

    #expect(planned.value == 1)
  }

  @Test("dismissing never interrupts a running import")
  func dismissWhileRunning() async {
    let gate = Gate()
    let model = model(apply: { _, _ in
      await gate.wait()
      return result
    })
    await model.prepareImport(from: folder)
    let running = Task { await model.confirmImport() }
    while model.importState != .importing { await Task.yield() }

    model.dismissImportResult()

    #expect(model.importState == .importing)
    await gate.open()
    await running.value
  }
}
