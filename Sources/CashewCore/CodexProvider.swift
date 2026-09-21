import Foundation

/// Codex usage, read from the endpoint the Codex CLI itself uses.
///
/// Undocumented and community-discovered, exactly like Claude's, so hard rule 3 applies in full:
/// every field is optional and every type a guess, and a field that is missing, null or the wrong
/// type drops that one row rather than the response.
struct CodexProvider: UsageProvider {
    let id: ProviderID = .codex

    static let host = "chatgpt.com"

    /// The endpoint's own host, so a test can hold it against `host` and catch a URL edited in
    /// isolation.
    static var endpointHost: String { endpoint.host ?? "" }

    /// Injected for the same reason `ClaudeProvider`'s is: the real probe reads the user's actual
    /// login, so the discovery *logic* has to be testable without one.
    private let presence: () -> Bool

    init(presence: @escaping () -> Bool = CodexCredentials.fileExists) {
        self.presence = presence
    }

    func credentialsExist() -> Bool { presence() }

    /// `backend-api/codex/usage`. `backend-api/wham/usage` returns a byte-identical body and is not
    /// used — one path, so there is one thing to re-probe when it drifts. The `api/codex/usage`
    /// form that appears in the CLI binary's string table 404s; reading endpoints out of a binary
    /// is also how this design nearly acquired a `window_minutes` field that does not exist.
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    private static let redirectPolicy = RefuseRedirects()

    /// Ephemeral for the same reasons as Claude's: no on-disk cache of usage responses, and no
    /// chance of serving a stale one. Cookies are nil rather than in-memory — the endpoint sets
    /// none today, and this way nothing changes if it starts.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Never called from a test — real network, real token. CI greps for it.
    func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void) {
        // No serial queue here, unlike Claude: reading a file cannot put a modal prompt on screen,
        // so there is nothing to keep off the main thread and nothing to stop stacking up.
        guard let token = CodexCredentials.read() else {
            return completion(.failure(UsageError.noCredentials))
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(token.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.session.dataTask(with: request) { data, response, error in
            completion(Self.result(data: data, response: response, error: error))
        }.resume()
    }

    /// Everything between the socket and the parser, pure so it is testable without a network.
    static func result(data: Data?, response: URLResponse?, error: Error?)
        -> Result<[LimitWindow], Error> {
        if let error { return .failure(UsageError.network(error)) }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failure(UsageError.badResponse)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { return .failure(UsageError.unauthorized) }
            if http.statusCode == 429 {
                return .failure(UsageError.rateLimited(retryAfter: ClaudeProvider.retryAfter(in: http)))
            }
            return .failure(UsageError.http(http.statusCode))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(UsageError.badResponse)
        }
        return .success(windows(in: object))
    }

    // MARK: - Parsing

    static func windows(in object: [String: Any]) -> [LimitWindow] {
        guard let limits = object["rate_limit"] as? [String: Any] else { return [] }
        return [window(limits["primary_window"], kind: .primary, id: "primary"),
                window(limits["secondary_window"], kind: .secondary, id: "secondary")]
            .compactMap { $0 }
    }

    private static func window(_ any: Any?, kind: LimitWindow.Kind, id: String) -> LimitWindow? {
        // `secondary_window: null` is the free plan's every response, not a fault.
        //
        // A missing or unreadable `limit_window_seconds` drops the whole row here, where a missing
        // *reset* (below, in `resetDate`) keeps it and reports "reset time unknown" instead. That
        // asymmetry is deliberate, not an oversight: a window with no length isn't a window — there
        // is nothing to label or to measure the percentage against — while a window with a real
        // percentage and no reset time is still a genuine reading worth showing.
        guard let entry = any as? [String: Any],
              let utilization = UsageJSON.number(entry["used_percent"]),
              let seconds = duration(entry["limit_window_seconds"])
        else { return nil }
        let label = windowLabel(seconds: seconds)
        return LimitWindow(kind: kind, id: id,
                           label: "CODEX · \(label)",
                           shortLabel: "Codex \(label.lowercased())",
                           optionLabel: "Codex (\(label.lowercased()))",
                           utilization: utilization,
                           resetsAt: resetDate(entry))
    }

    /// `reset_at` is epoch **seconds**, where Claude's `expiresAt` is milliseconds — two vendors,
    /// two units, and both are bare numbers that parse happily at the wrong scale. `UsageJSON.date`
    /// bounds it to roughly 1970±200 years, so a wild value drops the field instead of overflowing
    /// the `Int` conversion in `Fmt.countdown`.
    ///
    /// Falls back to `reset_after_seconds` from now: a row with a percentage and no reset time is
    /// still worth showing, and `UsageRow` says "reset time unknown" rather than pretending.
    private static func resetDate(_ entry: [String: Any], now: Date = Date()) -> Date? {
        if let at = UsageJSON.date(entry["reset_at"]) { return at }
        guard let after = duration(entry["reset_after_seconds"]) else { return nil }
        return now.addingTimeInterval(after)
    }

    /// `limit_window_seconds` and `reset_after_seconds` are durations, not percentages —
    /// `UsageJSON.number`'s 0–100 clamp exists for `used_percent` alone, and reusing it here would
    /// silently turn a real window length (18,000, 604,800, 2,592,000) or countdown into noise.
    /// Built on `UsageJSON.rawNumber`, which carries the same boolean and finiteness guards without
    /// the clamp, so there is exactly one place that could forget the boolean bridge.
    private static func duration(_ any: Any?) -> Double? {
        guard let value = UsageJSON.rawNumber(any), value > 0 else { return nil }
        return value
    }

    /// The heading text, derived from the window the server reported rather than hardcoded.
    ///
    /// Claude gets away with a literal "WEEKLY" because its cadence is fixed. Codex's is not: a free
    /// plan's primary window is 30 days and a paid plan's is hours, in the same field, so a
    /// hardcoded label would be wrong for half the users.
    static func windowLabel(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "WINDOW" }
        if seconds == 7 * 86_400 { return "WEEKLY" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded()))-HOUR" }
        return "\(Int((seconds / 86_400).rounded()))-DAY"
    }
}
