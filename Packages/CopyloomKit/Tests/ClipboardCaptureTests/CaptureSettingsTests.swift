import Foundation
import Testing

@testable import ClipboardCapture

@Suite("Capture settings store")
struct CaptureSettingsTests {
  private func isolatedDefaults() -> UserDefaults {
    let suite = "test.capture.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test("fresh install returns defaults without failing closed")
  func freshInstallDefaults() {
    let result = CaptureSettingsStore(defaults: isolatedDefaults()).load()
    #expect(result.didFailClosed == false)
    #expect(result.settings == .defaults)
    #expect(result.settings.captureEnabled == false)
    #expect(result.settings.retentionDays == 30)
    #expect(
      result.settings.ignoredBundleIdentifiers.contains("com.1password.1password"))
  }

  @Test("migrates legacy keys and lowercases bundle IDs")
  func migratesLegacyKeys() {
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "capture.enabled")
    defaults.set(false, forKey: "capture.paused")
    defaults.set(["COM.Apple.Safari"], forKey: "capture.ignoredBundleIdentifiers")

    let result = CaptureSettingsStore(defaults: defaults).load()
    #expect(result.didFailClosed == false)
    #expect(result.settings.captureEnabled == true)
    #expect(result.settings.ignoredBundleIdentifiers == ["com.apple.safari"])
    // Migration stamps the version so the next load is versioned.
    let second = CaptureSettingsStore(defaults: defaults).load()
    #expect(second.didFailClosed == false)
    #expect(second.settings == result.settings)
  }

  @Test("fails closed when ignore rules are missing or unreadable")
  func failsClosedOnMissingRules() {
    let defaults = isolatedDefaults()
    defaults.set(1, forKey: "capture.settingsVersion")
    defaults.set(true, forKey: "capture.enabled")
    defaults.set(false, forKey: "capture.paused")
    // No ignored list stored.

    let result = CaptureSettingsStore(defaults: defaults).load()
    #expect(result.didFailClosed == true)
    #expect(result.settings.captureEnabled == false)
    #expect(result.errorDescription != nil)
  }

  @Test("fails closed on unsupported version")
  func failsClosedOnUnknownVersion() {
    let defaults = isolatedDefaults()
    defaults.set(99, forKey: "capture.settingsVersion")
    defaults.set(true, forKey: "capture.enabled")

    let result = CaptureSettingsStore(defaults: defaults).load()
    #expect(result.didFailClosed == true)
    #expect(result.settings.captureEnabled == false)
  }

  @Test("clamps retention into the supported range")
  func clampsRetention() {
    var settings = CaptureSettings(retentionDays: 10_000)
    settings = settings.normalized()
    #expect(settings.retentionDays == CaptureSettings.maximumRetentionDays)

    settings = CaptureSettings(retentionDays: -5).normalized()
    #expect(settings.retentionDays == CaptureSettings.minimumRetentionDays)
  }

  @Test("round-trips through save and load")
  func roundTrips() {
    let defaults = isolatedDefaults()
    let store = CaptureSettingsStore(defaults: defaults)
    var settings = CaptureSettings.defaults
    settings.captureEnabled = true
    settings.retentionDays = 14
    settings.ignoredBundleIdentifiers = ["com.example.app"]
    store.save(settings)

    let result = store.load()
    #expect(result.didFailClosed == false)
    #expect(result.settings.captureEnabled == true)
    #expect(result.settings.retentionDays == 14)
    #expect(result.settings.ignoredBundleIdentifiers == ["com.example.app"])
  }
}
