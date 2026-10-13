import AppKit
import ClipDomain
import CoreGraphics
import QuickPasteFeature

/// Pastes one Paste Queue item into the app that is frontmost when ⌃⌥V is
/// pressed (ADR 0007 §4). It never re-activates a remembered app: the user
/// is already in the target field. Refusals write nothing and keep the item;
/// without Accessibility the item is copied for the user's own ⌘V.
@MainActor
final class PasteQueueDelivery: PasteQueueDelivering {
  private let copier: PasteboardClipCopier
  private let imageLoader: @MainActor (UUID) async -> (data: Data, uti: String)?

  /// How long the shortcut's modifier keys may stay down before Copyloom
  /// gives up on this press (nothing is written; the item stays next).
  private static let modifierReleaseTimeout: Duration = .seconds(2)
  private static let heldModifiers: CGEventFlags = [
    .maskControl, .maskAlternate, .maskCommand, .maskShift,
  ]

  init(
    copier: PasteboardClipCopier = PasteboardClipCopier(),
    imageLoader: @escaping @MainActor (UUID) async -> (data: Data, uti: String)?
  ) {
    self.copier = copier
    self.imageLoader = imageLoader
  }

  func deliverQueued(_ clip: ClipSummary) async throws -> PasteQueueDeliveryResult {
    // Copyloom's own window is not a paste target, and advancing here would
    // silently lose the item.
    guard
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    else {
      return .refused(.copyloomFrontmost)
    }
    // Wait for ⌃⌥ to come up before writing anything. A ⌘V posted while they
    // are down can reach the app combined with them, and a held shortcut
    // auto-repeats: each repeat would otherwise deliver another item.
    guard await waitForModifierRelease() else { return .refused(.keysHeld) }

    if clip.kind == .image {
      guard let image = await imageLoader(clip.id) else { return .unavailable }
      try copier.copyImage(
        image.data, uti: image.uti, sourceBundleID: clip.source?.bundleIdentifier)
    } else {
      try copier.copy(clip)
    }

    guard CGPreflightPostEventAccess() else { return .copied }
    try PasteKeystroke.postCommandV()
    return .pasted
  }

  private func waitForModifierRelease() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + Self.modifierReleaseTimeout
    while clock.now < deadline {
      if CGEventSource.flagsState(.combinedSessionState).intersection(Self.heldModifiers)
        .isEmpty
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}
