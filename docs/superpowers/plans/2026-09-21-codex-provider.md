# Codex Provider (PR 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show OpenAI Codex usage alongside Claude Code, using the per-provider plumbing PR 1 built.

**Architecture:** `CodexCredentials` reads the token `codex login` already wrote to `~/.codex/auth.json` — no Keychain, no OAuth, no writing. `CodexProvider` calls one endpoint and parses it defensively. `TitleSelection` starts returning `(provider, window)` pairs so the menu bar can glyph a window by provider, which also retires a PR 1 deferral. A **Providers** section in Settings hides a detected provider. Codex is wired in last, in the one task that changes what you see.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, AppKit + SwiftUI, swift-testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-21-multi-provider-usage-design.md` — read it, including **Carried into PR 2**, before starting any task.

## Global Constraints

- Zero third-party dependencies. `Package.swift` never gets a `dependencies:` array.
- `swiftLanguageModes: [.v5]` and `platforms: [.macOS(.v13)]` stay exactly as they are.
- Tests use swift-testing (`import Testing`), never XCTest. Run with `swift test --disable-xctest`.
- **Parsing tests feed JSON text through `JSONSerialization`**, never Swift dictionary literals — values must arrive as the `NSNumber`s a real response produces, or the boolean and integer bridging paths go untested.
- **All parsing is defensive** (hard rule 3): a missing, null or wrong-typed field drops that *one* row and renders `–`. Never force-unwrap a parsed field; never throw on an unexpected shape.
- **JSON booleans bridge to `NSNumber`** — check `isJSONBoolean` before reading any number, or `{"used_percent": true}` reads as 1%.
- Never print, log or commit a token. CI greps for this, and it applies to the Codex token exactly as it does to Claude's.
- Never construct `MenuController` or `AppDelegate` in a test — CI greps for it. Pure rules go in free types.
- **`CodexProvider.fetch` joins the never-call-from-a-test grep** — it reaches the real network with a real token.
- `MenuController` holds no vendor copy. Codex strings live on `ProviderID` or on the windows `CodexProvider` builds.
- Cashew **never** writes `~/.codex/`, never runs `codex`, never holds the refresh token, never authenticates.

## Baseline

`main` at `28f91e5`: `swift test --disable-xctest` → **421 tests in 35 suites passed**. Every task ends green, and the count only goes up.

## The response this is built against

Probed live twice against a **free** ChatGPT plan, most recently while writing this plan. Identifiers redacted; everything else verbatim.

`GET https://chatgpt.com/backend-api/codex/usage`
with `Authorization: Bearer <access_token>` and `ChatGPT-Account-Id: <account_id>` → `200`

```json
{
  "plan_type": "free",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 0,
      "limit_window_seconds": 2592000,
      "reset_after_seconds": 2592000,
      "reset_at": 1792615093
    },
    "secondary_window": null
  },
  "credits": { "has_credits": false, "unlimited": false },
  "rate_limit_reached_type": null
}
```

**`secondary_window: null` is the common case on this plan, not an error.** A paid plan is expected to populate it; that shape is unverified, and the fixture standing in for it is labelled as a guess about *values*, not about *shape*.

**`reset_at` is epoch seconds.** Claude's `expiresAt` is milliseconds. Two vendors, two units, one codebase, and both are bare numbers that parse without complaint at the wrong scale — read as milliseconds, `reset_at` lands three weeks after the epoch.

## File Map

| File | Responsibility |
|---|---|
| `Sources/CashewCore/CodexCredentials.swift` | **new** — read `~/.codex/auth.json`; token + account id, or absent |
| `Sources/CashewCore/CodexProvider.swift` | **new** — the endpoint client and all response parsing |
| `Sources/CashewCore/UsageAPI.swift` | `number`/`date` hoisted out of `ClaudeProvider` for both providers; `ProviderID.glyph` |
| `Sources/CashewCore/MenuController.swift` | `TitleSelection` returns pairs; the title glyphs; LIMITS SHOWN keys by provider |
| `Sources/CashewCore/Settings.swift` | `hiddenProviders` |
| `Sources/CashewCore/AppDelegate.swift` | Codex added to `providers` |
| `.github/workflows/build.yml` | `CodexProvider\(\)\.fetch` joins the grep |
| `CLAUDE.md`, `SECURITY.md`, `README.md`, `docs/TROUBLESHOOTING.md` | the second provider, and how to sign in |

---

### Task 1: `CodexCredentials`

**Files:**
- Create: `Sources/CashewCore/CodexCredentials.swift`
- Test: `Tests/CashewCoreTests/CodexCredentialsTests.swift` (new)

**Interfaces:**
- Produces: `enum CodexCredentials` with
  `static func parse(_ data: Data) -> Token?`,
  `struct Token: Equatable { let accessToken: String; let accountID: String }`,
  `static func fileExists() -> Bool`, `static func read() -> Token?`.

