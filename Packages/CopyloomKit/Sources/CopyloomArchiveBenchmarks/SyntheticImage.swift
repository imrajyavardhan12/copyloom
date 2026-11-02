import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Distinct 1024×768 synthetic cards, with a fixed non-sensitive caption.
/// They exercise real PNG decode + Vision preflight, not OCR accuracy on
/// real screenshots. Keep this profile separate from the text-only result.
enum SyntheticImage {
  static func png(index: Int) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: 1_024, height: 768, bitsPerComponent: 8, bytesPerRow: 1_024 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw BenchmarkFailure("image_context") }
    context.setFillColor(
      red: CGFloat(index % 256) / 255, green: CGFloat(index / 256) / 255, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
    let caption = NSAttributedString(
      string: "Copyloom synthetic image \(index)",
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica" as CFString, 36, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          gray: 1, alpha: 1),
      ])
    context.textPosition = CGPoint(x: 64, y: 384)
    CTLineDraw(CTLineCreateWithAttributedString(caption), context)
    guard let image = context.makeImage() else { throw BenchmarkFailure("image_bitmap") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw BenchmarkFailure("image_destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BenchmarkFailure("image_encode") }
    return data as Data
  }
}
