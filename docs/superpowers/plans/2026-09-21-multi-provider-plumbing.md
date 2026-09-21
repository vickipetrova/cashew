# Multi-Provider Plumbing (PR 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure Cashew's usage pipeline so it polls, fails, and renders *per provider*, with Claude remaining the only provider and no user-visible behaviour change.

**Architecture:** `LimitWindow.Kind` stops naming durations and starts naming rank. A `ProviderSnapshot` becomes the unit of state — windows plus that provider's own `updatedAt` and failure — so one provider's 429 or staleness cannot affect another. `AppDelegate` holds `[UsageProvider]` with per-provider generation counters, backoff and poll timers. `MenuController` renders a section per snapshot. Storage keys gain a `claude:` qualifier at exactly three boundaries.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, AppKit + SwiftUI, swift-testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-21-multi-provider-usage-design.md` — read it before starting any task.

## Global Constraints

- Zero third-party dependencies. `Package.swift` never gets a `dependencies:` array.
- `swiftLanguageModes: [.v5]` and `platforms: [.macOS(.v13)]` stay exactly as they are.
- Tests use swift-testing (`import Testing`), never XCTest. Run with `swift test --disable-xctest`.
- Parsing tests feed **JSON text** through `JSONSerialization`, never Swift dictionary literals.
- All parsing is defensive: a missing, null or wrong-typed field drops that one row, never throws.
- Never print, log or commit the OAuth token. CI greps for this.
- Never call from a test: everything in `CLAUDE.md`'s "Never called from a test" list, plus
  `ClaudeProvider.credentialsExist` added in Task 3.
- `MenuController` holds no Claude-specific strings. Copy lives in the provider.
- **This PR changes no user-visible behaviour.** The 391 existing tests are the proof. If a test
  needs its *expectations* changed rather than its *vocabulary*, stop — that is a behaviour change
  and it belongs in the spec first.

## Baseline

Captured 2026-09-21 on `main` at `4c28ce5`:

```
swift test --disable-xctest   →   Test run with 391 tests in 32 suites passed after 0.56 seconds.
```

Every task ends with that command passing. The count may only go **up**, never down.

## The one accepted on-disk consequence

`UsageHistory.save(snapshot:)` encodes whole `LimitWindow` values, so `Kind`'s raw values
(`"session"`, `"weekly"`, `"weeklyScoped"`) are written into `snapshot.json`. Task 1 changes those
raw values, so an existing `snapshot.json` stops decoding.

This fails soft by design — `UsageHistory.read` is `try? JSONDecoder().decode(...)`, so it returns
nil and `restorableSnapshot` returns nil. The visible effect is one cold start with no last-good
reading, resolved by the first poll. **Expected, not a regression.** Do not add a migration; the
spec records that there is no installed base to migrate.

`history.json` is unaffected — `Sample` stores `limitID`, not `kind`.

## File Map

| File | Change |
|---|---|
| `Sources/CashewCore/UsageAPI.swift` | `Kind` rename; `ProviderID`; `ProviderSnapshot`; `UsageProvider` gains `id`/`host`/`credentialsExist`; `ClaudeProvider` conforms |
| `Sources/CashewCore/Forecast.swift` | two exhaustive switches follow the rename |
| `Sources/CashewCore/Credentials.swift` | `exists(file:keychain:)` presence check that never decrypts |
| `Sources/CashewCore/Settings.swift` | `defaultTitleLimitIDs` becomes qualified |
| `Sources/CashewCore/Notifier.swift` | marker key takes a provider |
| `Sources/CashewCore/UsageHistory.swift` | `record`/`samples(for:)` take a provider |
| `Sources/CashewCore/AppDelegate.swift` | `[UsageProvider]`, per-provider state, Claude-only statusline overlay |
| `Sources/CashewCore/MenuController.swift` | renders `[ProviderSnapshot]`; per-section error and freshness |
| `Sources/CashewCore/UsagePanel.swift` | unchanged except where noted in Task 5 |
| `.github/workflows/build.yml` | `credentialsExist` added to the never-call-from-a-test grep |
| Tests (8 files) | vocabulary follows; new suites in Task 2, 3, 4 |

---

### Task 1: Rename `Kind` from duration to rank

**Files:**
- Modify: `Sources/CashewCore/UsageAPI.swift:16-23` (the enum), `:337`, `:343`, `:351` (builders)
- Modify: `Sources/CashewCore/Forecast.swift:35-40`, `:130-136`
- Modify: `Sources/CashewCore/MenuController.swift:23`
- Test: `Tests/CashewCoreTests/ForecastTests.swift`, `ParsingTests.swift`, `UsagePanelTests.swift`,
  `StatuslineFeedTests.swift`, `DefaultsBackedTests.swift`, `UsageHistoryTests.swift`,
  `BackoffTests.swift`

**Interfaces:**
- Produces: `LimitWindow.Kind.primary`, `.secondary`, `.secondaryScoped`. Every later task uses
  these names. `LimitWindow.sessionID`, `weeklyID`, `scopedID(model:)` are **unchanged** in both
  name and value.

**Do not touch:** the wire strings at `UsageAPI.swift:278-289` (`"session"`, `"weekly_all"`,
`"weekly_scoped"` — server protocol), `ClaudeProvider.session` (a `URLSession`), or
`UpdateCheck.session`.

- [ ] **Step 1: Rename the enum cases**

In `Sources/CashewCore/UsageAPI.swift`, replace lines 14-23:

```swift
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
```

- [ ] **Step 2: Run the build to let the compiler find every site**

Run: `swift build 2>&1 | grep -E "error:" | head -30`
Expected: errors in `Forecast.swift` (two exhaustive switches), `UsageAPI.swift` (three builders),
`MenuController.swift:23`. The switches have no `default`, which is why this is safe.

- [ ] **Step 3: Update the three builders**

`Sources/CashewCore/UsageAPI.swift` — change only the `kind:` argument, leaving ids and copy alone:

```swift
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
```

- [ ] **Step 4: Update `Forecast`'s two switches**

`Sources/CashewCore/Forecast.swift` lines 30-40:

```swift
    /// How far back to look, by rank.
    ///
    /// Claude's primary window is five hours, so 90 minutes is long enough to smooth out a single
    /// burst and short enough that a burst an hour ago still counts. Its secondary window is 168
    /// hours, where the same reasoning lands on a day.
    ///
    /// Keyed on rank rather than on a reported duration, which is a known approximation: a provider
    /// whose primary window is much longer than five hours gets a lookback far too short to see
    /// movement, and the `minimumMovementPoints` floor turns that into `.unknown` — quiet, not wrong.
    /// Deriving this from a reported duration needs a real long-window response to fit against.
    static func trailingWindow(for kind: LimitWindow.Kind) -> TimeInterval {
        switch kind {
        case .primary: return 90 * 60
        case .secondary, .secondaryScoped: return 24 * 60 * 60
        }
    }
