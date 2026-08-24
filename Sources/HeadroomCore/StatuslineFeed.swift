import Foundation

/// Plan usage as Claude Code already knows it, without asking the API.
///
/// Claude Code hands its statusline command a JSON payload on stdin, and that payload carries
/// `rate_limits.five_hour` and `rate_limits.seven_day` — the same two numbers Headroom polls for.
/// A one-line addition to the user's own statusline script drops them in a file, and Headroom reads
/// it. No token, no request, no Keychain prompt, and the numbers are live rather than up to fifteen
/// minutes stale.
///
/// **Headroom never edits `~/.claude/settings.json`.** The user's statusline is theirs — this one
/// already renders their directory, branch, model and context — and silently replacing it to install
/// a helper would be a poor trade for a menu bar app. Opting in is a line they paste and can delete.
struct StatuslineFeed {
    /// How stale the file may be before Headroom stops trusting it.
    ///
    /// The statusline only re-runs when something happens in Claude Code, so an idle session stops
    /// refreshing this — which is fine, because idle usage isn't changing either. The bound is for
    /// the case that isn't fine: Claude Code closed hours ago and the last numbers are frozen while
    /// another machine, or the web app, moves them. Past this, polling takes over.
    static let maxAge: TimeInterval = 5 * 60

    private let fileURL: URL

    /// Alongside the history and snapshot, in Headroom's own directory — see `SECURITY.md`.
    static let `default` = StatuslineFeed(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vickipetrova.headroom", isDirectory: true))

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("statusline.json")
    }

    /// The windows Claude Code last reported, or nil if there's nothing recent and readable.
    ///
    /// Nil is not an error. It means "poll instead", which is the normal state for anyone who hasn't
    /// opted in and for anyone whose Claude Code isn't running.
    func read(now: Date = Date()) -> [LimitWindow]? {
        guard let written = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date else { return nil }
        // The payload carries no timestamp of its own, so the file's mtime is the only answer to
        // "how old is this" — and it is the honest one, since the script rewrites on every render.
        guard now.timeIntervalSince(written) <= Self.maxAge, written <= now else { return nil }

        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let windows = Self.windows(in: object)
        return windows.isEmpty ? nil : windows
    }

    /// Pure, so every shape this file can take is reachable from a test.
    ///
    /// Parsed as defensively as the API response and for the same reason (hard rule 3): this is an
    /// undocumented payload from a tool that updates itself weekly. Anything missing or wrong-typed
    /// costs that one window, never the app. The helpers are `ClaudeProvider`'s rather than a second
    /// set — `number` already rejects JSON booleans and clamps, `date` already validates the epoch,
    /// and a second implementation would drift.
    static func windows(in object: [String: Any]) -> [LimitWindow] {
        guard let limits = object["rate_limits"] as? [String: Any] else { return [] }

        // Built through `ClaudeProvider`'s own constructors, which matters more than it looks: the
        // ids they assign are what `UsageHistory`, `Notifier` and the Show in Menu Bar selection key
        // on. A window arriving from this source has to *be* the same window, or switching sources
        // would split one limit's history in two and re-fire alerts already sent.
        return [
            window(limits["five_hour"], ClaudeProvider.sessionWindow),
            window(limits["seven_day"], ClaudeProvider.weeklyWindow),
        ].compactMap { $0 }

        // Per-model limits are deliberately absent: the statusline payload has no equivalent of the
        // API's `weekly_scoped`, so a `WEEKLY · FABLE` row can only come from polling. That is why
        // this is a second source rather than a replacement.
    }

    private static func window(_ any: Any?,
                               _ build: (Double, Date?) -> LimitWindow) -> LimitWindow? {
        guard let entry = any as? [String: Any],
              let utilization = ClaudeProvider.number(entry["used_percentage"]) else { return nil }
        // `resets_at` is a unix timestamp here, where the API sends an ISO string. `date` reads both.
        return build(utilization, ClaudeProvider.date(entry["resets_at"]))
    }
}

/// Combining the two sources.
///
/// Neither is complete on its own: the statusline is fresher but reports only the session and weekly
/// windows, while the API is the only thing that knows about per-model limits. Replacing one with the
/// other was tried first and was worse than either — a `WEEKLY · FABLE` row that blinked in and out
/// depending on whether a Claude Code session happened to be open.
enum SourceMerge {
    /// The polled reading, with any window the live source also reports substituted in.
    ///
    /// Order comes from the poll, because that is the order the API fixes and the panel is built
    /// around — session, then weekly, then scoped. Substituting in place rather than appending keeps
    /// that stable while a live reading arrives and departs.
    static func merge(polled: [LimitWindow], live: [LimitWindow]) -> [LimitWindow] {
        guard !live.isEmpty else { return polled }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged = polled.map { byID[$0.id] ?? $0 }
        // Before the first successful poll there is nothing to substitute into, and the live reading
        // is the only thing there is — which is also what makes a cold start with no network show
        // real numbers instead of "Loading…".
        let seen = Set(merged.map(\.id))
        merged.append(contentsOf: live.filter { !seen.contains($0.id) })
        return merged
    }
}
