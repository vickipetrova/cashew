# Headroom

Your Claude Code plan usage, in the macOS menu bar:

```
✻ 42% · 67%
```

Session (5-hour window) on the left, this week on the right. Click for reset times, live
countdowns, and per-model weekly limits when your plan reports them.

<!-- HERO GIF: record the menu bar with the dropdown open, save it as assets/headroom.gif,
     and uncomment the line below.
<img src="assets/headroom.gif" alt="Headroom in the menu bar, with the dropdown open" width="420">
-->

**Zero setup.** No cookies, no DevTools, nothing to paste. Headroom reads the OAuth token Claude
Code already has and asks Anthropic the same question `/usage` does.

## How it works

Every five minutes (configurable), Headroom sends one request:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <your Claude Code token>
anthropic-beta: oauth-2025-04-20
```

The token comes from wherever Claude Code keeps it — the macOS login Keychain (generic password,
service `Claude Code-credentials`) or `~/.claude/.credentials.json`. If both exist, Headroom uses
whichever one lives longest, so a leftover file can't shadow your live login.

Claude Code refreshes that token itself while you work, so there is nothing to maintain. If it has
gone stale because you haven't opened Claude Code in a while, the menu says so.

The first Keychain read prompts for permission, because Claude Code's Keychain item only trusts the
app that created it. Note that "Always Allow" won't stick across a rebuild if you built from source —
ad-hoc signatures change every time, so macOS sees a different app.

Because this is account-level data rather than session lifecycle, it keeps working when Claude Code
is closed.

> [!NOTE]
> **This endpoint is undocumented and community-discovered.** It is not a public API, and Anthropic
> can change or remove it without notice — it has already grown a second response shape alongside
> the original one. Headroom treats every field as optional: anything missing, null, or unexpected
> renders as `–` rather than crashing. If the numbers ever look wrong, check `/usage` inside Claude
> Code and [open an issue](../../issues) if they disagree.

## Install

### Build from source

```bash
git clone https://github.com/vickipetrova/headroom.git
cd headroom
./build.sh
cp -R build/Headroom.app /Applications/
open /Applications/Headroom.app
```

That's the whole toolchain: the Xcode Command Line Tools. No Xcode project, no third-party
dependencies. Tests run with `swift test --disable-xctest` — plain `swift test` needs XCTest, which
the Command Line Tools don't ship.

`swift run` won't work, and that's expected — it produces a bare binary with no `Info.plist`, so
there's no `LSUIElement`, no bundle identity for login items, and no notification registration.
`./build.sh && open build/Headroom.app` is the way to run it.

### DMG

Download the latest `Headroom.dmg` from [Releases](../../releases), open it, and drag Headroom into
Applications.

## Requirements

- **macOS 13+** (Ventura). Launch at login uses `SMAppService`, which is 13.0 and later.
- **A Claude Pro or Max plan.** Session and weekly windows are plan quotas. Metered API-key
  accounts don't have them, so there is nothing for Headroom to show — it says so plainly instead
  of showing zeroes.
- **Claude Code, signed in at least once**, so there's a token to read. If you set
  `CLAUDE_CONFIG_DIR`, Headroom won't find your login — Claude Code moves both the credentials file
  and the Keychain service name to match, and an app launched from Finder can't see that variable.

## Settings

Everything lives in the dropdown under **Settings**:

| Setting | Options | Default |
|---|---|---|
| Refresh every | 1 / 5 / 15 minutes | 5 minutes |
| Notify above | Off / 50% / 80% / 90% | 80% |
| Show in Menu Bar | any combination of the limits your plan reports | Session + Weekly |
| Colors | Alerts only / System | Alerts only |
| Live from Claude Code | on / off status, and setup when it's off — see [below](#live-usage-from-claude-code) | off |
| Launch at Login | on / off | off |

**Show in Menu Bar** picks which numbers appear in the title. The list is built from whatever the
API currently reports, so a per-model limit shows up by name once your plan has one. Choices are
stored against each limit's identifier rather than its name, so a limit that disappears for a while
comes back selected rather than silently reset — and at least one always stays on.

**Colors** decides how much the menu bar and the panel use colour. *Alerts only* keeps the spark
orange and everything else in the ordinary label colour until usage is worth noticing, then turns
yellow at 50% and red at 80% — so colour means "look at this" rather than being permanently on.
*System* is fully monochrome: the thresholds stop applying entirely and the spark becomes a template
image, so the whole item adapts like a built-in menu bar control.

Alerts fire at most once per window per reset period, so sitting at 85% doesn't produce an alert on
every poll. Lowering the threshold mid-window counts as a new crossing and will alert again.

macOS asks for notification permission the first time Headroom runs with alerts switched on. If you
decline — or later switch Headroom off in System Settings › Notifications — the menu says
*"Alerts blocked — open Notification settings"* rather than silently never alerting you.

## Live usage from Claude Code

Optional, and off until you add one line.

Claude Code already knows your plan usage — it hands `rate_limits.five_hour` and
`rate_limits.seven_day` to whatever statusline command you've configured, every time it renders,
which is far more often than Headroom polls. Let Headroom read that and **your session and weekly
numbers become live instead of up to fifteen minutes old**, updating as you work rather than on a
timer.

Headroom will **not** edit `~/.claude/settings.json`. Your statusline is yours, and quietly replacing
it to install a helper would be a bad trade for a menu bar app. So opting in is something you do, in
one of two ways depending on whether you already have a statusline.

### You already have a statusline script

Add this right after the line that reads stdin (usually `input=$(cat)`). **Settings › Set Up Live
Updates…** shows the same line with a button to copy it:

```bash
{ mkdir -p "$HOME/Library/Application Support/com.vickipetrova.headroom" \
  && printf '%s' "$input" | jq -c '{rate_limits}' \
     > "$HOME/Library/Application Support/com.vickipetrova.headroom/statusline.json"; } 2>/dev/null || true