```

And lines 122-136:

```swift
    /// Whether this forecast should colour the menu bar percentage.
    ///
    /// Secondary windows only, and on purpose: a primary window refills quickly, so being on pace
    /// for one is normal and colouring it would make the title shout during ordinary work. The
    /// secondary window is the one you cannot wait out.
    ///
    /// Here rather than in `MenuController` because the controller can't be built in a test, and a
    /// rule that lives there is a rule with no coverage.
    static func tintsTitle(kind: LimitWindow.Kind, forecast: Forecast) -> Bool {
        guard case .onPace = forecast else { return false }
        switch kind {
        case .secondary, .secondaryScoped: return true
        case .primary: return false
        }
    }
```

- [ ] **Step 5: Update `TitleSelection`'s fallback**

`Sources/CashewCore/MenuController.swift:23`:

```swift
        return windows.first { $0.kind == .primary }.map { [$0] } ?? Array(windows.prefix(1))
```

- [ ] **Step 6: Update the test vocabulary**

Mechanical across the 7 test files. `.session` → `.primary`, `.weekly` → `.secondary`,
`.weeklyScoped` → `.secondaryScoped`, **only where the value is a `LimitWindow.Kind`**.

Leave untouched: `RefuseRedirectsTests.swift:37-38` (those are `URLSession`s),
`LimitWindow.sessionID` / `weeklyID` (unchanged constants), the string literals `"session"`,
`"weekly"`, `"scoped:Fable"`, `"notified.session"` (ids, not kinds — Task 2 handles those).

Run this to find the sites, then edit by hand — do not `sed`, because of the false positives:

```bash
grep -rnE '\.(session|weekly|weeklyScoped)\b' Tests/ | grep -v RefuseRedirectsTests
```

- [ ] **Step 7: Add a test pinning the reason for the rename**

Append to `Tests/CashewCoreTests/ForecastTests.swift`:

```swift
    @Test func kindIsRankNotDuration() {
        // The rename's whole purpose. A provider may report a window of any length in its primary
        // slot — Codex's free plan reports 30 days where a paid plan reports hours — and the window
        // must keep the same kind, and therefore the same id, history and alert markers, across that
        // change. Nothing here may infer a kind from a duration.
        let short = LimitWindow(kind: .primary, id: "p", label: "l", shortLabel: "s",
                                optionLabel: "o", utilization: 10,
                                resetsAt: Date(timeIntervalSince1970: 5 * 60 * 60))
        let long = LimitWindow(kind: .primary, id: "p", label: "l", shortLabel: "s",
                               optionLabel: "o", utilization: 10,
                               resetsAt: Date(timeIntervalSince1970: 30 * 24 * 60 * 60))
        #expect(short.kind == long.kind)
        #expect(Forecast.trailingWindow(for: short.kind)
                == Forecast.trailingWindow(for: long.kind))
    }
```

- [ ] **Step 8: Run the full suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: `Test run with 392 tests in 32 suites passed` — 391 plus the one added above. Any
*failure* here means a behaviour change crept in; revert and re-read the diff.

- [ ] **Step 9: Commit**

```bash
git add Sources/CashewCore/UsageAPI.swift Sources/CashewCore/Forecast.swift \
        Sources/CashewCore/MenuController.swift Tests/
git commit -m "refactor: LimitWindow.Kind names rank, not duration

Codex reports a 30-day primary window on a free plan and a short one on
paid, in the same field, so a kind derived from duration would change
when a user upgrades — taking the window's id with it, resetting the
title selection, orphaning forecast history and re-firing alerts for a
limit that did not change.

The case doc comments already described rank; only the names did not.

Kind's raw values are persisted in snapshot.json, so an existing
snapshot stops decoding. That path is already try?-guarded and returns
nil, costing one cold start its last-good reading. No installed base to
migrate."
```

---

### Task 2: `ProviderID` and qualified storage keys

**Files:**
- Modify: `Sources/CashewCore/UsageAPI.swift` (add `ProviderID` above `LimitWindow`)
- Modify: `Sources/CashewCore/Notifier.swift:72-74`, `:41-66`
- Modify: `Sources/CashewCore/UsageHistory.swift:43-45`, `:52-61`
- Modify: `Sources/CashewCore/Settings.swift:77`
- Modify: `Sources/CashewCore/MenuController.swift:284-286` (the `Forecast.project` call site)
- Test: `Tests/CashewCoreTests/DefaultsBackedTests.swift`, `UsageHistoryTests.swift`

**Interfaces:**
- Consumes: `LimitWindow.Kind` from Task 1.
- Produces: `enum ProviderID: String, Codable, CaseIterable { case claude, codex }`;
  `ProviderID.qualify(_ windowID: String) -> String` returning `"claude:session"`;
  `Notifier.evaluate(_:provider:now:)`; `UsageHistory.record(_:provider:at:)`;
  `UsageHistory.samples(for:provider:)`.

- [ ] **Step 1: Write the failing test for qualification**

Append to `Tests/CashewCoreTests/DefaultsBackedTests.swift`, inside `struct SettingsTests`:

```swift
    @Test func qualifiedIDsAreDistinctAcrossProviders() {
        // Both providers name their short window the same thing. Unqualified, they would share a
        // notification marker, a history series and a title-selection entry.
        #expect(ProviderID.claude.qualify("session") == "claude:session")
        #expect(ProviderID.codex.qualify("session") == "codex:session")
        #expect(ProviderID.claude.qualify("session") != ProviderID.codex.qualify("session"))
    }

    @Test func qualificationSurvivesAnIDContainingAColon() {
        // Scoped ids already contain a colon ("scoped:Opus"), so the qualifier must not be parsed
        // back out by splitting — nothing does, and this records why nothing may start.
        #expect(ProviderID.claude.qualify("scoped:Opus") == "claude:scoped:Opus")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:|cannot find" | head -5`
Expected: `cannot find 'ProviderID' in scope`

- [ ] **Step 3: Add `ProviderID`**

In `Sources/CashewCore/UsageAPI.swift`, immediately above `struct LimitWindow`:

```swift
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
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, 394 tests.

- [ ] **Step 5: Qualify the notification marker key**

`Sources/CashewCore/Notifier.swift` — change the signature at line 41 and the key at 72-74:

```swift
    static func evaluate(_ windows: [LimitWindow], provider: ProviderID,
                         now: Date = Date()) {
```

```swift
    /// Keyed on the provider-qualified `LimitWindow.id`, never on the display label. Keying on
    /// display copy meant restyling a heading silently reset which alerts counted as already-sent;
    /// keying on a bare id would mean Codex's short window silencing Claude's.
    private static func markerKey(for window: LimitWindow, provider: ProviderID) -> String {
        "notified.\(provider.qualify(window.id))"
    }
```

And at line 50, inside `evaluate`'s loop:

```swift
            let key = markerKey(for: window, provider: provider)
```

- [ ] **Step 6: Qualify the history sample id**

`Sources/CashewCore/UsageHistory.swift` — lines 42-45 and 52-61:

```swift
    /// Every sample recorded for one limit, oldest first.
    func samples(for limitID: String, provider: ProviderID) -> [Sample] {
        let qualified = provider.qualify(limitID)
        return samples.filter { $0.limitID == qualified }
    }
```

```swift
    func record(_ windows: [LimitWindow], provider: ProviderID, at now: Date = Date()) {
        samples.append(contentsOf: windows.compactMap { window in
            // A window whose utilization couldn't be read is not a zero — it is nothing. Writing it
            // as 0 would look like a reset and throw the trailing window away.
            guard window.utilization.isFinite else { return nil }
            return Sample(at: now, limitID: provider.qualify(window.id),
                          utilization: window.utilization)
        })
        samples.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        write()
    }
```

- [ ] **Step 7: Qualify the default title selection**

`Sources/CashewCore/Settings.swift:77`:

```swift
    /// The two headline windows — what the title showed before this was configurable.
    ///
    /// Qualified, because the stored set is shared across providers: an unqualified `"session"`
    /// would select both Claude's and Codex's short window with one entry and give no way to
    /// choose between them.
    static let defaultTitleLimitIDs: Set<String> = [
        ProviderID.claude.qualify(LimitWindow.sessionID),
        ProviderID.claude.qualify(LimitWindow.weeklyID),
    ]
```

- [ ] **Step 8: Fix the call sites the compiler now rejects**

Run: `swift build 2>&1 | grep -E "error:" | head -20`

Expected sites: `AppDelegate.swift:128` (`history.record`), `:131` (`Notifier.evaluate`),
`MenuController.swift:284-286` (`history.samples(for:)`). Pass `.claude` at each for now — Task 4
replaces these with the per-snapshot provider.

`MenuController.swift:283-286` becomes:

```swift
    private func forecast(for window: LimitWindow) -> Forecast {
        Forecast.project(samples: history.samples(for: window.id, provider: .claude),
                         kind: window.kind, resetsAt: window.resetsAt, now: Date())
    }
```

- [ ] **Step 9: Update the tests that hardcode unqualified keys**

`Tests/CashewCoreTests/DefaultsBackedTests.swift:71` — the literal, not a constant:

```swift
    private let sessionKey = "notified.claude:session"
```

`:151-152`:

```swift
        #expect(defaults.string(forKey: "notified.claude:session") != nil)
        #expect(defaults.string(forKey: "notified.claude:weekly") != nil)
```

`:307` and the `titleLimitIDs` tests at `:311-340` — wrap every bare id in
`ProviderID.claude.qualify(...)`. For example `:307`:

```swift
        #expect(Settings.titleLimitIDs == [ProviderID.claude.qualify(LimitWindow.sessionID),
                                           ProviderID.claude.qualify(LimitWindow.weeklyID)])
