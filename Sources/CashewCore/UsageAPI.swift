import Foundation
import CashewShared

// MARK: - Provider-neutral model

/// Which product a set of usage windows came from.
///
/// `String`-backed and stable: these raw values are written into `UserDefaults` keys and into
/// `history.json`, so renaming one silently orphans a user's alert markers and forecast history.
enum ProviderID: String, Codable, CaseIterable {
    case claude
    case codex

    /// A window id made unique across providers, for storage keys only.
    ///
    /// Both providers call their short window something like "session", so an unqualified id would
    /// make Claude's and Codex's short windows share a notification marker, a history series and a
    /// title-selection entry.
    ///
    /// Never parsed back apart. A scoped id already contains a colon (`scoped:Opus`), so splitting
    /// on the separator would be wrong the moment anyone tried it — the qualified form is an opaque
    /// key, and the provider is always known from context where it matters.
    func qualify(_ windowID: String) -> String { "\(rawValue):\(windowID)" }

    /// The dropdown's section heading. Lives here rather than in `MenuController`, which is not
    /// allowed to hold a vendor's copy — the same rule that keeps `optionLabel` on `LimitWindow`.
    var sectionHeading: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        }
    }
}

/// One rate-limit window, described in terms no single vendor owns.
///
/// `label` is whatever the provider wants shown as that window's heading, so a future provider
/// can say "TODAY" or "THIS MONTH" without MenuController learning anything about it.
/// `Codable` so the last good reading survives a restart — see `UsageHistory.snapshot`. The encoded
/// form is Cashew's own file, never anything sent anywhere, so the field names are free to change
/// with the type; a snapshot that no longer decodes is simply discarded.
struct LimitWindow: Equatable, Codable {
    /// Backed by `String` rather than the default integer ordinal, so reordering these cases can't
    /// silently reinterpret an already-written snapshot.
    ///
    /// These name a window's **rank within its provider**, not how long it lasts. That distinction is
    /// load-bearing: Codex reports a 30-day primary window on a free plan and a short one on a paid
    /// plan, in the same field, so a kind derived from duration would change when a user upgrades —
    /// taking the window's id with it, resetting the title selection, orphaning its forecast history
    /// and re-firing its threshold alerts for a limit that did not change.
    enum Kind: String, Equatable, Codable {
        /// The short rolling window (Claude Code: 5 hours; Codex: whatever `primary_window` reports).
        case primary
        /// The long window, across everything.
        case secondary
        /// The long window, narrowed to one model. A provider may report several.
        case secondaryScoped
    }

    static let sessionID = "session"
    static let weeklyID = "weekly"
    static func scopedID(model: String) -> String { "scoped:\(model)" }

    let kind: Kind

    /// Stable identity — `"session"`, `"weekly"`, `"scoped:Opus"` — and the only thing that should
    /// ever be used to recognise "the same window" across polls.
    ///
    /// Separate from `label` on purpose. Identity used to *be* the display string, which meant
    /// restyling a heading silently changed which alerts counted as already-sent, and a model
    /// renamed by the vendor mid-period produced a duplicate alert. (The obvious fix,
    /// `scope.model.id`, isn't available: that field is null in the real response.)
    let id: String

    /// Display heading for the dropdown. Free to restyle — nothing keys off it.
    let label: String
    /// Sentence-case form for notifications, e.g. "This week".
    let shortLabel: String

    /// How this window is offered in the Show in Menu Bar list, e.g. "Session (5h)" or "Fable".
    ///
    /// Supplied by the provider like every other piece of display copy. "5h" is Claude's session
    /// length, not the app's — a provider whose short window is an hour would otherwise get a
    /// settings row that lies, and `MenuController` would be holding a vendor's fact, which is
    /// exactly what it is not allowed to do.
    let optionLabel: String
    /// Percent of the window consumed, 0–100.
    let utilization: Double
    let resetsAt: Date?
}

