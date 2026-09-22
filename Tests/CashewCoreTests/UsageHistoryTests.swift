import Foundation
import Testing

@testable import CashewCore

/// The sample store.
///
/// Every test writes into its own temp directory. `UsageHistory.default` points at the user's real
/// Application Support folder, and a test that touched it would be writing into the running app's
/// state — the same reason `Settings` and `Notifier` take an injected `UserDefaults`.
@Suite struct UsageHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cashew-history-\(UUID().uuidString)", isDirectory: true)
    }

    private func window(_ id: String, _ utilization: Double) -> LimitWindow {
        LimitWindow(kind: .primary, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: utilization, resetsAt: nil)
    }

    @Test func recordsOneSamplePerWindow() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10), window("weekly", 60)], provider: .claude, at: now)

        #expect(history.samples(for: "session", provider: .claude).map(\.utilization) == [10])
        #expect(history.samples(for: "weekly", provider: .claude).map(\.utilization) == [60])
        // Keyed by id, so one limit's history never leaks into another's rate.
        #expect(history.samples(for: "scoped:Fable", provider: .claude).isEmpty)
    }

    @Test func accumulatesAcrossPolls() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10)], provider: .claude, at: now.addingTimeInterval(-600))
        history.record([window("session", 20)], provider: .claude, at: now)
        #expect(history.samples(for: "session", provider: .claude).map(\.utilization) == [10, 20])
    }

    /// Survives a relaunch, which is the entire reason this is on disk rather than in memory — a
    /// menu bar app that forgot its history on every restart could never forecast a weekly window.
    @Test func samplesOutliveTheProcess() {
        let directory = scratch()
        UsageHistory(directory: directory).record([window("session", 42)], provider: .claude, at: now)
        #expect(UsageHistory(directory: directory).samples(for: "session", provider: .claude).map(\.utilization) == [42])
    }

    @Test func prunesSamplesPastTheRetentionWindow() {
        let history = UsageHistory(directory: scratch())
        let old = now.addingTimeInterval(-UsageHistory.retention - 60)
        let justInside = now.addingTimeInterval(-UsageHistory.retention + 60)

        history.record([window("session", 1)], provider: .claude, at: old)
        history.record([window("session", 2)], provider: .claude, at: justInside)
        history.record([window("session", 3)], provider: .claude, at: now)

        // Pruning happens on write, against the timestamp of the write being made.
        #expect(history.samples(for: "session", provider: .claude).map(\.utilization) == [2, 3])
    }

    /// A window whose utilization the endpoint didn't give is nothing, not zero. Recording it as 0
    /// would look like a reset to `Forecast` and throw the trailing window away.
    @Test func aNonFiniteReadingIsNotRecorded() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", .nan), window("weekly", 30)], provider: .claude, at: now)
        #expect(history.samples(for: "session", provider: .claude).isEmpty)
        #expect(history.samples(for: "weekly", provider: .claude).count == 1)
    }

    /// Reading is best-effort by design: a forecast sits on top of the number the user actually came
    /// for, so a corrupt file has to cost the forecast and nothing else.
    @Test func aCorruptFileYieldsAnEmptyHistoryRatherThanThrowing() throws {
        let directory = scratch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is not json".utf8)
            .write(to: directory.appendingPathComponent("history.json"))

        let history = UsageHistory(directory: directory)
        #expect(history.samples(for: "session", provider: .claude).isEmpty)
        // And it recovers: the next write replaces the unreadable file.
        history.record([window("session", 5)], provider: .claude, at: now)
        #expect(UsageHistory(directory: directory).samples(for: "session", provider: .claude).count == 1)
    }

    @Test func anAbsentFileIsSimplyAnEmptyHistory() {
        #expect(UsageHistory(directory: scratch()).samples(for: "session", provider: .claude).isEmpty)
    }

    // MARK: - The last good reading

    private func window(_ id: String, _ utilization: Double, resetsIn: TimeInterval?) -> LimitWindow {
        LimitWindow(kind: .primary, id: id, label: "SESSION · 5-HOUR", shortLabel: "Session",
                    optionLabel: "Session (5h)", utilization: utilization,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    /// Spelled out at every call site rather than defaulted to Claude: the bug this shape exists to
    /// prevent was a provider being assumed rather than stated.
    private func section(_ provider: ProviderID,
                         _ windows: [LimitWindow]) -> UsageHistory.Snapshot.Section {
        UsageHistory.Snapshot.Section(provider: provider, windows: windows)
    }

    /// The whole point: a launch that can't reach the API still has rows to draw. Every display
    /// field has to survive, not just the percentage — a heading and a reset time are what make it a
    /// row rather than a number.
    @Test func theLastGoodReadingSurvivesARestart() throws {
        let directory = scratch()
        let saved = [window("session", 82, resetsIn: 3_600),
                     window("weekly", 41, resetsIn: 200_000)]
        UsageHistory(directory: directory).save(snapshot: [section(.claude, saved)], at: now)

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.sections == [section(.claude, saved)])
        #expect(restored.windows(for: .claude) == saved)
        #expect(restored.at == now)
    }

    /// The rule this shape exists for: **a saved reading restores into the same provider sections it
    /// was saved from.**
    ///
    /// It did not. `save` took a flat `[LimitWindow]` holding every provider's rows at once and the
    /// restore had no way to tell them apart, so it handed all of them to Claude. A real cold start
    /// drew `CODEX · 30-DAY` under the `CLAUDE` heading — see `aRestoredReadingStillDrawsItsHeadings`
    /// below for the other half of the damage.
    @Test func aSavedReadingRestoresIntoTheSectionsItWasSavedFrom() throws {
        let directory = scratch()
        let claude = [window("session", 7, resetsIn: 3_600),
                      window("weekly", 28, resetsIn: 50_000)]
        let codex = [window("primary", 0, resetsIn: 2_500_000)]
        UsageHistory(directory: directory)
            .save(snapshot: [section(.claude, claude), section(.codex, codex)], at: now)

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))

        #expect(restored.sections.map(\.provider) == [.claude, .codex])
        #expect(restored.windows(for: .claude) == claude)
        #expect(restored.windows(for: .codex) == codex)
        // The symptom, stated directly: Codex's row is not one of Claude's.
        #expect(!restored.windows(for: .claude).contains { $0.id == "primary" })
    }

    /// The user-visible half, end to end, because the collapse cost more than one mislabelled row:
    /// two providers folded into one section, and headings are drawn only when there is more than
    /// one section to tell apart. So the dropdown lost the `CLAUDE` heading, the `CODEX` heading and
    /// the separator between them as well, and read as one undivided list.
    ///
    /// `PanelSections.rows` is already covered for two live snapshots; what nothing covered was the
    /// path that actually broke — snapshots rebuilt *from disk*.
    @Test func aRestoredReadingStillDrawsItsHeadings() throws {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [
            section(.claude, [window("session", 7, resetsIn: 3_600)]),
            section(.codex, [window("primary", 0, resetsIn: 2_500_000)]),
        ], at: now)

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        // Exactly what `AppDelegate.restoreLastGoodReading()` builds from it.
        let snapshots = restored.sections.map {
            ProviderSnapshot(provider: $0.provider, windows: $0.windows,
                             updatedAt: restored.at, failure: nil, restored: true)
        }

        let rows = PanelSections.rows(for: snapshots, now: now)
        #expect(rows == [.heading(.claude), .usage(.claude, restored.windows(for: .claude)[0]),
                         .separator,
                         .heading(.codex), .usage(.codex, restored.windows(for: .codex)[0])])
    }

    /// A provider whose every row has expired has nothing to say, and an empty section would still
    /// count towards the "more than one section" rule above — putting a `CLAUDE` heading over a
    /// Codex-only menu.
    @Test func aSectionLeftWithNothingIsDroppedRatherThanRestoredEmpty() throws {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [
            section(.claude, [window("session", 82, resetsIn: -3_600)]),   // reset an hour ago
            section(.codex, [window("primary", 0, resetsIn: 2_500_000)]),
        ], at: now.addingTimeInterval(-7_200))

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.sections.map(\.provider) == [.codex])

        let snapshots = restored.sections.map {
            ProviderSnapshot(provider: $0.provider, windows: $0.windows,
                             updatedAt: restored.at, failure: nil, restored: true)
        }
        // One section, so no headings — which is the *right* answer here, unlike the collapsed case.
        #expect(!PanelSections.rows(for: snapshots, now: now)
            .contains { if case .heading = $0 { return true } else { return false } })
    }

    /// A window that has already reset describes a period that is over. "82%" for a session that
    /// rolled over two hours ago reads as current and there is no way for the user to tell — worse
    /// than showing nothing.
    @Test func windowsThatHaveAlreadyResetAreNotRestored() throws {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [section(.claude, [
            window("session", 82, resetsIn: -3_600),   // reset an hour ago
            window("weekly", 41, resetsIn: 200_000),
        ])], at: now.addingTimeInterval(-7_200))

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.windows(for: .claude).map(\.id) == ["weekly"])
    }

    /// …and if that leaves nothing, there is nothing to show. Returning an empty snapshot would send
    /// `MenuController` down its non-empty branch to render a panel with no rows in it.
    @Test func aFullyExpiredSnapshotRestoresNothing() {
        let directory = scratch()
        UsageHistory(directory: directory)
            .save(snapshot: [section(.claude, [window("session", 82, resetsIn: -60)])],
                  at: now.addingTimeInterval(-7_200))
        #expect(UsageHistory(directory: directory).restorableSnapshot(now: now) == nil)
    }

    /// The provider never promised a reset time for these, so nothing says the reading has expired.
    @Test func aWindowWithNoResetTimeIsStillRestorable() throws {
        let directory = scratch()
        UsageHistory(directory: directory)
            .save(snapshot: [section(.claude, [window("session", 82, resetsIn: nil)])], at: now)
        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.windows(for: .claude).count == 1)
    }

    @Test func noSnapshotAtAllRestoresNothing() {
        #expect(UsageHistory(directory: scratch()).restorableSnapshot(now: now) == nil)
    }

    /// Same fail-soft rule as the samples file: the snapshot is a convenience, and an unreadable one
    /// costs the convenience rather than the launch.
    @Test func aCorruptSnapshotRestoresNothing() throws {
        let directory = scratch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        #expect(UsageHistory(directory: directory).restorableSnapshot(now: now) == nil)
    }

    /// The two files are independent — a corrupt history must not cost the snapshot, or a single bad
    /// write takes out both halves at once.
    @Test func theSnapshotAndTheSamplesFailIndependently() throws {
        let directory = scratch()
        UsageHistory(directory: directory)
            .save(snapshot: [section(.claude, [window("session", 82, resetsIn: 3_600)])], at: now)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))

        let history = UsageHistory(directory: directory)
        #expect(history.samples(for: "session", provider: .claude).isEmpty)
        #expect(history.restorableSnapshot(now: now) != nil)
    }

    /// End to end: what the store hands back is what the projection can actually use.
    @Test func recordedSamplesFeedAForecast() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10)], provider: .claude, at: now.addingTimeInterval(-60 * 60))
        history.record([window("session", 25)], provider: .claude, at: now.addingTimeInterval(-30 * 60))
        history.record([window("session", 40)], provider: .claude, at: now)

        let forecast = Forecast.project(samples: history.samples(for: "session", provider: .claude), kind: .primary,
                                        resetsAt: now.addingTimeInterval(3 * 60 * 60), now: now)
        #expect(forecast == .onPace(now.addingTimeInterval(120 * 60)))
    }

    @Test func twoProvidersRecordTheSameWindowIDSeparately() throws {
        let directory = scratch()
        let history = UsageHistory(directory: directory)
        let at = Date(timeIntervalSince1970: 1_000_000)
        let window = LimitWindow(kind: .primary, id: "session", label: "l", shortLabel: "s",
                                 optionLabel: "o", utilization: 10, resetsAt: nil)

        history.record([window], provider: .claude, at: at)
        history.record([LimitWindow(kind: .primary, id: "session", label: "l", shortLabel: "s",
                                    optionLabel: "o", utilization: 90, resetsAt: nil)],
                       provider: .codex, at: at)

        // Same window id, different providers: one series each, not one series of two.
        #expect(history.samples(for: "session", provider: .claude).map(\.utilization) == [10])
        #expect(history.samples(for: "session", provider: .codex).map(\.utilization) == [90])
    }
}
