import Foundation

/// One reading of one limit, at one moment.
///
/// `limitID` rather than the label, for the same reason `Notifier` keys on it: restyling a heading
/// must not orphan the history behind it.
struct Sample: Codable, Equatable {
    let at: Date
    let limitID: String
    let utilization: Double
}

/// Where a limit is heading, given how fast it has been moving.
///
/// A percentage on its own can't answer the only question that matters — 40% an hour into a
/// five-hour window and 40% four hours in are the same number and opposite situations.
///
/// Pure, and deliberately so: every rule here is awkward to reach through the live app, which needs
/// hours of real usage to produce one data point. Fixtures reach all of them in milliseconds.
enum Forecast: Equatable {
    /// Projected to reach 100% at this instant, which is *before* the window resets.
    case onPace(Date)
    /// Moving, but slowly enough that the reset arrives first.
    case underPace
    /// Not enough to say. Too few samples, no reset time, or a rate indistinguishable from idle.
    case unknown
}

extension Forecast {
    /// How far back to look, by kind.
    ///
    /// A session window is five hours, so 90 minutes is long enough to smooth out a single burst and
    /// short enough that a burst an hour ago still counts. A weekly window is 168 hours, where the
    /// same reasoning lands on a day.
    static func trailingWindow(for kind: LimitWindow.Kind) -> TimeInterval {
        switch kind {
        case .session: return 90 * 60
        case .weekly, .weeklyScoped: return 24 * 60 * 60
        }
    }

    /// A fall this large is a reset, not usage. Utilization only decreases when the window rolls
    /// over, and the endpoint's own rounding moves it by fractions of a point, never by ten.
    static let resetDropPoints: Double = 10

    /// Two samples is one interval, and one interval is one poll's worth of noise presented as a
    /// trend. Three is the smallest number that can disagree with itself.
    static let minimumSamples = 3

    /// How much of the trailing window the samples must actually cover.
    ///
    /// Sample *count* is not the same as observation *time*, and conflating them produced a false
    /// positive on the very first real run: five weekly samples spanning 22 minutes, one point of
    /// movement, extrapolated to "on pace, Saturday 1:44 AM" for a limit sitting at 2%. Twenty-two
    /// minutes says nothing about a 168-hour window, however many times you poll during it.
    static let minimumSpanFraction: Double = 0.25

    /// The endpoint reports `percent` as an integer, so one point is the smallest change that can
    /// exist and carries about half a point of rounding with it. A rate fitted to a single tick is
    /// mostly quantization error, and over a weekly window that error projects enormously.
    static let minimumMovementPoints: Double = 2

    /// Below this the projection is hundreds of hours out, and "next March" is a worse answer than
    /// no answer. It also absorbs the endpoint's own rounding jitter, which is why it isn't zero.
    static let idleRatePerHour: Double = 0.1

    static func project(samples: [Sample], kind: LimitWindow.Kind,
                        resetsAt: Date?, now: Date) -> Forecast {
        // Nothing to be on pace *for*. A window with no reset time can't be beaten or missed.
        guard let resetsAt else { return .unknown }

        let recent = samples
            .filter { now.timeIntervalSince($0.at) <= trailingWindow(for: kind) && $0.at <= now }
            .sorted { $0.at < $1.at }
        let live = sinceLastReset(recent)

        guard live.count >= minimumSamples, let first = live.first, let last = live.last else {
            return .unknown
        }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 0 else { return .unknown }
        // Enough observation time to be extrapolating from something. See `minimumSpanFraction`.
        guard elapsed >= trailingWindow(for: kind) * minimumSpanFraction else { return .unknown }

        let movement = last.utilization - first.utilization
        // Enough movement to be above the endpoint's own rounding. See `minimumMovementPoints`.
        // A limit that genuinely crept one point in six hours is far too slow to reach the cap
        // anyway, so nothing worth saying is lost here — it would have been `.underPace`.
        guard movement >= minimumMovementPoints else { return .unknown }

        let ratePerSecond = movement / elapsed
        // Covers idle, covers falling — a negative rate would otherwise project a hit date in the
        // past and read as an emergency — and covers the non-finite case a future provider could
        // produce, since `ClaudeProvider` clamps but the model here is provider-agnostic.
        guard ratePerSecond.isFinite, ratePerSecond * 3600 > idleRatePerHour else { return .unknown }

        let remaining = 100 - last.utilization
        guard remaining > 0 else { return .onPace(now) }

        // Projected from `now` off the most recent reading rather than from the oldest sample: the
        // rate is the fitted slope, but the *position* the user is being told about is the one they
        // can see in the panel. Anchoring to the window's start would put the hit date in the past
        // whenever the poll rate is slow and the trend is steep.
        let hit = now.addingTimeInterval(remaining / ratePerSecond)
        return hit < resetsAt ? .onPace(hit) : .underPace
    }

    /// Everything from the most recent reset onwards.
    ///
    /// Without this a window that rolled over an hour ago averages the tail of the old period with
    /// the start of the new one, and reports a rate that describes neither — for a weekly limit that
    /// wrong answer would persist for a day.
    private static func sinceLastReset(_ ascending: [Sample]) -> [Sample] {
        var start = ascending.startIndex
        for i in ascending.indices.dropFirst()
        where ascending[i].utilization < ascending[i - 1].utilization - resetDropPoints {
            start = i
        }
        return Array(ascending[start...])
    }

    /// Whether this forecast should colour the menu bar percentage.
    ///
    /// Weekly only, and on purpose: a session window refills every five hours, so being on pace for
    /// one is normal and colouring it would make the title shout during ordinary work. A weekly
    /// window is the one you cannot wait out.
    ///
    /// Here rather than in `MenuController` because the controller can't be built in a test, and a
    /// rule that lives there is a rule with no coverage.
    static func tintsTitle(kind: LimitWindow.Kind, forecast: Forecast) -> Bool {
        guard case .onPace = forecast else { return false }
        switch kind {
        case .weekly, .weeklyScoped: return true
        case .session: return false
        }
    }
}