/// A source of usage windows.
///
/// The protocol exists so a second provider is a new file rather than a change to `MenuController`,
/// which renders `[LimitWindow]` and knows nothing about where they came from.
protocol UsageProvider {
    /// Identity, for storage keys and for which section this provider's windows render in.
    var id: ProviderID { get }

    /// The single host this provider may contact.
    ///
    /// Declared rather than merely used, so the promise in `CLAUDE.md` hard rule 5 — one usage
    /// endpoint per detected provider, and nothing else — is legible from the type instead of
    /// having to be rediscovered by reading every URL in the file.
    static var host: String { get }

    /// Whether this provider has credentials at all. Must be cheap, must not hit the network, and
    /// must not be able to raise a Keychain prompt: it runs on every launch, for every provider.
    func credentialsExist() -> Bool

    func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void)
}

/// Which of the numbers still on screen are worth showing.
///
/// Cashew keeps the last good reading when a poll fails, which is right for the minutes-long
/// outages it was written for and wrong for the fifteen-day one that actually happened: the menu sat
/// there reporting `0% used · reset time unknown` on three rows, as though it were data.
///
/// Nothing here dims or annotates. A reading that no longer describes anything is removed, and the
/// panel falls back to saying only what went wrong — which is the honest answer when there is
/// nothing current to report.
enum Freshness {
    /// The longest window Cashew tracks is a week and the shortest is five hours, so a reading a
    /// full day old cannot describe the session window at all and is well adrift on the weekly one.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func displayable(_ windows: [LimitWindow], updatedAt: Date?, now: Date) -> [LimitWindow] {
        // No timestamp means no way to judge, and hiding data on a guess is worse than showing it.
        guard let updatedAt else { return windows }
        // The case that bit: `resetsAt` was nil on every row, so the per-window rule below could
        // never fire and the numbers stayed forever.
        guard now.timeIntervalSince(updatedAt) <= maxAge else { return [] }
        // A window whose reset has passed describes a period that has ended. In healthy operation the
        // next poll replaces it within minutes; it is only visible when polls are failing, which is
        // exactly when it is misleading.
        return windows.filter { $0.resetsAt.map { $0 > now } ?? true }
    }
}

/// One provider's current state: its windows, when they were read, and how its last poll failed.
///
/// The unit of state is the provider rather than the window because providers fail independently.
/// A flat `[LimitWindow]` carries one `updatedAt` and one error, so with two providers it must call
/// both stale or neither, and one provider's 429 would stall the other — the exact failure
/// `Backoff` and `reschedulePoll` exist to prevent.
struct ProviderSnapshot {
    let provider: ProviderID
    let windows: [LimitWindow]
    /// When `windows` were read. Nil before the first successful poll.
    let updatedAt: Date?
    /// This provider's own last failure, kept so its section can say what went wrong while another
    /// provider's section goes on showing numbers.
    let failure: Error?

    /// True while `windows` are the last good reading read back off disk and no poll in *this*
    /// process has confirmed them.
    ///
    /// The distinction has to be carried on the snapshot because the state it describes outlives the
    /// call that created it: a restored reading sits in `AppDelegate.snapshots` being re-published
    /// by the 60-second tick, which publishes on the default `recording: true`. Without this flag
    /// that tick would re-record samples that are already in `history.json` — inventing a flat
    /// stretch that never happened and dragging every burn rate towards idle — and would hand
    /// `Notifier.evaluate` a reading no poll produced, which can fire a threshold alert off a file.
    ///
    /// Cleared by the first real success. Deliberately *not* cleared by `failed`: a failed poll
    /// confirms nothing, and it is precisely the failing launch that keeps these numbers on screen.
    let restored: Bool

    /// Spelled out rather than synthesized so `restored` can default to false — a snapshot built
    /// from a poll is the normal case and should not have to say so at every call site.
    init(provider: ProviderID, windows: [LimitWindow], updatedAt: Date?, failure: Error?,
         restored: Bool = false) {
        self.provider = provider
        self.windows = windows
        self.updatedAt = updatedAt
        self.failure = failure
        self.restored = restored
    }

