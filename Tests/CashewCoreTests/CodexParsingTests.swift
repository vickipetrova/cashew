import Foundation
import Testing
@testable import CashewCore

@Suite struct CodexParsingTests {
    /// JSON text through JSONSerialization, never a Swift dictionary literal — the bridging traps
    /// only exist for the NSNumbers a real response produces.
    private func parse(_ text: String) -> [LimitWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else { return [] }
        return CodexProvider.windows(in: object)
    }

    /// The live free-plan response, captured 2026-09-21. Identifiers redacted; nothing else edited.
    private let freePlan = """
    {"plan_type":"free",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":0,"limit_window_seconds":2592000,
                         "reset_after_seconds":2592000,"reset_at":1792615093},
       "secondary_window":null},
     "credits":{"has_credits":false,"unlimited":false},
     "rate_limit_reached_type":null}
    """

    @Test func readsTheFreePlansSingleWindow() {
        let windows = parse(freePlan)
        #expect(windows.count == 1)
        #expect(windows[0].kind == .primary)
        #expect(windows[0].id == "primary")
        #expect(windows[0].utilization == 0)
        #expect(windows[0].label == "CODEX · 30-DAY")
        // Epoch SECONDS. Read as milliseconds this lands three weeks after 1970.
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_615_093))
    }

    @Test func aNullSecondaryWindowIsTheCommonCaseNotAnError() {
        // Free plans send `"secondary_window": null` on every request. One row, no complaint.
        #expect(parse(freePlan).map(\.id) == ["primary"])
    }

    /// A guess about VALUES, not about shape: no paid response has been captured. It proves the
    /// parser maps a present secondary_window; it does not prove a paid plan sends one like this.
    /// The name says so too, so a green suite is never read as evidence the paid path works —
    /// replacing this fixture with a captured response is the whole of the design's phase 3.
    @Test func aGuessedPaidPlanFixtureYieldsBothWindows() {
        let windows = parse("""
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,
                                         "reset_at":1792615093},
                       "secondary_window":{"used_percent":40,"limit_window_seconds":604800,
                                           "reset_at":1793000000}}}
        """)
        #expect(windows.map(\.kind) == [.primary, .secondary])
        #expect(windows.map(\.id) == ["primary", "secondary"])
        #expect(windows.map(\.label) == ["CODEX · 5-HOUR", "CODEX · WEEKLY"])
        #expect(windows.map(\.utilization) == [12, 40])
    }

    @Test func aBooleanPercentDropsTheRowRatherThanReadingAsOne() {
        // JSON booleans bridge to NSNumber, so `as? Double` on `true` yields 1.0.
        #expect(parse("""
        {"rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":18000}}}
        """).isEmpty)
    }

    @Test func aWrongTypedOrImpossibleWindowLengthDropsTheRow() {
        // The guard `duration` shares with `number` — a JSON boolean bridges to NSNumber, so an
        // unguarded `as? Double` on `true` yields 1.0 and would render a "0-HOUR" window.
        //
        // `1e30` is the one that crashed rather than misrendered. It is *finite*, so the
        // `isFinite` guard let it through — and `Int((seconds / 86_400).rounded())` traps on a value
        // past `Int`'s range, which is a crash on every poll from one server-controlled field.
        // `1e999` (JSON parses it to infinity) was already covered; the large finite case was not.
        // A century of seconds is over the ceiling without being anywhere near `Int`'s range, which
        // is the point: what closes this is the bound, not the size of any one value.
        for bad in ["true", "\"18000\"", "-1", "0", "1e30", "1e999", "3153600000"] {
            #expect(parse("""
            {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":\(bad)}}}
            """).isEmpty)
        }
    }

    @Test func aMissingResetTimeFallsBackToResetAfterSeconds() {
        let windows = parse("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000,
                                         "reset_after_seconds":3600}}}
        """)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt != nil)
    }

    /// The second path through the same hole. `reset_after_seconds` is added to `now` directly, so
    /// it never passes through `UsageJSON.date`'s plausible-epoch bound — the one the doc comment
    /// two lines above it claims protects this field. `duration`'s ceiling is what actually does,
    /// and an unbounded value would reach `Notifier.periodID`'s own unguarded
    /// `Int((resetsAt.timeIntervalSince1970 / 60).rounded())`.
    @Test func anImpossibleResetAfterDropsTheResetRatherThanTheRow() {
        let windows = parse("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000,
                                         "reset_after_seconds":1e30}}}
        """)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt == nil)
    }

    /// A plausible reset stays plausible: the ceiling must not be so tight that a real countdown on
    /// a 30-day window — the only window a free plan reports — is thrown away with the junk.
    @Test func aRealThirtyDayCountdownSurvivesTheCeiling() {
        let windows = parse("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":2592000,
                                         "reset_after_seconds":2592000}}}
        """)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt != nil)
        #expect(windows[0].label == "CODEX · 30-DAY")
    }

    @Test func noResetInformationAtAllStillRendersTheRow() {
        // A row with no reset time is honest — `UsageRow` says "reset time unknown" — and dropping
        // it would hide a real percentage over a missing field.
        let windows = parse(#"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}}"#)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt == nil)
    }

    @Test func aMissingOrWrongTypedRateLimitYieldsNothing() {
        #expect(parse(#"{"plan_type":"free"}"#).isEmpty)
        #expect(parse(#"{"rate_limit":null}"#).isEmpty)
        #expect(parse(#"{"rate_limit":[]}"#).isEmpty)
        #expect(parse(#"{"rate_limit":{"primary_window":"nope"}}"#).isEmpty)
    }

    @Test func utilizationIsClampedAndFinite() {
        #expect(parse(#"{"rate_limit":{"primary_window":{"used_percent":140,"limit_window_seconds":1}}}"#)
            .map(\.utilization) == [100])
        #expect(parse(#"{"rate_limit":{"primary_window":{"used_percent":1e999,"limit_window_seconds":1}}}"#)
            .isEmpty)
    }

    @Test func labelsComeFromTheReportedWindowLength() {
        // Server-reported and plan-dependent, so it cannot be hardcoded the way Claude's "WEEKLY"
        // is — a free plan's primary window is 30 days where a paid plan's is hours.
        #expect(CodexProvider.windowLabel(seconds: 5 * 3600) == "5-HOUR")
        #expect(CodexProvider.windowLabel(seconds: 7 * 86_400) == "WEEKLY")
        #expect(CodexProvider.windowLabel(seconds: 30 * 86_400) == "30-DAY")
        #expect(CodexProvider.windowLabel(seconds: 0) == "WINDOW")
    }

    /// The unit is chosen after rounding, not before. Choosing it from the raw seconds put a cliff
    /// at exactly one day: 86,399s rounded to "24-HOUR" while 86,400s rendered "1-DAY", so one
    /// second of drift in a server-reported value changed the heading's units.
    @Test func theDayBoundaryDoesNotRenderTwentyFourHours() {
        #expect(CodexProvider.windowLabel(seconds: 86_399) == "1-DAY")
        #expect(CodexProvider.windowLabel(seconds: 86_400) == "1-DAY")
        #expect(CodexProvider.windowLabel(seconds: 23 * 3600) == "23-HOUR")
    }

    @Test func aWindowTooShortToNameInHoursIsNotCalledZeroHour() {
        #expect(CodexProvider.windowLabel(seconds: 60) == "WINDOW")
    }
}
