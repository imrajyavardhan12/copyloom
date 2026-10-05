import SwiftUI

/// Lazily loaded image thumbnail shared by Quick Paste rows, Library rows
/// and cards. The `.task` starts on appearance and cancels on disappearance,
/// so off-screen rows never decode bytes. Callers inject the loader so this
/// view stays independent of any one feature model.
struct ClipThumbnail: View {
  enum Style {
    /// 28 pt square icon-sized badge for list rows.
    case badge
    /// Full-width image of a given height, for cards.
    case fill(height: CGFloat)
  }

  /// Main-actor and Sendable so the non-Sendable `NSImage?` result never
  /// crosses an isolation boundary on its way into view state.
  let load: @MainActor @Sendable () async -> NSImage?
  let isSelected: Bool
  var style: Style = .badge

  @State private var image: NSImage?

  var body: some View {
    switch style {
    case .badge:
      content
        .frame(width: 28, height: 28)
        .background(
          (isSelected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
          in: RoundedRectangle(cornerRadius: 7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task { @MainActor in image = await load() }
    case .fill(let height):
      // The image sits in an overlay on a fixed-size base: a `scaledToFill`
      // image otherwise reports its natural width to layout and pushes the
      // card past the grid edge.
      Color.secondary.opacity(0.12)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay { content }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task { @MainActor in image = await load() }
    }
  }

  private var content: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isSelected ? Color.white : Color.accentColor)
      }
    }
  }
}
