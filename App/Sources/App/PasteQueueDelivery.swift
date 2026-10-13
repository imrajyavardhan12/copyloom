import AppKit
import ClipDomain
import CoreGraphics
import QuickPasteFeature

/// Pastes one Paste Queue item into the app that is frontmost when ⌃⌥V is
/// pressed (ADR 0007 §4). It never re-activates a remembered app: the user
/// is already in the target field. Every refusal leaves the item on the
/// clipboard so the user's own ⌘V still works.
@MainActor
final class PasteQueueDelivery: PasteQueueDelivering {
  private let copier: PasteboardClipCopier
  private let imageLoader: @MainActor (UUID) async -> (data: Data, uti: String)?

  /// How long the shortcut's modifier keys may stay down before Copyloom
  /// gives up on posting ⌘V and leaves the item copied instead.
  private static let modifierReleaseTimeout: Duration = .milliseconds(500)
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
    if clip.kind == .image {
      guard let image = await imageLoader(clip.id) else { return .unavailable }
      try copier.copyImage(
        image.data, uti: image.uti, sourceBundleID: clip.source?.bundleIdentifier)
    } else {
      try copier.copy(clip)
    }

    guard CGPreflightPostEventAccess() else { return .copied(.noAccessibility) }
    guard
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    else {
      return .copied(.copyloomFrontmost)
    }
    // The user is still holding ⌃⌥ from the shortcut. A ⌘V posted now can
    // reach the app combined with them, so wait for the keys to come up.
    guard await waitForModifierRelease() else { return .copied(.modifiersHeld) }

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
