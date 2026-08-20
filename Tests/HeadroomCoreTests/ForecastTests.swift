import Foundation
import Testing

@testable import HeadroomCore

/// Burn-rate projection.
///
/// Every case is a hand-computed fixture rather than a property of real data, because the live app
/// produces one sample per poll — reaching "three samples over ninety minutes at a steady rate"
/// through the UI means waiting ninety minutes, and reaching the post-reset case means waiting five
/// hours. The arithmetic is written out in each test so a failure says which step drifted.
@Suite struct ForecastTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)
    private let threeHours: TimeInterval = 3 * 60 * 60

    /// Minutes before `now`, which is how every fixture below is expressed.
    private func sample(_ minutesAgo: Double, _ utilization: Double) -> Sample {
        Sample(at: now.addingTimeInterval(-minutesAgo * 60), limitID: "session",
               utilization: utilization)
    }

    private func project(_ samples: [Sample], kind: LimitWindow.Kind = .session,
                         resetsIn: TimeInterval? = 3 * 60 * 60) -> Forecast {
        Forecast.project(samples: samples, kind: kind,
                         resetsAt: resetsIn.map { now.addingTimeInterval($0) }, now: now)
    }

    /// 10% → 40% over an hour is 0.5 points/minute. 60 points remain, so 120 minutes to 100%, and
    /// the window doesn't reset for 180.
    @Test func steadyRateProjectsTheHitAndCallsItOnPace() {
        let forecast = project([sample(60, 10), sample(30, 25), sample(0, 40)])
        #expect(forecast == .onPace(now.addingTimeInterval(120 * 60)))
    }

    /// Same shape, a twelfth of the rate: 10% → 14% over an hour is 4 points/hour, so 86 points
    /// remain and 100% is 21.5 hours away. The window resets in three.
    @Test func aRateTooSlowToMatterIsUnderPace() {
        #expect(project([sample(60, 10), sample(30, 12), sample(0, 14)]) == .underPace)
    }

    /// Not moving isn't a forecast of "never" — it's an absence of evidence, and it renders as
    /// nothing at all rather than as a reassurance.
    @Test func idleIsUnknown() {
        #expect(project([sample(60, 40), sample(30, 40), sample(0, 40)]) == .unknown)
    }

    /// A falling reading projects a hit date in the *past* if the sign isn't guarded, which would
    /// render as the most alarming thing the panel can say.
    @Test func fallingUtilizationIsUnknownRatherThanANegativeProjection() {
        #expect(project([sample(60, 40), sample(30, 38), sample(0, 36)]) == .unknown)
    }

    /// The window reset 60 minutes ago — 88% to 5%. Only the three samples after the drop count:
    /// 5% → 35% over an hour, 0.5 points/minute, 65 points left, 130 minutes.
    ///
    /// Without reset handling the fit would run 88% → 35%, a *negative* rate, and report `.unknown` —
    /// so this asserts a specific date rather than merely "not unknown".
    @Test func aResetStartsAFreshWindow() {
        let forecast = project([sample(80, 85), sample(70, 88),
                                sample(60, 5), sample(30, 20), sample(0, 35)])
        #expect(forecast == .onPace(now.addingTimeInterval(130 * 60)))
    }

    /// A 10-point fall is the threshold, and ordinary usage never moves *down*. Anything at or under
    /// it stays in the same window rather than silently discarding history.
    @Test func aSmallDipIsNotTreatedAsAReset() {
        // 30 → 22 is an 8-point dip, under the threshold, so the fit still starts at 30 and the
        // overall rate is negative.
        #expect(project([sample(60, 30), sample(30, 22), sample(0, 28)]) == .unknown)
    }

    /// Two samples is one interval, which is one poll's worth of noise dressed up as a trend.
    @Test func twoSamplesAreNotEnough() {
        #expect(project([sample(30, 10), sample(0, 40)]) == .unknown)
    }

    @Test func noSamplesAtAllIsUnknown() {
        #expect(project([]) == .unknown)
    }

    /// Nothing to be on pace *for*.
    @Test func aWindowWithNoResetTimeIsUnknown() {
        #expect(project([sample(60, 10), sample(30, 25), sample(0, 40)], resetsIn: nil) == .unknown)
    }

    /// A session limit looks back 90 minutes. A sample from this morning describes a burst that has
    /// nothing to do with the current rate, and including it would drag the projection towards it.
    @Test func samplesOlderThanTheTrailingWindowAreIgnored() {
        let withAncient = project([sample(200, 0), sample(60, 10), sample(30, 25), sample(0, 40)])
        #expect(withAncient == .onPace(now.addingTimeInterval(120 * 60)))
    }

    /// …and a weekly limit looks back a day, so samples from twenty hours ago still count for it
    /// while a session limit has long since discarded them.
    @Test func aWeeklyLimitLooksBackFurtherThanASession() {
        let samples = [sample(20 * 60, 10), sample(10 * 60, 20), sample(0, 30)]
        #expect(project(samples, kind: .session, resetsIn: 100 * 60 * 60) == .unknown)
        #expect(project(samples, kind: .weekly, resetsIn: 100 * 60 * 60) != .unknown)
    }

    // MARK: - Not extrapolating from noise
    //
    // Both guards below exist because the feature produced a false positive on its first real run:
    // five weekly samples spanning 22 minutes, one point of movement, reported as "on pace, Saturday
    // 1:44 AM" for a limit sitting at 2%. Sample count was being mistaken for observation time, and
    // the endpoint's integer `percent` meant that single point was mostly rounding.

    /// Twenty-two minutes says nothing about a 168-hour window, however many times you poll in it.
    @Test func aShortBurstDoesNotForecastAWeeklyLimit() {
        let samples = [sample(22, 1), sample(15, 1), sample(7, 2), sample(0, 2)]
        #expect(project(samples, kind: .weekly, resetsIn: 123 * 60 * 60) == .unknown)
    }

    /// The same span *is* enough for a session window, which is where the proportion earns its keep —
    /// this is not a flat "wait six hours before saying anything".
    @Test func theSpanRequirementScalesWithTheWindow() {
        let samples = [sample(40, 10), sample(20, 20), sample(0, 30)]
        #expect(project(samples, kind: .session, resetsIn: 3 * 60 * 60) != .unknown)
        #expect(project(samples, kind: .weekly, resetsIn: 3 * 60 * 60) == .unknown)
    }

    /// `percent` is an integer, so a one-point delta is at the endpoint's own resolution and carries
    /// about half a point of rounding — fitting a rate to it is fitting a rate to noise.
    ///
    /// The case where this is the *only* thing standing in the way is a nearly-full window: at 95%
    /// there are five points left, so one tick of rounding over half an hour projects the cap two
    /// hours out and would put "on pace" under a row whose number is already red. Everywhere else
    /// the span and idle rules get there first — which mutation testing had to prove, because the
    /// first two fixtures written for this guard were actually being caught by the idle threshold.
    @Test func aSinglePointOfMovementIsNotARate() {
        let nearlyFull = [sample(30, 95), sample(15, 95), sample(0, 96)]
        #expect(project(nearlyFull, kind: .session, resetsIn: 3 * 60 * 60) == .unknown)
    }

    /// Real movement at the same utilization still forecasts, so this suppresses rounding rather
    /// than suppressing bad news.
    @Test func realMovementNearTheCapStillForecasts() {
        let climbing = [sample(30, 90), sample(15, 93), sample(0, 96)]
        #expect(project(climbing, kind: .session, resetsIn: 3 * 60 * 60) != .unknown)
    }

    /// Movement clear of both the rounding floor and the idle threshold still forecasts — the guards
    /// suppress noise, not signal.
    ///
    /// Two points over twenty hours would *not*, but that is the idle rule doing its job rather than
    /// this one: 0.1 points/hour is 40 days from the cap.
    @Test func movementAboveTheRoundingFloorStillForecasts() {
        let samples = [sample(20 * 60, 1), sample(10 * 60, 5), sample(0, 9)]
        #expect(project(samples, kind: .weekly, resetsIn: 500 * 60 * 60) != .unknown)
    }

    /// Already there. Reporting a hit date in the future for a limit that is at 100% would be
    /// nonsense, and dividing by the remaining distance would be a divide by zero.
    @Test func aLimitAlreadyAtTheCapIsOnPaceNow() {
        #expect(project([sample(60, 90), sample(30, 95), sample(0, 100)]) == .onPace(now))
    }

    // MARK: - Which forecasts colour the menu bar

    @Test func onlyWeeklyLimitsOnPaceTintTheTitle() {
        let hit = Forecast.onPace(now)
        #expect(Forecast.tintsTitle(kind: .weekly, forecast: hit))
        #expect(Forecast.tintsTitle(kind: .weeklyScoped, forecast: hit))
        // A session window refills every five hours, so being on pace for one is an ordinary
        // afternoon — colouring it would make the title shout during normal work.
        #expect(!Forecast.tintsTitle(kind: .session, forecast: hit))
    }

    @Test func nothingElseTintsTheTitle() {
        #expect(!Forecast.tintsTitle(kind: .weekly, forecast: .underPace))
        #expect(!Forecast.tintsTitle(kind: .weekly, forecast: .unknown))
    }
}