```

`Tests/CashewCoreTests/UsageHistoryTests.swift:177`:

```swift
        let forecast = Forecast.project(samples: history.samples(for: "session", provider: .claude),
                                        kind: .primary,
```

Every other `history.record(...)` / `history.samples(for:)` call in that file gains
`provider: .claude`.

- [ ] **Step 10: Add a test that the two providers don't collide in storage**

Append to `Tests/CashewCoreTests/UsageHistoryTests.swift`:

```swift
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
```

- [ ] **Step 11: Add the matching notifier test**

Append inside `struct NotifierTests` in `Tests/CashewCoreTests/DefaultsBackedTests.swift`:

```swift
    @Test func twoProvidersAlertIndependentlyForTheSameWindowID() throws {
        Settings.notifyThreshold = 80
        let window = LimitWindow(kind: .primary, id: "session", label: "SESSION",
                                 shortLabel: "Session", optionLabel: "opt",
                                 utilization: 85, resetsAt: Date(timeIntervalSince1970: 9_000_000))

        Notifier.evaluate([window], provider: .claude)
        Notifier.evaluate([window], provider: .codex)

        // Two alerts, not one swallowed by the other's marker.
        #expect(recorder.count == 2)
        #expect(defaults.string(forKey: "notified.claude:session") != nil)
        #expect(defaults.string(forKey: "notified.codex:session") != nil)
    }
```

- [ ] **Step 12: Run the full suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, 396 tests.

- [ ] **Step 13: Commit**

```bash
git add Sources/ Tests/
git commit -m "refactor: qualify storage keys by provider

LimitWindow.id is a persisted key in three places — the notification
dedup key, UsageHistory's Sample.limitID and the title-selection set —
and both providers name their short window 'session'. Unqualified, Codex
hitting 80% would suppress Claude's alert, their samples would fit one
forecast line, and one title-selection entry would mean both.

Qualification is confined to those three boundaries; everything else
keeps working on plain LimitWindow. The qualified form is never parsed
back apart — a scoped id already contains a colon."
```

---

### Task 3: `UsageProvider` gains identity, host and a presence check

**Files:**
- Modify: `Sources/CashewCore/UsageAPI.swift:57-61` (the protocol), `:150+` (`ClaudeProvider`)
- Modify: `Sources/CashewCore/Credentials.swift`
- Modify: `.github/workflows/build.yml:153`
- Test: `Tests/CashewCoreTests/CredentialsTests.swift`

**Interfaces:**
- Consumes: `ProviderID` from Task 2.
- Produces: `UsageProvider { var id: ProviderID { get }; static var host: String { get }; func credentialsExist() -> Bool; func fetch(...) }`;
  `Credentials.exists(file:keychain:) -> Bool`; `ClaudeProvider(presence:)`.

- [ ] **Step 1: Write the failing test for the presence rule**

Append to `Tests/CashewCoreTests/CredentialsTests.swift`:

```swift
    @Test func presenceIsTrueWhenEitherStoreHasSomething() {
        #expect(Credentials.exists(file: .absent, keychain: .absent) == false)
        #expect(Credentials.exists(file: .found(sample), keychain: .absent))
        #expect(Credentials.exists(file: .absent, keychain: .found(sample)))
    }

    @Test func aDeniedKeychainStillCountsAsPresent() {
        // Denial means there is something there we were refused, which is the opposite of absent.
        // Treating it as absent would hide the provider and with it the one error message that
        // tells the user how to fix it.
        #expect(Credentials.exists(file: .absent, keychain: .accessDenied))
    }
```

Add the fixture near the top of the suite if one is not already present:

```swift
    private let sample = Credentials.Candidate(token: "t", expiresAtMillis: nil,
                                               isOverride: false, source: .file)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `type 'Credentials' has no member 'exists'`

- [ ] **Step 3: Add the pure presence rule**

In `Sources/CashewCore/Credentials.swift`, beside `resolve(file:keychain:)`:

```swift
    /// Whether there is a Claude Code login here at all, without reading it.
    ///
    /// Pure, like `resolve`, so discovery is testable without touching a real login — the impure
    /// half is `keychainItemExists()` below, which CI keeps out of tests.
    ///
    /// `.accessDenied` counts as present. Something is there and macOS refused it, which is the
    /// opposite of absent: reporting it as absent would hide the provider entirely and with it the
    /// one message that tells the user how to fix it.
    static func exists(file: Outcome, keychain: Outcome) -> Bool {
        [file, keychain].contains { $0 != .absent }
    }
```

- [ ] **Step 4: Add the non-decrypting Keychain probe**

Also in `Credentials.swift`:

```swift
    /// Does the Keychain item exist, without decrypting it?
    ///
    /// `kSecReturnAttributes` without `kSecReturnData` asks securityd for metadata only, which does
    /// not evaluate the item's decrypt ACL and therefore cannot raise the permission prompt. That
    /// matters more than it looks: discovery runs on every launch, and a discovery check that
    /// prompted would be worse than having no discovery at all.
    ///
    /// Never called from a test — it reads the real login Keychain. CI greps for it.
    static func keychainItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        // Anything else — including a denial — means something is there that we could not read.
        default: return true
        }
    }

    /// Does the credentials file exist? Cheap, and no prompt is possible.
    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: (credentialsPath as NSString).expandingTildeInPath)
    }
```

- [ ] **Step 5: Extend the protocol**

`Sources/CashewCore/UsageAPI.swift:57-61`:

```swift
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
```

- [ ] **Step 6: Conform `ClaudeProvider`**

In `Sources/CashewCore/UsageAPI.swift`, inside `struct ClaudeProvider`:

```swift
    let id: ProviderID = .claude

    static let host = "api.anthropic.com"

    /// Injected so the discovery *logic* is testable while the real probe stays out of tests — the
    /// same seam, and the same reason, as `Credentials.token(in:)`. The default reads the real
    /// login; a test passes its own answer.
    private let presence: () -> Bool

    init(presence: @escaping () -> Bool = Credentials.loginExists) {
        self.presence = presence
    }

    func credentialsExist() -> Bool { presence() }
```

The default is one named function rather than an inline closure, so there is exactly one place that
knows how the real probe is assembled. Add it to `Credentials.swift`, beside the two probes from
Step 4:

```swift
    /// Is there a Claude Code login on this machine at all?
    ///
    /// The impure composition of the two probes above, kept as one named function so
    /// `ClaudeProvider`'s default argument stays readable and there is a single symbol for CI to
    /// grep. Never called from a test.
    static func loginExists() -> Bool {
        exists(file: fileExists() ? .accessDenied : .absent,
               keychain: keychainItemExists() ? .accessDenied : .absent)
    }
```

> `.accessDenied` is used here purely as a stand-in for "something is there", because `exists`
> only asks whether an outcome is `.absent` and building a throwaway `Candidate` with an empty
> token would put a fake credential into a type whose whole job is not to hold one.

- [ ] **Step 7: Verify the endpoint uses the declared host**

Add to `Tests/CashewCoreTests/RefuseRedirectsTests.swift`:

```swift
    @Test func theClaudeEndpointOnlyTalksToItsDeclaredHost() {
        // Hard rule 5 is per-provider now: each provider names the one host it may contact, and
        // this is what keeps the declaration honest rather than decorative.
        #expect(ClaudeProvider.host == "api.anthropic.com")
        #expect(ClaudeProvider.endpointHost == ClaudeProvider.host)
    }
```

Expose the endpoint's host in `UsageAPI.swift` to make that checkable:

```swift
    /// The endpoint's own host, so a test can hold it against `host` and catch a URL edited in
    /// isolation. Internal rather than private purely for that check.
    static var endpointHost: String { endpoint.host ?? "" }
```

- [ ] **Step 8: Add the CI guard**

`.github/workflows/build.yml:153` — extend the alternation inside the existing grep:

```
|UpdateCheck\.fetch|Credentials\.keychainItemExists|Credentials\.fileExists
```

- [ ] **Step 9: Run the suite and the guard**

```bash
swift test --disable-xctest 2>&1 | tail -3
grep -rnE 'Credentials\.(keychainItemExists|fileExists)' Tests/ || echo "OK — guard clean"
```
Expected: PASS at 399 tests, and `OK — guard clean`.

- [ ] **Step 10: Commit**

```bash
git add Sources/ Tests/ .github/workflows/build.yml
git commit -m "feat: providers declare identity, host and credential presence

Discovery needs to know whether a provider has a login without reading
it. For Claude that means SecItemCopyMatching with kSecReturnAttributes
and without kSecReturnData — metadata only, which does not evaluate the
item's decrypt ACL and so cannot raise the permission prompt. Discovery
runs on every launch; one that prompted would be worse than none.

The probe is injected, because the real one reads the user's actual
login Keychain — the same reason accessToken() is already on CI's
never-call-from-a-test grep, which both new entry points join.

An access-denied Keychain counts as present: something is there that we
were refused, and reporting it absent would hide the provider along with
the message explaining how to fix it."
```

---

### Task 4: `ProviderSnapshot` and per-provider polling

**Files:**
- Modify: `Sources/CashewCore/UsageAPI.swift` (add `ProviderSnapshot` after `Freshness`)
- Modify: `Sources/CashewCore/AppDelegate.swift:15-29`, `:78-104`, `:120-164`
- Test: `Tests/CashewCoreTests/BackoffTests.swift` (new suite for snapshot behaviour)

**Interfaces:**
- Consumes: `ProviderID` (Task 2), `UsageProvider.id` / `credentialsExist()` (Task 3).
- Produces: `struct ProviderSnapshot { let provider: ProviderID; let windows: [LimitWindow]; let updatedAt: Date?; let failure: Error? }`
  and `ProviderSnapshot.displayable(now:) -> [LimitWindow]`.
  `MenuController.update(snapshots: [ProviderSnapshot])` is defined in Task 5 and called from here.

- [ ] **Step 1: Write the failing test for per-provider freshness**

Append to `Tests/CashewCoreTests/BackoffTests.swift`:

```swift
@Suite struct ProviderSnapshotTests {
    private func window(_ id: String, resetsIn: TimeInterval, from now: Date) -> LimitWindow {
        LimitWindow(kind: .primary, id: id, label: id, shortLabel: id, optionLabel: id,
                    utilization: 10, resetsAt: now.addingTimeInterval(resetsIn))
    }

    @Test func oneProviderGoingStaleDoesNotAffectTheOther() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = ProviderSnapshot(provider: .claude,
                                     windows: [window("session", resetsIn: 3600, from: now)],
                                     updatedAt: now.addingTimeInterval(-60), failure: nil)
        // Past Freshness.maxAge (24h), so this provider has nothing honest left to show.
        let stale = ProviderSnapshot(provider: .codex,
                                     windows: [window("session", resetsIn: 3600, from: now)],
                                     updatedAt: now.addingTimeInterval(-48 * 3600), failure: nil)

        #expect(fresh.displayable(now: now).count == 1)
        #expect(stale.displayable(now: now).isEmpty)
    }

    @Test func aFailureOnOneProviderLeavesTheOthersWindowsIntact() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let failed = ProviderSnapshot(provider: .codex, windows: [],
                                      updatedAt: nil, failure: UsageError.unauthorized)
        let ok = ProviderSnapshot(provider: .claude,
                                  windows: [window("session", resetsIn: 3600, from: now)],
                                  updatedAt: now, failure: nil)
        #expect(failed.displayable(now: now).isEmpty)
        #expect(ok.displayable(now: now).count == 1)
        #expect(ok.failure == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --disable-xctest 2>&1 | grep -E "cannot find" | head -3`
Expected: `cannot find 'ProviderSnapshot' in scope`

- [ ] **Step 3: Add `ProviderSnapshot`**

In `Sources/CashewCore/UsageAPI.swift`, immediately after `enum Freshness`:

```swift
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

    /// What is worth putting on screen for this provider, by the one `Freshness` rule.
    func displayable(now: Date = Date()) -> [LimitWindow] {
        Freshness.displayable(windows, updatedAt: updatedAt, now: now)
    }

    /// The same snapshot with a fresh reading. Failure is cleared — a success supersedes it.
    func succeeded(windows: [LimitWindow], at now: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, updatedAt: now, failure: nil)
    }

    /// The same snapshot with a failure recorded. Windows and `updatedAt` are deliberately kept:
    /// a dead network should not blank numbers that were true a few minutes ago, and `Freshness`
    /// is what eventually removes them.
    func failed(_ error: Error) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, updatedAt: updatedAt, failure: error)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, 401 tests.

- [ ] **Step 5: Replace `AppDelegate`'s single-provider state**

`Sources/CashewCore/AppDelegate.swift` — replace line 15 and lines 84-118:

```swift
    private let providers: [UsageProvider] = [ClaudeProvider()]
```

```swift
    /// Consecutive rate-limited replies, **per provider**. Reset by that provider's next success,
    /// and by any settings change, since that is the user explicitly asking for a different cadence.
    private var rateLimitStreak: [ProviderID: Int] = [:]

    /// One poll timer per provider, so a provider being told to slow down cannot slow the others.
    private var pollTimers: [ProviderID: Timer] = [:]

    /// Bumped for every fetch and compared when it lands, **per provider**.
    ///
    /// Per provider and not global, which is the whole point: a single counter meant any provider's
    /// fetch invalidated every other provider's in-flight reply, so a second provider would silently
    /// drop the first one's results. Within one provider it still does its original job — stopping a
    /// slow poll from overwriting fresher numbers stamped `updatedAt: Date()`.
    private var fetchGeneration: [ProviderID: Int] = [:]

    /// The last full reading from each provider, before any live overlay.
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]
```

- [ ] **Step 6: Make polling per-provider**

Replace `reschedulePoll()` and `backOff(retryAfter:)`:

```swift
    private func reschedulePoll() {
        rateLimitStreak.removeAll()
        for provider in activeProviders {
            pollTimers[provider.id]?.invalidate()
            pollTimers[provider.id] = schedule(every: Settings.refreshInterval) { [weak self] in
                self?.refresh(provider)
            }
        }
    }

    /// Replace one provider's repeating poll with a single delayed one after being told to slow down.
    ///
    /// This is the fix for a fifteen-day outage: the app was rate-limited, kept asking every five
    /// minutes regardless, and had no way back except being noticed and restarted.
    ///
    /// Scoped to the provider that was refused. A shared timer would mean Codex being throttled also
    /// throttling Claude, which is the original bug wearing a different hat.
    private func backOff(_ provider: ProviderID, retryAfter: TimeInterval?) {
        let streak = (rateLimitStreak[provider] ?? 0) + 1
        rateLimitStreak[provider] = streak
        let delay = Backoff.delay(attempt: streak, retryAfter: retryAfter,
                                  base: Settings.refreshInterval)
        pollTimers[provider]?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh(provider)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimers[provider] = timer
    }

    /// Only providers the user actually has. A provider with no credentials is not polled, does not
    /// appear, and costs no network — see the discovery rule in the design.
    private var activeProviders: [UsageProvider] {
        providers.filter { $0.credentialsExist() }
    }

    private func refresh(_ id: ProviderID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        refresh(provider)
    }

    /// Poll every active provider. Called at launch, on wake, and from Refresh Now.
    private func refresh() {
        let active = activeProviders
        // Nothing detected at all: keep Claude so its own copy explains how to sign in, rather than
        // rendering an empty menu with no account of why.
        let toPoll = active.isEmpty ? providers.filter { $0.id == .claude } : active
        for provider in toPoll { refresh(provider) }
    }
