import ClipDomain
import ClipSearch
import ClipStore
import ClipboardCapture
import Darwin
import Foundation

// MARK: - Records

private struct CorpusRecord: Decodable {
  var sequence: Int
  var uuid: String
  var text: String
  var capturedAtMilliseconds: Int64
}

private struct QueryStats: Encodable {
  var name: String
  var samples: Int
  var medianMs: Double
  var p95Ms: Double
  var p99Ms: Double
  var minMs: Double
  var maxMs: Double
  var resultChecksum: Int
}

private struct Report: Encodable {
  var commit: String
  var configuration: String
  var hardwareModel: String
  var architecture: String
  var cpuCount: Int
  var osVersion: String
  var sqliteVersion: String
  var journalMode: String
  var corpusRecords: Int
  var loadSeconds: Double
  var loadPerSecond: Double
  var dedupSeconds: Double
  var dedupPerSecond: Double
  var retentionExpireSeconds: Double
  var retentionPurgeSeconds: Double
  var databaseBytes: Int
  var walBytes: Int
  var queries: [QueryStats]
  var concurrentP95Ms: Double
  var peakRSSBytes: Int
  var cpuSeconds: Double
  var verdict30ms: Bool
}

// MARK: - Helpers

private func nowNanoseconds() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
  return sorted[index]
}

private func sysctlInt(_ name: String) -> Int {
  var value: Int32 = 0
  var size = MemoryLayout<Int32>.size
  guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
  return Int(value)
}

private func sysctlString(_ name: String) -> String {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "unknown" }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
  return String(cString: buffer)
}

private func fileSize(at url: URL) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

private func parseQuery(
  _ input: String, now: Date, calendar: Calendar
) throws -> SearchQuery {
  try SearchQueryParser().parse(
    input, context: SearchParseContext(now: now, calendar: calendar))
}

// MARK: - Benchmark

