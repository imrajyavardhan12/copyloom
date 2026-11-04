#!/usr/bin/env swift  // Regenerate the approved Paper weave identity: xcrun swift scripts/generate-app-icons.swift  // Apple frameworks only; this developer tool is not part of the app runtime.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum IconGenerationError: Error {
  case bitmap, image, png, pdf
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent()
private let assets = root.appending(path: "App/Resources/Assets.xcassets")
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hex >> 16) & 255) / 255,
    green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

private func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func outline(_ path: CGPath, width: CGFloat) -> CGPath {
  path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// Alternating over/under crossings are real negative space, not background-
// colored strokes. The same vector geometry works on every menu-bar material.
private func paperPaths() -> (back: CGPath, front: CGPath) {
  let back = rounded(CGRect(x: 390, y: 360, width: 300, height: 390), radius: 65)
  let front = rounded(CGRect(x: 280, y: 250, width: 300, height: 390), radius: 65)
  let crossing = CGPath(rect: CGRect(x: 340, y: 584, width: 100, height: 104), transform: nil)
  let backInk = outline(back, width: 58)
  let frontInk = outline(front, width: 58)
  return (
    backInk.subtracting(outline(front, width: 86)).union(backInk.intersection(crossing)),
    frontInk.subtracting(outline(back, width: 86).intersection(crossing))
  )
}

private func drawMark(in context: CGContext, monochrome: Bool) {
  let paths = paperPaths()
  context.saveGState()
  // Optical centering of the asymmetrically offset paper loops.
  context.translateBy(x: 27, y: 12)
  context.setFillColor(color(monochrome ? 0x000000 : 0x83DCD3))
  context.addPath(paths.back)
  context.fillPath()
  context.setFillColor(color(monochrome ? 0x000000 : 0xF6F8FF))
  context.addPath(paths.front)
  context.fillPath()
  context.restoreGState()
}

private func appIcon(pixels: Int) throws -> CGImage {
  guard
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
      bytesPerRow: pixels * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw IconGenerationError.bitmap }
  let scale = CGFloat(pixels) / 1024
  context.scaleBy(x: scale, y: scale)
  let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 184)
  context.saveGState()
  // Quartz shadows use device space: scale them explicitly, otherwise the
  // small representations get a clipped, square halo instead of a soft edge.
  context.setShadow(
    offset: CGSize(width: 0, height: -12 * scale), blur: 26 * scale,
    color: color(0x050D1B, alpha: 0.23))
  context.setFillColor(color(0x111E33))
  context.addPath(plate)
  context.fillPath()
  context.restoreGState()
  context.saveGState()
  context.addPath(plate)
  context.clip()
  let gradient = CGGradient(
    colorsSpace: colorSpace, colors: [color(0x243C60), color(0x101A2E)] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: 260, y: 940), end: CGPoint(x: 750, y: 100),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  context.restoreGState()
  context.setStrokeColor(color(0xFFFFFF, alpha: 0.10))
  context.setLineWidth(2)
  context.addPath(plate)
  context.strokePath()
  drawMark(in: context, monochrome: false)
  guard let image = context.makeImage() else { throw IconGenerationError.image }
  return image
}

private func savePNG(_ image: CGImage, at url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw IconGenerationError.png }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw IconGenerationError.png }
}

private func saveMenuPDF(at url: URL) throws {
  var bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
  guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
    throw IconGenerationError.pdf
  }
  context.beginPDFPage(nil)
  context.translateBy(x: 9, y: 9)
  context.scaleBy(x: 0.028, y: 0.028)
  context.translateBy(x: -512, y: -512)
  drawMark(in: context, monochrome: true)
  context.endPDFPage()
  context.closePDF()
}

private func saveJSON(_ object: [String: Any], at url: URL) throws {
  var data = try JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  data.append(0x0A)
  try data.write(to: url, options: .atomic)
}

let appDirectory = assets.appending(path: "AppIcon.appiconset")
let menuDirectory = assets.appending(path: "MenuBarMark.imageset")
try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuDirectory, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
try saveJSON(["info": info], at: assets.appending(path: "Contents.json"))
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try savePNG(try appIcon(pixels: size * scale), at: appDirectory.appending(path: filename))
    images.append([
      "filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)",
    ])
  }
}
try saveJSON(["images": images, "info": info], at: appDirectory.appending(path: "Contents.json"))
try saveMenuPDF(at: menuDirectory.appending(path: "MenuBarMark.pdf"))
try saveJSON(
  [
    "images": [["filename": "MenuBarMark.pdf", "idiom": "mac"]], "info": info,
    "properties": [
      "preserves-vector-representation": true, "template-rendering-intent": "template",
    ],
  ], at: menuDirectory.appending(path: "Contents.json"))
print("Generated Paper weave app icons (16–1024 px) and an 18 pt vector menu-bar template.")
