import AppKit
import ClipDomain
import ClipSearch
import ClipTransforms
import Foundation
import ImageIO
import Observation

/// Sidebar sections with real query backing. Files/Code/Colors are absent on
/// purpose: no detection backs them yet, and this model never shows a section
/// it cannot fill (slice 2).
public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
  case history
  case favorites
  case pinned
  case images
  case links
  case files
  case code
  case colors

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .history: "History"
    case .favorites: "Favorites"
    case .pinned: "Pinned"
    case .images: "Images"
    case .links: "Links"
    case .files: "Files"
    case .code: "Code"
    case .colors: "Colors"
    }
  }

  public var systemImage: String {
    switch self {
    case .history: "clock"
    case .favorites: "star"
    case .pinned: "pin"
    case .images: "photo"
    case .links: "link"
    case .files: "folder"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .colors: "swatchbook"
    }
  }

  var baseFilters: [SearchFilter] {
    switch self {
    case .history: []
    case .favorites: [.favorite]
    case .pinned: [.pinned]
    case .images: [.contentType(.image)]
    case .links: [.contentType(.link)]
    case .files: [.contentType(.file)]
    case .code: [.contentType(.code)]
    case .colors: [.contentType(.color)]
    }
  }
}

public enum LibraryDensity: String, CaseIterable, Sendable {
  case list
  case cards
}

/// What the content pane shows: a static section, a user collection, or a
/// re-parsed saved query. Smart queries execute as-is; section filters do
/// not combine into them.
public enum LibraryTarget: Hashable, Sendable {
  case section(LibrarySection)
  case collection(UUID)
  case smart(UUID)
}

/// What an export produced. Counts only: skipped clips are never described.
public struct LibraryExportSummary: Equatable, Sendable {
  public let clips: Int
  public let attachments: Int
  public let skippedSensitive: Int
  public let skippedQuarantinedImages: Int
  public let skippedMissingAttachments: Int

  public init(
    clips: Int, attachments: Int, skippedSensitive: Int, skippedQuarantinedImages: Int,
    skippedMissingAttachments: Int
  ) {
    self.clips = clips
    self.attachments = attachments
    self.skippedSensitive = skippedSensitive
    self.skippedQuarantinedImages = skippedQuarantinedImages
    self.skippedMissingAttachments = skippedMissingAttachments
  }

  public var skippedTotal: Int {
    skippedSensitive + skippedQuarantinedImages + skippedMissingAttachments
  }
}

/// Failures the export closure can name so the model can show a specific,
/// fixed message. Anything else becomes a generic message: error text can
/// carry paths or content and is never shown.
public enum LibraryExportFailure: Error, Equatable, Sendable {
  case destinationExists
}

public enum LibraryExportState: Equatable, Sendable {
  case idle
  case running
  case cancelled
  case failed(String)
  case finished(LibraryExportSummary, name: String)
}

/// What an import will do (when shown for confirmation) or did (when
/// finished). Counts only: a record is never described, so nothing here can
/// carry clip content.
public struct LibraryImportSummary: Equatable, Sendable {
  public let clipsInArchive: Int
  public let clipsAdded: Int
  public let clipsAlreadyPresent: Int
  public let imagesQueuedForOCR: Int
  /// Text or images the same privacy rules as capture refused.
  public let rejectedByPrivacy: Int
  /// Records that were malformed or broke a bound.
  public let rejectedInvalid: Int
  public let collectionsAdded: Int
  public let queriesAdded: Int
  public let queriesSkipped: Int
  /// Imported clips that the next retention cleanup would delete.
  public let retentionAtRisk: Int
  public let unlistedFiles: Int
  /// Clips the exporting app left out (sensitive, withheld images, ...).
  public let skippedAtExport: Int
  /// The history window `retentionAtRisk` was measured against.
  public let retentionDays: Int?

