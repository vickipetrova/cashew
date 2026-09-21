# Usage metrics from more than one provider — design

**Date:** 2026-09-21
**Target:** Codex (OpenAI) alongside Claude Code, on a seam that takes a third provider without redesign
**Status:** awaiting review

## The question this answers

Cashew reads one provider's usage. `MenuController` already renders `[LimitWindow]` and knows
nothing about where the numbers came from, so the *rendering* seam exists. What does not exist is
any way to poll two providers, fail at one without failing at the other, or tell two windows apart
once they are both called `session`.

This spec covers that. Session tracking — hooks, transcripts, status words — is **not** in scope;
see [Out of scope](#out-of-scope).

Six decisions were settled before writing this, and the rest follows from them:

| Decision | Choice | Why |
|---|---|---|
| Model shape | Per-provider snapshot, `LimitWindow` untouched | Providers fail independently; a flat list cannot express it |
| `LimitWindow.Kind` | Rank, not duration: `.primary` / `.secondary` / `.secondaryScoped` | A duration-derived kind changes when the user's plan changes |
| Menu bar title | Existing picker over namespaced ids, glyph only when >1 provider shown | Single-provider users see today's title, unchanged |
| Discovery | Auto-detect; a provider with no credentials does not appear | Matches "needs no setup of its own" |
| Network rule | Per provider, contacted only when detected | A Claude-only user's traffic is unchanged |
| Sequencing | Two PRs: plumbing, then Codex | The refactor is behaviour-preserving and the 391 tests prove it |

Migration is deliberately absent: the project has effectively no installed base at 0.1.0, so
namespaced ids are written fresh rather than migrated. The one visible consequence is that a
menu-bar title selection made before the change is not carried across.

## Why a per-provider snapshot, and not a flag on the window

The cheap version of this feature namespaces `LimitWindow.id` to `"claude:session"`, keeps one flat
array, and parses the provider back out of the prefix. It does not work, for a reason that has
already cost this project fifteen days of dead menu bar once.

**Providers fail independently.** Claude can be serving 200s while Codex returns 429 with a
`Retry-After`. `UsageError.rateLimited` carries that header and `Backoff.delay` turns it into a
schedule — per provider, or one rate-limited provider stalls the other, which is precisely the
failure `reschedulePoll` was fixed to prevent.

A flat array also has one `updatedAt`. `Freshness.displayable(_:updatedAt:now:)` is the single
definition of whether a reading is still worth showing, used by the panel, the title, the error copy
and `restorableSnapshot`. Given one timestamp for two providers it must either mark both stale or
neither, and both answers are wrong.

So the unit of state is the provider, not the window:

```swift
enum ProviderID: String, Codable { case claude, codex }

struct ProviderSnapshot {
    let provider: ProviderID
    let windows: [LimitWindow]
    let updatedAt: Date?
    let failure: UsageError?
}
```

`LimitWindow` keeps its shape, its `Codable` representation and its four parsing traps. Everything
that operates on `[LimitWindow]` — `Forecast`, `Fmt`, `UsageRow`, `TitleSelection`,
`Freshness.displayable` — keeps its current signature and applies per snapshot.

The protocol gains identity, a declared host, and a presence check:

```swift
protocol UsageProvider {
    var id: ProviderID { get }
    static var host: String { get }
    func credentialsExist() -> Bool
    func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void)
}
```

**`credentialsExist()` must never decrypt.** For Claude that means `SecItemCopyMatching` with
`kSecReturnAttributes` and *without* `kSecReturnData`: presence without decryption, so discovery
cannot fire the Keychain permission prompt. A discovery check that prompts would be worse than no
discovery at all.

## Why `Kind` becomes rank rather than duration

Today:

```swift
enum Kind: String, Equatable, Codable {
    /// The short rolling window (Claude Code: 5 hours).
    case session
    /// The long window, across everything.
    case weekly
    /// The long window, narrowed to one model. A provider may report several.
    case weeklyScoped
}
```

The doc comments already describe these by **rank** — short window, long window, long window
narrowed. Only the case names encode Anthropic's particular cadence. The rename below is therefore
closer to making the type say what it already means than to changing it.

`Forecast` meanwhile leans on those names as a stand-in for how long the window is:

```swift
/// A session window is five hours, so 90 minutes is long enough to smooth out a single burst...
/// A weekly window is 168 hours, where the same reasoning lands on a day.
case .session: return 90 * 60
case .weekly, .weeklyScoped: return 24 * 60 * 60
```

Codex reports `limit_window_seconds`, and on the free plan its **primary** window is 30 days. The
tempting fix — a fourth case for long windows, or deriving the case from the duration — is wrong,
and not marginally:

> A paid plan reports a short rolling window in the *same* `primary_window` field. A kind derived
> from duration therefore changes when the user upgrades their plan. The id changes with it, which
> resets the title selection, orphans the window's forecast history, and re-fires its 80% and 95%
> notifications as though it were a new limit.

Duration is a property of the plan. Identity must not depend on it.

```swift
enum Kind: String, Equatable, Codable { case primary, secondary, secondaryScoped }
```

| Provider | Window | Kind |
|---|---|---|
| Claude | 5-hour | `.primary` |
| Claude | weekly, all models | `.secondary` |
| Claude | weekly, one model | `.secondaryScoped` |
| Codex | `primary_window` | `.primary` |
| Codex | `secondary_window` | `.secondary` |

This is also the vendor's own vocabulary — OpenAI named the fields `primary_window` and
`secondary_window`.

Both rules that branch on `Kind` survive the rename unchanged in meaning: the long window tints the
title on an `.onPace` forecast and the short one does not; the short window looks back 90 minutes
and the long one a day.

Nothing user-facing moves. `label` is a stored `String` the provider computes, so Claude still says
`SESSION · 5-HOUR` and `WEEKLY · ALL MODELS`, and Codex derives its heading from
`limit_window_seconds`.

### A deferred limitation, recorded deliberately

Codex's 30-day window gets the `.primary` lookback of 90 minutes, which is far too short for a
window that moves about 0.14% a day.

The effect is benign and worth stating so it is not mistaken for a bug: `Forecast` requires the
samples to span a quarter of the trailing window **and** to move more than one point, so it returns
`.unknown` and renders no forecast. Quiet, not wrong — the direction this codebase already errs in.

The real fix is to derive the lookback from a reported window duration rather than from `Kind`. It
is deferred because there is exactly one real duration to design against and no paid-plan response
to check a formula against. Guessing a formula now would be inventing a rule with no way to falsify
it.

## What Codex actually returns

Probed against a live free-plan account on 2026-09-21. Identifiers redacted; every other value is
verbatim.

`GET https://chatgpt.com/backend-api/codex/usage`
with `Authorization: Bearer <access_token>` and `ChatGPT-Account-Id: <account_id>` → `200`

```json
{
  "user_id": "<redacted>",
  "account_id": "<redacted>",
  "email": "<redacted>",
  "plan_type": "free",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 0,
      "limit_window_seconds": 2592000,
      "reset_after_seconds": 2592000,
      "reset_at": 1792604585
    },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": null,
  "model_usage": {},
  "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false,
               "balance": null, "approx_local_messages": null, "approx_cloud_messages": null },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "rate_limit_reset_credits": { "available_count": 0, "applicable_available_count": 0 }
}
```

`https://chatgpt.com/backend-api/wham/usage` returns a byte-identical body. Only the `codex/usage`
form is implemented; the alias is recorded here, not coded against.

`https://chatgpt.com/backend-api/api/codex/usage` — the path that appears in the binary's string
table — returns `404`. Worth recording, because reading endpoint paths out of a binary is how this
document nearly acquired a `window_minutes` field that does not exist.

### Mapping

| Response | → | `LimitWindow` |
|---|---|---|
| `rate_limit.primary_window` | → | `kind: .primary` |
| `rate_limit.secondary_window` | → | `kind: .secondary`; **the row is dropped when null** |
| `used_percent` | → | `utilization`, clamped 0–100, finiteness-checked, `isJSONBoolean`-guarded |
| `reset_at` | → | `resetsAt`, **epoch seconds** |
| `reset_after_seconds` | → | fallback for `resetsAt` when `reset_at` is absent |
| `limit_window_seconds` | → | the `label` text |
| `plan_type` | → | copy for a plan with no usable window |

Two hazards specific to this provider:

- **`reset_at` is epoch seconds.** Claude's `expiresAt` is milliseconds. Two vendors, two units, one
  codebase, and both are plain numbers that parse without complaint at the wrong scale — read as
  milliseconds, `reset_at` lands three weeks after the epoch.
- **The heading cannot be hardcoded.** Claude's `WEEKLY` is safe because the cadence is fixed.
  Codex's is server-reported and differs by plan, so the label is derived from
  `limit_window_seconds` and a 30-day window must not be printed as "weekly".

Hard rule 3 applies unchanged: a missing, null or wrong-typed field drops **that row** and renders
`–`. `secondary_window: null` is the common case, not an error.

## Credentials

`~/.codex/auth.json`, mode `0600`, written by `codex login`:

```
auth_mode: "chatgpt"
tokens: { id_token, access_token, refresh_token, account_id }
last_refresh: ISO8601
```

**There is no Keychain item.** Seven candidate service names and a full keychain scan for anything
matching "codex" found nothing. So none of `Credentials.swift`'s machinery has an analogue here:
there is one source, so no file-versus-Keychain ranking, no `.accessDenied` latch, no serial queue
guarding a modal prompt.

The access token is a JWT carrying `exp` and `chatgpt_plan_type`. **Neither is parsed.** There is one
credential with no alternative to rank it against, so an expiry serves no purpose except to invent a
staleness rule Cashew would then have to keep in step with OpenAI's; an expired token returns 401 and
that is the honest signal. Plan type arrives in the response.

Cashew never writes this file, never runs `codex`, never holds the refresh token, and never
authenticates. When the file is absent the provider is not shown; when the token is rejected the
section says so and points at `codex login`, exactly as the Claude section points at opening a
session.

## Work items

### PR 1 — provider-agnostic plumbing

No behaviour change. Claude remains the only provider; the existing 391 tests are the safety net.

1. `ProviderID`, `ProviderSnapshot`, and `UsageProvider` gaining `id` / `host` / `credentialsExist()`.
2. `LimitWindow.Kind` renamed to `.primary` / `.secondary` / `.secondaryScoped`, with the two
   `switch` statements in `Forecast` updated. The id constants beside it — `sessionID`, `weeklyID`,
   `scopedID(model:)` — rename with it and stay *unqualified*: they name a window within its
   provider, and qualification happens only at the storage boundary in item 4.
3. `AppDelegate` holds `[UsageProvider]` and `[ProviderSnapshot]`; per-provider poll scheduling and
   `Backoff`.
4. `qualifiedID(provider:window:)` → `"claude:session"`, applied at exactly three storage
   boundaries: `Notifier`'s dedup key, `UsageHistory.Sample.limitID`, and the title-selection set.
   Nowhere else.
5. `MenuController` renders a section per snapshot; `UsagePanel` gains a provider heading.
   Section order is fixed, so rows cannot reorder under a click already in flight.

### PR 2 — the Codex provider

1. `CodexCredentials` — read `~/.codex/auth.json`, return token and account id, or absent.
2. `CodexProvider` — the endpoint client and all response parsing, defensive per hard rule 3.
3. Discovery and the **Providers** section in Settings: one switch per *detected* provider.
   If neither provider is detected, Claude is still shown with its existing sign-in guidance —
   otherwise a fresh install renders a blank menu with no explanation.
4. Menu bar glyph, shown only when limits from more than one provider are selected.
5. Docs, below.

### Documentation changes

- **`CLAUDE.md` hard rule 5** becomes per-provider: one usage endpoint per *detected* provider, plus
  the once-a-day GitHub update check. Unchanged in substance — no analytics, no identifiers, no
  downloads — and a Claude-only user's traffic is byte-for-byte what it is today.
- **`SECURITY.md`** and **`README.md`** carry the same wording; both currently promise two hosts.
- **`CLAUDE.md`** architecture table gains the new files and records the `reset_at` seconds /
  `expiresAt` milliseconds hazard next to the existing ISO8601 traps.
- **`docs/TROUBLESHOOTING.md`** gains "My Codex usage doesn't appear" → run `codex login`; Cashew
  reads what the CLI already wrote and cannot sign you in.

## Out of scope

- **Session tracking for Codex.** Hooks, transcripts, status words, the `CLAUDE CODE` dropdown
  section. Codex configures through `config.toml`, and hard rule 6's guarantees — never write a file
  you could not parse, back it up once, change only your own entries — would require a TOML editor
  written under hard rule 2's zero-dependency constraint. That is a separate spec.
- **A forecast lookback derived from window duration.** Deferred above, with reasons.
- **The `wham/usage` alias**, `model_usage`, `credits`, `spend_control`, `promo`, and
  `rate_limit_reset_credits`. Recorded in the response above; none drive a row.
- **Refreshing an expired Codex token.** Cashew reports, the CLI refreshes.
- **A third provider.** The seam is built so one can be added; none is.

## Testing

Everything below runs under `swift test --disable-xctest`.

**Parsing** feeds **JSON text** through `JSONSerialization`, never Swift dictionary literals — values
have to arrive as the `NSNumber`s a real response produces, or the boolean and integer bridging paths
go untested. Fixtures:

- the free-plan response above, verbatim, including `secondary_window: null`
- a two-window response built from the observed field names, so the paid shape has coverage even
  though it is unverified against a live paid account
- `used_percent` as `true` — must drop the row, not read as 1%
- `reset_at` absent, with `reset_after_seconds` present — must fall back
- `reset_at` at a plausible epoch-seconds value — must not land in 1970
- a `rate_limit` object that is missing, null, or not an object

**Isolation:** a snapshot whose provider failed renders its error while the other snapshot still
renders numbers; one provider's `Retry-After` does not change the other's poll schedule.

**Identity:** `qualifiedID` is distinct across providers for the same `Kind`; a window's id is stable
when `limit_window_seconds` changes, which is the plan-upgrade case the `Kind` decision exists for.

**Discovery:** `credentialsExist()` returns false with no file present, and the Claude
implementation is asserted not to request `kSecReturnData`.

Per the existing rule, `CodexProvider.fetch` is added to the CI grep of things a test never calls —
it reaches the real network with a real token.

## Sequencing

1. PR 1, plumbing, behaviour-preserving, green on the existing suite.
2. PR 2, the Codex provider and its docs.

Both through pull requests; `main` is protected and the `build` check gates the merge.
