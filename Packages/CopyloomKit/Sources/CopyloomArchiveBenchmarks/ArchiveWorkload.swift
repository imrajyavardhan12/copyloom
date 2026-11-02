import ClipArchive
import ClipDomain
import ClipStore
import ClipboardCapture
import CryptoKit
import Darwin
import Foundation

struct ArchiveWorkload {
  let root: URL
  let corpus: URL
  let records: Int
  let images: Int

  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let textGate = TextOutputGate()
  private static let imageGate = ImageAcceptanceGate(
    preflight: VisionImagePreflight(), configuration: CaptureConfiguration(isEnabled: true))

  private var total: Int { records + images }
  private var original: URL { root.appending(path: "original") }

  func run(_ phase: String) async throws {
    switch phase {
    case "seed": try await seed()
    case "roundtrip", "reimportcheck": try await check(phase)
    default: try await measure(phase)
    }
  }

  private func database(_ name: String) throws -> AppDatabase {
    try AppDatabase.open(at: root.appending(path: "\(name)/copyloom.sqlite"))
  }

  private func exporter(_ database: AppDatabase) -> ArchiveExporter {
    ArchiveExporter(
      source: database.archiveSource(), isExportable: { Self.textGate.kind(for: $0) != nil },
      createdBy: .init(
        app: "Copyloom", appVersion: "benchmark", schemaVersion: AppDatabase.schemaVersion))
  }