**Why this is so much smaller than `Credentials.swift`:** there is exactly one store. No Keychain item exists — seven candidate service names and a full keychain scan for "codex" found nothing — so there is no file-versus-Keychain ranking, no `.accessDenied` latch, and no serial queue guarding a modal prompt. The JWT's `exp` and `chatgpt_plan_type` claims are deliberately **not** parsed: with one credential and nothing to rank it against, an expiry only invents a staleness rule we would then have to keep in step with OpenAI's, and an expired token returns 401, which is the honest signal.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CashewCoreTests/CodexCredentialsTests.swift`:

```swift
import Foundation
import Testing
@testable import CashewCore

@Suite struct CodexCredentialsTests {
    /// The real file's shape, with the token values replaced. Fed as JSON text, like every other
    /// parsing test here, so values arrive as the types `JSONSerialization` really produces.
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func readsTheTokenAndAccountID() throws {
        let token = try #require(CodexCredentials.parse(json("""
        {"auth_mode":"chatgpt",
         "OPENAI_API_KEY":null,
         "tokens":{"id_token":"a.b.c","access_token":"x.y.z","refresh_token":"r","account_id":"acct-1"},
         "last_refresh":"2026-09-21T17:38:49.613648Z"}
        """)))
        #expect(token.accessToken == "x.y.z")
        #expect(token.accountID == "acct-1")
    }

    @Test func anApiKeyLoginHasNoChatgptTokens() {
        // `codex login --with-api-key` writes this shape. A metered API key has no plan quota to
        // report, so there is nothing for Cashew to show and nothing to parse.
        #expect(CodexCredentials.parse(json("""
        {"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":null}
        """)) == nil)
    }

    @Test func aMissingOrEmptyFieldIsNotACredential() {
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"x.y.z"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"account_id":"acct-1"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"","account_id":"a"}}"#)) == nil)
    }

    @Test func aWrongTypedFieldIsNotACredential() {
        // JSON booleans bridge to NSNumber and numbers are not strings; neither may be coerced.
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":true,"account_id":"a"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"x","account_id":7}}"#)) == nil)
    }

    @Test func rubbishIsNotACredential() {
        #expect(CodexCredentials.parse(json("not json at all")) == nil)
        #expect(CodexCredentials.parse(json("[]")) == nil)
        #expect(CodexCredentials.parse(Data()) == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'CodexCredentials' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/CashewCore/CodexCredentials.swift`:

```swift
import Foundation
import CashewShared

/// Finds the token `codex login` already wrote, so Cashew needs no setup of its own.
///
/// The Codex half of the promise `Credentials` makes for Claude Code, and much smaller for one
/// reason: there is exactly one store. Codex keeps nothing in the login Keychain — checked, and
/// nothing matching "codex" exists there — so there is no ranking between stores, no access-denied
/// latch, and no serial queue guarding a modal permission prompt.
///
/// Nothing here logs, prints, caches or persists the token. Cashew never writes this file, never
/// runs `codex`, never holds the refresh token and never authenticates. See the guardrails in
/// CLAUDE.md.
enum CodexCredentials {
    struct Token: Equatable {
        let accessToken: String
        let accountID: String
    }

    private static let path = "~/.codex/auth.json"

    private static var expandedPath: String { (path as NSString).expandingTildeInPath }

    /// Cheap, no network, no prompt — this runs on every launch as part of provider discovery.
    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: expandedPath)
    }

    static func read() -> Token? {
        guard let data = FileManager.default.contents(atPath: expandedPath) else { return nil }
        return parse(data)
    }

    /// Pure, so the whole matrix is testable without a real login — this is the only part of this
    /// file a test may call.
    ///
    /// The `id_token` and `refresh_token` are ignored on purpose, and the access token's JWT claims
    /// are not decoded: `exp` would only invent a staleness rule Cashew would then have to keep in
    /// step with OpenAI's, and an expired token returns 401, which says it plainly. `plan_type`
    /// arrives in the usage response anyway.
    static func parse(_ data: Data) -> Token? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        // `as? String` on an NSNumber correctly fails, and `isJSONBoolean` is not needed here —
        // a bridged boolean is an NSNumber, which is not a String either.
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty
        else { return nil }
        return Token(accessToken: accessToken, accountID: accountID)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **426** tests (421 + 5).

- [ ] **Step 5: Guard the impure entry points**

`.github/workflows/build.yml` — extend the never-call-from-a-test alternation with
`|CodexCredentials\.(read|fileExists)`. Then confirm:

```bash
grep -rnE 'CodexCredentials\.(read|fileExists)' Tests/ || echo "guard clean"
```

- [ ] **Step 6: Commit**

```bash
git add Sources/CashewCore/CodexCredentials.swift Tests/CashewCoreTests/CodexCredentialsTests.swift .github/workflows/build.yml
git commit -m "feat: read the Codex login codex CLI already wrote

One store, so none of Credentials.swift's machinery has an analogue:
no ranking between file and Keychain, no access-denied latch, no serial
queue guarding a modal prompt. Codex keeps nothing in the login Keychain.

The JWT's exp and plan_type claims are deliberately not decoded. With one
credential and nothing to rank it against, an expiry only invents a
staleness rule we would have to keep in step with OpenAI's; an expired
token returns 401, which says it plainly."
```

---

### Task 2: `CodexProvider`

**Files:**
- Create: `Sources/CashewCore/CodexProvider.swift`
- Modify: `Sources/CashewCore/UsageAPI.swift` — hoist `number` and `date` out of `ClaudeProvider`
- Test: `Tests/CashewCoreTests/CodexParsingTests.swift` (new)

**Interfaces:**
- Consumes: `CodexCredentials.Token`, `CodexCredentials.read()`, `CodexCredentials.fileExists()`.
- Produces: `struct CodexProvider: UsageProvider` with `id = .codex`, `static let host = "chatgpt.com"`,
  `init(presence: @escaping () -> Bool = CodexCredentials.fileExists)`,
  `static func windows(in object: [String: Any]) -> [LimitWindow]`,
  `static func result(data:response:error:) -> Result<[LimitWindow], Error>`,
  `static func windowLabel(seconds: Double) -> String`.
- Produces: `enum UsageJSON` with `static func number(_ any: Any?) -> Double?` and
  `static func date(_ any: Any?) -> Date?`, moved verbatim from `ClaudeProvider`.

- [ ] **Step 1: Hoist the shared JSON guards first, and prove nothing moved**

`ClaudeProvider.number` and `ClaudeProvider.date` already carry the boolean guard, the finiteness
check, the 0–100 clamp and the plausible-epoch range. Codex needs all four. Move them, do not copy
them — a second copy is a second place for the `isJSONBoolean` trap to be forgotten.

In `Sources/CashewCore/UsageAPI.swift`, add above `struct ClaudeProvider`:

```swift
/// The JSON guards every provider needs, in one place.
///
/// Shared rather than duplicated because each one exists for a bug that has already happened, and a
/// second copy is a second place to forget one: `{"percent": true}` reading as 1% because JSON
/// booleans bridge to `NSNumber`; `Fmt.pct` trapping on a non-finite value it converts with `Int`;
/// and a wild timestamp overflowing the `Int` conversion in `Fmt.countdown`.
enum UsageJSON {
    /// Percentages have been seen as Int and as Double, from both providers.
    static func number(_ any: Any?) -> Double? { /* body moved verbatim from ClaudeProvider */ }

    /// Accepts epoch seconds as a number, or ISO8601 with or without fractional seconds.
    /// Codex sends the former, Claude the latter — and the same wrong-scale hazard applies to both.
    static func date(_ any: Any?) -> Date? { /* body moved verbatim from ClaudeProvider */ }
}
```

Move the two function bodies and the two private constants they use (`plausibleEpochRange`,
`fractionalISO`, `plainISO`) into `UsageJSON` unchanged, then point `ClaudeProvider` at them:

```bash
grep -rn 'ClaudeProvider\.number\|ClaudeProvider\.date' Sources/ Tests/
```

Update every hit to `UsageJSON.` — inside `ClaudeProvider` the unqualified calls become
`UsageJSON.number(...)` / `UsageJSON.date(...)`.

- [ ] **Step 2: Run the suite to prove the hoist changed nothing**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: **426** tests, unchanged. This is a pure move; any failure means the move was not pure.

- [ ] **Step 3: Write the failing parsing tests**

Create `Tests/CashewCoreTests/CodexParsingTests.swift`:

```swift
import Foundation
import Testing
@testable import CashewCore

@Suite struct CodexParsingTests {
    /// JSON text through JSONSerialization, never a Swift dictionary literal — the bridging traps
    /// only exist for the NSNumbers a real response produces.
    private func parse(_ text: String) -> [LimitWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else { return [] }
        return CodexProvider.windows(in: object)
    }

    /// The live free-plan response, captured 2026-09-21. Identifiers redacted; nothing else edited.
    private let freePlan = """
    {"plan_type":"free",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":0,"limit_window_seconds":2592000,
                         "reset_after_seconds":2592000,"reset_at":1792615093},
       "secondary_window":null},
     "credits":{"has_credits":false,"unlimited":false},
     "rate_limit_reached_type":null}
    """

    @Test func readsTheFreePlansSingleWindow() {
        let windows = parse(freePlan)
        #expect(windows.count == 1)
        #expect(windows[0].kind == .primary)
        #expect(windows[0].id == "primary")
        #expect(windows[0].utilization == 0)
        #expect(windows[0].label == "CODEX · 30-DAY")
        // Epoch SECONDS. Read as milliseconds this lands three weeks after 1970.
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_615_093))
    }

    @Test func aNullSecondaryWindowIsTheCommonCaseNotAnError() {
        // Free plans send `"secondary_window": null` on every request. One row, no complaint.
        #expect(parse(freePlan).map(\.id) == ["primary"])
    }

    /// A guess about VALUES, not about shape: no paid response has been captured. It proves the
    /// parser maps a present secondary_window; it does not prove a paid plan sends one like this.
    @Test func aTwoWindowResponseYieldsBothWindows() {
        let windows = parse("""
        {"plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,
                                         "reset_at":1792615093},
                       "secondary_window":{"used_percent":40,"limit_window_seconds":604800,
                                           "reset_at":1793000000}}}
        """)
        #expect(windows.map(\.kind) == [.primary, .secondary])
        #expect(windows.map(\.id) == ["primary", "secondary"])
        #expect(windows.map(\.label) == ["CODEX · 5-HOUR", "CODEX · WEEKLY"])
        #expect(windows.map(\.utilization) == [12, 40])
    }

    @Test func aBooleanPercentDropsTheRowRatherThanReadingAsOne() {
        // JSON booleans bridge to NSNumber, so `as? Double` on `true` yields 1.0.
        #expect(parse("""
        {"rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":18000}}}
        """).isEmpty)
    }

    @Test func aMissingResetTimeFallsBackToResetAfterSeconds() {
        let windows = parse("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000,
                                         "reset_after_seconds":3600}}}
        """)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt != nil)
    }

    @Test func noResetInformationAtAllStillRendersTheRow() {
        // A row with no reset time is honest — `UsageRow` says "reset time unknown" — and dropping
        // it would hide a real percentage over a missing field.
        let windows = parse(#"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}}"#)
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt == nil)
    }

    @Test func aMissingOrWrongTypedRateLimitYieldsNothing() {
        #expect(parse(#"{"plan_type":"free"}"#).isEmpty)
        #expect(parse(#"{"rate_limit":null}"#).isEmpty)
        #expect(parse(#"{"rate_limit":[]}"#).isEmpty)
        #expect(parse(#"{"rate_limit":{"primary_window":"nope"}}"#).isEmpty)
    }

    @Test func utilizationIsClampedAndFinite() {
        #expect(parse(#"{"rate_limit":{"primary_window":{"used_percent":140,"limit_window_seconds":1}}}"#)
            .map(\.utilization) == [100])
        #expect(parse(#"{"rate_limit":{"primary_window":{"used_percent":1e999,"limit_window_seconds":1}}}"#)
            .isEmpty)
    }

    @Test func labelsComeFromTheReportedWindowLength() {
        // Server-reported and plan-dependent, so it cannot be hardcoded the way Claude's "WEEKLY"
        // is — a free plan's primary window is 30 days where a paid plan's is hours.
        #expect(CodexProvider.windowLabel(seconds: 5 * 3600) == "5-HOUR")
        #expect(CodexProvider.windowLabel(seconds: 7 * 86_400) == "WEEKLY")
        #expect(CodexProvider.windowLabel(seconds: 30 * 86_400) == "30-DAY")
        #expect(CodexProvider.windowLabel(seconds: 0) == "WINDOW")
    }
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'CodexProvider' in scope`

- [ ] **Step 5: Write `CodexProvider`**

Create `Sources/CashewCore/CodexProvider.swift`:

```swift
import Foundation

