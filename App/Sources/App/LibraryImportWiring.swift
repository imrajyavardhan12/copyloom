import ClipArchive
import ClipDomain
import ClipStore
import ClipboardCapture
import Foundation
import LibraryFeature

/// The production wiring of Import Library: which privacy gates an archive
/// has to pass, how archive failures map to fixed user-facing reasons, and how
/// the importer's counts become the model's summary. One place, shared by the
/// app and the DEBUG preview check, so what is tested is what ships.
nonisolated enum LibraryImportWiring {
  struct Actions {
    let plan: LibraryModel.ImportAction
    let apply: LibraryModel.ImportAction
  }

  /// Archive content faces the rules a fresh copy does: the same text gate
  /// (size, sensitive detector, kind) and the same image gate (byte and pixel
  /// ceilings, Vision privacy preflight under its timeout).
  static func gates(textGate: TextOutputGate, imageGate: ImageAcceptanceGate) -> ImportGates {
    ImportGates(
      acceptText: { text in textGate.kind(for: text).map(archiveKind) },
      inspectImage: { data, uti in
        guard case .allow(let width, let height) = await imageGate.evaluate(data: data, uti: uti)
        else {
          return nil
        }
        return ImageInspection(width: width, height: height)
      })
  }

  /// `retentionDays` is read when an import starts, so a change in Settings
  /// is respected. Nil means history is kept forever.
  static func actions(
    database: AppDatabase,
    textGate: TextOutputGate,
    imageGate: ImageAcceptanceGate,
    retentionDays: @escaping @Sendable () async -> Int?
  ) -> Actions {
    let importer = ArchiveImporter(
      sink: database.archiveSink(), gates: gates(textGate: textGate, imageGate: imageGate))

    @Sendable func cutoff() async -> (days: Int?, date: Date?) {
      guard let days = await retentionDays() else { return (nil, nil) }
      return (days, Date().addingTimeInterval(-TimeInterval(days) * 86_400))
    }

    return Actions(
      plan: { folder, _ in
        let archive = try verify(folder)
        let window = await cutoff()
        do {
          return summary(
            try await importer.plan(archive, retentionCutoff: window.date),
            retentionDays: window.days)
        } catch {
          throw failure(error, writing: false)
        }
      },
      apply: { folder, report in
        // Verified again, not trusted from the plan: the folder may have
        // changed while the user read the confirmation.
        let archive = try verify(folder)
        let window = await cutoff()
        do {
          return summary(
            try await importer.apply(
              archive, retentionCutoff: window.date,
              progress: { report($0.processed, $0.total) }),
            retentionDays: window.days)
        } catch {
          throw failure(error, writing: true)
        }
      })
  }

  // MARK: - Mapping

  private static func verify(_ folder: URL) throws -> VerifiedArchive {
    do {
      return try ArchiveVerifier().verify(at: folder)
    } catch {
      throw failure(error, writing: false)
    }
  }

  /// Archive problems become fixed reasons; cancellation passes through; any
  /// other error is left for the model's generic message (error text can
  /// carry paths or content and is never shown).
  static func failure(_ error: Error, writing: Bool) -> Error {
    guard let archiveError = error as? ArchiveError else { return error }
    switch archiveError {
    case .notAnArchive: return LibraryImportFailure.notAnArchive
    case .missingManifest: return LibraryImportFailure.incomplete
    case .unsupportedVersion: return LibraryImportFailure.newerVersion
    default:
      return writing ? LibraryImportFailure.changedDuringImport : LibraryImportFailure.damaged
    }
  }

  static func summary(_ result: ImportSummary, retentionDays: Int?) -> LibraryImportSummary {
    let privacy =
      result.rejections.count(.refusedByPrivacyGate) + result.rejections.count(.refusedImage)
    let skipped = result.skippedAtExport
    return LibraryImportSummary(
      clipsInArchive: result.clipsInArchive,
      clipsAdded: result.clipsAdded + result.clipsAddedWithNewUUID,
      clipsAlreadyPresent: result.clipsMerged,
      imagesQueuedForOCR: result.imagesQueuedForOCR,
      rejectedByPrivacy: privacy,
      rejectedInvalid: result.rejections.total - privacy,
      collectionsAdded: result.library.collectionsAdded,
      queriesAdded: result.library.queriesAdded,
      queriesSkipped: result.library.queriesSkippedVersion,
      retentionAtRisk: result.retentionAtRisk,
      unlistedFiles: result.unlistedFiles,
      skippedAtExport: skipped.sensitive + skipped.quarantinedImage + skipped.missingAttachment,
      retentionDays: retentionDays)
  }

  private static func archiveKind(_ kind: ClipKind) -> ArchiveClipKind {
    switch kind {
    case .text: .text
    case .link: .link
    case .image: .image
    case .code: .code
    case .color: .color
    case .file: .file
    }
  }
}
