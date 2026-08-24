import Foundation
import Testing

@testable import HeadroomCore

/// Reading plan usage out of what Claude Code hands its statusline.
///
/// Fixtures are the real payload, captured from a running session rather than copied from the docs —
/// which mattered: the documentation shows `used_percentage` as `23.5`, and the live payload sends
/// `16`. A parser written against the docs alone would have been tested only on the Double path.
@Suite struct StatuslineFeedTests {
    private let now = Date(timeIntervalSince1970: 1_787_570_000)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-statusline-\(UUID().uuidString)", isDirectory: true)
    }

    @discardableResult
    private func write(_ json: String, to directory: URL, age: TimeInterval = 0) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statusline.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    /// Captured verbatim from a live session.
    private let real = """
        {"rate_limits":{"five_hour":{"used_percentage":16,"resets_at":1787578800},
        "seven_day":{"used_percentage":17,"resets_at":1787666400}}}
        """

    @Test func readsBothWindowsFromTheRealPayload() throws {
        let windows = try #require(StatuslineFeed(directory: scratch(), seed: real, now: now).read(now: now))
        #expect(windows.map(\.utilization) == [16, 17])
        #expect(windows.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_787_578_800),
                                            Date(timeIntervalSince1970: 1_787_666_400)])
    }

    /// The reason this reuses `ClaudeProvider`'s window builders rather than constructing its own:
    /// `UsageHistory`, `Notifier` and the Show in Menu Bar selection all key on `id`. If the two
    /// sources disagreed, switching between them would split one limit's history in two and re-fire
    /// alerts that had already been sent.
    @Test func windowsAreIndistinguishableFromThePolledOnes() {
        let fromStatusline = StatuslineFeed.windows(in: [
            "rate_limits": ["five_hour": ["used_percentage": 16],
                            "seven_day": ["used_percentage": 17]],
        ])
        #expect(fromStatusline.map(\.id) == [LimitWindow.sessionID, LimitWindow.weeklyID])
        #expect(fromStatusline.map(\.kind) == [.session, .weekly])
        #expect(fromStatusline.map(\.label) == ["SESSION · 5-HOUR", "WEEKLY · ALL MODELS"])
        #expect(fromStatusline.map(\.optionLabel) == ["Session (5h)", "Weekly (all models)"])
    }

    /// The docs say 23.5, the live payload says 16. Both are real.
    @Test(arguments: [("16", 16.0), ("23.5", 23.5), ("0", 0.0), ("100", 100.0)])
    func percentagesParseAsIntOrDouble(_ raw: String, _ expected: Double) throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":\#(raw)}}}"#
        let windows = try #require(StatuslineFeed(directory: scratch(), seed: json, now: now).read(now: now))
        #expect(windows.first?.utilization == expected)
    }

    /// Same guard as the API parser: `as? Double` on a JSON boolean yields 1.0, so `true` would read
    /// as 1% without the CoreFoundation type check.
    @Test func aBooleanIsNotOnePercent() {
        let windows = StatuslineFeed.windows(in: [
            "rate_limits": ["five_hour": ["used_percentage": true]],
        ])
        #expect(windows.isEmpty)
    }

    /// One malformed window costs that window, never the other and never the app.
    @Test func abadWindowDoesNotTakeTheGoodOneWithIt() {
        let windows = StatuslineFeed.windows(in: [
            "rate_limits": ["five_hour": ["used_percentage": "lots"],
                            "seven_day": ["used_percentage": 17]],
        ])
        #expect(windows.map(\.id) == [LimitWindow.weeklyID])
    }

    /// A window with no usable reset time still renders — the panel says "reset time unknown".
    @Test func aMissingResetTimeIsNotFatal() {
        let windows = StatuslineFeed.windows(in: [
            "rate_limits": ["five_hour": ["used_percentage": 16]],
        ])
        #expect(windows.count == 1)
        #expect(windows.first?.resetsAt == nil)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"rate_limits":{}}"#,
        #"{"rate_limits":[]}"#,
        #"{"rate_limits":null}"#,
        #"{"context_window":{"used_percentage":8}}"#,   // a payload with no rate_limits at all
        #"not json"#,
    ])
    func anythingUnusableMeansPollInstead(_ json: String) throws {
        #expect(StatuslineFeed(directory: scratch(), seed: json, now: now).read(now: now) == nil)
    }

    @Test func noFileAtAllMeansPollInstead() {
        #expect(StatuslineFeed(directory: scratch()).read(now: now) == nil)
    }

    // MARK: - Freshness

    /// Claude Code closed hours ago: the numbers are frozen while a second machine or the web app
    /// moves them. Past the bound, the API is the only source that can be right.
    @Test func astaleFileIsIgnored() throws {
        let feed = StatuslineFeed(directory: scratch(), seed: real, now: now,
                                  age: StatuslineFeed.maxAge + 60)
        #expect(feed.read(now: now) == nil)
    }

    @Test func afreshFileIsUsed() throws {
        let feed = StatuslineFeed(directory: scratch(), seed: real, now: now,
                                  age: StatuslineFeed.maxAge - 60)
        #expect(feed.read(now: now) != nil)
    }

    /// A clock that jumped, or a file written by something with a bad clock. Trusting a future
    /// timestamp would keep stale numbers alive indefinitely, since they'd never *become* old.
    @Test func afileFromTheFutureIsIgnored() throws {
        let feed = StatuslineFeed(directory: scratch(), seed: real, now: now, age: -3_600)
        #expect(feed.read(now: now) == nil)
    }
}

