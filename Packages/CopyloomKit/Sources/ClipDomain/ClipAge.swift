import Foundation

/// Compact, static "how long ago" text for dense lists.
///
/// SwiftUI's `Text(date, style: .relative)` prints "11 min, 9 secs", which
/// wraps in narrow rows and re-renders every row every second. List rows only
/// need orientation, so this floors to one unit (`now`, `11m`, `3h`, `2d`) and
/// falls back to a short date after a week. Floors rather than rounds, so an
/// item never looks newer than it is.
///
/// The unit suffixes are English literals; localizing them belongs with the
/// app-wide localization pass.
public enum ClipAge {
  public static func text(
    from date: Date,
    now: Date,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    let seconds = now.timeIntervalSince(date)
    guard seconds >= 60 else { return "now" }
    switch seconds {
    case ..<3_600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3_600))h"
    case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
    default:
      var style = Date.FormatStyle(locale: locale, calendar: calendar)
        .day().month(.abbreviated)
      style.timeZone = calendar.timeZone
      return date.formatted(style)
    }
  }

  /// Full phrase for VoiceOver and tooltips ("11 minutes ago").
  public static func spokenText(
    from date: Date,
    now: Date,
    locale: Locale = .current
  ) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = locale
    return formatter.localizedString(for: date, relativeTo: now)
  }
}