```

- [ ] **Step 7: Make `refresh(_:)` per-provider**

Replace the body of the old `refresh()` (lines 134-164) with:

```swift
    private func refresh(_ provider: UsageProvider) {
        let id = provider.id
        let generation = (fetchGeneration[id] ?? 0) + 1
        fetchGeneration[id] = generation
        provider.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration[id] else { return }
                let existing = self.snapshots[id]
                    ?? ProviderSnapshot(provider: id, windows: [], updatedAt: nil, failure: nil)
                switch result {
                case .success(let windows):
                    // Recorded before the menu renders, so the row being built can already see this
                    // poll's sample. Only on success: a failed poll leaves the last good numbers on
                    // screen, and re-recording them would invent a flat stretch that never happened.
                    self.snapshots[id] = existing.succeeded(windows: windows, at: Date())
                    self.publish(at: Date())
                    // Back to the normal cadence, for this provider only. A manual Refresh Now that
                    // is also refused must not reset the streak, or mashing it defeats the mechanism.
                    if (self.rateLimitStreak[id] ?? 0) > 0 { self.reschedulePoll() }
                case .failure(let error):
                    self.snapshots[id] = existing.failed(error)
                    self.publish(at: Date())
                    if case UsageError.rateLimited(let retryAfter) = error {
                        self.backOff(id, retryAfter: retryAfter)
                    }
                }
            }
        }
    }
