import AppKit
import ClipDomain
import SwiftUI

/// Presentation pieces shared by Quick Paste and the Library, so a clip looks
/// like the same thing everywhere.

extension ClipKind {
  var displayName: String {
    switch self {
    case .text: "Text"
    case .link: "Link"
    case .image: "Image"
    case .code: "Code"
    case .color: "Color"
    case .file: "File"
    }
  }
}

/// Compact age ("11m") that refreshes once a minute. `Text(date, style:
/// .relative)` re-rendered every row every second and printed "11 min, 9
/// secs", which wraps in narrow rows.
struct ClipAgeText: View {
  enum Style { case compact, spoken }

  let date: Date
  var style: Style = .compact

  var body: some View {
    TimelineView(.everyMinute) { context in
      switch style {
      case .compact:
        Text(ClipAge.text(from: date, now: context.date))
          .help(date.formatted(date: .abbreviated, time: .shortened))
          .accessibilityLabel(ClipAge.spokenText(from: date, now: context.date))
      case .spoken:
        Text(ClipAge.spokenText(from: date, now: context.date))
          .help(date.formatted(date: .abbreviated, time: .shortened))
      }
    }
  }
}

/// One quiet visual language for both surfaces: selection is a neutral wash
/// rather than an accent slab, the accent is kept for focus, and secondary
/// information steps down through `.secondary` and `.tertiary` instead of
/// extra colors or boxes.
enum ClipStyle {
  static let rowRadius: CGFloat = 8
  static let cardRadius: CGFloat = 12

  /// Selected row or card background. Neutral so it works over any material
  /// in light and dark; contrast stays with the primary text color.
  static let selection = Color.primary.opacity(0.08)
  static let hairline = Color.primary.opacity(0.08)
}

/// Kind icon for list rows. Images resolve thumbnails; hex colors show their
/// swatch (functional notations keep the palette icon; the Transform menu
/// converts them to hex).
struct KindBadge: View {
  let clip: ClipSummary
  let loadThumbnail: @MainActor @Sendable () async -> NSImage?
  let isSelected: Bool

  var body: some View {
    Group {
      switch clip.kind {
      case .image:
        ClipThumbnail(load: loadThumbnail, isSelected: isSelected)
      case .code:
        badge("chevron.left.forwardslash.chevron.right")
      case .color:
        if let swatch = Color(hex: clip.text) {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(swatch)
            .overlay {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
            .frame(width: 28, height: 28)
        } else {
          badge("paintpalette")
        }
      case .file:
        badge("doc.fill")
      case .link:
        badge("link")
      case .text:
        badge("text.alignleft")
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }

  /// A bare monochrome glyph: the kind is information, not decoration, so it
  /// gets no tinted tile and no accent color.
  private func badge(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 14, weight: .regular))
      .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      .frame(width: 28, height: 28)
  }
}