/// Combining a live statusline reading with the last poll.
///
/// The rule this suite exists to hold: **the live source must never remove a row.** Using it alone
/// was tried first, and a `WEEKLY · FABLE` row that appeared and vanished depending on whether a
/// Claude Code session was open was worse than either source on its own.
@Suite struct SourceMergeTests {
    private func window(_ kind: LimitWindow.Kind, _ id: String, _ utilization: Double) -> LimitWindow {
        LimitWindow(kind: kind, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: utilization, resetsAt: nil)
    }

    private var polled: [LimitWindow] {
        [window(.session, LimitWindow.sessionID, 10),
         window(.weekly, LimitWindow.weeklyID, 20),
         window(.weeklyScoped, "scoped:Fable", 30)]
    }

    /// The whole point: fresher numbers where the live source has them, and the per-model row it
    /// knows nothing about left exactly where it was.
    @Test func liveReadingsReplaceTheirCounterpartsAndNothingElse() {
        let merged = SourceMerge.merge(
            polled: polled,
            live: [window(.session, LimitWindow.sessionID, 16),
                   window(.weekly, LimitWindow.weeklyID, 18)])

        #expect(merged.map(\.id) == [LimitWindow.sessionID, LimitWindow.weeklyID, "scoped:Fable"])
        #expect(merged.map(\.utilization) == [16, 18, 30])
    }

    /// Order is the API's, because that is what the panel is built around. A live reading arriving
    /// or departing must not reshuffle the rows under the user.
    @Test func orderComesFromThePollNotTheLiveSource() {
        let merged = SourceMerge.merge(
            polled: polled,
            live: [window(.weekly, LimitWindow.weeklyID, 18),
                   window(.session, LimitWindow.sessionID, 16)])
        #expect(merged.map(\.id) == [LimitWindow.sessionID, LimitWindow.weeklyID, "scoped:Fable"])
    }

    @Test func noLiveReadingLeavesThePollUntouched() {
        #expect(SourceMerge.merge(polled: polled, live: []) == polled)
    }

    /// Before the first successful poll the live reading is all there is — which is what lets a cold
    /// start with no network show real numbers instead of "Loading…".
    @Test func withoutAPollTheLiveReadingStandsAlone() {
        let live = [window(.session, LimitWindow.sessionID, 16)]
        #expect(SourceMerge.merge(polled: [], live: live) == live)
    }

    /// A limit the poll has never reported still appears rather than being silently dropped.
    @Test func aLiveOnlyWindowIsAppendedRatherThanDiscarded() {
        let merged = SourceMerge.merge(
            polled: [window(.session, LimitWindow.sessionID, 10)],
            live: [window(.weekly, LimitWindow.weeklyID, 18)])
        #expect(merged.map(\.id) == [LimitWindow.sessionID, LimitWindow.weeklyID])
    }

    /// Substitution is by `id`, which is the same key `UsageHistory` and `Notifier` use — matching on
    /// anything else would split one limit's history in two.
    @Test func substitutionIsByIdentifierNotPosition() {
        let merged = SourceMerge.merge(
            polled: polled,
            live: [window(.weeklyScoped, "scoped:Fable", 99)])
        #expect(merged.map(\.utilization) == [10, 20, 99])
    }
}

/// Test-only convenience: build a feed with its file already in place at a chosen age.
extension StatuslineFeed {
    init(directory: URL, seed json: String, now: Date, age: TimeInterval = 0) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statusline.json")
        try? Data(json.utf8).write(to: url)
        try? FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        self.init(directory: directory)
    }
}
