import Foundation

/// Plan usage as Claude Code already knows it, without asking the API.
///
/// Claude Code hands its statusline command a JSON payload on stdin, and that payload carries
/// `rate_limits.five_hour` and `rate_limits.seven_day` — the same two numbers Cashew polls for.
/// A one-line addition to the user's own statusline script drops them in a file, and Cashew reads
/// it. No token, no request, no Keychain prompt, and the numbers are live rather than up to fifteen
/// minutes stale.
///
/// **Cashew never edits the user's statusline.** It is theirs — this one already renders their
/// directory, branch, model and context — and silently replacing it to install a helper would be a
/// poor trade for a menu bar app. Opting in is a line they paste and can delete. (Cashew does add
/// its own *hooks* to `~/.claude/settings.json` for session tracking — see `HookInstaller` — and
/// never touches the `statusLine` key.)
struct StatuslineFeed {
    /// How stale the file may be before Cashew stops trusting it.
    ///
    /// The statusline only re-runs when something happens in Claude Code, so an idle session stops
    /// refreshing this — which is fine, because idle usage isn't changing either. The bound is for
    /// the case that isn't fine: Claude Code closed hours ago and the last numbers are frozen while
    /// another machine, or the web app, moves them. Past this, polling takes over.
    static let maxAge: TimeInterval = 5 * 60

    private let fileURL: URL

    /// Alongside the history and snapshot, in Cashew's own directory — see `SECURITY.md`.
    static let `default` = StatuslineFeed(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vickipetrova.cashew", isDirectory: true))

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("statusline.json")
    }

    /// The windows Claude Code last reported, or nil if there's nothing recent and readable.
    ///
    /// Nil is not an error. It means "poll instead", which is the normal state for anyone who hasn't
    /// opted in and for anyone whose Claude Code isn't running.
    func read(now: Date = Date()) -> [LimitWindow]? {
        guard case .live(let windows, _) = load(now: now) else { return nil }
        return windows
    }

    /// Whether the feed is working, for the Settings submenu.
    ///
    /// Exists because the opt-in is a line in a script the app can't see: without it, a user who
    /// pasted the line wrong, or who is missing `jq`, gets polling and no hint that anything failed —
    /// every error in the snippet is swallowed on purpose.
    func status(now: Date = Date()) -> Status {
        switch load(now: now) {
        case .notSetUp: return .notSetUp
        case .live(_, let written): return .live(since: written)
        case .idle(let written): return .idle(since: written)
        case .unreadable: return .unreadable
        case .noLimits: return .noLimits
        }
    }

    enum Status: Equatable {
        /// No file: the line was never added, or Claude Code hasn't rendered a statusline since.
        case notSetUp
        case live(since: Date)
        /// Older than `maxAge`, or dated in the future. Normal whenever Claude Code is closed.
        case idle(since: Date)
        /// Fresh but not JSON. What a missing `jq` produces: the shell creates the file for the
        /// redirect before `jq` fails to run, so it is rewritten empty on every render.
        case unreadable
        /// Fresh JSON with no usable window — an account without plan limits, or a session that
        /// hasn't heard back from the API yet.
        case noLimits

        /// Phrased as a feature being on or off. "Live · updated just now" sat directly under the
        /// refresh settings and read as one more note about polling, which left the setup command
        /// beneath it looking unexplained.
        func label(now: Date = Date()) -> String {
            switch self {
            case .notSetUp: return "Off"
            case .live(let since): return "On · updated \(Fmt.age(of: since, from: now))"
            case .idle(let since) where since > now: return "On · waiting for Claude Code"
            case .idle(let since): return "On · last reading \(Fmt.age(of: since, from: now))"
            case .unreadable: return "Not working — is jq installed?"
            case .noLimits: return "On · no plan limits reported"
            }
        }

        /// Whether the menu offers setup. Only where it could help: once readings arrive — live, idle,
        /// or carrying no limits because of the plan — the snippet is already doing its job, and a
        /// standing command to copy it again is exactly what looked unexplained.
        var offersSetup: Bool {
            switch self {
            case .notSetUp, .unreadable: return true
            case .live, .idle, .noLimits: return false
            }
        }
    }

    /// Menu and dialog copy, kept here rather than in `MenuController`, which stays free of
    /// Claude-specific strings.
    /// Inside the Claude Code section, which has already said so.
    static let menuHeading = "LIVE UPDATES"
    static let setupMenuTitle = "Set Up Live Updates…"
    static let setupDialogTitle = "Live updates from Claude Code"
    static let setupDialogMessage = """
        Cashew checks your usage every few minutes. While you're using Claude Code, it can update \
        live instead — Claude Code already passes your usage to its statusline, and one line in your \
        statusline script hands it to Cashew.

        Add the line below to your statusline script, right after the line that reads its input. It \
        needs jq, which macOS 15 and later include.

        No statusline yet? Cashew's docs have a complete starter script.
        """
    static let setupCopyButton = "Copy Snippet"

    /// The one line a user adds to their statusline script. `docs/LIVE-UPDATES.md` quotes it
    /// verbatim, and a test holds the two together — a copy that drifted from the docs would be the
    /// worse of both.
    static let setupCommand = """
        { mkdir -p "$HOME/Library/Application Support/com.vickipetrova.cashew" \\
          && printf '%s' "$input" | jq -c '{rate_limits}' \\
             > "$HOME/Library/Application Support/com.vickipetrova.cashew/statusline.json"; } 2>/dev/null || true
        """

    /// What Copy Snippet puts on the clipboard: the command, with enough comment around it to
    /// still make sense when it is pasted somewhere an hour later.
    ///
    /// The URL is pasted into the user's own statusline script and stays there indefinitely, so it
    /// has to point somewhere that will not move. A README anchor was the wrong choice — README
    /// sections get reordered and renamed, and this link cannot be corrected once it is on someone
    /// else's disk. A file path can only break if the file is deleted, and `theSnippetLinksToAPage`
    /// fails the build if it is.
    static let setupSnippet = """
        # Cashew: live plan usage in the menu bar. Goes in your Claude Code statusline script,
        # right after `input=$(cat)`. No statusline yet? See
        # https://github.com/vickipetrova/cashew/blob/main/docs/LIVE-UPDATES.md
        \(setupCommand)

        """

    private enum Loaded {
        case notSetUp
        case live([LimitWindow], written: Date)
        case idle(Date)
        case unreadable
        case noLimits
    }

    private func load(now: Date) -> Loaded {
        guard let written = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date else { return .notSetUp }
        // The payload carries no timestamp of its own, so the file's mtime is the only answer to
        // "how old is this" — and it is the honest one, since the script rewrites on every render.
        guard now.timeIntervalSince(written) <= Self.maxAge, written <= now else { return .idle(written) }

        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }

        let windows = Self.windows(in: object)
        return windows.isEmpty ? .noLimits : .live(windows, written: written)
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