    /// What is worth putting on screen for this provider, by the one `Freshness` rule.
    func displayable(now: Date = Date()) -> [LimitWindow] {
        Freshness.displayable(windows, updatedAt: updatedAt, now: now)
    }

    /// Which of these windows this process actually observed, and may therefore record as samples,
    /// evaluate for alerts, and write back as the last good reading.
    ///
    /// For a polled snapshot that is all of them. For a restored one it is none of its own — those
    /// rows were recorded when they were polled, by whichever run polled them — and only whatever
    /// the live overlay just contributed. That split is what keeps the restore honest without
    /// silencing the live feed: `StatuslineFeed` is rewritten every time Claude Code renders, so
    /// during an outage it is the one genuinely new reading there is, and suppressing it too would
    /// stop the forecast and the threshold alerts for as long as the failure lasts.
    ///
    /// - Parameter live: the overlay that was merged into `windows`, or empty if none was.
    func observed(live: [LimitWindow] = []) -> [LimitWindow] {
        restored ? live : windows
    }

    /// The same snapshot with a fresh reading. Failure is cleared — a success supersedes it — and so
    /// is `restored`: a poll has now confirmed these numbers.
    func succeeded(windows: [LimitWindow], at now: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, updatedAt: now, failure: nil)
    }

    /// The same snapshot with a failure recorded. Windows and `updatedAt` are deliberately kept:
    /// a dead network should not blank numbers that were true a few minutes ago, and `Freshness`
    /// is what eventually removes them.
    func failed(_ error: Error) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, updatedAt: updatedAt, failure: error,
                         restored: restored)
    }
}

enum UsageError: LocalizedError {
    case noCredentials
    case credentialsAccessDenied
    case unauthorized
    /// 429, kept separate from `http` because it is the one status that carries an instruction:
    /// stop asking so often. `retryAfter` is the server's own answer to "how long", when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code login found. Open Claude Code once to sign in."
        case .credentialsAccessDenied:
            return "Can't read your Claude Code login — allow Cashew access when macOS asks."
        case .unauthorized:
            return "Token expired — open a Claude Code session to refresh it."
        case .rateLimited:
            // Deliberately not "HTTP 429": this is the one error a user can act on by doing nothing,
            // and the old copy read as a fault to be fixed rather than a wait to be sat out.
            return "Too many requests — Cashew is asking less often until this clears."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .network:
            return "Can't reach api.anthropic.com."
        case .badResponse:
            return "Couldn't read the usage response."
        }
    }
}

/// How long to wait before asking again after being told to slow down.
///
/// Pure so the schedule is testable — the alternative is a fifteen-day experiment, which is exactly
/// how the absence of this was discovered.
enum Backoff {
    /// Never wait longer than this, even if the server asks for more. A header saying "come back
    /// tomorrow" would otherwise leave the menu bar dead for a day with no way out but a restart.
    static let ceiling: TimeInterval = 60 * 60

    /// `attempt` counts consecutive rate-limited replies, starting at 1.
    ///
    /// The server's own `Retry-After` wins when it gave one — it knows when the window clears and we
    /// are only guessing. Otherwise the interval doubles from the poll interval, so a user on the
    /// 1-minute setting stops making 60 requests an hour into an endpoint that is refusing.
    static func delay(attempt: Int, retryAfter: TimeInterval?, base: TimeInterval) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return min(retryAfter, ceiling)
        }
        // `pow` on a large attempt overflows to infinity rather than trapping, and `min` would then
        // return the ceiling anyway — but the exponent is clamped so the intent doesn't rely on that.
        let doublings = pow(2.0, Double(min(max(attempt, 1), 16)))
        return min(base * doublings, ceiling)
    }
}

