import AppKit
import Foundation
import Testing

@testable import CashewCore

/// Formatting. Every function takes `now` (and `clock` takes a locale and time zone) so these are
/// pure functions of their arguments — no waiting on a clock, no dependence on the machine's region.
@Suite struct FormatTests {
    private let now = Date(timeIntervalSince1970: 0)
    private func offset(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - Percentages

    @Test func percentageOfNothingIsADash() {
        #expect(Fmt.pct(nil) == "–")
    }

    @Test(arguments: [(0.0, "0%"), (3.0, "3%"), (49.4, "49%"), (49.5, "50%"),
                      (79.6, "80%"), (100.0, "100%")])
    func percentageRoundsToNearest(_ value: Double, _ expected: String) {
        #expect(Fmt.pct(value) == expected)
    }

    /// `Int(_: Double)` traps on a non-finite value. The parser clamps before this is reached, but
    /// the guard here means a future caller can't reintroduce the crash.
    @Test func percentageSurvivesNonFiniteInput() {
        #expect(Fmt.pct(.nan) == "–")
        #expect(Fmt.pct(.infinity) == "–")
    }

    // MARK: - Countdowns

    @Test func countdownToNothingIsUnknown() {
        #expect(Fmt.countdown(to: nil, from: now) == "unknown")
    }

    /// The full boundary table. Several of these are surprising (+1 second reads "0m"), which is
    /// exactly why they're pinned.
    @Test(arguments: [
        (-86_400.0, "now"), (-1.0, "now"), (0.0, "now"), (0.9, "now"),
        (1.0, "0m"), (59.0, "0m"), (60.0, "1m"), (3_599.0, "59m"),
        (3_600.0, "1h 0m"), (3_661.0, "1h 1m"), (86_399.0, "23h 59m"),
        (86_400.0, "1d 0h"), (86_401.0, "1d 0h"), (90_000.0, "1d 1h"),
        (604_800.0, "7d 0h"),
    ])
    func countdownBoundaries(_ seconds: TimeInterval, _ expected: String) {
        #expect(Fmt.countdown(to: offset(seconds), from: now) == expected)
    }

    @Test func countdownSurvivesAnAbsurdDate() {
        #expect(Fmt.countdown(to: .distantFuture, from: now) != "")
        #expect(Fmt.countdown(to: Date(timeIntervalSince1970: .infinity), from: now) == "unknown")
    }

    // MARK: - Age of the data

    /// Shown next to Refresh Now, so it answers "are these numbers stale?" rather than "what time
    /// was it?". Under a minute reads as "just now" rather than "0m ago", which would look broken.
    @Test(arguments: [
        (0.0, "just now"), (44.0, "just now"), (45.0, "1m ago"), (59.0, "1m ago"),
        (60.0, "1m ago"), (301.0, "5m ago"), (3_599.0, "59m ago"),
        (3_600.0, "1h ago"), (86_399.0, "23h ago"), (86_400.0, "1d ago"), (200_000.0, "2d ago"),
    ])
    func ageReadsAsElapsedTime(_ elapsed: TimeInterval, _ expected: String) {
        #expect(Fmt.age(of: offset(-elapsed), from: now) == expected)
    }

    @Test func ageOfNothingIsNever() {
        #expect(Fmt.age(of: nil, from: now) == "never")
    }

    /// A clock that jumps backwards (NTP correction, timezone change) must not produce a negative
    /// age or a crash.
    @Test func aFutureTimestampDoesNotGoNegative() {
        #expect(Fmt.age(of: offset(3_600), from: now) == "just now")
    }

    // MARK: - Clock times

    @Test func clockOfNothingIsAQuestionMark() {
        #expect(Fmt.clock(nil, from: now) == "?")
    }

    private let utc = TimeZone(identifier: "UTC")!

    /// 24-hour locales give a stable exact string. Note the deliberate absence of an `en_US`
    /// equality assertion: since ICU 72 the separator before AM/PM is U+202F (narrow no-break
    /// space), so a typed "5:40 PM" would not match while looking identical in the failure output.
    @Test(arguments: ["en_GB", "de_DE", "fr_FR"])
    func clockUsesTwentyFourHourTimeWhereTheLocaleDoes(_ identifier: String) {
        let time = Fmt.clock(offset(63_000), from: now,
                             locale: Locale(identifier: identifier), timeZone: utc)
        #expect(time == "17:30")
    }

    @Test func clockUsesTwelveHourTimeWhereTheLocaleDoes() {
        let time = Fmt.clock(offset(63_000), from: now,
                             locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(time.hasPrefix("5:30"))
        #expect(time.contains("PM"))
    }

    @Test func clockRespectsTheTimeZone() {
        let berlin = try? #require(TimeZone(identifier: "Europe/Berlin"))
        let time = Fmt.clock(offset(63_000), from: now,
                             locale: Locale(identifier: "en_GB"), timeZone: berlin ?? utc)
        #expect(time == "18:30")  // UTC+1 in January
    }

    /// Regression: `countdown` switched to days at 86 400 while `clock` added the weekday only
    /// *above* it, so at exactly 24 hours the menu read "Resets 9:00 AM — in 1d 0h" — the ambiguity
    /// the weekday exists to remove.
    @Test func clockAndCountdownAgreeOnWhereADayBegins() {
        let gb = Locale(identifier: "en_GB")
        let boundary = offset(86_400)

        // The same instant rendered twice, differing only in how far away it is. Comparing two
        // *different* instants would pass whichever branch ran, since their times differ anyway.
        let asNearby = Fmt.clock(boundary, from: boundary, locale: gb, timeZone: utc)
        let atBoundary = Fmt.clock(boundary, from: now, locale: gb, timeZone: utc)

        #expect(Fmt.countdown(to: boundary, from: now) == "1d 0h")  // countdown says days
        #expect(atBoundary != asNearby)                             // so clock must say weekday
        #expect(atBoundary.hasSuffix(asNearby))
    }

    /// Locale-agnostic invariant: the weekday form is the bare form with something in front. Holds
    /// wherever `EEE` leads, and fails loudly if the two-branch logic is ever collapsed.
    @Test(arguments: ["en_GB", "de_DE", "en_US", "ja_JP"])
    func weekdayFormExtendsTheBareForm(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        let near = offset(3_600)
        let far = offset(3_600 + 86_400 * 2)
        let bare = Fmt.clock(near, from: now, locale: locale, timeZone: utc)
        let withWeekday = Fmt.clock(far, from: now, locale: locale, timeZone: utc)
        #expect(withWeekday.hasSuffix(bare))
        #expect(withWeekday.count > bare.count)
    }

    // MARK: - Colour modes

    private func title(_ u: Double, _ mode: Settings.ColorMode) -> NSColor {
        Fmt.color(u, mode: mode, role: .title)
    }

    private func bar(_ u: Double, _ mode: Settings.ColorMode) -> NSColor {
        Fmt.color(u, mode: mode, role: .bar)
    }

    /// Asserted relationally rather than against `NSColor` identity — these are dynamic catalogue
    /// colours, and what matters is *where* the bands change, not which colour each one is.
    @Test func alertsOnlyChangesBandAtFiftyAndEighty() {
        for role in [Fmt.ColorRole.title, .bar] {
            let c = { (u: Double) in Fmt.color(u, mode: .alertsOnly, role: role) }
            #expect(c(0) == c(49.9))
            #expect(c(50) != c(49.9))
            #expect(c(50) == c(79.9))
            #expect(c(80) != c(79.9))
            #expect(c(80) == c(100))
        }
    }

    // MARK: - Past timestamps

    /// The fifteen-day bug, as a test.
    ///
    /// `clock`'s weekday branch tests `date.timeIntervalSince(now) >= dayThreshold`, which is only
    /// ever true looking *forward*. Fed a past date it always rendered a bare time, so a reading from
    /// fifteen days earlier displayed as "Showing data from 4:44 AM" — directly above a correctly
    /// rendered "Refresh Now (15d ago)". The two lines described the same instant and disagreed.
    @Test func anOldReadingIsNotRenderedAsATimeOfDay() {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        let fifteenDaysAgo = now.addingTimeInterval(-15 * 24 * 60 * 60)

        let stamp = Fmt.stamp(fifteenDaysAgo, from: now)
        #expect(stamp == "15d ago")
        // The precise regression: it must not agree with `clock`, which is what it used to call.
        #expect(stamp != Fmt.clock(fifteenDaysAgo, from: now))
        // …and it must agree with the Refresh Now row, which was right all along.
        #expect(stamp == Fmt.age(of: fifteenDaysAgo, from: now))
    }

    /// Today's readings keep the wall-clock time: it's precise, and there's no ambiguity about which
    /// day is meant.
    @Test func atodaysReadingKeepsItsClockTime() {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        let earlier = now.addingTimeInterval(-3 * 60 * 60)
        #expect(Fmt.stamp(earlier, from: now) == Fmt.clock(earlier, from: now))
    }

    @Test func theStampSwitchesFormAtTheDayBoundary() {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        let justUnder = now.addingTimeInterval(-(86_400 - 60))
        let justOver = now.addingTimeInterval(-(86_400 + 60))
        #expect(Fmt.stamp(justUnder, from: now) == Fmt.clock(justUnder, from: now))
        #expect(Fmt.stamp(justOver, from: now) == Fmt.age(of: justOver, from: now))
    }

    @Test func aMissingTimestampDegradesRatherThanCrashing() {
        #expect(Fmt.stamp(nil) == "?")
    }

    /// A weekly limit you'll hit on Thursday deserves attention at 30% as much as at 60%, and the
    /// number alone can't say so — this is the only way the ramp ever fires below its threshold.
    @Test func beingOnPacePromotesACalmTitleToYellow() {
        #expect(Fmt.color(30, mode: .alertsOnly, role: .title, onPace: true) == .systemYellow)
        #expect(Fmt.color(30, mode: .alertsOnly, role: .title, onPace: false) == .labelColor)
    }

    /// It promotes, never demotes. A forecast is a weaker signal than already being at 85%.
    @Test func beingOnPaceNeverSoftensTheHigherBands() {
        for utilization in [50.0, 79.9, 80.0, 100.0] {
            #expect(Fmt.color(utilization, mode: .alertsOnly, role: .title, onPace: true)
                == Fmt.color(utilization, mode: .alertsOnly, role: .title, onPace: false))
        }
    }

    /// The bar keeps tracking utilization, so the panel still reads as a measurement — the pace line
    /// underneath is where the forecast speaks.
    @Test func beingOnPaceLeavesTheBarAlone() {
        #expect(Fmt.color(30, mode: .alertsOnly, role: .bar, onPace: true) == Fmt.spark)
    }

    /// Choosing System is choosing no colour at all; a forecast doesn't reopen that.
    @Test func beingOnPaceDoesNotColourSystemMode() {
        #expect(Fmt.color(30, mode: .system, role: .title, onPace: true) == .labelColor)
    }

    /// The point of the default: below the first threshold nothing is tinted for severity. The
    /// number takes the ordinary label colour and only the bar carries the brand.
    @Test func alertsOnlyIsCalmBelowFifty() {
        #expect(title(0, .alertsOnly) == .labelColor)
        #expect(title(49.9, .alertsOnly) == .labelColor)
        #expect(bar(0, .alertsOnly) == Fmt.spark)
        #expect(bar(49.9, .alertsOnly) == Fmt.spark)
        // …and the two surfaces genuinely differ while calm, which is why the role exists.
        #expect(title(0, .alertsOnly) != bar(0, .alertsOnly))
    }

    /// Above the thresholds both surfaces agree, so a red number never sits over an orange bar.
    @Test func alertsOnlyAgreesAcrossSurfacesWhenItMatters() {
        #expect(title(50, .alertsOnly) == bar(50, .alertsOnly))
        #expect(title(80, .alertsOnly) == bar(80, .alertsOnly))
        #expect(title(100, .alertsOnly) == bar(100, .alertsOnly))
    }

    /// "Fully monochrome" has to mean the thresholds stop applying, not merely that the calm colours
    /// changed — otherwise System mode still goes red at 80% and isn't monochrome at all.
    @Test(arguments: [0.0, 49.9, 50.0, 79.9, 80.0, 100.0])
    func systemModeIgnoresUtilizationEntirely(_ utilization: Double) {
        #expect(title(utilization, .system) == .labelColor)
        #expect(bar(utilization, .system) == .secondaryLabelColor)
    }

    @Test func systemModeUsesNoBrandOrAlertColour() {
        for u in [0.0, 60.0, 95.0] {
            #expect(title(u, .system) != Fmt.spark)
            #expect(title(u, .system) != .systemRed)
            #expect(bar(u, .system) != Fmt.spark)
            #expect(bar(u, .system) != .systemRed)
        }
    }

    /// Every comparison against NaN is false, so a NaN slips past both bands into the `default` case
    /// and renders as **red** — an alarm raised by a number we couldn't even read. `ClaudeProvider`
    /// clamps before this point, but `Fmt` is shared with any future provider, and the neighbouring
    /// `UsageRow.fraction` guards the same value for the same reason.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteUtilizationIsNotAnAlert(_ utilization: Double) {
        #expect(title(utilization, .alertsOnly) != .systemRed)
        #expect(bar(utilization, .alertsOnly) != .systemRed)
        #expect(title(utilization, .alertsOnly) != .systemYellow)
        #expect(bar(utilization, .alertsOnly) != .systemYellow)
        // It renders as the calm state, matching what `Fmt.pct` shows for the same value ("–").
        #expect(title(utilization, .alertsOnly) == .labelColor)
        #expect(bar(utilization, .alertsOnly) == Fmt.spark)
    }

}

/// The menu bar image itself is covered in `MenuBarAnimationTests`, which renders pixels and must
/// run on the main thread — AppKit drawing is not thread-safe, and swift-testing runs suites in
/// parallel.
@Suite struct ElapsedTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [(0.0, "0s"), (59, "59s"), (60, "1m 00s"), (65, "1m 05s"),
                      (3599, "59m 59s"), (3600, "1h 00m"), (3720, "1h 02m")])
    func elapsed(_ seconds: Double, _ expected: String) {
        #expect(Fmt.elapsed(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func elapsedEdges() {
        #expect(Fmt.elapsed(since: nil, now: now) == "")
        #expect(Fmt.elapsed(since: now.addingTimeInterval(30), now: now) == "0s")
    }
}