  private func importer(_ database: AppDatabase) -> ArchiveImporter {
    ArchiveImporter(
      sink: database.archiveSink(),
      gates: ImportGates(
        acceptText: { text in
          Self.textGate.kind(for: text).flatMap { Self.archiveKind($0) }
        },
        inspectImage: { data, uti in
          guard
            case .allow(let width, let height) = await Self.imageGate.evaluate(data: data, uti: uti)
          else { return nil }
          return ImageInspection(width: width, height: height)
        }))
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

  private struct CorpusRecord: Decodable {
    var uuid: UUID
    var text: String
    var capturedAtMilliseconds: Int64
  }

  private func seed() async throws {
    for name in ["source", "target"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: name), withIntermediateDirectories: false)
    }
    let source = try database("source")
    defer { try? source.close() }
    let target = try database("target")
    try target.close()
    let repository = source.repository
    let collection = try await repository.createCollection(name: "Benchmark", at: Self.now)
    _ = try await repository.saveQuery(name: "Text", queryText: "type:text", at: Self.now)
    let sources = [
      ClipSource(
        bundleIdentifier: "com.apple.Safari", applicationName: "Safari", provenance: .declared),
      ClipSource(
        bundleIdentifier: "com.mitchellh.ghostty", applicationName: "Ghostty", provenance: .declared
      ),
      ClipSource(
        bundleIdentifier: "com.apple.Preview", applicationName: "Preview", provenance: .declared),
    ]
    // Setup is deliberately a separate process. Loading the corpus here
    // cannot contaminate any export/import phase's peak memory measurement.
    let data = try Data(contentsOf: corpus)
    let lines = data.split(separator: 0x0A)
    guard lines.count == records else { throw BenchmarkFailure("corpus_count") }
    let decoder = JSONDecoder()
    for (index, line) in lines.enumerated() {
      let record = try decoder.decode(CorpusRecord.self, from: Data(line))
      // The standard corpus has exact duplicates. A versioned suffix
      // ensures the requested scale means live clips, not input records,
      // without changing the shared search fixture or its old baselines.
      let text = record.text + "\narchive-sequence-\(index)"
      guard let kind = Self.textGate.kind(for: text) else {
        throw BenchmarkFailure("corpus_privacy_gate")
      }
      let date = Date(timeIntervalSince1970: Double(record.capturedAtMilliseconds) / 1_000)
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: record.uuid, kind: kind, text: text, capturedAt: date,
          source: sources[index % sources.count]))
      if index.isMultiple(of: 1_000) {
        try await repository.setPinned(id: record.uuid, isPinned: true)
        try await repository.tagClip(id: record.uuid, tag: "Benchmark")
        try await repository.addToCollection(
          collectionID: collection.id, clipID: record.uuid, at: Self.now)
        try await repository.recordUse(id: record.uuid, at: Self.now)
      }
      if index.isMultiple(of: 1_500) {
        try await repository.setFavorite(id: record.uuid, isFavorite: true)
      }
    }
    for index in 0..<images {
      let data = try SyntheticImage.png(index: index)
      guard
        case .allow(let width, let height) = await Self.imageGate.evaluate(
          data: data, uti: "public.png")
      else { throw BenchmarkFailure("synthetic_image_gate") }
      _ = try await repository.saveAcceptedImage(
        AcceptedImageClip(
          id: UUID(), data: data, uti: "public.png", width: width, height: height,
          capturedAt: Self.now, source: nil))
    }
    guard try await repository.count() == total else { throw BenchmarkFailure("seed_live_count") }
    let health = try await source.health()
    try saveJSON(
      SetupReport(
        corpusBytes: data.count,
        corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        textUniquenessSuffix: "archive-sequence-v1",
        sqliteVersion: health.sqliteVersion, journalMode: health.journalMode),
      to: root.appending(path: "setup.json"))
  }

  private func measure(_ phase: String) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let storeName = phase == "export" ? "source" : "target"
    let store = try database(storeName)
    defer { try? store.close() }
    let before = try await store.repository.count()
    var verificationSeconds = 0.0
    var operationSeconds = 0.0
    var summary = ImportSummary()
    var manifest: ArchiveManifest
    if phase == "export" {
      guard before == total else { throw BenchmarkFailure("export_live_count") }
      let operationStart = DispatchTime.now().uptimeNanoseconds
      manifest = try await exporter(store).export(to: original, now: Self.now)
      operationSeconds = Self.elapsed(since: operationStart)
      guard manifest.skipped == .none else { throw BenchmarkFailure("export_skips") }
    } else {
      guard phase == "verify" || before == (phase == "reimport" ? total : 0) else {
        throw BenchmarkFailure("target_live_count")
      }
      let verifyStart = DispatchTime.now().uptimeNanoseconds
      // Match the app: verify independently before plan and again before
      // apply. Never time an apply that trusts a prior verified handle.
      let archive = try ArchiveVerifier().verify(at: original)
      verificationSeconds = Self.elapsed(since: verifyStart)
      manifest = archive.manifest
      if phase != "verify" {
        let operationStart = DispatchTime.now().uptimeNanoseconds
        if phase == "plan" {
          summary = try await importer(store).plan(archive, retentionCutoff: nil, now: Self.now)
        } else {
          summary = try await importer(store).apply(archive, retentionCutoff: nil, now: Self.now)
        }
        operationSeconds = Self.elapsed(since: operationStart)
        guard summary.clipsInArchive == total, summary.rejections.total == 0,
          summary.metadataDropped == 0, summary.libraryEntriesRejected == 0,
          summary.clipsAddedWithNewUUID == 0,
          summary.clipsAdded == (phase == "reimport" ? 0 : total),
          summary.clipsMerged == (phase == "reimport" ? total : 0),
          summary.imagesQueuedForOCR == (phase == "reimport" ? 0 : images)
        else { throw BenchmarkFailure("import_counts") }
      }
    }
    let after = try await store.repository.count()
    guard manifest.counts.clips == total, manifest.counts.attachments == images,
      after == (phase == "verify" ? before : (phase == "plan" ? 0 : total))
    else { throw BenchmarkFailure("phase_counts") }
    let databaseBytes = try fileSize("\(storeName)/copyloom.sqlite")
    let walBytes = try fileSize("\(storeName)/copyloom.sqlite-wal")
    try store.close()
    let seconds = Self.elapsed(since: start)
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw BenchmarkFailure("resource_usage") }
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    let archiveBytes =
      manifest.files.reduce(0) { $0 + $1.bytes }
      + (try Data(contentsOf: original.appending(path: "manifest.json"))).count
    try saveJSON(
      PhaseReport(
        name: phase, processID: getpid(), processGroupID: getpgrp(), seconds: seconds,
        verificationSeconds: verificationSeconds, operationSeconds: operationSeconds,
        peakRSSBytes: Int(usage.ru_maxrss), cpuSeconds: cpu,
        clipsBefore: before, clipsAfter: after, added: summary.clipsAdded,
        merged: summary.clipsMerged, rejected: summary.rejections.total,
        imagesQueuedForOCR: summary.imagesQueuedForOCR, archiveBytes: archiveBytes,
        databaseBytes: databaseBytes, walBytes: walBytes),
      to: root.appending(path: "\(phase).json"))
  }

  /// Correctness work is not part of measured phases. Compare every logical
  /// archive file, not just the count; a wrong payload/relationship must fail.
  private func check(_ phase: String) async throws {
    let store = try database("target")
    defer { try? store.close() }
    let destination = root.appending(path: phase)
    let exported = try await exporter(store).export(to: destination, now: Self.now)
    let originalManifest = try ArchiveVerifier().verify(at: original).manifest
    let checked = try ArchiveVerifier().verify(at: destination).manifest
    guard exported == checked, checked.counts == originalManifest.counts,
      checked.skipped == .none, checked.archiveDigest == originalManifest.archiveDigest,
      checked.files.sorted(by: { $0.path < $1.path })
        == originalManifest.files.sorted(by: { $0.path < $1.path }),
      try await store.repository.count() == total,
      try await store.repository.pendingOCRJobCount() == images
    else { throw BenchmarkFailure("roundtrip_content") }
    _ = try await store.health()
  }

  private func fileSize(_ relativePath: String) throws -> Int {
    let path = root.appending(path: relativePath).path
    guard FileManager.default.fileExists(atPath: path) else { return 0 }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let bytes = attributes[.size] as? Int else { throw BenchmarkFailure("file_size") }
    return bytes
  }

  private static func elapsed(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
