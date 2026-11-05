import SwiftUI

extension View {
  /// Gives a custom, floating surface Apple's Liquid Glass (`glassEffect`, `regular` variant) on
  /// macOS 26 and later, and a system material on earlier systems.
  ///
  /// Liquid Glass is for the functional layer that floats above content, so this is applied to a
  /// whole panel, never to rows or controls inside it. The system handles Reduce Transparency and
  /// the user's Liquid Glass preference. Hosted CI builds with an SDK that predates
  /// `glassEffect`, so the glass branch compiles only when the compiler knows it.
  func glassSurface(cornerRadius: CGFloat) -> some View {
    modifier(GlassSurface(cornerRadius: cornerRadius))
  }
}

private struct GlassSurface: ViewModifier {
  let cornerRadius: CGFloat
  @Environment(\.usesGlassSurface) private var usesGlassSurface

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if !usesGlassSurface {
      content
    } else {
      #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
          content.glassEffect(.regular, in: shape)
        } else {
          material(content)
        }
      #else
        material(content)
      #endif
    }
  }

  private func material(_ content: Content) -> some View {
    content
      .background(.ultraThickMaterial)
      .clipShape(shape)
      .overlay { shape.strokeBorder(.separator.opacity(0.7), lineWidth: 1) }
  }
}

extension EnvironmentValues {
  /// Off in preview snapshots: an offscreen window has nothing behind it for glass to sample.
  @Entry var usesGlassSurface = true
}
