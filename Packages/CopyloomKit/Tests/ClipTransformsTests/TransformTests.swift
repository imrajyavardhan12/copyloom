import ClipDomain
import Foundation
import Testing

@testable import ClipTransforms

private func clip(_ text: String, kind: ClipKind = .text) -> ClipSummary {
  ClipSummary(
    id: UUID(), kind: kind, text: text,
    createdAt: Date(timeIntervalSince1970: 0),
    lastSeenAt: Date(timeIntervalSince1970: 0),
    copyCount: 1, isPinned: false, isFavorite: false, source: nil)
}

private func run(_ id: String, _ input: String) throws -> String {
  let transform = try #require(TransformRegistry.builtIn.transform(id: id))
  return try transform.apply(input)
}

@Suite("Registry")
struct TransformRegistryTests {
  @Test("ids are unique and every built-in has a title")
  func idsUnique() {
    let all = TransformRegistry.builtIn.all
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(all.allSatisfy { !$0.title.isEmpty })
  }

  @Test("images and files offer no transforms")
  func nonTextOffersNothing() {
    #expect(TransformRegistry.builtIn.transforms(for: clip("x", kind: .image)).isEmpty)
    #expect(TransformRegistry.builtIn.transforms(for: clip("/tmp/a", kind: .file)).isEmpty)
  }

