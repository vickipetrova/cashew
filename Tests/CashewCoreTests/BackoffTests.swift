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

/// Which providers get polled. Pure on purpose: this rule used to live only in `AppDelegate`, which
/// no test may construct, and that is exactly how a launch with no credentials scheduling no poll at
/// all went unnoticed.
@Suite struct PollPlanTests {
    @Test func withNoCredentialsClaudeIsStillPolledSoItsSignInCopyRenders() {
        #expect(PollPlan.providersToPoll(active: [], all: [.claude, .codex]) == [.claude])
    }

    @Test func withCredentialsOnlyTheDetectedProvidersArePolled() {
        #expect(PollPlan.providersToPoll(active: [.codex], all: [.claude, .codex]) == [.codex])
    }

    @Test func aHiddenProviderIsNotPolled() {
        // Hiding is not just a display choice: it stops the network call, so hiding Codex returns a
        // Claude-only user to exactly the traffic they had before this feature existed.
        #expect(PollPlan.providersToPoll(active: [.claude, .codex], all: [.claude, .codex],
                                         hidden: [.codex]) == [.claude])
    }

    @Test func hidingEveryProviderStillPollsClaudeSoItsCopyRenders() {
        // The same reason the no-credentials fallback exists: a blank menu explains nothing.
        #expect(PollPlan.providersToPoll(active: [.claude], all: [.claude, .codex],
                                         hidden: [.claude]) == [.claude])
    }

    /// The trap door this task's correction exists to close: `MenuController`'s Settings list has
    /// to be built from credential *presence*, never from what's currently polled — because hiding
    /// a provider removes it from the polled set, and a Settings list built from that would make
    /// the very switch that could turn it back on disappear the moment it's used.
    ///
    /// `MenuController` can't be constructed in a test, so this asserts the rule where it actually
    /// lives: `PollPlan.detectedProviders` takes no `hidden` parameter at all — it structurally
    /// cannot filter by it — while `PollPlan.providersToPoll` does, and the two diverge on exactly
    /// the input that matters: a detected-but-hidden provider.
    @Test func detectedProvidersDoNotShrinkWhenAProviderIsHiddenUnlikePolledProviders() {
        let active: [ProviderID] = [.claude, .codex]
        let hidden: Set<ProviderID> = [.codex]

        let detected = PollPlan.detectedProviders(active: active)
        let polled = PollPlan.providersToPoll(active: active, all: active, hidden: hidden)

        #expect(detected == [.claude, .codex])
        #expect(polled == [.claude])
        #expect(!detected.subtracting(polled).isEmpty)
    }
}

/// Which readings are still worth putting on screen.
///
/// Every case here was observed on the real app, which spent fifteen days reporting `0% used ·
/// reset time unknown` on three rows as though it were data.
@Suite struct FreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private func window(_ id: String, resetsIn: TimeInterval?) -> LimitWindow {
        LimitWindow(kind: .primary, id: id, label: id, shortLabel: id, optionLabel: id,
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

@Suite struct ProviderSnapshotTests {
    private func window(_ id: String, resetsIn: TimeInterval, from now: Date) -> LimitWindow {
        LimitWindow(kind: .primary, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: 10, resetsAt: now.addingTimeInterval(resetsIn))
    }

    @Test func oneProviderGoingStaleDoesNotAffectTheOther() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = ProviderSnapshot(provider: .claude,
                                     windows: [window("session", resetsIn: 3600, from: now)],
                                     updatedAt: now.addingTimeInterval(-60), failure: nil)
        // Past Freshness.maxAge (24h), so this provider has nothing honest left to show.
        let stale = ProviderSnapshot(provider: .codex,
                                     windows: [window("session", resetsIn: 3600, from: now)],
                                     updatedAt: now.addingTimeInterval(-48 * 3600), failure: nil)

        #expect(fresh.displayable(now: now).count == 1)
        #expect(stale.displayable(now: now).isEmpty)
    }

    @Test func aFailureOnOneProviderLeavesTheOthersWindowsIntact() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let failed = ProviderSnapshot(provider: .codex, windows: [],
                                      updatedAt: nil, failure: UsageError.unauthorized)
        let ok = ProviderSnapshot(provider: .claude,
                                  windows: [window("session", resetsIn: 3600, from: now)],
                                  updatedAt: now, failure: nil)
        #expect(failed.displayable(now: now).isEmpty)
        #expect(ok.displayable(now: now).count == 1)
        #expect(ok.failure == nil)
    }