/// Which providers to poll. Pure, because this rule silently went wrong once already: it lived only
/// in AppDelegate, which no test can build.
enum PollPlan {
    /// The providers worth polling. When none has credentials, Claude is polled anyway so its
    /// own sign-in copy has somewhere to render — an empty menu explains nothing.
    static func providersToPoll(active: [ProviderID], all: [ProviderID]) -> [ProviderID] {
        active.isEmpty ? all.filter { $0 == .claude } : active
    }
}

// MARK: - Claude

/// The JSON guards every provider needs, in one place.
///
/// Shared rather than duplicated because each one exists for a bug that has already happened, and a
/// second copy is a second place to forget one: `{"percent": true}` reading as 1% because JSON
/// booleans bridge to `NSNumber`; `Fmt.pct` trapping on a non-finite value it converts with `Int`;
/// and a wild timestamp overflowing the `Int` conversion in `Fmt.countdown`.
enum UsageJSON {
    /// `percent` and `utilization` have both been seen as Int and as Double.
    ///
    /// The finite check and the clamp are not paranoia: `Fmt.pct` does `Int(value.rounded())`, and
    /// converting a Double to Int traps on NaN, infinity, or anything past Int's range. A single
    /// `{"percent": 1e30}` — or `1e999`, which JSON parses to +infinity — would crash the menu bar
    /// rather than dropping a row.
    static func number(_ any: Any?) -> Double? {
        // See `isJSONBoolean`: without this, `{"percent": true}` reads as 1%.
        guard let any, !isJSONBoolean(any) else { return nil }
        let value: Double
        if let double = any as? Double { value = double }
        else if let int = any as? Int { value = Double(int) }
        else { return nil }
        guard value.isFinite else { return nil }
        // Clamped rather than rejected: a plan reporting 105% is over its limit, and saying "100%"
        // is far more useful than dropping the row exactly when it matters most.
        return min(max(value, 0), 100)
    }

    /// Timestamps outside this range are junk, and a wild one would overflow the `Int` conversion in
    /// `Fmt.countdown`. Roughly 1970±200 years.
    private static let plausibleEpochRange = -6_311_433_600.0...6_311_433_600.0