```

If your script stores stdin under a different name than `input`, change `$input` to match.

### You don't have one yet

Most people don't. Save this as `~/.claude/headroom-statusline.sh` — it shows the model and the
current folder, and hands the usage numbers to Headroom:

```bash
#!/bin/bash
input=$(cat)

{ mkdir -p "$HOME/Library/Application Support/com.vickipetrova.headroom" \
  && printf '%s' "$input" | jq -c '{rate_limits}' \
     > "$HOME/Library/Application Support/com.vickipetrova.headroom/statusline.json"; } 2>/dev/null || true

printf '%s' "$input" | jq -r '"\(.model.display_name // "Claude") · \(.workspace.current_dir // "" | split("/") | last // "")"'
```

Then point Claude Code at it by adding this to `~/.claude/settings.json` (merge it into the existing
object if the file already has settings in it):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/headroom-statusline.sh"
  }
}
```

The statusline appears the next time Claude Code renders one — send a message in any session.

### Checking it works

**Settings › Live from Claude Code** shows what Headroom sees:

| Status | Meaning |
|---|---|
| On · updated 1m ago | Working. |
| On · last reading 3h ago | Set up, but Claude Code hasn't rendered a statusline in the last five minutes — normal when it's closed. Headroom falls back to polling. |
| Off | No reading has ever arrived. The line isn't in your script, or the script isn't the one in `settings.json`. |
| Not working — is jq installed? | The script runs but writes nothing. The snippet needs `jq`, which macOS 15 and later include; on macOS 13 or 14, `brew install jq`. |
| On · no plan limits reported | Readings arrive but carry no usage — an account without plan limits, or a session that hasn't made a request yet. |

Only `rate_limits` is written — not the working directory, session id, transcript path or cost that
the rest of the payload carries. Every failure is swallowed, so a broken snippet can never break your
statusline, which is also why the status above exists. Delete the line to opt out.

**It supplements polling rather than replacing it.** The statusline payload has no per-model
breakdown, so a `WEEKLY · OPUS` row can only come from the API — and an earlier version of this that
used the statusline *instead of* polling made that row blink in and out depending on whether a Claude
Code session happened to be open, which was worse than either source alone. Headroom keeps polling on
your normal schedule and overlays the live numbers on top, matched by limit, so no row ever
disappears.

Once the file is more than five minutes old Headroom stops trusting it and shows the polled numbers
alone — an idle session isn't refreshing the file, but idle usage isn't moving either. Nothing to
configure either way, and nothing changes if you skip this entirely.

## Why not the built-in menu bar?

Claude Code will tell you a number. `/usage` gives you the same percentages Headroom reads, and you
can look at them whenever you think to.

The gap isn't the number, it's the rate. **40% an hour into a five-hour window and 40% four hours in
are the same reading and opposite situations**, and nothing that samples once can tell them apart.
The first is a morning that ends fine. The second is a morning that ends at 3pm.

So Headroom keeps a short history of what each limit has read and works out how fast you're actually
moving. When that rate would reach the cap before the window resets, one line appears under the
limit:

```
On pace to hit the limit ~Thu 14:00
```