  public init(
    clipsInArchive: Int, clipsAdded: Int, clipsAlreadyPresent: Int, imagesQueuedForOCR: Int,
    rejectedByPrivacy: Int, rejectedInvalid: Int, collectionsAdded: Int, queriesAdded: Int,
    queriesSkipped: Int, retentionAtRisk: Int, unlistedFiles: Int, skippedAtExport: Int,
    retentionDays: Int? = nil
  ) {
    self.retentionDays = retentionDays
    self.clipsInArchive = clipsInArchive
    self.clipsAdded = clipsAdded
    self.clipsAlreadyPresent = clipsAlreadyPresent
    self.imagesQueuedForOCR = imagesQueuedForOCR
    self.rejectedByPrivacy = rejectedByPrivacy
    self.rejectedInvalid = rejectedInvalid
    self.collectionsAdded = collectionsAdded
    self.queriesAdded = queriesAdded
    self.queriesSkipped = queriesSkipped
    self.retentionAtRisk = retentionAtRisk
    self.unlistedFiles = unlistedFiles
    self.skippedAtExport = skippedAtExport
  }

  public var rejectedTotal: Int { rejectedByPrivacy + rejectedInvalid }
}

/// Reasons an archive was refused that the importer closure can name, so the
/// model shows a fixed message. Anything else becomes a generic message.
public enum LibraryImportFailure: Error, Equatable, Sendable {
  case notAnArchive
  case incomplete
  case newerVersion
  /// Failed the integrity, path-safety or size checks.
  case damaged
  /// Failed re-verification part-way through writing. Earlier batches are
  /// already in the library, so the message must not claim otherwise.
  case changedDuringImport
}

public struct LibraryImportProgress: Equatable, Sendable {
  public let processed: Int
  public let total: Int
}

public enum LibraryImportState: Equatable, Sendable {
  case idle
  /// Verifying the archive and working out the plan. Nothing is written.
  case checking(name: String)
  /// The plan is ready; nothing happens until the user confirms.
  case confirming(LibraryImportSummary, name: String)
  case importing
  case cancelled
  case failed(String)
  case finished(LibraryImportSummary, name: String)
}

/// A computed, not-yet-persisted transform result for the selected clip.
public struct TransformPreview: Equatable, Sendable {
  public let transformID: String
  public let title: String
  public let output: String
}

@MainActor
@Observable
public final class LibraryModel {
  public private(set) var section: LibrarySection = .history
  public private(set) var density: LibraryDensity = .list
  public private(set) var items: [ClipSummary] = []
  public private(set) var selectedID: UUID?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public private(set) var collections: [ClipCollection] = []
  public private(set) var smartQueries: [SavedQuery] = []
  public private(set) var activeCollectionID: UUID?
  public private(set) var activeSmartQueryID: UUID?
  private var transformSession: TransformSession?
  public private(set) var exportState: LibraryExportState = .idle
  public private(set) var importState: LibraryImportState = .idle
  public private(set) var importProgress: LibraryImportProgress?

  @ObservationIgnored private let repository: any ClipRepository
  @ObservationIgnored private let parser: SearchQueryParser
  @ObservationIgnored private let now: @MainActor @Sendable () -> Date
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private var requestGeneration = 0
  @ObservationIgnored private let transformRegistry: TransformRegistry
  @ObservationIgnored private let transformOutputKind: @Sendable (String) -> ClipKind?
  @ObservationIgnored private let makeID: @Sendable () -> UUID
  @ObservationIgnored private let libraryExporter:
    (@Sendable (URL) async throws -> LibraryExportSummary)?
  @ObservationIgnored private var exportTask: Task<LibraryExportSummary, Error>?
  @ObservationIgnored private let libraryImportPlanner: ImportAction?
  @ObservationIgnored private let libraryImporter: ImportAction?
  @ObservationIgnored private var importTask: Task<LibraryImportSummary, Error>?
  @ObservationIgnored private var pendingImport: URL?
  // Same lazy-thumbnail shape as Quick Paste's model; the two converge when
  // a shared integration module lands (see ADR-0005).
  @ObservationIgnored private let thumbnails = NSCache<NSUUID, NSImage>()

  public init(
    repository: any ClipRepository,
    parser: SearchQueryParser = SearchQueryParser(),
    now: @escaping @MainActor @Sendable () -> Date = { .now },
    calendar: Calendar = .current,
    transforms: TransformRegistry = .builtIn,
    transformOutputKind: @escaping @Sendable (String) -> ClipKind? = { _ in nil },
    makeID: @escaping @Sendable () -> UUID = { UUID() },
    libraryExporter: (@Sendable (URL) async throws -> LibraryExportSummary)? = nil,
    libraryImportPlanner: ImportAction? = nil,
    libraryImporter: ImportAction? = nil
  ) {
    self.libraryExporter = libraryExporter
    self.libraryImportPlanner = libraryImportPlanner
    self.libraryImporter = libraryImporter
    self.transformRegistry = transforms
    self.transformOutputKind = transformOutputKind
    self.makeID = makeID
    self.repository = repository
    self.parser = parser
    self.now = now
    self.calendar = calendar
  }

