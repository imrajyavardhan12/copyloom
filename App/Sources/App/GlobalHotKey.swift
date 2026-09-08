import Carbon.HIToolbox
import Foundation

/// Global keyboard shortcuts via Carbon `RegisterEventHotKey` (no Input
/// Monitoring permission required). One instance owns one event handler and
/// any number of registrations; the handler dispatches by pressed hotkey ID
/// so shortcuts never cross-fire.
final class GlobalHotKey {
  enum RegistrationError: Error {
    case installHandler(OSStatus)
    case register(OSStatus)
  }

  struct Registration: Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var identifier: UInt32
    var action: @MainActor @Sendable () -> Void
  }

  static let quickPasteIdentifier: UInt32 = 1
  static let libraryIdentifier: UInt32 = 2

  private static let signature: OSType = 0x4350_4C4D  // CPLM

  private let context: HotKeyContext
  private let storage = HotKeyStorage()

  convenience init(action: @escaping @MainActor @Sendable () -> Void) throws {
    try self.init(registrations: [
      Registration(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | controlKey),
        identifier: Self.quickPasteIdentifier,
        action: action
      )
    ])
  }

  init(registrations: [Registration]) throws {
    let context = HotKeyContext()
    self.context = context
    storage.context = context

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      copyloomHotKeyHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(context).toOpaque(),
      &storage.eventHandlerReference
    )
    guard installStatus == noErr else {
      throw RegistrationError.installHandler(installStatus)
    }

    do {
      for registration in registrations {
        let box = HotKeyCallbackBox(
          identifier: registration.identifier, action: registration.action)
        context.boxes.append(box)
        let hotKeyID = EventHotKeyID(
          signature: Self.signature,
          id: registration.identifier
        )
        var reference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
          registration.keyCode,
          registration.modifiers,
          hotKeyID,
          GetApplicationEventTarget(),
          0,
          &reference
        )
        guard registerStatus == noErr, let reference else {
          throw RegistrationError.register(registerStatus)
        }
        storage.hotKeyReferences.append(reference)
      }
    } catch {
      storage.unregister()
      throw error
    }
  }
}

private nonisolated final class HotKeyStorage: @unchecked Sendable {
  var hotKeyReferences: [EventHotKeyRef] = []
  var eventHandlerReference: EventHandlerRef?
  var context: HotKeyContext?

  func unregister() {
    for reference in hotKeyReferences {
      UnregisterEventHotKey(reference)
    }
    hotKeyReferences = []
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
      self.eventHandlerReference = nil
    }
    context = nil
  }

  deinit {
    unregister()
  }
}

private final class HotKeyContext: @unchecked Sendable {
  var boxes: [HotKeyCallbackBox] = []
}

private final class HotKeyCallbackBox: NSObject, @unchecked Sendable {
  let identifier: UInt32
  let action: @MainActor @Sendable () -> Void

  init(identifier: UInt32, action: @escaping @MainActor @Sendable () -> Void) {
    self.identifier = identifier
    self.action = action
  }

  @objc func invoke() {
    Task { @MainActor in action() }
  }
}

private let copyloomHotKeyHandler: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  let context = Unmanaged<HotKeyContext>.fromOpaque(userData).takeUnretainedValue()
  var pressed = EventHotKeyID(signature: 0, id: 0)
  let status: OSStatus = withUnsafeMutablePointer(to: &pressed) { pointer in
    pointer.withMemoryRebound(
      to: UInt8.self, capacity: MemoryLayout<EventHotKeyID>.size
    ) { bytes in
      GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        bytes
      )
    }
  }
  guard status == noErr else { return OSStatus(eventNotHandledErr) }
  guard let box = context.boxes.first(where: { $0.identifier == pressed.id }) else {
    return OSStatus(eventNotHandledErr)
  }
  box.performSelector(
    onMainThread: #selector(HotKeyCallbackBox.invoke), with: nil, waitUntilDone: false)
  return noErr
}
