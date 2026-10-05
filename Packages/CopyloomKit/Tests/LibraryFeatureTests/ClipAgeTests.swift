import ClipDomain
import Foundation
import Testing

@Suite("Clip age")
struct ClipAgeTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let english = Locale(identifier: "en_GB")
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func text(secondsAgo: TimeInterval) -> String {
    ClipAge.text(
      from: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: english)
  }

  @Test("under a minute reads as now, including small clock skew")
  func justNow() {
    #expect(text(secondsAgo: 0) == "now")
    #expect(text(secondsAgo: 59) == "now")
    #expect(text(secondsAgo: -30) == "now")
  }

  @Test("minutes, hours and days are compact and floor, never round up")
  func compactUnits() {
    #expect(text(secondsAgo: 60) == "1m")
    #expect(text(secondsAgo: 11 * 60 + 59) == "11m")
    #expect(text(secondsAgo: 3_600) == "1h")
    #expect(text(secondsAgo: 23 * 3_600 + 3_599) == "23h")
    #expect(text(secondsAgo: 24 * 3_600) == "1d")
    #expect(text(secondsAgo: 6 * 86_400 + 86_399) == "6d")
  }

  @Test("a week or older shows an unambiguous short date")
  func olderShowsDate() {
    let date = now.addingTimeInterval(-10 * 86_400)
    #expect(ClipAge.text(from: date, now: now, calendar: calendar, locale: english) == "5 Jan")
  }

  @Test("the spoken form is a full phrase, not an abbreviation")
  func spoken() {
    let ago = ClipAge.spokenText(from: now.addingTimeInterval(-90), now: now, locale: english)
    #expect(ago == "1 minute ago")
    #expect(ClipAge.spokenText(from: now, now: now, locale: english) == "just now")
  }
}