    /// The seam that broke, from the pure side. `AppDelegate` answers a failed poll with
    /// `existing.failed(error)` and hands the result to `MenuController.update(snapshots:)`, which
    /// replaces its whole array — so anything `failed` drops is gone from the dropdown and from the
    /// menu bar title, not merely un-refreshed. Every earlier test on this branch built a snapshot
    /// that already had both windows and a failure; none covered a snapshot *acquiring* one.
    @Test func aFailureKeepsTheWindowsAndTheTimeTheyWereRead() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let read = now.addingTimeInterval(-600)
        let before = ProviderSnapshot(provider: .claude,
                                      windows: [window("session", resetsIn: 3600, from: now)],
                                      updatedAt: read, failure: nil)
        let after = before.failed(UsageError.unauthorized)
        #expect(after.windows == before.windows)
        #expect(after.updatedAt == read)
        #expect(after.failure != nil)
        #expect(after.displayable(now: now).count == 1)
    }

    /// A restored reading is still restored after the poll that failed on top of it. A failed poll
    /// confirms nothing, so clearing the flag here would let the 60-second tick start recording
    /// numbers off disk from the moment the first poll came back — which is the launch this whole
    /// arrangement is for.
    @Test func aFailureDoesNotTurnARestoredReadingIntoAPolledOne() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let restored = ProviderSnapshot(provider: .claude,
                                        windows: [window("session", resetsIn: 3600, from: now)],
                                        updatedAt: now.addingTimeInterval(-3600), failure: nil,
                                        restored: true)
        #expect(restored.failed(UsageError.network(UsageError.badResponse)).restored)
        #expect(restored.failed(UsageError.network(UsageError.badResponse)).observed().isEmpty)
    }

    /// A poll confirms what a restore only remembered, so a success clears the flag — otherwise
    /// nothing would ever be recorded again after a launch that started from disk.
    @Test func aSuccessClearsTheRestoredFlag() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = [window("session", resetsIn: 3600, from: now)]
        let restored = ProviderSnapshot(provider: .claude, windows: fresh,
                                        updatedAt: now.addingTimeInterval(-3600), failure: nil,
                                        restored: true)
        let polled = restored.succeeded(windows: fresh, at: now)
        #expect(!polled.restored)
        #expect(polled.observed() == fresh)
    }

    /// The rule the seed introduces: restored rows are not an observation. They were recorded when
    /// they were polled, and re-recording them once a minute would invent a flat stretch that never
    /// happened and hand `Notifier` a reading no poll produced.
    @Test func aRestoredSnapshotObservesNothingOfItsOwn() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let restored = ProviderSnapshot(provider: .claude,
                                        windows: [window("session", resetsIn: 3600, from: now),
                                                  window("weekly", resetsIn: 90_000, from: now)],
                                        updatedAt: now.addingTimeInterval(-3600), failure: nil,
                                        restored: true)
        #expect(restored.observed().isEmpty)
        // Still shown, which is the entire point of restoring it.
        #expect(restored.displayable(now: now).count == 2)
    }

    /// The other half, and the one that is easy to get wrong by suppressing too much: the live
    /// statusline overlay is written by Claude Code as it renders, so it is genuinely new even while
    /// every poll is failing. Silencing it too would stop the forecast and the threshold alerts for
    /// as long as the outage lasts. Only the overlay is observed — the restored row the overlay
    /// doesn't cover (a scoped window, which the statusline never reports) is not.
    @Test func aRestoredSnapshotStillObservesTheLiveOverlay() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let live = [window("session", resetsIn: 3600, from: now)]
        let merged = ProviderSnapshot(provider: .claude,
                                      windows: live + [window("scoped:Fable", resetsIn: 90_000,
                                                              from: now)],
                                      updatedAt: now, failure: nil, restored: true)
        #expect(merged.observed(live: live).map(\.id) == ["session"])
    }

    /// A polled snapshot observes everything it has, overlay included — that is today's behaviour
    /// and the flag must not narrow it.
    @Test func aPolledSnapshotObservesAllOfItsWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let windows = [window("session", resetsIn: 3600, from: now),
                       window("weekly", resetsIn: 90_000, from: now)]
        let polled = ProviderSnapshot(provider: .claude, windows: windows, updatedAt: now,
                                      failure: nil)
        #expect(polled.observed(live: [windows[0]]) == windows)
    }

    /// The default is the ordinary case, so nothing built from a poll has to say so.
    @Test func aSnapshotIsPolledUnlessItSaysOtherwise() {
        #expect(!ProviderSnapshot(provider: .claude, windows: [], updatedAt: nil,
                                  failure: nil).restored)
    }
}
