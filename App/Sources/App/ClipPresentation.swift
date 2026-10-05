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

  private func badge(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .foregroundStyle(isSelected ? Color.white : Color.accentColor)
      .frame(width: 28, height: 28)
      .background(
        (isSelected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
        in: RoundedRectangle(cornerRadius: 7)
      )
  }
}