/// Codex usage, read from the endpoint the Codex CLI itself uses.
///
/// Undocumented and community-discovered, exactly like Claude's, so hard rule 3 applies in full:
/// every field is optional and every type a guess, and a field that is missing, null or the wrong
/// type drops that one row rather than the response.
struct CodexProvider: UsageProvider {
    let id: ProviderID = .codex

    static let host = "chatgpt.com"

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
        var request = URLRequest(url: endpoint)
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
        guard let entry = any as? [String: Any],
              let utilization = UsageJSON.number(entry["used_percent"]),
              let seconds = UsageJSON.number(entry["limit_window_seconds"])
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
        guard let after = UsageJSON.number(entry["reset_after_seconds"]), after > 0 else { return nil }
        return now.addingTimeInterval(after)
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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **435** tests (426 + 9).

- [ ] **Step 7: Guard `fetch`, and hold the declared host to the endpoint**

`.github/workflows/build.yml` — add `|CodexProvider\(\)\.fetch` to the alternation.

Add to `Tests/CashewCoreTests/RefuseRedirectsTests.swift`:

```swift
    @Test func theCodexEndpointOnlyTalksToItsDeclaredHost() {
        #expect(CodexProvider.host == "chatgpt.com")
        #expect(CodexProvider.endpointHost == CodexProvider.host)
    }

    @Test func theCodexSessionRefusesRedirects() {
        // Same reason as the other two: a redirect off the declared host would silently break the
        // one-host-per-provider promise in hard rule 5.
        #expect(CodexProvider.session.delegate is RefuseRedirects)
    }
```

and expose the host in `CodexProvider`, internal purely for that check:

```swift
    /// The endpoint's own host, so a test can hold it against `host` and catch a URL edited in
    /// isolation.
    static var endpointHost: String { endpoint.host ?? "" }
```

- [ ] **Step 8: Run the suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **437** tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/CashewCore/CodexProvider.swift Sources/CashewCore/UsageAPI.swift Tests/ .github/workflows/build.yml
git commit -m "feat: read Codex usage from the endpoint the CLI uses

Built against a live free-plan response: one 30-day primary window and
secondary_window null, which is that plan's every reply rather than a
fault. The two-window fixture is a guess about values, not about shape —
no paid response has been captured, and the test says so.

Two hazards specific to this provider. reset_at is epoch seconds where
Claude's expiresAt is milliseconds, and both are bare numbers that parse
happily at the wrong scale. And the heading cannot be hardcoded: the
window length is server-reported and plan-dependent, so it is derived
from limit_window_seconds.

number() and date() move to a shared UsageJSON rather than being copied.
Each guard in them exists for a bug that already happened, and a second
copy is a second place to forget one."
```

---

### Task 3: `TitleSelection` returns pairs, and the title glyphs by provider

**Files:**
- Modify: `Sources/CashewCore/MenuController.swift` — `TitleSelection.windows`, `titleWindows()`, `renderTitle()`, the LIMITS SHOWN list
- Modify: `Sources/CashewCore/UsageAPI.swift` — `ProviderID.titleGlyph`
- Test: `Tests/CashewCoreTests/UsagePanelTests.swift`

**Interfaces:**
- Produces: `TitleSelection.windows(from:selection:) -> [(provider: ProviderID, window: LimitWindow)]`
  (was `-> [LimitWindow]`), and `ProviderID.titleGlyph: String`.

**Why this task exists at all.** `titleWindows()` currently returns bare `[LimitWindow]`, and a bare
window does not know its provider — so the title cannot mark which product a percentage belongs to,
and the LIMITS SHOWN list has to re-associate a window to its section by `Equatable` containment
(`sections.first { $0.windows.contains(window) }`), which picks the first section when two providers
report value-equal windows. Returning pairs fixes both, and retires the deferral the spec records
under **Carried into PR 2**.

**No visible change yet.** With one provider the glyph never renders and the title is byte-for-byte
what it is today. Task 5 is where this becomes visible.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CashewCoreTests/UsagePanelTests.swift`:

```swift
    @Test func selectionCarriesEachWindowsProvider() {
        // A bare LimitWindow cannot say which product it came from, so the title could not mark it
        // and LIMITS SHOWN had to guess by value equality.
        let sections = [(provider: ProviderID.claude, windows: [window(.primary, "session")]),
                        (provider: ProviderID.codex, windows: [window(.primary, "primary")])]
        let shown = TitleSelection.windows(
            from: sections,
            selection: [ProviderID.claude.qualify("session"), ProviderID.codex.qualify("primary")])
        #expect(shown.map(\.provider) == [.claude, .codex])
        #expect(shown.map(\.window.id) == ["session", "primary"])
    }

    @Test func theGlyphAppearsOnlyWhenMoreThanOneProviderIsShown() {
        // The rule the user picked: a single-provider title is exactly today's title.
        #expect(TitleGlyphs.needed(for: [.claude]) == false)
        #expect(TitleGlyphs.needed(for: [.claude, .claude]) == false)
        #expect(TitleGlyphs.needed(for: [.claude, .codex]))
    }

    @Test func everyProviderHasADistinctGlyph() {
        // Two providers sharing a glyph would be worse than none — it would look like one product.
        let glyphs = ProviderID.allCases.map(\.titleGlyph)
        #expect(Set(glyphs).count == glyphs.count)
        #expect(glyphs.allSatisfy { !$0.isEmpty })
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:|cannot find" | head -3`
Expected: `cannot find 'TitleGlyphs' in scope`, and a type mismatch on `shown.map(\.provider)`.

- [ ] **Step 3: Add the glyph and the rule**

In `Sources/CashewCore/UsageAPI.swift`, on `ProviderID`, beside `sectionHeading`:

```swift
    /// The mark that tells two providers' percentages apart in the menu bar.
    ///
    /// Only drawn when more than one provider's limits are selected — see `TitleGlyphs.needed`.
    /// With one provider the title is exactly what it was before providers were a concept, which is
    /// the whole reason the rule is conditional rather than always-on.
    var titleGlyph: String {
        switch self {
        case .claude: return "✻"
        case .codex: return "◆"
        }
    }
```

In `Sources/CashewCore/MenuController.swift`, beside `TitleSelection`:

```swift
/// Whether the menu bar needs to say which provider a percentage belongs to.
///
/// Pure and separate for the same reason `TitleSelection` is: `MenuController` cannot be built in a
/// test, and a rule that lives there is a rule with no coverage.
enum TitleGlyphs {
    static func needed(for providers: [ProviderID]) -> Bool {
        Set(providers).count > 1
    }
}
```

- [ ] **Step 4: Change `TitleSelection.windows` to return pairs**

Keep every existing comment and both branches — only the element type changes:

```swift
    static func windows(from sections: [(provider: ProviderID, windows: [LimitWindow])],
                        selection: Set<String>)
        -> [(provider: ProviderID, window: LimitWindow)] {
        guard !selection.isEmpty else { return [] }
        let shown = sections.flatMap { section in
            section.windows
                .filter { selection.contains(section.provider.qualify($0.id)) }
                .map { (provider: section.provider, window: $0) }
        }
        guard shown.isEmpty else { return shown }
        // Everything chosen has gone missing. Global, not per-section: a per-section fallback would
        // put an unselected provider's window in the title purely because that provider happened to
        // report something.
        let all = sections.flatMap { s in s.windows.map { (provider: s.provider, window: $0) } }
        return all.first { $0.window.kind == .primary }.map { [$0] } ?? Array(all.prefix(1))
    }
```

- [ ] **Step 5: Draw the glyph in `renderTitle()`**

Replace the per-window loop. Windows of one provider stay joined by `·`; a glyph and a wider gap
separate providers:

```swift
        let shown = titleWindows()
        let glyphed = TitleGlyphs.needed(for: shown.map(\.provider))
        var lastProvider: ProviderID?
        for (index, entry) in shown.enumerated() {
            if index > 0 {
                // A wider gap between providers than between one provider's own windows, so the
                // grouping reads without a second separator character doing the work.
                let gap = entry.provider == lastProvider ? " · " : "  "
                title.append(NSAttributedString(string: gap, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            if glyphed, entry.provider != lastProvider {
                title.append(NSAttributedString(string: "\(entry.provider.titleGlyph) ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let tinted = Forecast.tintsTitle(kind: entry.window.kind,
                                             forecast: forecast(for: entry.window,
                                                                provider: entry.provider))
            title.append(percentage(of: entry.window, mode: mode, onPace: tinted))
            lastProvider = entry.provider
        }
```

Note `forecast(for:provider:)` is now reachable here, so `renderTitle` no longer needs
`provider(of:)`. Check whether `provider(of:)` has any caller left:

```bash
grep -n 'provider(of:' Sources/CashewCore/MenuController.swift
```

If none, delete it — it was kept in PR 1 solely for this call site, and its `?? .claude` fallback is
the last by-id guess in the file.

- [ ] **Step 6: Key LIMITS SHOWN by provider instead of by value equality**

In `menuBarSettings()`, the `rendered` set is built from `TitleSelection.windows`. It now carries
providers, so build it from qualified ids and drop the `contains(window)` lookup:

```swift
        let rendered = Set(TitleSelection.windows(from: sections, selection: Settings.titleLimitIDs)
            .map { $0.provider.qualify($0.window.id) })
```

and compare each row with `rendered.contains(snapshot.provider.qualify(window.id))`. That removes
the `Equatable`-containment guess the spec lists under **Carried into PR 2**.

- [ ] **Step 7: Run the suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **440** tests (437 + 3). Existing `TitleSelection` tests need their expectations
rewritten from `\.id` to `\.window.id` — that is a vocabulary change, not a behaviour change. If an
expectation's *meaning* has to change, stop: that is a behaviour change and it belongs in the spec.

- [ ] **Step 8: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat: carry the provider through the title selection

A bare LimitWindow cannot say which product it came from, so the menu bar
could not mark a percentage and LIMITS SHOWN re-associated a window to
its section by Equatable containment — picking the first section whenever
two providers reported value-equal windows.

TitleSelection now returns (provider, window) pairs, which retires that
deferral and lets the title glyph by provider. The glyph is drawn only
when more than one provider's limits are selected, so a single-provider
title is byte-for-byte what it was."
```

---

### Task 4: Discovery, and a Providers section in Settings

**Files:**
- Modify: `Sources/CashewCore/Settings.swift` — `hiddenProviders`
- Modify: `Sources/CashewCore/MenuController.swift` — the Providers section
- Modify: `Sources/CashewCore/AppDelegate.swift` — respect `hiddenProviders`
- Test: `Tests/CashewCoreTests/DefaultsBackedTests.swift`

**Interfaces:**
- Produces: `Settings.hiddenProviders: Set<ProviderID>`,
  `Settings.hiddenProviders(toggling:in:) -> Set<ProviderID>`,
  `PollPlan.providersToPoll(active:all:hidden:)` — the existing two-argument form gains a third.

**The rule, from the spec:** a provider appears when its credentials exist. If *neither* provider is
detected, Claude is still shown so its sign-in copy has somewhere to render — an empty menu explains
nothing. A detected provider can be hidden in Settings, and hiding it stops it being polled, so
hiding Codex returns a Claude-only user to exactly today's network behaviour.

- [ ] **Step 1: Write the failing tests**

Append to the `SettingsTests` suite in `Tests/CashewCoreTests/DefaultsBackedTests.swift`:

```swift
    @Test func noProviderIsHiddenByDefault() {
        #expect(Settings.hiddenProviders.isEmpty)
    }