  /// Transform preview for the selected clip. Hidden (not cleared) when the
  /// selection moves, so a result can never be shown or saved against the
  /// wrong clip.
  public var transformPreview: TransformPreview? { currentTransformSession?.preview }

  /// Status or failure text for the transform UI. Fixed strings only: never
  /// clip content.
  public var transformMessage: String? { currentTransformSession?.message }

  private var currentTransformSession: TransformSession? {
    guard let transformSession, transformSession.clipID == selectedID else { return nil }
    return transformSession
  }

  public var selectedClip: ClipSummary? {
    guard let selectedID else { return nil }
    return items.first(where: { $0.id == selectedID })
  }

  public func select(section: LibrarySection) async {
    self.section = section
    activeCollectionID = nil
    activeSmartQueryID = nil
    selectedID = nil
    await refresh()
  }

  public var title: String {
    if let activeCollectionID {
      return collections.first(where: { $0.id == activeCollectionID })?.name
        ?? "Collection"
    }
    if let activeSmartQueryID {
      return smartQueries.first(where: { $0.id == activeSmartQueryID })?.name
        ?? "Smart Collection"
    }
    return section.title
  }

  public func selectCollection(id: UUID) async {
    activeCollectionID = id
    activeSmartQueryID = nil
    selectedID = nil
    await runCollectionListing(id: id)
  }

  public func selectSmart(id: UUID) async {
    activeSmartQueryID = id
    activeCollectionID = nil
    selectedID = nil
    await runSmartListing(id: id)
  }

  public func refreshCollections() async {
    do {
      collections = try await repository.listCollections()
      smartQueries = try await repository.listQueries()
    } catch {
      errorMessage = "Unable to load collections"
    }
  }

  public func createCollection(name: String) async {
    do {
      let collection = try await repository.createCollection(
        name: name, at: now())
      await refreshCollections()
      await selectCollection(id: collection.id)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to create the collection"
    }
  }

  public func renameCollection(id: UUID, name: String) async {
    do {
      try await repository.renameCollection(id: id, name: name, at: now())
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to rename the collection"
    }
  }

  public func deleteCollection(id: UUID) async {
    do {
      try await repository.deleteCollection(id: id)
      if activeCollectionID == id {
        activeCollectionID = nil
        await refresh()
      }
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the collection"
    }
  }