    /// Accepts epoch seconds as a number, or ISO8601 with or without fractional seconds.
    /// Codex sends the former, Claude the latter — and the same wrong-scale hazard applies to both.
    static func date(_ any: Any?) -> Date? {
        // See `isJSONBoolean`: without this, `{"resets_at": false}` parses as 1 January 1970.
        guard let any, !isJSONBoolean(any) else { return nil }
        if let seconds = any as? Double {
            guard seconds.isFinite, plausibleEpochRange.contains(seconds) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = any as? String else { return nil }
        // Timestamps currently arrive as "2026-08-02T16:39:59.408408+00:00". The fractional-seconds
        // parser is required for those and returns nil without them, so both are needed.
        return fractionalISO.date(from: string) ?? plainISO.date(from: string)
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct ClaudeProvider: UsageProvider {
    let id: ProviderID = .claude

    static let host = "api.anthropic.com"

    /// The endpoint's own host, so a test can hold it against `host` and catch a URL edited in
    /// isolation. Internal rather than private purely for that check.
    static var endpointHost: String { endpoint.host ?? "" }

    /// Injected so the discovery *logic* is testable while the real probe stays out of tests — the
    /// same seam, and the same reason, as `Credentials.token(in:)`. The default reads the real
    /// login; a test passes its own answer.
    private let presence: () -> Bool

    init(presence: @escaping () -> Bool = Credentials.loginExists) {
        self.presence = presence
    }

    func credentialsExist() -> Bool { presence() }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let redirectPolicy = RefuseRedirects()

    /// Ephemeral: no on-disk cache of usage responses, and no chance of serving a stale one.
    /// `httpCookieStorage` is nil rather than merely in-memory, matching the update check — the
    /// endpoint sets no cookie today, and this way nothing changes if it starts.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Serialized and off the caller's thread on purpose. Reading the Keychain can put a modal
    /// permission dialog on screen, and every caller of `refresh()` is the main thread — so doing it
    /// inline would freeze the menu bar until the user answered. Serial also stops the poll timer and
    /// the wake notification from stacking two dialogs on top of each other.
    private static let credentialQueue = DispatchQueue(label: "com.vickipetrova.cashew.credentials")

    func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void) {
        Self.credentialQueue.async {
            switch Credentials.accessToken() {
            case .failure(let failure):
                completion(.failure(failure == .accessDenied
                    ? UsageError.credentialsAccessDenied
                    : UsageError.noCredentials))
            case .success(let token):
                Self.send(token: token, completion: completion)
            }
        }
    }

    private static func send(token: String,
                             completion: @escaping (Result<[LimitWindow], Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            completion(result(data: data, response: response, error: error))
        }.resume()
    }

    /// Everything between the socket and the parser, as a pure function so it can be tested without
    /// a network — the same reason `windows(in:)` is separate. This is the second-likeliest place for
    /// the endpoint to drift (a new status code, an `{"error": …}` envelope), and it used to be
    /// unreachable by any test because it lived inside the `dataTask` closure.
    static func result(data: Data?, response: URLResponse?, error: Error?)
        -> Result<[LimitWindow], Error> {
        if let error { return .failure(UsageError.network(error)) }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failure(UsageError.badResponse)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { return .failure(UsageError.unauthorized) }
            if http.statusCode == 429 {
                return .failure(UsageError.rateLimited(retryAfter: retryAfter(in: http)))
            }
            return .failure(UsageError.http(http.statusCode))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Covers a JSON array root and anything that isn't JSON at all.
            return .failure(UsageError.badResponse)
        }
        return .success(windows(in: object))
    }

    /// `Retry-After`, in seconds from now.
    ///
    /// RFC 9110 allows two forms and servers use both: a delta in seconds, or an HTTP date. Parsed
    /// defensively like everything else here — an unreadable header is simply no header, and the
    /// caller falls back to doubling. A date already in the past yields nil rather than a negative
    /// wait, which would otherwise schedule the retry immediately and defeat the whole mechanism.
    static func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        if let seconds = TimeInterval(raw) {
            return seconds > 0 ? seconds : nil
        }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        let seconds = date.timeIntervalSinceNow
        return seconds > 0 ? seconds : nil
    }

    /// RFC 9110's preferred date format. Fixed locale and timezone: the parse must not follow the
    /// user's region, or a Mac set to a non-Gregorian calendar fails to read a valid header.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    // MARK: - Parsing
    //
    // This endpoint is undocumented and community-discovered: it has already grown a second,
    // richer shape alongside the original one, and it will drift again. Every field here is
    // treated as optional and every type as a guess. A field that is missing, null, or the wrong
    // type drops that one row — it never throws and never crashes.

