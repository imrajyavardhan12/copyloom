import Foundation

/// Versioned capture settings stored outside `history.sqlite`.
///
/// Security-critical capture state (pause/ignore rules) must survive history
/// corruption and must fail closed: unknown or corrupt rules disable capture
/// with a visible error instead of silently widening capture.
public struct CaptureSettings: Equatable, Sendable, Codable {
  public static let currentVersion = 1
  public static let defaultRetentionDays = 30
  public static let minimumRetentionDays = 1
  public static let maximumRetentionDays = 365

  public static let defaultIgnoredBundleIdentifiers: Set<String> = [
    "com.1password.1password",
    "com.apple.keychainaccess",
    "com.apple.passwords",
    "com.bitwarden.desktop",
    "in.sinew.enpass-desktop",
    "org.keepassxc.keepassxc",
  ]

  public var version: Int
  public var captureEnabled: Bool
  public var capturePaused: Bool
  public var ignoredBundleIdentifiers: Set<String>
  public var retentionDays: Int

  public init(
    version: Int = CaptureSettings.currentVersion,
    captureEnabled: Bool = false,
    capturePaused: Bool = false,
    ignoredBundleIdentifiers: Set<String> = CaptureSettings.defaultIgnoredBundleIdentifiers,
    retentionDays: Int = CaptureSettings.defaultRetentionDays
  ) {
    self.version = version
    self.captureEnabled = captureEnabled
    self.capturePaused = capturePaused
    self.ignoredBundleIdentifiers = Set(ignoredBundleIdentifiers.map { $0.lowercased() })
    self.retentionDays = retentionDays
  }

  public static var defaults: CaptureSettings { CaptureSettings() }

  /// Normalizes and clamps non-security fields. Security fields are never
  /// defaulted silently by this method; see `CaptureSettingsStore.load()`.
  public func normalized() -> CaptureSettings {
    var copy = self
    copy.ignoredBundleIdentifiers = Set(ignoredBundleIdentifiers.map { $0.lowercased() })
    copy.retentionDays = min(
      max(retentionDays, Self.minimumRetentionDays),
      Self.maximumRetentionDays
    )
    if copy.version != Self.currentVersion {
      copy.version = Self.currentVersion
    }
    return copy
  }
}

public struct CaptureSettingsLoadResult: Equatable, Sendable {
  public let settings: CaptureSettings
  /// True when stored data was unknown/corrupt and capture was force-disabled.
  public let didFailClosed: Bool
  public let errorDescription: String?

  public init(settings: CaptureSettings, didFailClosed: Bool, errorDescription: String? = nil) {
    self.settings = settings
    self.didFailClosed = didFailClosed
    self.errorDescription = errorDescription
  }
}

/// UserDefaults-backed store. History DB is never consulted so a corrupt
/// database cannot erase exclusions.
public struct CaptureSettingsStore: @unchecked Sendable {
  private enum Key {
    static let version = "capture.settingsVersion"
    static let captureEnabled = "capture.enabled"
    static let capturePaused = "capture.paused"
    static let ignoredBundleIdentifiers = "capture.ignoredBundleIdentifiers"
    static let retentionDays = "capture.retentionDays"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func load() -> CaptureSettingsLoadResult {
    // Fresh install: no version key and no legacy keys.
    let hasVersion = defaults.object(forKey: Key.version) != nil
    let hasLegacy =
      defaults.object(forKey: Key.captureEnabled) != nil
      || defaults.object(forKey: Key.capturePaused) != nil
      || defaults.object(forKey: Key.ignoredBundleIdentifiers) != nil
      || defaults.object(forKey: Key.retentionDays) != nil

    if !hasVersion, !hasLegacy {
      return CaptureSettingsLoadResult(settings: .defaults, didFailClosed: false)
    }

    // Legacy install (pre-versioning): migrate old keys forward.
    if !hasVersion, hasLegacy {
      let migrated = readFieldsAllowingDefaults()
      var normalized = migrated.normalized()
      // Never auto-enable capture through migration.
      normalized.capturePaused = normalized.captureEnabled && normalized.capturePaused
      persist(normalized)
      return CaptureSettingsLoadResult(settings: normalized, didFailClosed: false)
    }

    guard let storedVersion = defaults.object(forKey: Key.version) as? Int else {
      return failClosed("Capture settings version is unreadable.")
    }
    guard storedVersion == CaptureSettings.currentVersion else {
      return failClosed("Capture settings version \(storedVersion) is unsupported.")
    }
    guard
      let ignored = defaults.object(forKey: Key.ignoredBundleIdentifiers)
        as? [String]
    else {
      // Missing ignore-list with a version stamp means corrupt/tampered prefs.
      // Fail closed rather than capturing with no exclusions.
      if defaults.object(forKey: Key.ignoredBundleIdentifiers) == nil {
        return failClosed("Ignored-application rules are missing.")
      }
      return failClosed("Ignored-application rules are unreadable.")
    }

    let enabled = defaults.object(forKey: Key.captureEnabled) as? Bool
    let paused = defaults.object(forKey: Key.capturePaused) as? Bool
    let retention = defaults.object(forKey: Key.retentionDays) as? Int

    guard let enabled, let paused else {
      return failClosed("Capture state is unreadable.")
    }

    var settings = CaptureSettings(
      captureEnabled: enabled,
      capturePaused: enabled && paused,
      ignoredBundleIdentifiers: Set(ignored),
      retentionDays: retention ?? CaptureSettings.defaultRetentionDays
    )
    settings = settings.normalized()
    return CaptureSettingsLoadResult(settings: settings, didFailClosed: false)
  }

  public func save(_ settings: CaptureSettings) {
    persist(settings.normalized())
  }

  // MARK: - Private

  private func readFieldsAllowingDefaults() -> CaptureSettings {
    let enabled = defaults.object(forKey: Key.captureEnabled) as? Bool ?? false
    let paused = defaults.object(forKey: Key.capturePaused) as? Bool ?? false
    let ignored =
      (defaults.object(forKey: Key.ignoredBundleIdentifiers) as? [String])
      .map(Set.init)
      ?? CaptureSettings.defaultIgnoredBundleIdentifiers
    let retention =
      defaults.object(forKey: Key.retentionDays) as? Int
      ?? CaptureSettings.defaultRetentionDays
    return CaptureSettings(
      captureEnabled: enabled,
      capturePaused: paused,
      ignoredBundleIdentifiers: ignored,
      retentionDays: retention
    )
  }

  private func persist(_ settings: CaptureSettings) {
    defaults.set(CaptureSettings.currentVersion, forKey: Key.version)
    defaults.set(settings.captureEnabled, forKey: Key.captureEnabled)
    defaults.set(settings.capturePaused, forKey: Key.capturePaused)
    defaults.set(Array(settings.ignoredBundleIdentifiers), forKey: Key.ignoredBundleIdentifiers)
    defaults.set(settings.retentionDays, forKey: Key.retentionDays)
  }

  private func failClosed(_ message: String) -> CaptureSettingsLoadResult {
    var safe = CaptureSettings.defaults
    safe.captureEnabled = false
    safe.capturePaused = false
    // Persist the safe state and version so the next launch is deterministic,
    // but report failure so the UI shows a visible error.
    persist(safe)
    return CaptureSettingsLoadResult(
      settings: safe,
      didFailClosed: true,
      errorDescription: message
    )
  }
}