and, for a weekly limit, the percentage in the menu bar turns yellow even if it's nowhere near the
usual threshold — because a weekly limit you'll hit on Thursday is worth knowing about at 30%.

The rest of the time it says nothing at all. There is deliberately no "you're fine" message: a line
that reassures you every ordinary day is a line you stop reading, and then it goes unread on the day
it matters. Silence is the normal state, and the forecast appearing is the signal.

Two honest limits. It's a straight-line projection over a trailing window — 90 minutes for a session
limit, a day for a weekly one — so it assumes the next hour looks like the last, which it won't if
you stop for lunch or start a big refactor. And it needs a few samples before it will say anything,
so a freshly installed Headroom stays quiet for a while. When it can't tell, it says nothing rather
than guessing.

## Roadmap

Deliberately small for v0.1. Not planned by me, but very welcome as contributions — each of these is
[an open issue](../../issues) with the design questions written out:

- A historical sparkline of the session window — [#2](../../issues/2)
- Graceful mode for non-Pro/Max accounts — [#5](../../issues/5)
- Additional providers — Cursor, Codex, Copilot — behind the existing `UsageProvider` protocol — [#1](../../issues/1)
- Multiple accounts in one menu — [#12](../../issues/12)

The first two are tagged
[good first issue](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22); the rest are
[help wanted](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22), meaning they need a
design decision agreed in the issue before much code gets written.

Already shipped, and no longer on the list: a configurable menu bar title format and a
model-scoped-only mode, both of which the *Show in Menu Bar* setting covers.

Out of scope: cost dashboards, telemetry, anything needing an API key. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Other projects in this space

There are several good ones, and they solve different problems. If Headroom isn't the shape you
want, one of these probably is:

- **[ClaudeBar](https://github.com/tddworks/ClaudeBar)** — the big one. Tracks a dozen assistants
  (Claude, Codex, Gemini, Copilot, and more), themes, Homebrew cask.
- **[Claude Usage Bar](https://github.com/Blimp-Labs/claude-usage-bar)** — richer detail: usage
  history charts, per-model breakdown, extra-usage spend in USD.
- **[ClaudeUsageBar](https://github.com/Artzainnn/claudeusagebar)** — covers claude.ai usage too,
  not just Claude Code. Setup is copying a cookie out of DevTools.
- **[Claude Usage](https://github.com/richhickson/claudecodeusage)** — closest to Headroom in
  spirit: small, native, session and weekly at a glance.
- **[Claude Status Bar](https://github.com/m1ckc3s/claude-status-bar)** — a different question
  entirely: whether Claude Code is *currently* thinking, running a tool, or waiting on you. Pairs
  well with this one, and its repo is the template this one's build script follows.

Headroom's one distinguishing bet is that you shouldn't have to set anything up.

## Uninstall

```bash
rm -rf /Applications/Headroom.app
rm -rf ~/Library/Application\ Support/com.vickipetrova.headroom
defaults delete com.vickipetrova.headroom
```

If you turned on Launch at Login, switch it off first (or remove Headroom from System Settings ›
General › Login Items).

Those three lines are everything: the app, the usage history the forecast is computed from, and your
preferences. No caches, no logs, no config files anywhere else.

## Claude Code sessions

Headroom also shows what Claude Code is doing. The spark in the menu bar spins while a session is
working and gains a dot when one is waiting for your permission, and the dropdown lists each live
session with its project, branch, current step and how long the turn has run.

To do that, Headroom adds a small set of hooks to `~/.claude/settings.json` the first time it runs.
It changes nothing else in that file, keeps a one-time backup at
`~/.claude/settings.json.bak-headroom`, and records only each session's state, folder and tool
*names* — never your prompts or tool input. Sessions already open when the hooks are added appear
once they're restarted.

Turn it off under **Settings › Track Claude Code Sessions**, which removes the hooks. **Turn it off
before deleting Headroom**; if you forget, the leftover hooks do nothing and Claude Code ignores them.

Session tracking was inspired by [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
by Mick Cesanek.

## Security

Headroom reads your OAuth token, holds it in memory for one request, and sends it to exactly one
place: `api.anthropic.com`. It also asks GitHub once a day whether a newer Headroom exists (turn it
off under Settings). No telemetry, no analytics, no identifiers. See [SECURITY.md](SECURITY.md).

## Trademark / Not affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or
sponsored by Anthropic.** "Claude" and the Claude spark are trademarks of Anthropic, used here
nominatively. The MIT license below covers this source code only and conveys no rights to
Anthropic's trademarks or brand.

## License

MIT © Victoria Petrova. See [LICENSE](LICENSE).
