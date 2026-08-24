import Foundation

// MARK: - Provider-neutral model

/// One rate-limit window, described in terms no single vendor owns.
///
/// `label` is whatever the provider wants shown as that window's heading, so a future provider
/// can say "TODAY" or "THIS MONTH" without MenuController learning anything about it.
/// `Codable` so the last good reading survives a restart — see `UsageHistory.snapshot`. The encoded
/// form is Headroom's own file, never anything sent anywhere, so the field names are free to change
/// with the type; a snapshot that no longer decodes is simply discarded.
struct LimitWindow: Equatable, Codable {
    /// Backed by `String` rather than the default integer ordinal, so reordering these cases can't
    /// silently reinterpret an already-written snapshot.
    enum Kind: String, Equatable, Codable {
        /// The short rolling window (Claude Code: 5 hours).
        case session
        /// The long window, across everything.
        case weekly
        /// The long window, narrowed to one model. A provider may report several.
        case weeklyScoped
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

/// A source of usage windows. `ClaudeProvider` is the only implementation in v0.1; the protocol
/// exists so Cursor/Codex/Copilot providers can be added without MenuController changing.
protocol UsageProvider {
    func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void)
}

/// `JSONSerialization` turns `true`/`false` into `NSNumber`s, and `NSNumber as? Double` happily
/// yields 1.0 and 0.0 — so a boolean sails through any numeric parse unless it is rejected first.
/// Comparing the CoreFoundation type id is the only reliable discriminator: `as? Bool` is no good,
/// because `NSNumber(42) as? Bool` also succeeds. Shared by the usage parser and `Credentials`.
func isJSONBoolean(_ any: Any) -> Bool {
    CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID()
}

enum UsageError: LocalizedError {
    case noCredentials
    case credentialsAccessDenied
    case unauthorized
    case http(Int)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code login found. Open Claude Code once to sign in."
        case .credentialsAccessDenied:
            return "Can't read your Claude Code login — allow Headroom access when macOS asks."
        case .unauthorized:
            return "Token expired — open a Claude Code session to refresh it."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .network:
            return "Can't reach api.anthropic.com."
        case .badResponse:
            return "Couldn't read the usage response."
        }
    }
}

// MARK: - Claude

struct ClaudeProvider: UsageProvider {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Refuses every redirect, so the bearer token can only ever be sent to the one host in
    /// `endpoint`. SECURITY.md promises exactly one network destination; without this that promise
    /// rests on CFNetwork's uncontracted behaviour for `Authorization` across a cross-host hop, for
    /// an endpoint we already expect to drift. A 3xx now surfaces as an ordinary `UsageError.http`.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let redirectPolicy = RefuseRedirects()

    /// Ephemeral: no on-disk cache of usage responses, and no chance of serving a stale one.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Serialized and off the caller's thread on purpose. Reading the Keychain can put a modal
    /// permission dialog on screen, and every caller of `refresh()` is the main thread — so doing it
    /// inline would freeze the menu bar until the user answered. Serial also stops the poll timer and
    /// the wake notification from stacking two dialogs on top of each other.
    private static let credentialQueue = DispatchQueue(label: "com.vickipetrova.headroom.credentials")

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
            return .failure(http.statusCode == 401
                ? UsageError.unauthorized
                : UsageError.http(http.statusCode))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Covers a JSON array root and anything that isn't JSON at all.
            return .failure(UsageError.badResponse)
        }
        return .success(windows(in: object))
    }

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
                  let utilization = number(entry["percent"])
            else { continue }
            let resetsAt = date(entry["resets_at"])

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

    private static func sessionWindow(utilization: Double, resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .session, id: LimitWindow.sessionID,
                    label: "SESSION · 5-HOUR", shortLabel: "Session", optionLabel: "Session (5h)",
                    utilization: utilization, resetsAt: resetsAt)
    }

    private static func weeklyWindow(utilization: Double, resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .weekly, id: LimitWindow.weeklyID,
                    label: "WEEKLY · ALL MODELS", shortLabel: "Weekly",
                    optionLabel: "Weekly (all models)",
                    utilization: utilization, resetsAt: resetsAt)
    }

    private static func scopedWindow(model: String, utilization: Double,
                                     resetsAt: Date?) -> LimitWindow {
        LimitWindow(kind: .weeklyScoped, id: LimitWindow.scopedID(model: model),
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
              let utilization = number(dict["utilization"])
        else { return nil }
        return (utilization, date(dict["resets_at"]))
    }

    /// `percent` and `utilization` have both been seen as Int and as Double.
    ///
    /// The finite check and the clamp are not paranoia: `Fmt.pct` does `Int(value.rounded())`, and
    /// converting a Double to Int traps on NaN, infinity, or anything past Int's range. A single
    /// `{"percent": 1e30}` — or `1e999`, which JSON parses to +infinity — would crash the menu bar
    /// rather than dropping a row.
    private static func number(_ any: Any?) -> Double? {
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

    private static func date(_ any: Any?) -> Date? {
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