  public func addToCollection(collectionID: UUID, clipID: UUID) async {
    do {
      try await repository.addToCollection(
        collectionID: collectionID, clipID: clipID, at: now())
      if activeCollectionID == collectionID {
        await runCollectionListing(id: collectionID)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to add to the collection"
    }
  }

  public func removeFromCollection(collectionID: UUID, clipID: UUID) async {
    do {
      try await repository.removeFromCollection(
        collectionID: collectionID, clipID: clipID)
      if activeCollectionID == collectionID {
        await runCollectionListing(id: collectionID)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to remove from the collection"
    }
  }

  public func saveSmartQuery(name: String, queryText: String) async {
    let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      // Validate with the real parser before persisting.
      _ = try parser.parse(
        trimmed, context: SearchParseContext(now: now(), calendar: calendar))
      let query = try await repository.saveQuery(
        name: name, queryText: trimmed, at: now())
      await refreshCollections()
      await selectSmart(id: query.id)
      errorMessage = nil
    } catch {
      errorMessage = "That query does not parse"
    }
  }

  public func renameSmartQuery(id: UUID, name: String) async {
    do {
      try await repository.renameQuery(id: id, name: name, at: now())
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to rename the Smart Collection"
    }
  }

  public func deleteSmartQuery(id: UUID) async {
    do {
      try await repository.deleteQuery(id: id)
      if activeSmartQueryID == id {
        activeSmartQueryID = nil
        await refresh()
      }
      await refreshCollections()
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the Smart Collection"
    }
  }

  public func setTags(id: UUID, names: [String]) async {
    do {
      let current = Set(try await repository.tags(for: id).map(\.normalized))
      let desired = Set(
        names.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
      for name in desired.subtracting(current) {
        try await repository.tagClip(id: id, tag: name)
      }
      for name in current.subtracting(desired) {
        try await repository.untagClip(id: id, tag: name)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update tags"
    }
  }

  public func tags(for id: UUID) async -> [ClipTag] {
    (try? await repository.tags(for: id)) ?? []
  }

  public func setDensity(_ density: LibraryDensity) {
    self.density = density
  }

  public func refresh() async {
    await runQuery(text: [], filters: section.baseFilters)
  }

  public func search(_ input: String) async {
    // Search always scopes to the static section library: typing while a
    // collection or Smart Collection is open returns to section scope
    // rather than silently intersecting two scopes.
    activeCollectionID = nil
    activeSmartQueryID = nil
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await refresh()
      return
    }
    do {
      let query = try parser.parse(
        input,
        context: SearchParseContext(now: now(), calendar: calendar)
      )
      await runQuery(
        text: query.text, filters: section.baseFilters + query.filters)
    } catch {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "Invalid search query"
    }
  }

  public func select(id: UUID?) {
    selectedID = id
  }

  public func toggleFavorite(id: UUID) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let newValue = !items[index].isFavorite
    do {
      try await repository.setFavorite(id: id, isFavorite: newValue)
      items[index] = items[index].withFavorite(newValue)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update the favorite"
    }
  }

  public func togglePin(id: UUID) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let newValue = !items[index].isPinned
    do {
      try await repository.setPinned(id: id, isPinned: newValue)
      items[index] = items[index].withPinned(newValue)
      errorMessage = nil
    } catch {
      errorMessage = "Unable to update the pin"
    }
  }

  public func delete(id: UUID) async {
    do {
      try await repository.delete(id: id, at: now())
      items.removeAll(where: { $0.id == id })
      if selectedID == id { selectedID = nil }
      errorMessage = nil
    } catch {
      errorMessage = "Unable to delete the clip"
    }
  }

  // MARK: - Transforms (M3 slice 5, ADR-0005 §5)

  public func transforms(for clip: ClipSummary) -> [any ClipTransform] {
    transformRegistry.transforms(for: clip)
  }

  /// Runs a transform over the selected clip's text. Pure: nothing is
  /// persisted or copied until the user chooses to.
  public func previewTransform(id: String) {
    guard let clip = selectedClip, let transform = transformRegistry.transform(id: id),
      transform.applies(to: clip)
    else {
      return
    }
    do {
      let output = try transform.apply(clip.text)
      transformSession = TransformSession(
        clipID: clip.id,
        preview: TransformPreview(
          transformID: transform.id, title: transform.title, output: output),
        message: nil)
    } catch let error as TransformError {
      transformSession = TransformSession(clipID: clip.id, preview: nil, message: error.message)
    } catch {
      transformSession = TransformSession(
        clipID: clip.id, preview: nil, message: "The transform failed")
    }
  }

  public func dismissTransformPreview() {
    transformSession = nil
  }

