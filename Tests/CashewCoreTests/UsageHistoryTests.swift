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
        LimitWindow(kind: .session, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: utilization, resetsAt: nil)
    }

    @Test func recordsOneSamplePerWindow() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10), window("weekly", 60)], at: now)

        #expect(history.samples(for: "session").map(\.utilization) == [10])
        #expect(history.samples(for: "weekly").map(\.utilization) == [60])
        // Keyed by id, so one limit's history never leaks into another's rate.
        #expect(history.samples(for: "scoped:Fable").isEmpty)
    }

    @Test func accumulatesAcrossPolls() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10)], at: now.addingTimeInterval(-600))
        history.record([window("session", 20)], at: now)
        #expect(history.samples(for: "session").map(\.utilization) == [10, 20])
    }

    /// Survives a relaunch, which is the entire reason this is on disk rather than in memory — a
    /// menu bar app that forgot its history on every restart could never forecast a weekly window.
    @Test func samplesOutliveTheProcess() {
        let directory = scratch()
        UsageHistory(directory: directory).record([window("session", 42)], at: now)
        #expect(UsageHistory(directory: directory).samples(for: "session").map(\.utilization) == [42])
    }

    @Test func prunesSamplesPastTheRetentionWindow() {
        let history = UsageHistory(directory: scratch())
        let old = now.addingTimeInterval(-UsageHistory.retention - 60)
        let justInside = now.addingTimeInterval(-UsageHistory.retention + 60)

        history.record([window("session", 1)], at: old)
        history.record([window("session", 2)], at: justInside)
        history.record([window("session", 3)], at: now)

        // Pruning happens on write, against the timestamp of the write being made.
        #expect(history.samples(for: "session").map(\.utilization) == [2, 3])
    }

    /// A window whose utilization the endpoint didn't give is nothing, not zero. Recording it as 0
    /// would look like a reset to `Forecast` and throw the trailing window away.
    @Test func aNonFiniteReadingIsNotRecorded() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", .nan), window("weekly", 30)], at: now)
        #expect(history.samples(for: "session").isEmpty)
        #expect(history.samples(for: "weekly").count == 1)
    }

    /// Reading is best-effort by design: a forecast sits on top of the number the user actually came
    /// for, so a corrupt file has to cost the forecast and nothing else.
    @Test func aCorruptFileYieldsAnEmptyHistoryRatherThanThrowing() throws {
        let directory = scratch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is not json".utf8)
            .write(to: directory.appendingPathComponent("history.json"))

        let history = UsageHistory(directory: directory)
        #expect(history.samples(for: "session").isEmpty)
        // And it recovers: the next write replaces the unreadable file.
        history.record([window("session", 5)], at: now)
        #expect(UsageHistory(directory: directory).samples(for: "session").count == 1)
    }

    @Test func anAbsentFileIsSimplyAnEmptyHistory() {
        #expect(UsageHistory(directory: scratch()).samples(for: "session").isEmpty)
    }

    // MARK: - The last good reading

    private func window(_ id: String, _ utilization: Double, resetsIn: TimeInterval?) -> LimitWindow {
        LimitWindow(kind: .session, id: id, label: "SESSION · 5-HOUR", shortLabel: "Session",
                    optionLabel: "Session (5h)", utilization: utilization,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    /// The whole point: a launch that can't reach the API still has rows to draw. Every display
    /// field has to survive, not just the percentage — a heading and a reset time are what make it a
    /// row rather than a number.
    @Test func theLastGoodReadingSurvivesARestart() throws {
        let directory = scratch()
        let saved = [window("session", 82, resetsIn: 3_600),
                     window("weekly", 41, resetsIn: 200_000)]
        UsageHistory(directory: directory).save(snapshot: saved, at: now)

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.windows == saved)
        #expect(restored.at == now)
    }

    /// A window that has already reset describes a period that is over. "82%" for a session that
    /// rolled over two hours ago reads as current and there is no way for the user to tell — worse
    /// than showing nothing.
    @Test func windowsThatHaveAlreadyResetAreNotRestored() throws {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [
            window("session", 82, resetsIn: -3_600),   // reset an hour ago
            window("weekly", 41, resetsIn: 200_000),
        ], at: now.addingTimeInterval(-7_200))

        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.windows.map(\.id) == ["weekly"])
    }

    /// …and if that leaves nothing, there is nothing to show. Returning an empty snapshot would send
    /// `MenuController` down its non-empty branch to render a panel with no rows in it.
    @Test func aFullyExpiredSnapshotRestoresNothing() {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [window("session", 82, resetsIn: -60)],
                                                at: now.addingTimeInterval(-7_200))
        #expect(UsageHistory(directory: directory).restorableSnapshot(now: now) == nil)
    }

    /// The provider never promised a reset time for these, so nothing says the reading has expired.
    @Test func aWindowWithNoResetTimeIsStillRestorable() throws {
        let directory = scratch()
        UsageHistory(directory: directory).save(snapshot: [window("session", 82, resetsIn: nil)],
                                                at: now)
        let restored = try #require(UsageHistory(directory: directory).restorableSnapshot(now: now))
        #expect(restored.windows.count == 1)
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
        UsageHistory(directory: directory).save(snapshot: [window("session", 82, resetsIn: 3_600)],
                                                at: now)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))

        let history = UsageHistory(directory: directory)
        #expect(history.samples(for: "session").isEmpty)
        #expect(history.restorableSnapshot(now: now) != nil)
    }

    /// End to end: what the store hands back is what the projection can actually use.
    @Test func recordedSamplesFeedAForecast() {
        let history = UsageHistory(directory: scratch())
        history.record([window("session", 10)], at: now.addingTimeInterval(-60 * 60))
        history.record([window("session", 25)], at: now.addingTimeInterval(-30 * 60))
        history.record([window("session", 40)], at: now)

        let forecast = Forecast.project(samples: history.samples(for: "session"), kind: .session,
                                        resetsAt: now.addingTimeInterval(3 * 60 * 60), now: now)
        #expect(forecast == .onPace(now.addingTimeInterval(120 * 60)))
    }
}