@main
private enum CopyloomBenchmarks {
  static func main() async throws {
    var corpusPath: String?
    var workdirPath: String?
    var outputPath: String?
    var commit = ProcessInfo.processInfo.environment["COPYLOOM_COMMIT"] ?? "unknown"
    var index = 1
    while index < CommandLine.arguments.count {
      switch CommandLine.arguments[index] {
      case "--corpus":
        index += 1
        corpusPath = CommandLine.arguments[index]
      case "--workdir":
        index += 1
        workdirPath = CommandLine.arguments[index]
      case "--output":
        index += 1
        outputPath = CommandLine.arguments[index]
      case "--commit":
        index += 1
        commit = CommandLine.arguments[index]
      default:
        FileHandle.standardError.write(
          Data(
            "unknown argument: \(CommandLine.arguments[index])\nusage: copyloom-bench --corpus PATH --workdir DIR --output PATH [--commit HASH]\n"
              .utf8))
        throw ExitCode.failure
      }
      index += 1
    }
    guard let corpusPath, let workdirPath, let outputPath else {
      FileHandle.standardError.write(
        Data(
          "usage: copyloom-bench --corpus PATH --workdir DIR --output PATH [--commit HASH]\n".utf8))
      throw ExitCode.failure
    }

    let calendar = Calendar(identifier: .gregorian)
    let queryNow = Date(timeIntervalSince1970: 1_800_000_000)
    let workdir = URL(fileURLWithPath: workdirPath)
    try FileManager.default.createDirectory(
      at: workdir, withIntermediateDirectories: true)
    let databaseURL = workdir.appending(path: "bench.sqlite")
    try? FileManager.default.removeItem(at: databaseURL)

    // Load deterministic corpus plus fixed probe documents (phrase hits,
    // Unicode hits, and a dedicated source that app: filters resolve).
    let rawCorpus = try String(contentsOfFile: corpusPath, encoding: .utf8)
    let decoder = JSONDecoder()
    var fixtures: [(id: UUID, kind: ClipKind, text: String, date: Date, source: ClipSource?)] =
      try rawCorpus.split(separator: "\n").map { line in
        let record = try decoder.decode(CorpusRecord.self, from: Data(line.utf8))
        return (
          id: UUID(uuidString: record.uuid) ?? UUID(),
          kind: CapturePolicy().classifyText(record.text),
          text: record.text,
          date: Date(timeIntervalSince1970: TimeInterval(record.capturedAtMilliseconds) / 1_000),
          source: nil
        )
      }
    let probeSources = [
      ("com.apple.Safari", "Safari"),
      ("com.mitchellh.ghostty", "Ghostty"),
      ("com.apple.Preview", "Preview"),
    ]
    for (offset, _) in fixtures.enumerated() {
      let (bundleID, name) = probeSources[offset % probeSources.count]
      fixtures[offset].source = ClipSource(
        bundleIdentifier: bundleID, applicationName: name, provenance: .declared)
    }
    let probeBase = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<50 {
      fixtures.append(
        (
          id: UUID(),
          kind: .text,
          text: "the quick brown postgres connection pool drained again slowly marker-\(i)",
          date: probeBase.addingTimeInterval(Double(i)),
          source: ClipSource(
            bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit",
            provenance: .declared)
        ))
    }
    for i in 0..<20 {
      fixtures.append(
        (
          id: UUID(),
          kind: .text,
          text: "Café orders a naïve résumé printout numéro \(i)",
          date: probeBase.addingTimeInterval(Double(1_000 + i)),
          source: nil
        ))
    }

    let database = try AppDatabase.open(at: databaseURL)
    let repository = database.repository
    let loadStart = nowNanoseconds()
    for fixture in fixtures {
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: fixture.id, kind: fixture.kind, text: fixture.text,
          capturedAt: fixture.date, source: fixture.source))
    }
    for sequence in stride(from: 0, to: fixtures.count, by: 1_000) {
      try await repository.setPinned(id: fixtures[sequence].id, isPinned: true)
    }
    let loadSeconds = Double(nowNanoseconds() - loadStart) / 1_000_000_000

    // Search matrix: warm-up plus measured samples per class.
    var queryStats: [QueryStats] = []
    var checksum = 0
    func measure(name: String, query: SearchQuery, samples: Int = 30) async throws {
      for _ in 0..<5 {
        _ = try await repository.search(query, limit: 100)
      }
      var latencies: [Double] = []
      var hits = 0
      for _ in 0..<samples {
        let start = nowNanoseconds()
        let results = try await repository.search(query, limit: 100)
        latencies.append(Double(nowNanoseconds() - start) / 1_000_000)
        hits += results.count
      }
      latencies.sort()
      checksum += hits
      queryStats.append(
        QueryStats(
          name: name, samples: samples,
          medianMs: percentile(latencies, 0.50),
          p95Ms: percentile(latencies, 0.95),
          p99Ms: percentile(latencies, 0.99),
          minMs: latencies.first ?? 0, maxMs: latencies.last ?? 0,
          resultChecksum: hits))
    }

    let noText = SearchQuery(text: [], filters: [])
    try await measure(
      name: "common-term",
      query: SearchQuery(text: [.term("postgres")], filters: []))
    try await measure(
      name: "rare-term",
      query: SearchQuery(text: [.term("rare-marker-0")], filters: []))
    try await measure(
      name: "mid-term",
      query: SearchQuery(text: [.term("item")], filters: []))
    try await measure(
      name: "phrase",
      query: SearchQuery(text: [.phrase("postgres connection pool")], filters: []))
    try await measure(
      name: "unicode-term",
      query: SearchQuery(text: [.term("café")], filters: []))
    try await measure(
      name: "filter-app",
      query: SearchQuery(text: [], filters: [.application("Safari")]))
    try await measure(name: "filter-pinned", query: SearchQuery(text: [], filters: [.pinned]))
    try await measure(
      name: "filter-type-text",
      query: SearchQuery(text: [], filters: [.contentType(.text)]))
    try await measure(
      name: "filter-date",
      query: SearchQuery(
        text: [],
        filters: [
          .after(
            calendar.startOfDay(
              for: Date(timeIntervalSince1970: 1_600_000_000)))
        ]))
    try await measure(
      name: "mixed-term-filter",
      query: SearchQuery(text: [.term("postgres")], filters: [.application("Safari")]))
    try await measure(name: "recent-timeline", query: noText, samples: 30)

    // Parser end-to-end for the representative mixed query.
    let parsed = try parseQuery("postgres app:Safari", now: queryNow, calendar: calendar)
    try await measure(name: "parsed-mixed", query: parsed)

    // Search under a bounded concurrent writer.
    let writer = Task {
      for i in 0..<300 {
        _ = try? await repository.saveAcceptedText(
          AcceptedTextClip(
            id: UUID(), text: "concurrent writer payload \(i) postgres",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)))
      }
    }
    var concurrentLatencies: [Double] = []
    for _ in 0..<30 {
      let start = nowNanoseconds()
      _ = try await repository.search(
        SearchQuery(text: [.term("postgres")], filters: []), limit: 100)
      concurrentLatencies.append(Double(nowNanoseconds() - start) / 1_000_000)
    }
    await writer.value
    concurrentLatencies.sort()

    // Dedup path: re-save existing texts under fresh UUIDs.
    let dedupStart = nowNanoseconds()
    for i in 0..<1_000 {
      _ = try await repository.saveAcceptedText(
        AcceptedTextClip(
          id: UUID(), kind: fixtures[i].kind, text: fixtures[i].text,
          capturedAt: fixtures[i].date, source: fixtures[i].source))
    }
    let dedupSeconds = Double(nowNanoseconds() - dedupStart) / 1_000_000_000

    // Retention sweep over half the corpus, then tombstone purge.
    let retentionCutoff = Date(timeIntervalSince1970: 1_700_000_000 + 50_000)
    let expireStart = nowNanoseconds()
    _ = try await repository.deleteExpired(before: retentionCutoff)
    let expireSeconds = Double(nowNanoseconds() - expireStart) / 1_000_000_000
    let purgeStart = nowNanoseconds()
    _ = try await repository.purgeDeleted(before: Date(timeIntervalSince1970: 1_800_000_000))
    let purgeSeconds = Double(nowNanoseconds() - purgeStart) / 1_000_000_000
    let health = try await database.health()

    var usage = rusage()
    getrusage(Int32(RUSAGE_SELF), &usage)
    let peakRSS = Int(usage.ru_maxrss)
    let cpuSeconds =
      Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
      + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

    let walURL = workdir.appending(path: "bench.sqlite-wal")
    let report = Report(
      commit: commit,
      configuration: "release",
      hardwareModel: sysctlString("hw.model"),
      architecture: sysctlString("hw.machine"),
      cpuCount: sysctlInt("hw.ncpu"),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      sqliteVersion: health.sqliteVersion,
      journalMode: health.journalMode,
      corpusRecords: fixtures.count,
      loadSeconds: loadSeconds,
      loadPerSecond: Double(fixtures.count) / loadSeconds,
      dedupSeconds: dedupSeconds,
      dedupPerSecond: 1_000 / dedupSeconds,
      retentionExpireSeconds: expireSeconds,
      retentionPurgeSeconds: purgeSeconds,
      databaseBytes: fileSize(at: databaseURL),
      walBytes: fileSize(at: walURL),
      queries: queryStats,
      concurrentP95Ms: percentile(concurrentLatencies, 0.95),
      peakRSSBytes: peakRSS,
      cpuSeconds: cpuSeconds,
      verdict30ms: queryStats.allSatisfy { $0.p95Ms < 30 }
    )
    try? database.close()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = try encoder.encode(report)
    try payload.write(to: URL(fileURLWithPath: outputPath))

    print(
      "commit=\(commit) records=\(fixtures.count) load=\(String(format: "%.1f", report.loadPerSecond))/s"
    )
    for query in queryStats {
      print(
        "\(query.name): p50=\(String(format: "%.2f", query.medianMs))ms p95=\(String(format: "%.2f", query.p95Ms))ms p99=\(String(format: "%.2f", query.p99Ms))ms hits=\(query.resultChecksum)"
      )
    }
    print(
      "concurrent-p95=\(String(format: "%.2f", report.concurrentP95Ms))ms rss=\(peakRSS / 1_048_576)MiB db=\(report.databaseBytes / 1_048_576)MiB verdict30ms=\(report.verdict30ms) checksum=\(checksum)"
    )
  }
}

private enum ExitCode: Error {
  case failure
}