  /// Saves the previewed output as a new clip. The output policy runs first
  /// and defaults to refusing everything, so a model constructed without the
  /// capture gate can never persist transformed text (a decode can turn an
  /// innocuous clip into a credential).
  public func saveTransformPreview() async {
    guard let session = currentTransformSession, let preview = session.preview else { return }
    guard let kind = transformOutputKind(preview.output) else {
      transformSession?.message = "Not saved: the result looks sensitive or is too large"
      return
    }
    do {
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: makeID(), kind: kind, text: preview.output, capturedAt: now(), source: nil))
    } catch {
      transformSession?.message = "Unable to save the result"
      return
    }
    await reloadCurrentListing()
    transformSession?.message = "Saved as a new clip"
  }

  private func reloadCurrentListing() async {
    if let activeCollectionID {
      await runCollectionListing(id: activeCollectionID)
    } else if let activeSmartQueryID {
      await runSmartListing(id: activeSmartQueryID)
    } else {
      await refresh()
    }
  }

  // MARK: - Export (M3 slice 6b)

  /// Exports the whole library to `destination` (a path that must not exist).
  /// A model built without an exporter refuses, mirroring the transform save
  /// gate: nothing can be written out unless the privacy gates were wired.
  public func exportLibrary(to destination: URL) async {
    guard exportState != .running else { return }
    guard let exporter = libraryExporter else {
      exportState = .failed("Export is unavailable")
      return
    }
    exportState = .running
    let task = Task { try await exporter(destination) }
    exportTask = task
    do {
      let summary = try await task.value
      exportState = .finished(summary, name: destination.lastPathComponent)
    } catch is CancellationError {
      exportState = .cancelled
    } catch LibraryExportFailure.destinationExists {
      exportState = .failed("An item with that name already exists")
    } catch {
      exportState = .failed("The export could not be completed")
    }
    exportTask = nil
  }

  public func cancelExport() {
    exportTask?.cancel()
  }

  /// Clears a finished, failed or cancelled result. A running export is
  /// never interrupted by dismissing.
  public func dismissExportResult() {
    guard exportState != .running else { return }
    exportState = .idle
  }

  // MARK: - Import (M3 slice 6c)

  /// Reads an archive folder and works out what importing would do. Writes
  /// nothing; the user confirms with `confirmImport()`. The planner and the
  /// importer are both required: a model built without them refuses, so no
  /// path exists that imports without the privacy gates being wired.
  public typealias ImportAction =
    @Sendable (URL, @escaping @Sendable (Int, Int) -> Void) async throws -> LibraryImportSummary

  public func prepareImport(from folder: URL) async {
    switch importState {
    case .checking, .importing: return
    default: break
    }
    guard let planner = libraryImportPlanner, libraryImporter != nil else {
      importState = .failed("Import is unavailable")
      return
    }
    let name = folder.lastPathComponent
    importState = .checking(name: name)
    pendingImport = nil
    let task = Task { try await planner(folder) { _, _ in } }
    importTask = task
    do {
      let plan = try await task.value
      importState = .confirming(plan, name: name)
      pendingImport = folder
    } catch is CancellationError {
      importState = .cancelled
    } catch {
      importState = .failed(Self.importMessage(for: error))
    }
    importTask = nil
  }

  /// Imports the archive `prepareImport` planned. Does nothing unless a plan
  /// is waiting for confirmation.
  public func confirmImport() async {
    guard case .confirming(_, let name) = importState, let folder = pendingImport,
      let importer = libraryImporter
    else { return }
    pendingImport = nil
    importState = .importing
    importProgress = nil
    let report: @Sendable (Int, Int) -> Void = { [weak self] processed, total in
      Task { @MainActor in self?.recordImportProgress(processed: processed, total: total) }
    }
    let task = Task { try await importer(folder, report) }
    importTask = task
    do {
      let summary = try await task.value
      importState = .finished(summary, name: name)
    } catch is CancellationError {
      importState = .cancelled
    } catch {
      importState = .failed(Self.importMessage(for: error))
    }
    importTask = nil
    importProgress = nil
    // Whatever was imported, even by a cancelled run, is already in the store.
    await refresh()
    await refreshCollections()
  }

  public func cancelImport() {
    importTask?.cancel()
  }

  /// Clears a result, or declines a plan that is waiting. A running check or
  /// import is never interrupted by dismissing.
  public func dismissImportResult() {
    switch importState {
    case .checking, .importing: return
    default:
      pendingImport = nil
      importState = .idle
    }
  }

  private func recordImportProgress(processed: Int, total: Int) {
    guard importState == .importing, processed >= (importProgress?.processed ?? 0) else {
      return
    }
    importProgress = LibraryImportProgress(processed: processed, total: total)
  }

  private static func importMessage(for error: Error) -> String {
    switch error as? LibraryImportFailure {
    case .notAnArchive: "That folder is not a Copyloom export."
    case .incomplete: "That export is incomplete: it has no manifest."
    case .newerVersion: "That export was made by a newer version of Copyloom."
    case .damaged: "That export failed its integrity check, so nothing was imported."
    case .changedDuringImport:
      "That export changed while it was being imported. Clips imported before then were kept; run the import again to finish."
    case nil: "The import could not be completed"
    }
  }

  public func imageData(for id: UUID) async -> Data? {
    try? await repository.attachmentData(for: id)
  }

  /// Quarantine state for one clip: nil means no OCR job (non-images, or
  /// jobs shed on delete). The inspector renders `.withheld` as the
  /// quarantine banner; `.pending` as an indexing note.
  public func ocrStatus(for id: UUID) async -> OCRJobStatus? {
    try? await repository.ocrJob(for: id)?.status
  }

  public func attachmentMeta(for id: UUID) async throws -> ClipAttachment? {
    try await repository.attachment(for: id)
  }

  public func loadThumbnail(for clip: ClipSummary) async -> NSImage? {
    guard clip.kind == .image else { return nil }
    let key = clip.id as NSUUID
    if let cached = thumbnails.object(forKey: key) { return cached }
    guard let data = try? await repository.attachmentData(for: clip.id),
      let thumbnail = Self.makeThumbnail(from: data, maxPixelSize: 512)
    else {
      return nil
    }
    thumbnails.setObject(thumbnail, forKey: key)
    return thumbnail
  }

  /// Large downsampled image for the inspector. Not cached: only one is on
  /// screen at a time, and downsampling keeps a 25 MB capture from decoding
  /// at full size.
  public func loadPreview(for clip: ClipSummary) async -> NSImage? {
    guard clip.kind == .image,
      let data = try? await repository.attachmentData(for: clip.id)
    else {
      return nil
    }
    return Self.makeThumbnail(from: data, maxPixelSize: 1_600)
  }

  private static func makeThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
    let options: CFDictionary =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    else {
      return nil
    }
    return NSImage(cgImage: thumbnail, size: .zero)
  }

  private func runCollectionListing(id: UUID) async {
    await replaceItems {
      try await repository.collectionClips(collectionID: id, limit: 200)
    }
  }

  private func runSmartListing(id: UUID) async {
    guard let saved = smartQueries.first(where: { $0.id == id }) else {
      activeSmartQueryID = nil
      await refresh()
      return
    }
    guard saved.queryVersion == SavedQuery.currentVersion else {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "This saved query needs an update"
      return
    }
    do {
      let query = try parser.parse(
        saved.queryText,
        context: SearchParseContext(now: now(), calendar: calendar)
      )
      await runQuery(text: query.text, filters: query.filters)
    } catch {
      requestGeneration &+= 1
      items = []
      selectedID = nil
      isLoading = false
      errorMessage = "This saved query no longer parses"
    }
  }

  private func runQuery(text: [SearchTextClause], filters: [SearchFilter]) async {
    await replaceItems {
      try await repository.search(
        SearchQuery(text: text, filters: filters), limit: 200)
    }
  }

  private func replaceItems(
    _ operation: () async throws -> [ClipSummary]
  ) async {
    requestGeneration &+= 1
    let generation = requestGeneration
    isLoading = true
    errorMessage = nil
    do {
      let newItems = try await operation()
      guard generation == requestGeneration else { return }
      items = newItems
      if let selectedID, !newItems.contains(where: { $0.id == selectedID }) {
        self.selectedID = nil
      }
    } catch {
      guard generation == requestGeneration else { return }
      items = []
      selectedID = nil
      errorMessage = "Unable to load local history"
    }
    guard generation == requestGeneration else { return }
    isLoading = false
  }
}

private struct TransformSession {
  let clipID: UUID
  var preview: TransformPreview?
  var message: String?
}

extension ClipSummary {
  fileprivate func withPinned(_ isPinned: Bool) -> ClipSummary {
    ClipSummary(
      id: id, kind: kind, text: text, createdAt: createdAt,
      lastSeenAt: lastSeenAt, copyCount: copyCount, useCount: useCount,
      lastUsedAt: lastUsedAt, isPinned: isPinned, isFavorite: isFavorite,
      source: source
    )
  }

  fileprivate func withFavorite(_ isFavorite: Bool) -> ClipSummary {
    ClipSummary(
      id: id, kind: kind, text: text, createdAt: createdAt,
      lastSeenAt: lastSeenAt, copyCount: copyCount, useCount: useCount,
      lastUsedAt: lastUsedAt, isPinned: isPinned, isFavorite: isFavorite,
      source: source
    )
  }
}