  @Test("JSON actions are offered only for JSON-looking text or code")
  func jsonOffered() {
    let json = TransformRegistry.builtIn.transforms(for: clip(#"{"a":1}"#, kind: .code)).map(\.id)
    #expect(json.contains("json.pretty"))
    #expect(json.contains("json.minify"))
    #expect(json.contains("json.validate"))
    let prose = TransformRegistry.builtIn.transforms(for: clip("hello world")).map(\.id)
    #expect(!prose.contains("json.pretty"))
  }

  @Test("color conversions are offered only for colors, never to the same format")
  func colorOffered() {
    let ids = TransformRegistry.builtIn.transforms(for: clip("#ff0000", kind: .color)).map(\.id)
    #expect(ids.contains("color.rgb"))
    #expect(ids.contains("color.hsl"))
    #expect(!ids.contains("color.hex"))
    let text = TransformRegistry.builtIn.transforms(for: clip("#ff0000")).map(\.id)
    #expect(!text.contains("color.rgb"))
  }

  @Test("unknown id resolves to nothing")
  func unknownID() {
    #expect(TransformRegistry.builtIn.transform(id: "nope") == nil)
  }
}

@Suite("JSON transforms")
struct JSONTransformTests {
  @Test("pretty prints with two-space indent and preserves key order")
  func pretty() throws {
    let output = try run("json.pretty", #"{"b":[1,2],"a":{"c":null},"e":[],"f":{}}"#)
    #expect(
      output == """
        {
          "b": [
            1,
            2
          ],
          "a": {
            "c": null
          },
          "e": [],
          "f": {}
        }
        """)
  }

  @Test("minify removes insignificant whitespace and preserves key order")
  func minify() throws {
    let output = try run("json.minify", "{\n  \"z\" : [ 1, 2 ],\n  \"a\" : true\n}")
    #expect(output == #"{"z":[1,2],"a":true}"#)
  }

  @Test("number text and string escapes survive byte-for-byte")
  func lexemesPreserved() throws {
    let input = #"{"n":1.10,"big":12345678901234567890,"e":1E+2,"s":"a \"{,}\" é \/"}"#
    let minified = try run("json.minify", input)
    #expect(minified == input)
    let pretty = try run("json.pretty", input)
    #expect(try run("json.minify", pretty) == input)
  }

  @Test("pretty-printing scales linearly on multi-megabyte clips")
  func prettyScales() throws {
    // Regression: appending indentation scalar-by-scalar into a
    // `String.UnicodeScalarView` made pretty-printing quadratic (≈92 s for
    // 5 MiB). Capture allows 5 MiB clips, so this must stay fast. The bound
    // is generous (≈50× the linear cost) to avoid flaking on slow CI.
    let record = #"{"id":1,"name":"item","vals":[1.10,2,3],"nested":{"k":"v"}}"#
    let count = 2 * 1_024 * 1_024 / (record.utf8.count + 1)
    let json = "[" + Array(repeating: record, count: count).joined(separator: ",") + "]"
    let start = ContinuousClock.now

    let output = try run("json.pretty", json)

    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(try run("json.minify", output) == json)
  }

  @Test("structural characters inside strings are not reformatted")
  func stringsUntouched() throws {
    let output = try run("json.pretty", #"{"k":"[1, 2]: {x}"}"#)
    #expect(output == "{\n  \"k\": \"[1, 2]: {x}\"\n}")
  }

  @Test("invalid JSON throws a typed error and never returns partial output")
  func invalid() {
    #expect(throws: TransformError.self) { try run("json.pretty", "{oops") }
    #expect(throws: TransformError.self) { try run("json.minify", "") }
  }

  @Test("validate returns the input unchanged when valid, throws otherwise")
  func validate() throws {
    #expect(try run("json.validate", "[1, 2]") == "[1, 2]")
    #expect(throws: TransformError.self) { try run("json.validate", "[1, 2") }
  }
}

@Suite("Text transforms")
struct TextTransformTests {
  @Test("case conversions")
  func cases() throws {
    #expect(try run("text.uppercase", "Hello, wörld") == "HELLO, WÖRLD")
    #expect(try run("text.lowercase", "Hello, WÖRLD") == "hello, wörld")
    #expect(try run("text.titlecase", "the quick  brown fox") == "The Quick  Brown Fox")
    #expect(try run("text.titlecase", "don't PANIC") == "Don't Panic")
  }

  @Test("trim removes only outer whitespace and newlines")
  func trim() throws {
    #expect(try run("text.trim", "  \n a  b \t\n") == "a  b")
  }

  @Test("collapse whitespace squeezes runs and trims")
  func collapse() throws {
    #expect(try run("text.collapse-whitespace", "  a \t\n b   c ") == "a b c")
  }
}

@Suite("Encoding transforms")
struct EncodingTransformTests {
  @Test("URL encode escapes reserved characters and round-trips")
  func urlRoundTrip() throws {
    let encoded = try run("url.encode", "a b&c=d/é")
    #expect(encoded == "a%20b%26c%3Dd%2F%C3%A9")
    #expect(try run("url.decode", encoded) == "a b&c=d/é")
  }

  @Test("URL decode of malformed escapes throws")
  func urlDecodeInvalid() {
    #expect(throws: TransformError.self) { try run("url.decode", "%E0%A4%A") }
  }

  @Test("Base64 encodes UTF-8 and round-trips")
  func base64RoundTrip() throws {
    let encoded = try run("base64.encode", "héllo")
    #expect(encoded == "aMOpbGxv")
    #expect(try run("base64.decode", encoded) == "héllo")
  }

  @Test("Base64 decode tolerates whitespace and missing padding")
  func base64Lenient() throws {
    #expect(try run("base64.decode", " aGVs\nbG8 ") == "hello")
  }

  @Test("Base64 decode accepts the URL-safe alphabet")
  func base64URLSafe() throws {
    #expect(try run("base64.decode", "Pz8_Pz8-") == "?????>")
  }

  @Test("decode actions are offered only when the text plausibly needs them")
  func decodeOffered() {
    let registry = TransformRegistry.builtIn
    #expect(registry.transforms(for: clip("a%20b")).map(\.id).contains("url.decode"))
    #expect(!registry.transforms(for: clip("a b")).map(\.id).contains("url.decode"))
    #expect(registry.transforms(for: clip("aGVsbG8=")).map(\.id).contains("base64.decode"))
    #expect(!registry.transforms(for: clip("hello, world!")).map(\.id).contains("base64.decode"))
  }

  @Test("Base64 decode rejects non-Base64 and non-UTF-8 payloads")
  func base64Invalid() {
    #expect(throws: TransformError.self) { try run("base64.decode", "***") }
    #expect(throws: TransformError.self) { try run("base64.decode", "/w==") }
  }
}

@Suite("Color transforms")
struct ColorTransformTests {
  @Test("hex to rgb and hsl")
  func fromHex() throws {
    #expect(try run("color.rgb", "#ff0000") == "rgb(255, 0, 0)")
    #expect(try run("color.hsl", "#ff0000") == "hsl(0, 100%, 50%)")
    #expect(try run("color.rgb", "#0f8") == "rgb(0, 255, 136)")
  }

  @Test("rgb to hex and hsl")
  func fromRGB() throws {
    #expect(try run("color.hex", "rgb(0, 128, 255)") == "#0080ff")
    #expect(try run("color.hsl", "rgb(0, 128, 255)") == "hsl(210, 100%, 50%)")
  }

  @Test("hsl to hex and rgb")
  func fromHSL() throws {
    #expect(try run("color.hex", "hsl(120, 100%, 25%)") == "#008000")
    #expect(try run("color.rgb", "hsl(120, 100%, 25%)") == "rgb(0, 128, 0)")
  }

  @Test("alpha is preserved across formats")
  func alpha() throws {
    #expect(try run("color.rgb", "#ff000080") == "rgba(255, 0, 0, 0.5)")
    #expect(try run("color.hex", "rgba(255, 0, 0, 0.5)") == "#ff000080")
    #expect(try run("color.hsl", "rgba(255, 0, 0, 0.5)") == "hsla(0, 100%, 50%, 0.5)")
  }

  @Test("whitespace and case are tolerated; garbage throws")
  func tolerance() throws {
    #expect(try run("color.rgb", "  #FF0000\n") == "rgb(255, 0, 0)")
    #expect(throws: TransformError.self) { try run("color.rgb", "not a color") }
    #expect(throws: TransformError.self) { try run("color.rgb", "rgb(300, 0, 0)") }
  }

  @Test("greys convert without hue artifacts")
  func greys() throws {
    #expect(try run("color.hsl", "#808080") == "hsl(0, 0%, 50%)")
    #expect(try run("color.hex", "hsl(0, 0%, 100%)") == "#ffffff")
  }
}
