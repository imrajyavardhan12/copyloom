import ClipDomain
import Foundation

/// HEX / RGB / HSL conversions for clips classified as colors.
///
/// Accepts exactly the shapes capture classifies as `.color` (`#rgb`,
/// `#rgba`, `#rrggbb`, `#rrggbbaa`, integer `rgb()/rgba()/hsl()/hsla()`), so
/// every color clip is convertible and nothing else is offered.
enum ColorTransforms {
  static let all: [FunctionTransform] = [
    transform(id: "color.hex", title: "Convert to HEX", target: .hex),
    transform(id: "color.rgb", title: "Convert to RGB", target: .rgb),
    transform(id: "color.hsl", title: "Convert to HSL", target: .hsl),
  ]

  private enum Format: Equatable { case hex, rgb, hsl }

  private struct Color {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Double
    let format: Format
  }

  private static func transform(id: String, title: String, target: Format) -> FunctionTransform {
    FunctionTransform(
      id: id, title: title,
      isRelevant: { clip in
        guard clip.kind == .color, let color = parse(clip.text) else { return false }
        return color.format != target
      },
      transform: { input in
        guard let color = parse(input) else {
          throw TransformError("Not a recognized color")
        }
        return render(color, as: target)
      })
  }

  // MARK: - Parsing

  private static func parse(_ input: String) -> Color? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasPrefix("#") { return parseHex(text.dropFirst()) }
    if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
      let name = String(text[..<open])
      let parts = text[text.index(after: open)..<text.index(before: text.endIndex)]
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      switch name {
      case "rgb", "rgba": return parseRGB(parts, hasAlpha: name == "rgba")
      case "hsl", "hsla": return parseHSL(parts, hasAlpha: name == "hsla")
      default: return nil
      }
    }
    return nil
  }

  private static func parseHex(_ hex: Substring) -> Color? {
    guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
    var digits = Array(hex)
    if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
    func byte(_ offset: Int) -> Int {
      Int(String(digits[offset...offset + 1]), radix: 16) ?? 0
    }
    let alpha = digits.count == 8 ? Double(byte(6)) / 255 : 1
    return Color(red: byte(0), green: byte(2), blue: byte(4), alpha: alpha, format: .hex)
  }

  private static func parseRGB(_ parts: [String], hasAlpha: Bool) -> Color? {
    guard parts.count == (hasAlpha ? 4 : 3) else { return nil }
    let channels = parts.prefix(3).compactMap(Int.init)
    guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else {
      return nil
    }
    guard let alpha = parseAlpha(parts, hasAlpha: hasAlpha) else { return nil }
    return Color(
      red: channels[0], green: channels[1], blue: channels[2], alpha: alpha, format: .rgb)
  }

  private static func parseHSL(_ parts: [String], hasAlpha: Bool) -> Color? {
    guard parts.count == (hasAlpha ? 4 : 3) else { return nil }
    guard let hue = Int(parts[0]), (0...360).contains(hue),
      parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
      let saturation = Int(parts[1].dropLast()), (0...100).contains(saturation),
      let lightness = Int(parts[2].dropLast()), (0...100).contains(lightness),
      let alpha = parseAlpha(parts, hasAlpha: hasAlpha)
    else {
      return nil
    }
    let (red, green, blue) = hslToRGB(
      hue: Double(hue), saturation: Double(saturation) / 100, lightness: Double(lightness) / 100)
    return Color(red: red, green: green, blue: blue, alpha: alpha, format: .hsl)
  }

  private static func parseAlpha(_ parts: [String], hasAlpha: Bool) -> Double? {
    guard hasAlpha else { return 1 }
    guard let alpha = Double(parts[3]), (0...1).contains(alpha) else { return nil }
    return alpha
  }

  // MARK: - Rendering

  private static func render(_ color: Color, as target: Format) -> String {
    let opaque = color.alpha >= 1
    switch target {
    case .hex:
      var result = "#" + hexByte(color.red) + hexByte(color.green) + hexByte(color.blue)
      if !opaque { result += hexByte(Int((color.alpha * 255).rounded())) }
      return result
    case .rgb:
      let channels = "\(color.red), \(color.green), \(color.blue)"
      return opaque ? "rgb(\(channels))" : "rgba(\(channels), \(alphaText(color.alpha)))"
    case .hsl:
      let (hue, saturation, lightness) = rgbToHSL(
        red: color.red, green: color.green, blue: color.blue)
      let channels = "\(hue), \(saturation)%, \(lightness)%"
      return opaque ? "hsl(\(channels))" : "hsla(\(channels), \(alphaText(color.alpha)))"
    }
  }

  private static func hexByte(_ value: Int) -> String {
    let text = String(value, radix: 16)
    return text.count == 1 ? "0" + text : text
  }

  /// Two decimals with trailing zeros dropped: 0.5, 0.25, 0.
  private static func alphaText(_ alpha: Double) -> String {
    var text = String(format: "%.2f", alpha)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  // MARK: - Color-space math

  private static func hslToRGB(
    hue: Double, saturation: Double, lightness: Double
  ) -> (Int, Int, Int) {
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let sector = hue.truncatingRemainder(dividingBy: 360) / 60
    let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double)
    switch sector {
    case ..<1: (r, g, b) = (chroma, secondary, 0)
    case ..<2: (r, g, b) = (secondary, chroma, 0)
    case ..<3: (r, g, b) = (0, chroma, secondary)
    case ..<4: (r, g, b) = (0, secondary, chroma)
    case ..<5: (r, g, b) = (secondary, 0, chroma)
    default: (r, g, b) = (chroma, 0, secondary)
    }
    let match = lightness - chroma / 2
    func channel(_ value: Double) -> Int { Int(((value + match) * 255).rounded()) }
    return (channel(r), channel(g), channel(b))
  }

  private static func rgbToHSL(red: Int, green: Int, blue: Int) -> (Int, Int, Int) {
    let r = Double(red) / 255
    let g = Double(green) / 255
    let b = Double(blue) / 255
    let high = max(r, g, b)
    let low = min(r, g, b)
    let delta = high - low
    let lightness = (high + low) / 2
    guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }
    let saturation = delta / (1 - abs(2 * lightness - 1))
    var hue: Double
    switch high {
    case r: hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
    case g: hue = 60 * ((b - r) / delta + 2)
    default: hue = 60 * ((r - g) / delta + 4)
    }
    if hue < 0 { hue += 360 }
    let roundedHue = Int(hue.rounded()) % 360
    return (roundedHue, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
  }
}
