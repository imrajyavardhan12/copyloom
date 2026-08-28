import Carbon.HIToolbox
import Foundation

final class GlobalHotKey {
  enum RegistrationError: Error {
    case installHandler(OSStatus)
    case register(OSStatus)
  }

  private static let signature: OSType = 0x4350_4C4D  // CPLM
  private static let identifier: UInt32 = 1

  private let callbackBox: HotKeyCallbackBox
  private let storage = HotKeyStorage()

  init(action: @escaping @MainActor @Sendable () -> Void) throws {
    callbackBox = HotKeyCallbackBox(action: action)
    storage.callbackBox = callbackBox

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      copyloomHotKeyHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(callbackBox).toOpaque(),
      &storage.eventHandlerReference
    )
    guard installStatus == noErr else {
      throw RegistrationError.installHandler(installStatus)
    }

    let hotKeyID = EventHotKeyID(
      signature: Self.signature,
      id: Self.identifier
    )
    let registerStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      UInt32(cmdKey | controlKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &storage.hotKeyReference
    )
    guard registerStatus == noErr else {
      storage.unregister()
      throw RegistrationError.register(registerStatus)
    }
  }

}

private nonisolated final class HotKeyStorage: @unchecked Sendable {
  var hotKeyReference: EventHotKeyRef?
  var eventHandlerReference: EventHandlerRef?
  var callbackBox: HotKeyCallbackBox?

  func unregister() {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
      self.hotKeyReference = nil
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
      self.eventHandlerReference = nil
    }
    callbackBox = nil
  }

  deinit {
    unregister()
  }
}

private final class HotKeyCallbackBox: NSObject, @unchecked Sendable {
  let action: @MainActor @Sendable () -> Void

  init(action: @escaping @MainActor @Sendable () -> Void) {
    self.action = action
  }

  @objc func invoke() {
    Task { @MainActor in action() }
  }
}

private let copyloomHotKeyHandler: EventHandlerUPP = { _, _, userData in
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let box = Unmanaged<HotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
  box.performSelector(
    onMainThread: #selector(HotKeyCallbackBox.invoke), with: nil, waitUntilDone: false)
  return noErr
}
