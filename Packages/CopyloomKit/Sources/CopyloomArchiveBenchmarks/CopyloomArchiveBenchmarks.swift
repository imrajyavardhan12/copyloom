import Darwin
import Foundation

private struct Options {
  var corpus: URL
  var workdir: URL
  var records: Int
  var images: Int
  var commit: String
  var phase: String?

  static func parse() throws -> Options {
    let args = CommandLine.arguments
    var values: [String: String] = [:]
    let allowed = ["--corpus", "--workdir", "--records", "--images", "--commit", "--phase"]
    var index = 1
    while index < args.count {
      guard allowed.contains(args[index]), index + 1 < args.count,
        values[args[index]] == nil
      else { throw BenchmarkFailure("arguments") }
      values[args[index]] = args[index + 1]
      index += 2
    }
    guard let corpus = values["--corpus"], let workdir = values["--workdir"],
      let records = Int(values["--records"] ?? "100000"), (1...1_000_000).contains(records),
      let images = Int(values["--images"] ?? "0"), (0...1000).contains(images),
      records + images <= 1_000_000
    else { throw BenchmarkFailure("arguments") }
    let phase = values["--phase"]
    if let phase,
      !["seed", "export", "verify", "plan", "apply", "roundtrip", "reimport", "reimportcheck"]
        .contains(phase)
    {
      throw BenchmarkFailure("arguments")
    }
    return Options(
      corpus: URL(fileURLWithPath: corpus).standardizedFileURL,
      workdir: URL(fileURLWithPath: workdir).standardizedFileURL,
      records: records, images: images, commit: values["--commit"] ?? "unknown", phase: phase)
  }

  var total: Int { records + images }
}

struct BenchmarkFailure: Error {
  let code: String
  init(_ code: String) { self.code = code }
}

struct PhaseReport: Codable {
  var name: String
  var processID: Int32
  var processGroupID: Int32
  var seconds: Double
  var verificationSeconds: Double
  var operationSeconds: Double
  var peakRSSBytes: Int
  var cpuSeconds: Double
  var clipsBefore: Int
  var clipsAfter: Int
  var added: Int
  var merged: Int
  var rejected: Int
  var imagesQueuedForOCR: Int
  var archiveBytes: Int
  var databaseBytes: Int
  var walBytes: Int
}

struct SetupReport: Codable {
  var corpusBytes: Int
  var corpusSHA256: String
  var textUniquenessSuffix: String
  var sqliteVersion: String
  var journalMode: String
}

private struct Report: Encodable {
  var processGroupID: Int32
  var commit: String
  var configuration: String
  var hardwareModel: String
  var architecture: String
  var cpuCount: Int
  var osVersion: String
  var swiftVersion: String
  var xcodeVersion: String
  var textRecords: Int
  var imageRecords: Int
  var setup: SetupReport
  var phases: [PhaseReport]
  var roundTripVerified: Bool
  var reimportContentUnchanged: Bool
}

func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(value).write(to: url, options: .atomic)
}

private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func sysctlString(_ name: String) -> String {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "unknown" }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
  return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Tool versions contain no corpus values or user-selected paths. Failed
/// subprocesses are reported with fixed codes, never localized error text.
private func version(_ executable: String, _ arguments: [String]) throws -> String {
  let data = try BenchmarkProcess.run(
    executable: executable, arguments: arguments, captureOutput: true)
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@main
private enum CopyloomArchiveBenchmarks {
  static func main() async {
    do {
      let options = try Options.parse()
      if let phase = options.phase {
        let marker = options.workdir.appending(path: ".copyloom-archive-bench")
        guard try String(contentsOf: marker, encoding: .utf8) == "synthetic-only\n" else {
          throw BenchmarkFailure("workdir_marker")
        }
        try await ArchiveWorkload(
          root: options.workdir, corpus: options.corpus,
          records: options.records, images: options.images
        ).run(phase)
      } else {
        try run(options)
        print("Archive benchmark passed (\(options.total) clips).")
      }
    } catch {
      let code = (error as? BenchmarkFailure)?.code ?? "operation"
      FileHandle.standardError.write(Data("Archive benchmark failed (\(code)).\n".utf8))
      exit(1)
    }
  }

  private static func run(_ options: Options) throws {
    // mkdir is exclusive: never delete, reuse or overwrite a caller's data.
    guard mkdir(options.workdir.path, S_IRWXU) == 0 else {
      throw BenchmarkFailure("new_workdir_required")
    }
    try Data("synthetic-only\n".utf8).write(
      to: options.workdir.appending(path: ".copyloom-archive-bench"))
    guard let executable = Bundle.main.executableURL else {
      throw BenchmarkFailure("executable_location")
    }
    // Every workload runs in a fresh process. Neither corpus seeding nor
    // correctness re-exports can inflate a measured phase's lifetime RSS.
    for phase in [
      "seed", "export", "verify", "plan", "apply", "roundtrip", "reimport", "reimportcheck",
    ] {
      do {
        _ = try BenchmarkProcess.run(
          executable: executable.path,
          arguments: [
            "--phase", phase, "--corpus", options.corpus.path, "--workdir", options.workdir.path,
            "--records", String(options.records), "--images", String(options.images),
          ])
      } catch {
        throw BenchmarkFailure("phase_\(phase)")
      }
    }
    let setup = try loadJSON(SetupReport.self, from: options.workdir.appending(path: "setup.json"))
    let phases = try ["export", "verify", "plan", "apply", "reimport"].map { phase in
      try loadJSON(PhaseReport.self, from: options.workdir.appending(path: "\(phase).json"))
    }
    #if DEBUG
      let configuration = "debug"
    #else
      let configuration = "release"
    #endif
    let report = Report(
      processGroupID: getpgrp(), commit: options.commit, configuration: configuration,
      hardwareModel: sysctlString("hw.model"), architecture: sysctlString("hw.machine"),
      cpuCount: ProcessInfo.processInfo.processorCount,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      swiftVersion: try version("/usr/bin/xcrun", ["swift", "--version"]),
      xcodeVersion: try version("/usr/bin/xcodebuild", ["-version"]),
      textRecords: options.records, imageRecords: options.images, setup: setup, phases: phases,
      roundTripVerified: true, reimportContentUnchanged: true)
    try saveJSON(report, to: options.workdir.appending(path: "report.json"))
  }
}
