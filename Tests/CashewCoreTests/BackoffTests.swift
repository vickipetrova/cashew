import Foundation
import Testing

@testable import CashewCore

/// How long to wait after being told to slow down.
///
/// Pure, and it has to be: the behaviour this replaces was discovered by an app sitting rate-limited
/// for fifteen days, which is not a test anyone can run.
@Suite struct BackoffTests {
    private let fiveMinutes: TimeInterval = 5 * 60

    /// The server knows when its window clears; we are guessing. When it says, we listen.
    @Test func theServersOwnAdviceWins() {
        #expect(Backoff.delay(attempt: 1, retryAfter: 90, base: fiveMinutes) == 90)
        // Even when that is *shorter* than the interval we would have picked ourselves.
        #expect(Backoff.delay(attempt: 4, retryAfter: 30, base: fiveMinutes) == 30)
    }

    /// …up to a point. "Come back tomorrow" would leave the menu bar dead for a day with no way out
    /// but a restart, which is the failure mode this whole mechanism exists to prevent.
    @Test func advicePastTheCeilingIsClamped() {
        #expect(Backoff.delay(attempt: 1, retryAfter: 86_400, base: fiveMinutes) == Backoff.ceiling)
    }

    /// Without advice, back off geometrically rather than repeating the same interval forever.
    @Test func waitsGrowWithEachRefusal() {
        let first = Backoff.delay(attempt: 1, retryAfter: nil, base: fiveMinutes)
        let second = Backoff.delay(attempt: 2, retryAfter: nil, base: fiveMinutes)
        let third = Backoff.delay(attempt: 3, retryAfter: nil, base: fiveMinutes)

        #expect(first > fiveMinutes)   // the first refusal already slows us below the normal cadence
        #expect(second > first)
        #expect(third > second)
    }

    @Test func growthStopsAtTheCeiling() {
        #expect(Backoff.delay(attempt: 50, retryAfter: nil, base: fiveMinutes) == Backoff.ceiling)
        // Large exponents must not overflow into a NaN or a negative wait.
        let huge = Backoff.delay(attempt: 10_000, retryAfter: nil, base: fiveMinutes)
        #expect(huge == Backoff.ceiling)
        #expect(huge.isFinite)
    }

    /// The 1-minute refresh setting is the one that made this urgent: 60 requests an hour into an
    /// endpoint that is refusing. Even there the first backoff has to be a real slowdown.
    @Test func theShortestRefreshIntervalStillBacksOff() {
        let minute: TimeInterval = 60
        #expect(Backoff.delay(attempt: 1, retryAfter: nil, base: minute) >= 2 * minute)
    }

    /// Nonsense from the server is no worse than silence from it.
    @Test(arguments: [Double.nan, .infinity, -1, 0])
    func anUnusableRetryAfterFallsBackToDoubling(_ retryAfter: Double) {
        let delay = Backoff.delay(attempt: 2, retryAfter: retryAfter, base: fiveMinutes)
        #expect(delay == Backoff.delay(attempt: 2, retryAfter: nil, base: fiveMinutes))
        #expect(delay.isFinite)
        #expect(delay > 0)
    }

    /// An attempt counter that somehow arrives at zero or below must not produce a wait shorter than
    /// the normal poll, which would be a busier-when-refused loop.
    @Test(arguments: [0, -1])
    func adegenerateAttemptCountStillWaits(_ attempt: Int) {
        #expect(Backoff.delay(attempt: attempt, retryAfter: nil, base: fiveMinutes) > fiveMinutes)
    }
}

/// Which readings are still worth putting on screen.
///
/// Every case here was observed on the real app, which spent fifteen days reporting `0% used ·
/// reset time unknown` on three rows as though it were data.
@Suite struct FreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private func window(_ id: String, resetsIn: TimeInterval?) -> LimitWindow {
        LimitWindow(kind: .session, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: 42, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    @Test func freshReadingsAreShownUnchanged() {
        let windows = [window("session", resetsIn: 3_600), window("weekly", resetsIn: 200_000)]
        #expect(Freshness.displayable(windows, updatedAt: now.addingTimeInterval(-60), now: now)
            == windows)
    }

    /// The exact shape of the bug: no reset times at all, so no per-window rule could ever fire, and
    /// the numbers stayed on screen for over two weeks.
    @Test func aReadingTooOldToMeanAnythingIsDroppedEntirely() {
        let windows = [window("session", resetsIn: nil), window("weekly", resetsIn: nil)]
        let fifteenDaysAgo = now.addingTimeInterval(-15 * 24 * 60 * 60)
        #expect(Freshness.displayable(windows, updatedAt: fifteenDaysAgo, now: now).isEmpty)
    }

    @Test func aWindowWhoseResetHasPassedIsDropped() {
        let shown = Freshness.displayable(
            [window("session", resetsIn: -60), window("weekly", resetsIn: 200_000)],
            updatedAt: now.addingTimeInterval(-300), now: now)
        #expect(shown.map(\.id) == ["weekly"])
    }

    /// The provider never promised a reset time for these, so nothing says they've expired — as long
    /// as the reading itself is recent.
    @Test func aRecentWindowWithNoResetTimeSurvives() {
        let shown = Freshness.displayable([window("session", resetsIn: nil)],
                                          updatedAt: now.addingTimeInterval(-300), now: now)
        #expect(shown.count == 1)
    }

    /// Hiding data on a guess is worse than showing it: with no timestamp there is nothing to judge.
    @Test func withoutATimestampNothingIsDropped() {
        let windows = [window("session", resetsIn: nil)]
        #expect(Freshness.displayable(windows, updatedAt: nil, now: now) == windows)
    }

    /// The boundary, from both sides, since this is the number that decides whether a row vanishes.
    @Test func theAgeLimitIsAppliedAtTheBoundary() {
        let windows = [window("session", resetsIn: 3_600)]
        let justInside = now.addingTimeInterval(-Freshness.maxAge + 60)
        let justOutside = now.addingTimeInterval(-Freshness.maxAge - 60)
        #expect(!Freshness.displayable(windows, updatedAt: justInside, now: now).isEmpty)
        #expect(Freshness.displayable(windows, updatedAt: justOutside, now: now).isEmpty)
    }
}