```

- [ ] **Step 8: Apply the statusline overlay to Claude only**

Replace `publishMergingLiveReadings(at:)` with:

```swift
    /// Assemble every provider's snapshot and publish them.
    ///
    /// The statusline overlay is applied to **Claude's** snapshot and nothing else. `StatuslineFeed`
    /// reads what Claude Code hands its own statusline; it is Claude's live feed, not the app's, and
    /// merging it into a combined list could overwrite another provider's window that happens to
    /// share an unqualified id.
    private func publish(at updatedAt: Date) {
        var assembled: [ProviderSnapshot] = []
        for provider in providers {
            guard var snapshot = snapshots[provider.id] else { continue }
            if provider.id == .claude, let live = statusline.read(), !live.isEmpty {
                let merged = SourceMerge.merge(polled: snapshot.windows, live: live)
                snapshot = ProviderSnapshot(provider: .claude, windows: merged,
                                            updatedAt: updatedAt, failure: snapshot.failure)
            }
            guard !snapshot.windows.isEmpty || snapshot.failure != nil else { continue }
            if !snapshot.windows.isEmpty {
                history.record(snapshot.windows, provider: snapshot.provider, at: updatedAt)
                Notifier.evaluate(snapshot.windows, provider: snapshot.provider)
            }
            assembled.append(snapshot)
        }
        guard !assembled.isEmpty else { return }
        history.save(snapshot: assembled.flatMap(\.windows), at: updatedAt)
        menuController.update(snapshots: assembled)
    }
```

- [ ] **Step 9: Update the 60-second tick**

`applicationDidFinishLaunching`, lines 44-55 — the gate now asks the snapshots, not `polled`:

```swift
            if !self.snapshots.isEmpty || self.statusline.read() != nil {
                self.publish(at: Date())
            }