    @Test func hidingAProviderRoundTrips() {
        Settings.hiddenProviders = [.codex]
        #expect(Settings.hiddenProviders == [.codex])
    }

    @Test func anUnknownStoredProviderIsIgnoredRatherThanCrashing() {
        // A hand-edited plist, or a provider removed in a later version, must not take the app down.
        Settings.defaults.set(["codex", "not-a-provider"], forKey: "hiddenProviders")
        #expect(Settings.hiddenProviders == [.codex])
    }

    @Test func togglingHidesAndShows() {
        #expect(Settings.hiddenProviders(toggling: .codex, in: []) == [.codex])
        #expect(Settings.hiddenProviders(toggling: .codex, in: [.codex]).isEmpty)
    }
```

And to `BackoffTests.swift`, beside `PollPlanTests`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `type 'Settings' has no member 'hiddenProviders'`

- [ ] **Step 3: Add the preference**

In `Sources/CashewCore/Settings.swift`, add `static let hiddenProviders = "hiddenProviders"` to the
`Key` enum, then:

```swift
    /// Providers the user has switched off, by `ProviderID.rawValue`.
    ///
    /// Stored as the hidden set rather than the shown set so that a provider added in a later
    /// version appears by default — an allow-list would silently hide every future provider until
    /// the user went looking for it.
    ///
    /// Unrecognised entries are dropped rather than trusted: a hand-edited plist, or a provider
    /// removed in a later version, must not be able to take the app down.
    static var hiddenProviders: Set<ProviderID> {
        get {
            let stored = defaults.array(forKey: Key.hiddenProviders) as? [String] ?? []
            return Set(stored.compactMap(ProviderID.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: Key.hiddenProviders) }
    }

    /// Pure, so the rule is testable without a menu.
    static func hiddenProviders(toggling id: ProviderID,
                                in current: Set<ProviderID>) -> Set<ProviderID> {
        var next = current
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }
```

- [ ] **Step 4: Teach `PollPlan` about hiding**

```swift
    /// The providers worth polling: detected, and not switched off.
    ///
    /// When that leaves nothing, Claude is polled anyway so its own sign-in copy has somewhere to
    /// render — an empty menu explains nothing, which is the same reason the no-credentials
    /// fallback exists.
    static func providersToPoll(active: [ProviderID], all: [ProviderID],
                                hidden: Set<ProviderID> = []) -> [ProviderID] {
        let shown = active.filter { !hidden.contains($0) }
        return shown.isEmpty ? all.filter { $0 == .claude } : shown
    }
```

Then pass `hidden: Settings.hiddenProviders` from `AppDelegate.providersToPoll()`.

- [ ] **Step 5: Add the Providers section to the Settings tree**

In `MenuController`, beside `Copy.menuBarSection`, add `static let providersSection = "Providers"`,
and insert the section *first* — it decides what the rest of the menu is about:

```swift
        if let providers = providerSettings() {
            submenu.addItem(section(Copy.providersSection, providers))
        }
        submenu.addItem(section(Copy.menuBarSection, menuBarSettings()))
```

```swift
    /// One switch per *detected* provider, or nothing at all.
    ///
    /// Returns nil when fewer than two providers are detected: a section offering a single switch
    /// that turns off the only thing the app can show is a way to break Cashew, not a preference.
    /// A provider with no credentials is not listed — there is nothing to switch.
    private func providerSettings() -> NSMenu? {
        let detected = snapshots.map(\.provider)
        guard detected.count > 1 else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hidden = Settings.hiddenProviders
        for provider in detected {
            menu.addItem(SettingsRow.toggle(
                "\(provider.sectionHeading.capitalized) (\(hidden.contains(provider) ? "off" : "on"))",
                isOn: !hidden.contains(provider),
                onToggle: { [weak self] _ in
                    Settings.hiddenProviders = Settings.hiddenProviders(toggling: provider,
                                                                        in: Settings.hiddenProviders)
                    self?.onSettingsChanged?()
                }))
        }
        return menu
    }
```

> A toggle row's `title` must say which way it is set — a view-backed item draws no title, but
> `title` is still what VoiceOver and `get name of every menu item` report. That is why the state is
> in the string.

- [ ] **Step 6: Hide a hidden provider's section from the dropdown**

In `PanelSections.visible`, drop hidden providers so hiding Codex removes its rows as well as its
polling:

```swift
    static func visible(_ snapshots: [ProviderSnapshot], now: Date = Date(),
                        hidden: Set<ProviderID> = []) -> [ProviderSnapshot] {
        snapshots.filter {
            !hidden.contains($0.provider)
                && (!$0.displayable(now: now).isEmpty || $0.failure != nil)
        }
    }
```

`rows(for:now:)` calls `visible` internally, so it has to thread the set through rather than have
`rebuild()` reach past it:

```swift
    static func rows(for snapshots: [ProviderSnapshot], now: Date = Date(),
                     hidden: Set<ProviderID> = []) -> [Row] {
        let sections = visible(snapshots, now: now, hidden: hidden)
        // …unchanged from here
```

`rebuild()` then calls `PanelSections.rows(for: snapshots, hidden: Settings.hiddenProviders)`. Both
defaults stay empty so every existing test keeps compiling and keeps meaning what it meant.

Add a test that a hidden provider produces no rows:

```swift
    @Test func aHiddenProviderProducesNoRows() {
        // Hiding removes the section, not just the heading — and with the other provider left
        // alone, no heading either, because there is again only one section to tell apart.
        let both = [snapshot(.claude, ["session"]), snapshot(.codex, ["primary"])]
        let rows = PanelSections.rows(for: both, now: now, hidden: [.codex])
        #expect(rows == [.usage(.claude, both[0].windows[0])])
    }
```

- [ ] **Step 7: Run the suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **447** tests (440 + 7).

- [ ] **Step 8: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat: hide a detected provider from Settings

Stored as the hidden set rather than the shown set, so a provider added
in a later version appears by default instead of being silently withheld
until someone goes looking for the switch.

Hiding stops the polling, not just the rows — so hiding Codex returns a
Claude-only user to exactly the traffic they had before this existed.
The section only appears once more than one provider is detected: a lone
switch that turns off the only thing the app can show is a way to break
Cashew, not a preference."
```

---

### Task 5: Turn Codex on, document it, and look at it

This is the only task that changes what the user sees.

**Files:**
- Modify: `Sources/CashewCore/AppDelegate.swift:15`
- Modify: `CLAUDE.md`, `SECURITY.md`, `README.md`, `docs/TROUBLESHOOTING.md`
- Modify: `docs/superpowers/specs/2026-09-21-multi-provider-usage-design.md` — tick off what PR 2 closed

- [ ] **Step 1: Wire it in**

```swift
    private let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()]
```

Order matters: it is the order sections render in, and `ProviderID.allCases` order is separate. Claude
first, because it is the provider every existing user has.

- [ ] **Step 2: Run the suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, **447** tests, unchanged — no test constructs `AppDelegate`.

- [ ] **Step 3: Look at it, with the real account**

```bash
CASHEW_SIGN_ID="Developer ID Application: VICTORIA PETROVA PETROVA (ZD94VQJW2K)" ./build.sh
pkill -f "MacOS/Cashew"; open build/Cashew.app
osascript -e 'tell application "System Events" to tell process "Cashew" \
  to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'
```

Expect a `CLAUDE` heading over the three Claude rows, then a `CODEX` heading over one row reading
`CODEX · 30-DAY` at 0%. The Claude heading appears here for the first time — with one provider there
was nothing to tell apart.

**Judge the menu bar title by eye, and say if it is wrong.** Cashew's spark image already leads the
item, and with both providers selected the title becomes `✻ 42% · 67%  ◆ 7%` — a spark, then a glyph,
then another glyph. It may read as cluttered. This plan cannot settle that; looking at it can. If it
is wrong, the cheapest fixes are dropping Claude's glyph (the spark already implies it) or defaulting
Codex's window out of the title selection.

- [ ] **Step 4: Check the hidden path**

Turn Codex off in **Settings › Providers**, confirm its section and its rows disappear, and confirm
via `Console.app` or a proxy that nothing further is sent to `chatgpt.com`. Hiding must stop the
traffic, not just the rows.

- [ ] **Step 5: Documentation**

- **`CLAUDE.md`** — architecture table gains `CodexCredentials.swift` and `CodexProvider.swift`;
  add the response-shape section for Codex with the two hazards (epoch **seconds** vs Claude's
  milliseconds; the label derived from `limit_window_seconds` because the cadence is plan-dependent);
  note that `Settings.hiddenProviders` stores the hidden set and why.
- **`SECURITY.md`** — `~/.codex/auth.json` is read, never written; `chatgpt.com` is contacted only
  when that file exists and Codex is not hidden.
- **`README.md`** — Codex is supported; it needs `codex login` and a ChatGPT plan, since a metered
  API key has no quota to report.
- **`docs/TROUBLESHOOTING.md`** — "My Codex usage doesn't appear": run `codex login`; Cashew reads
  what the CLI wrote and cannot sign you in. Add that a free plan reports one 30-day window, which
  is correct rather than a missing row.
- **The spec** — under **Carried into PR 2**, mark the LIMITS SHOWN `Equatable` containment and the
  `PollPlan` hardcoded `.claude` items as closed, and leave the rest with a note saying PR 2 did not
  reach them.

- [ ] **Step 6: Final verification and PR**

```bash
swift test --disable-xctest 2>&1 | tail -1
swift build 2>&1 | grep -E "error|warning" || echo "build clean"
grep -rnE 'CodexProvider\(\)\.fetch|CodexCredentials\.(read|fileExists)' Tests/ || echo "guards clean"
git push -u origin feat/codex-provider
```

Open the PR against `main`, stating: what a free plan shows (one 30-day window), that the two-window
paid shape is still unverified against a live response, and that hiding a provider stops its traffic.

## Self-review notes

Checked against the spec's PR 2 work items:

- `CodexCredentials` reading `~/.codex/auth.json` — Task 1 ✅
- `CodexProvider`, endpoint client and defensive parsing — Task 2 ✅
- Discovery and the Providers section in Settings — Task 4 ✅
- Menu bar glyph, only when more than one provider is shown — Task 3 ✅
- Docs — Task 5 ✅
- Deferrals retired: LIMITS SHOWN `Equatable` containment (Task 3, Step 6), `PollPlan`'s hardcoded
  fallback (Task 4, Step 4 — now takes `hidden:`, though the `.claude` fallback itself remains and
  is still listed in the spec) ✅

**Not addressed by this plan, and deliberately:** the spec's weakest-coverage item — that nothing
tests one provider's `Retry-After` leaving another's schedule alone. It needs `AppDelegate`'s timer
bookkeeping extracted into a pure `PollSchedule`, which is a refactor of PR 1's code rather than part
of adding a provider. It stays in **Carried into PR 2** as the first thing PR 3 should do, and it is
now *more* reachable than before, because a second provider finally exists to be throttled.
