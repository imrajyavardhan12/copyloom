import Foundation

private struct Fixture: Encodable {
  let sequence: Int
  let uuid: String
  let text: String
  let capturedAtMilliseconds: Int64
}

private struct Generator {
  private static let vocabulary = [
    "clipboard", "postgres", "connection", "refused", "Safari", "Ghostty", "Swift",
    "privacy", "local", "invoice", "screenshot", "project", "JSON", "deployment", "color",
    "Figma", "terminal", "documentation", "tokenizer", "collection",
  ]

  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func fixture(sequence: Int) -> Fixture {
    let wordCount = 6 + Int(next() % 30)
    var words: [String] = []
    words.reserveCapacity(wordCount + 2)
    for _ in 0..<wordCount {
      words.append(Self.vocabulary[Int(next() % UInt64(Self.vocabulary.count))])
    }
    if sequence.isMultiple(of: 997) {
      words.append("rare-marker-\(sequence)")
    }
    if sequence.isMultiple(of: 13) {
      words.append("https://example.invalid/item/\(sequence)")
    }

    return Fixture(
      sequence: sequence,
      uuid: deterministicUUID(sequence: sequence),
      text: words.joined(separator: " "),
      capturedAtMilliseconds: 1_700_000_000_000 + Int64(sequence * 1_000)
    )
  }

  private mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }

  private func deterministicUUID(sequence: Int) -> String {
    let value = UInt64(sequence)
    return String(
      format: "%08X-%04X-7%03X-8%03X-%012llX",
      UInt32(truncatingIfNeeded: value >> 32),
      UInt16(truncatingIfNeeded: value >> 16),
      UInt16(truncatingIfNeeded: value) & 0x0FFF,
      UInt16(truncatingIfNeeded: value >> 4) & 0x0FFF,
      value
    ).lowercased()
  }
}

private struct Options {
  let records: Int
  let outputURL: URL

  static func parse(arguments: [String]) throws -> Options {
    var records = 100_000
    var outputPath: String?
    var index = 1

    while index < arguments.count {
      switch arguments[index] {
      case "--records":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
          throw OptionsError.invalidRecords
        }
        records = value
      case "--output":
        index += 1
        guard index < arguments.count else { throw OptionsError.missingOutput }
        outputPath = arguments[index]
      default:
        throw OptionsError.unknownArgument(arguments[index])
      }
      index += 1
    }

    guard let outputPath else { throw OptionsError.missingOutput }
    return Options(
      records: records,
      outputURL: URL(fileURLWithPath: outputPath).standardizedFileURL
    )
  }
}

private enum OptionsError: Error, CustomStringConvertible {
  case invalidRecords
  case missingOutput
  case unknownArgument(String)
  case unableToCreateOutput(String)

  var description: String {
    switch self {
    case .invalidRecords: return "--records must be a positive integer"
    case .missingOutput: return "--output PATH is required"
    case .unknownArgument(let argument): return "unknown argument: \(argument)"
    case .unableToCreateOutput(let path): return "unable to create output file: \(path)"
    }
  }
}

@main
private enum CopyloomCorpusGenerator {
  static func main() throws {
    do {
      let options = try Options.parse(arguments: CommandLine.arguments)
      try FileManager.default.createDirectory(
        at: options.outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: options.outputURL.path) {
        try FileManager.default.removeItem(at: options.outputURL)
      }
      guard FileManager.default.createFile(atPath: options.outputURL.path, contents: nil) else {
        throw OptionsError.unableToCreateOutput(options.outputURL.path)
      }
      let file = try FileHandle(forWritingTo: options.outputURL)
      defer { try? file.close() }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var generator = Generator(seed: 0xC0_FF_EE_12_34_56_78)

      for sequence in 0..<options.records {
        var line = try encoder.encode(generator.fixture(sequence: sequence))
        line.append(0x0A)
        try file.write(contentsOf: line)
      }

      print("Generated \(options.records) deterministic records at \(options.outputURL.path)")
    } catch let error as OptionsError {
      FileHandle.standardError.write(
        Data(
          "error: \(error.description)\nusage: copyloom-corpus [--records N] --output PATH\n".utf8)
      )
      throw error
    }
  }
}