```

- [ ] **Step 10: Build and fix the remaining call sites**

Run: `swift build 2>&1 | grep -E "error:" | head -20`

`menuController.update(windows:updatedAt:)` and `update(error:)` no longer exist as used — Task 5
introduces `update(snapshots:)`. **Do Task 5 before expecting a clean build**; if working strictly
task-by-task, stub `update(snapshots:)` in `MenuController` to call the existing
`update(windows:updatedAt:)` with `snapshots.flatMap(\.windows)` and the newest `updatedAt`, so this
task is independently verifiable, and replace the stub in Task 5.

- [ ] **Step 11: Run the suite**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, 401 tests.

- [ ] **Step 12: Commit**

```bash
git add Sources/ Tests/
git commit -m "refactor: poll, fail and back off per provider

AppDelegate held one provider, one polled array, one rateLimitStreak,
one pollTimer and one fetchGeneration. Each becomes per-provider.

fetchGeneration is the one that would have bitten silently: a single
counter meant any provider's fetch invalidated every other provider's
in-flight reply, so adding a second provider would make the first
intermittently stop updating — about the hardest symptom to attribute
back to this change.

The statusline overlay now applies to Claude's snapshot alone. It reads
what Claude Code hands its own statusline; against a combined list it
could overwrite another provider's window sharing an unqualified id."
```

---

### Task 5: Render a section per provider

**Files:**
- Modify: `Sources/CashewCore/MenuController.swift:49-52`, `:113-146`, `:265-297`, `:299-387`, `:669-764`
- Modify: `Sources/CashewCore/UsageAPI.swift` (add `ProviderID.sectionHeading`)
- Test: `Tests/CashewCoreTests/UsagePanelTests.swift`

**Interfaces:**
- Consumes: `ProviderSnapshot` (Task 4).
- Produces: `MenuController.update(snapshots: [ProviderSnapshot])`, replacing
  `update(windows:updatedAt:)` and `update(error:)`.

**The constraint that shapes this task:** PR 1 must produce no visible change. With Claude as the
only provider, the menu must render byte-for-byte as it does today — which means **no provider
heading when only one provider is shown**.

- [ ] **Step 1: Write the failing test for the heading rule**

Append to `Tests/CashewCoreTests/UsagePanelTests.swift`:

```swift
@Suite struct ProviderSectionTests {
    private func snapshot(_ provider: ProviderID, _ ids: [String]) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: ids.map {
                LimitWindow(kind: .primary, id: $0, label: $0.uppercased(), shortLabel: $0,
                            optionLabel: $0, utilization: 10, resetsAt: nil)
            },
            updatedAt: Date(timeIntervalSince1970: 1_000_000), failure: nil)
    }

    @Test func oneProviderGetsNoHeading() {
        // Today's menu, unchanged. A "CLAUDE" heading above the only section would be a visible
        // change in a refactor that is supposed to have none.
        #expect(PanelSections.headingsNeeded(for: [snapshot(.claude, ["session"])]) == false)
    }

    @Test func twoProvidersGetHeadings() {
        #expect(PanelSections.headingsNeeded(for: [snapshot(.claude, ["session"]),
                                                   snapshot(.codex, ["session"])]))
    }

    @Test func aProviderWithNothingToShowIsNotASection() {
        // An empty snapshot must not count towards "more than one", or a Codex provider that is
        // present but reporting nothing would put a heading above Claude for no reason.
        let empty = ProviderSnapshot(provider: .codex, windows: [], updatedAt: nil, failure: nil)
        #expect(PanelSections.headingsNeeded(for: [snapshot(.claude, ["session"]), empty]) == false)
    }

    @Test func headingsNameTheProvider() {
        #expect(ProviderID.claude.sectionHeading == "CLAUDE")
        #expect(ProviderID.codex.sectionHeading == "CODEX")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --disable-xctest 2>&1 | grep -E "cannot find" | head -3`
Expected: `cannot find 'PanelSections' in scope`

- [ ] **Step 3: Add the pure section rule**

In `Sources/CashewCore/MenuController.swift`, beside `enum TitleSelection`:

```swift
/// Which provider sections the dropdown draws, and whether they need naming.
///
/// Pure and separate from `MenuController` for the same reason `TitleSelection` is: the controller
/// cannot be constructed in a test, so a rule that lives inside it is a rule with no coverage.
enum PanelSections {
    /// A snapshot worth drawing: it has something to show, or something to say about why it doesn't.
    static func visible(_ snapshots: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        snapshots.filter { !$0.displayable(now: now).isEmpty || $0.failure != nil }
    }

    /// Headings appear only once there is more than one section to tell apart.
    ///
    /// With a single provider the menu is exactly what it was before providers were a concept, which
    /// is what makes adding the second one a change the existing user never sees until it applies
    /// to them.
    static func headingsNeeded(for snapshots: [ProviderSnapshot], now: Date = Date()) -> Bool {
        visible(snapshots, now: now).count > 1
    }
}
```

- [ ] **Step 4: Add the heading copy**

In `Sources/CashewCore/UsageAPI.swift`, on `ProviderID`:

```swift
    /// The dropdown's section heading. Lives here rather than in `MenuController`, which is not
    /// allowed to hold a vendor's copy — the same rule that keeps `optionLabel` on `LimitWindow`.
    var sectionHeading: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: PASS, 405 tests.

- [ ] **Step 6: Replace `MenuController`'s state**

Lines 49-52:

```swift
    private var snapshots: [ProviderSnapshot] = []
    private var isMenuOpen = false
```

(`windows`, `lastUpdated` and `lastError` all go — they are per-snapshot now.)

- [ ] **Step 7: Replace the update entry points**

Lines 113-134:

```swift
    func update(snapshots: [ProviderSnapshot]) {
        self.snapshots = snapshots
        renderTitle()
        // A poll can land while the dropdown is open, and the open dropdown is not rebuilt. Without
        // this the rows keep rendering the state they were built from — most visibly a countdown
        // running down to the *previous* window's reset and pinning at "now".
        refreshLiveRows()
    }
```

`update(error:)` is deleted: a failure now arrives inside its provider's snapshot.

- [ ] **Step 8: Make the flat accessors span snapshots**

First, widen `TitleSelection.windows` from Task 2's single-provider bridge to sections. **The
fallback must stay global.** Evaluating it per section would mean that a user who selected only
Claude's windows still got Codex's primary window in the title, because Codex's section would find
nothing selected and "helpfully" fall back — surfacing a window the user never picked:

```swift
enum TitleSelection {
    /// Which limits the menu bar title shows, given what each provider reported and what the user
    /// picked. Sections rather than a flat list, because the stored selection is qualified by
    /// provider and a bare `LimitWindow` does not know which provider it came from.
    static func windows(from sections: [(provider: ProviderID, windows: [LimitWindow])],
                        selection: Set<String>) -> [LimitWindow] {
        // Choosing nothing is a real choice, and it has to be told apart from choosing something
        // that has since gone missing — the fallback below must not fire for it, or unchecking the
        // last limit would silently put a number back.
        guard !selection.isEmpty else { return [] }
        // Order comes from the response within a section, and from section order across them.
        let shown = sections.flatMap { section in
            section.windows.filter { selection.contains(section.provider.qualify($0.id)) }
        }
        guard shown.isEmpty else { return shown }
        // Everything chosen has gone missing. The user did ask for numbers, so a stale scope list
        // is no reason to show none of them. Global, not per-section: a per-section fallback would
        // put an unselected provider's window in the title purely because that provider happened to
        // report something.
        let all = sections.flatMap(\.windows)
        return all.first { $0.kind == .primary }.map { [$0] } ?? Array(all.prefix(1))
    }
}
```

Add a test for exactly that hazard in `Tests/CashewCoreTests/UsagePanelTests.swift`:

```swift
    @Test func aSelectionFromOneProviderDoesNotPullInAnothersFallback() {
        // The per-section-fallback trap. Claude's window is selected and present, so nothing is
        // "missing" — Codex must contribute nothing, not its primary window.
        let sections = [(provider: ProviderID.claude,
                         windows: [window(.primary, LimitWindow.sessionID)]),
                        (provider: ProviderID.codex,
                         windows: [window(.primary, "session")])]
        let shown = TitleSelection.windows(
            from: sections, selection: [ProviderID.claude.qualify(LimitWindow.sessionID)])
        #expect(shown.count == 1)
    }
```

Then the accessors. Lines 265-297:

```swift
    /// Every window worth putting on screen, across every provider, in section order.
    private func displayWindows() -> [LimitWindow] {
        let now = Date()
        return PanelSections.visible(snapshots, now: now).flatMap { $0.displayable(now: now) }
    }

    /// The windows the title shows, across every provider.
    ///
    /// Task 2 bridged this with a hardcoded `.claude`, because a bare `LimitWindow` does not know
    /// its provider while the selection set is stored qualified. Now that snapshots carry the
    /// provider, the bridge is replaced — a hardcoded `.claude` here would make every Codex window
    /// permanently unselectable.
    private func titleWindows() -> [LimitWindow] {
        let now = Date()
        let sections = PanelSections.visible(snapshots, now: now)
            .map { (provider: $0.provider, windows: $0.displayable(now: now)) }
        return TitleSelection.windows(from: sections, selection: Settings.titleLimitIDs)
    }

    /// The provider a window belongs to, for keying its history and its selection entry.
    private func provider(of window: LimitWindow) -> ProviderID {
        snapshots.first { $0.windows.contains(where: { $0.id == window.id }) }?.provider ?? .claude
    }

    private func forecast(for window: LimitWindow) -> Forecast {
        Forecast.project(samples: history.samples(for: window.id, provider: provider(of: window)),
                         kind: window.kind, resetsAt: window.resetsAt, now: Date())
    }
```

> **Implementer note:** `provider(of:)` scanning by id is adequate here because ids are unique within
> a provider and sections are drawn per snapshot. If it shows up in a profile, pass the provider down
> from the section loop in `rebuild()` instead of looking it up — it is available there for free.

- [ ] **Step 9: Rebuild the dropdown in sections**

Replace the usage-row portion of `rebuild()` (lines 322-357):

```swift
        let sections = PanelSections.visible(snapshots)
        let needHeadings = PanelSections.headingsNeeded(for: snapshots)

        if sections.isEmpty {
            if snapshots.contains(where: { $0.failure != nil }) {
                menu.addItem(textRow { [weak self] in
                    guard let self,
                          let failed = self.snapshots.first(where: { $0.failure != nil }),
                          let error = failed.failure else { return nil }
                    return self.message(for: error, in: failed)
                })
            } else if snapshots.contains(where: { $0.updatedAt != nil }) {
                menu.addItem(textRow {
                    """
                    No plan limits reported for this account. Pro and Max plans have session and \
                    weekly windows; metered API-key accounts have no quota to show.
                    """
                })
            } else {
                menu.addItem(textRow { "Loading…" })
            }
        } else {
            for (index, section) in sections.enumerated() {
                // A rule between providers, but never between the rows inside one: a line between
                // every usage row made three windows look like three unrelated panels stacked up.
                // Between providers it divides genuinely different things, which is what separators
                // are for here.
                if index > 0 { menu.addItem(.separator()) }
                if needHeadings { menu.addItem(headingRow(section.provider.sectionHeading)) }
                for window in section.displayable() {
                    menu.addItem(usageRow(for: window, provider: section.provider))
                }
                if section.failure != nil {
                    menu.addItem(errorRow(for: section.provider))
                }
            }
        }
```

- [ ] **Step 10: Key the live rows on provider as well as id**

Lines 669-690 and 729-736:

```swift
    private func usageRow(for window: LimitWindow, provider: ProviderID) -> NSMenuItem {
        let id = window.id
        let row = UsageRow(window, mode: Settings.colorMode, forecast: forecast(for: window))
        let hosted = HostedRow(UsageRowView(row: row), title: row.spoken)
        liveRows.append(LiveRow { [weak self] in
            guard let self, let window = self.window(id: id, provider: provider) else { return }
            let row = UsageRow(window, mode: Settings.colorMode, forecast: self.forecast(for: window))
            hosted.update(UsageRowView(row: row), title: row.spoken)
        })
        return hosted.item
    }

    /// The window this row was built for, as it stands in the *latest* poll of its own provider.
    ///
    /// Looking it up beats closing over the `LimitWindow`: a captured value made a held-open menu go
    /// on counting down to the reset of a window the poll had already replaced, reach "now", and
    /// stay pinned there until the menu was closed and reopened.
    ///
    /// Keyed on provider *and* id, because the id alone is only unique within a provider.
    private func window(id: String, provider: ProviderID) -> LimitWindow? {
        snapshots.first { $0.provider == provider }?.windows.first { $0.id == id }
    }

    private func errorRow(for provider: ProviderID) -> NSMenuItem {
        textRow { [weak self] in
            guard let self,
                  let section = self.snapshots.first(where: { $0.provider == provider }),
                  let error = section.failure else { return nil }
            return self.message(for: error, in: section)
        }
    }
```

- [ ] **Step 11: Make the error copy per-section**

Lines 766-777:

```swift
    /// A provider's error copy, plus the "you're looking at old numbers" note that only makes sense
    /// when that provider still has numbers on screen to be old.
    private func message(for error: Error, in snapshot: ProviderSnapshot) -> String {
        let description = (error as? UsageError)?.errorDescription ?? error.localizedDescription
        // Keyed on what is actually on screen *for this provider*: once `Freshness` drops its rows,
        // promising "showing data from…" would point at numbers that aren't there any more.
        guard !snapshot.displayable().isEmpty, let updatedAt = snapshot.updatedAt else {
            return description
        }
        // `Fmt.stamp`, never `Fmt.clock` — clock renders a bare time for any past date, so this line
        // once claimed a fifteen-day-old reading was from "4:44 AM".
        return "\(description) Showing data from \(Fmt.stamp(updatedAt))."
    }
```

- [ ] **Step 12: Fix the remaining references**

Run: `swift build 2>&1 | grep -E "error:" | head -20`

Expect: `renderTitle()`'s `lastError`/`lastUpdated` branches (line 224-232), `refreshRow()`'s age
(line 748), and the Settings LIMITS SHOWN list (lines 471-492). For each:

- `renderTitle`'s empty branch: `"!"` when any snapshot has a failure, `"–"` when any has an
  `updatedAt`, `"…"` otherwise.
- `refreshRow`: use the newest `updatedAt` across snapshots —
  `snapshots.compactMap(\.updatedAt).max()`.
- LIMITS SHOWN: iterate `snapshots`, and build each row's id with
  `section.provider.qualify(window.id)` so the selection matches `Settings.titleLimitIDs`.

- [ ] **Step 13: Run the suite and check the live menu**

```bash
swift test --disable-xctest 2>&1 | tail -3
./build.sh && pkill -f "MacOS/Cashew"; open build/Cashew.app
osascript -e 'tell application "System Events" to tell process "Cashew" \
  to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'
```

Expected: 405 tests pass, and the menu reads **exactly** as it did before this PR — three usage
rows, no `CLAUDE` heading, the same `CLAUDE CODE` session section, the same commands. A heading
appearing here is a bug, not a feature; it means `headingsNeeded` counted an empty snapshot.

- [ ] **Step 14: Commit**

```bash
git add Sources/ Tests/
git commit -m "refactor: render a dropdown section per provider

MenuController held one flat [LimitWindow], one lastUpdated and one
lastError, so two providers would have had to be called stale together
or fresh together, and one provider's failure would blank the other's
status line. It now renders [ProviderSnapshot], each with its own
freshness and its own error row.

Headings appear only once there is more than one section to tell apart,
so a Claude-only menu is exactly what it was before providers were a
concept — which is what keeps this PR free of visible change.

Live rows key on provider and id together; an id is only unique within
its provider."
```

---

### Task 6: Documentation, guards, and the pull request

**Files:**
- Modify: `CLAUDE.md` (hard rule 5, architecture table, the Kind note)
- Modify: `SECURITY.md`, `README.md` (the two-host promise)
- Test: the whole suite, plus a live check

- [ ] **Step 1: Rewrite hard rule 5 in `CLAUDE.md`**

```markdown
5. **One usage endpoint per detected provider, plus `api.github.com`** for a once-a-day update check
   the user can turn off. Each provider declares its single host as `UsageProvider.host`, and a
   provider is only contacted when its credentials are present — so a user with only Claude Code
   installed produces exactly the traffic Cashew produced when Claude was the only provider. No
   analytics, no identifiers, no downloads.
```

- [ ] **Step 2: Add the `Kind` note to `CLAUDE.md`**

Under the response-shape traps:

```markdown
**`LimitWindow.Kind` names rank, not duration**, and that is load-bearing rather than cosmetic. A
provider may report a window of any length in its primary slot — Codex sends a 30-day primary window
on a free plan and a short one on paid, in the same field. A kind derived from duration would
therefore change when a user upgrades their plan, taking the window's id with it: the title
selection resets, the forecast history is orphaned, and its threshold alerts fire again for a limit
that did not change. Nothing may infer a kind from a duration.
```

- [ ] **Step 3: Update the architecture table**

Add rows for `ProviderID` / `ProviderSnapshot` (in `UsageAPI.swift`) and note that `AppDelegate`
owns one poll timer, backoff streak and generation counter *per provider*.

- [ ] **Step 4: Update `SECURITY.md` and `README.md`**

Both currently promise two hosts. Use the hard-rule-5 wording, and keep the sentence that a
Claude-only user's traffic is unchanged — it is the part a reader actually cares about.

- [ ] **Step 5: Full verification**

```bash
swift test --disable-xctest 2>&1 | tail -3
grep -rnE 'Credentials\.(keychainItemExists|fileExists)' Tests/ || echo "guard clean"
grep -rnE '(print|NSLog|debugPrint|os_log)[^\n]*[Tt]oken' Sources/ Tests/ \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || echo "no token logging"
./build.sh
```

Expected: 405 tests pass, both guards clean, build succeeds.

- [ ] **Step 6: Open the PR**

```bash
git push -u origin refactor/multi-provider-plumbing
gh pr create --title "refactor: poll, fail and render per provider" --body "$(cat <<'BODY'
PR 1 of the multi-provider work in `docs/superpowers/specs/2026-09-21-multi-provider-usage-design.md`.
**Adds no provider and changes no behaviour** — Claude is still the only provider, and the menu
renders exactly as it did. The pre-existing 391 tests are the safety net; they all still pass.

### What moved

- `LimitWindow.Kind` names **rank** (`.primary` / `.secondary` / `.secondaryScoped`), not duration.
  A provider may report a window of any length in its primary slot, so a duration-derived kind would
  change when a user's plan changes — taking the window's id, its history and its alert markers with it.
- `ProviderSnapshot` is the unit of state: windows plus that provider's own `updatedAt` and failure.
  A flat list carries one of each, so with two providers it must call both stale or neither.
- Polling, `Backoff`, the rate-limit streak and the fetch-generation counter are **per provider**.
  The generation counter mattered most: a single one meant any provider's fetch invalidated every
  other provider's in-flight reply.
- The statusline overlay applies to Claude's snapshot alone — it is Claude Code's live feed, not the
  app's.
- Storage keys are qualified (`claude:session`) at exactly three boundaries: the notification dedup
  key, `Sample.limitID`, and the title-selection set.
- Providers declare `id`, `host` and `credentialsExist()`. The Claude probe uses
  `kSecReturnAttributes` without `kSecReturnData`, so discovery cannot raise a Keychain prompt, and
  it is injected so the logic is testable without reading a real login.

### One on-disk consequence

`Kind`'s raw values are encoded into `snapshot.json`, so an existing snapshot stops decoding. That
path is already `try?`-guarded and returns nil, costing one cold start its last-good reading. There
is no installed base to migrate; the spec records this.

### Verification

- `swift test --disable-xctest` — 405 tests, 0 failures
- Live menu checked via `osascript`: identical to before, no provider heading with one provider
- CI's token-logging and never-call-from-a-test greps clean, with two new entries added

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

## Self-review notes

Checked against the spec:

- Per-provider snapshot, failure isolation, per-provider backoff — Task 4 ✅
- `Kind` as rank, both `Forecast` switches — Task 1 ✅
- `qualifiedID` at exactly three storage boundaries — Task 2 ✅
- `credentialsExist()` non-decrypting **and** injectable, CI grep — Task 3 ✅
- Sectioned panel — Task 5 ✅
- Hard rule 5 per-provider, docs — Task 6 ✅
- `fetchGeneration` per provider — Task 4, Step 5 ✅
- Statusline overlay Claude-only — Task 4, Step 8 ✅

Deferred to PR 2, per the spec: `CodexProvider`, `CodexCredentials`, discovery UI in Settings, the
menu bar provider glyph. `ProviderID.codex` exists from Task 2 so storage keys and tests can
exercise two providers, but nothing constructs a Codex provider in this PR.