    static func windows(in object: [String: Any]) -> [LimitWindow] {
        var session: LimitWindow?
        var weekly: LimitWindow?
        var scoped: [LimitWindow] = []

        // Preferred shape: a `limits` array, which generalizes the old Opus-specific weekly key
        // into `weekly_scoped` entries that name their own model.
        //
        // Cast to [Any] and filter, not to [[String: Any]]. A conditional cast to an array of a
        // concrete element type checks every element and yields nil if a single one fails — so one
        // unrecognized entry would discard the whole array rather than itself, which is exactly the
        // "drops that row" rule inverted. Adding one entry shape is the most likely way this endpoint
        // drifts next.
        let limits = (object["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for entry in limits {
            guard let kind = entry["kind"] as? String,
                  let utilization = UsageJSON.number(entry["percent"])
            else { continue }
            let resetsAt = UsageJSON.date(entry["resets_at"])

            switch kind {
            case "session":
                session = sessionWindow(utilization: utilization, resetsAt: resetsAt)
            case "weekly_all":
                weekly = weeklyWindow(utilization: utilization, resetsAt: resetsAt)
            case "weekly_scoped":
                let scope = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                scoped.append(scopedWindow(model: modelName(scope?["display_name"]),
                                           utilization: utilization, resetsAt: resetsAt))
            default:
                continue  // A kind we don't know yet. Ignoring it beats guessing at a label.
            }
        }

        // Original shape, still returned alongside the array. Used to fill anything the array
        // didn't provide, so a rename on either side degrades to a missing row rather than a
        // blank app.
        if session == nil, let legacy = legacyWindow(object["five_hour"]) {
            session = sessionWindow(utilization: legacy.utilization, resetsAt: legacy.resetsAt)
        }
        if weekly == nil, let legacy = legacyWindow(object["seven_day"]) {
            weekly = weeklyWindow(utilization: legacy.utilization, resetsAt: legacy.resetsAt)
        }
        if scoped.isEmpty, let legacy = legacyWindow(object["seven_day_opus"]) {
            scoped.append(scopedWindow(model: "Opus",
                                       utilization: legacy.utilization, resetsAt: legacy.resetsAt))
        }

        // `id` is what the menu matches rows on and what alert markers are keyed on, so it has to be
        // unique — and it is derived from a server-controlled model name. Two scoped entries sharing
        // a display name would otherwise collapse: both rows would render the first one's numbers,
        // and their alerts would share a marker.
        return [session, weekly].compactMap { $0 } + uniquelyIdentified(scoped)
    }

    private static func uniquelyIdentified(_ windows: [LimitWindow]) -> [LimitWindow] {
        var taken: Set<String> = []
        return windows.map { window in
            // Loops rather than counting occurrences: a suffix can itself collide, because a model
            // could genuinely be named "Opus#2" and the generated id for a second "Opus" is exactly
            // that. Counting alone would emit the duplicate this pass exists to prevent.
            var id = window.id
            var suffix = 1
            while !taken.insert(id).inserted {
                suffix += 1
                id = "\(window.id)#\(suffix)"
            }
            guard id != window.id else { return window }
            return LimitWindow(kind: window.kind, id: id,
                               label: window.label, shortLabel: window.shortLabel,
                               optionLabel: window.optionLabel,
                               utilization: window.utilization, resetsAt: window.resetsAt)
        }
    }

    // One builder per window kind, so the array branch and the legacy branch can't drift apart in
    // how they label the same window.

    static func sessionWindow(utilization: Double, resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .primary, id: LimitWindow.sessionID,
                    label: "SESSION · 5-HOUR", shortLabel: "Session", optionLabel: "Session (5h)",
                    utilization: utilization, resetsAt: resetsAt)
    }

    static func weeklyWindow(utilization: Double, resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .secondary, id: LimitWindow.weeklyID,
                    label: "WEEKLY · ALL MODELS", shortLabel: "Weekly",
                    optionLabel: "Weekly (all models)",
                    utilization: utilization, resetsAt: resetsAt)
    }

    private static func scopedWindow(model: String, utilization: Double,
                                     resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .secondaryScoped, id: LimitWindow.scopedID(model: model),
                    label: "WEEKLY · \(model.uppercased())",
                    shortLabel: "Weekly (\(model))",
                    optionLabel: model,
                    utilization: utilization, resetsAt: resetsAt)
    }

    /// The model name is server-controlled and ends up in a menu label, a notification title, and a
    /// `UserDefaults` key, so it is bounded here rather than trusted. An empty name used to render
    /// "THIS WEEK ()".
    private static let modelNameLimit = 64

    private static func modelName(_ any: Any?) -> String {
        guard let raw = any as? String else { return "scoped" }
        // Strips control characters, not just newlines: this string reaches a menu label, a
        // notification title and a UserDefaults key, and bidi overrides like U+202E can reorder the
        // text around it.
        let cleaned = raw
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "scoped" }
        return String(cleaned.prefix(modelNameLimit))
    }

    private static func legacyWindow(_ any: Any?) -> (utilization: Double, resetsAt: Date?)? {
        guard let dict = any as? [String: Any],
              let utilization = UsageJSON.number(dict["utilization"])
        else { return nil }
        return (utilization, UsageJSON.date(dict["resets_at"]))
    }

}
