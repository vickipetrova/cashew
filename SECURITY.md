# Security

Cashew handles one thing that is sensitive by nature — your Claude Code OAuth token — and, if you
turn session tracking on, a few that are sensitive by context: where you are working, and the tail
of the transcript it checks to tell an interrupted turn from a finished one.

Here is exactly what happens to all of it.

## What it reads

The access token Claude Code already stores, from either of:

- The macOS login Keychain, generic password, service `Claude Code-credentials`
- `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`

When both exist Cashew ranks them rather than taking the first it finds, so a stale leftover file
can't shadow the login Claude Code is actively refreshing. In order: a file containing a bare token
wins outright — Claude Code never writes that shape, so it can only be a deliberate override you put
there yourself; otherwise whichever expires later wins; and a tie goes to the Keychain, matching
Claude Code's own precedence.

The Keychain read goes through `Security.framework` in-process (`SecItemCopyMatching`), not by
shelling out to `/usr/bin/security` — so the token never crosses a pipe or appears in any
subprocess's output.

Cashew reads the token fresh for each request and drops it. It never caches it, writes it to
disk, or copies it anywhere. Nothing in the source prints or logs it, and CI fails the build if a
`print`/`NSLog` mentioning a token appears in `Sources/`.

### And, with session tracking on, two things that are not the token

Both are read and immediately discarded. Neither is stored, logged, or sent anywhere.

**The tail of each tracked session's transcript.** Claude Code does not fire a `Stop` hook when you
interrupt a turn with Esc, so the only way to know a turn ended that way is to look. Cashew reads
the **last 64,000 bytes** of the transcript, walks back to the last `user` or `assistant` entry, and
tests one thing: whether its text begins `[Request interrupted by user`. What it keeps is that
single true/false, in memory, keyed on the file's modification time so the read is skipped while
nothing changes. The conversation itself is parsed and thrown away — none of it reaches a variable
that outlives the check, a file, or the network.

**The nearest `.git/HEAD` at or above each session's folder**, to show the branch name next to the
project. Cashew walks up from the folder to find it, and when `.git` is a file rather than a
directory — a worktree or a submodule — it follows the `gitdir:` pointer inside, which can lead
outside the session's folder. Only the branch string is kept, and only in memory.

If you would rather Cashew did not open your transcripts at all, turn off
**Settings › Claude Code › Track sessions**. That is the switch that governs both reads — with it
off, neither happens.

## Where it goes

One usage endpoint per provider it detects credentials for, plus one more:

```
GET https://api.anthropic.com/api/oauth/usage                          (with your token)
GET https://api.github.com/repos/vickipetrova/cashew/releases/latest   (no token, at most once a day)
```

Each provider declares its single host, and Cashew only contacts a provider whose credentials it
found — so if Claude Code is the only one you have installed, this is exactly the traffic it has
always sent, unchanged. The second line above is the update check. It carries no token, cookie or identifier beyond a
`User-Agent: Cashew/<version>` header, never downloads anything, and can be turned off under
Settings. No telemetry, no analytics, no crash reporting, no third-party services.

Both sessions are ephemeral, so no response is cached to disk and no cookie outlives the process.
**Neither follows a redirect.** For the usage request that is what makes the destination above a
guarantee rather than an expectation: the token cannot be forwarded to another host even if the
endpoint starts returning a `Location`. The update check refuses them for consistency — it carries
no token, but it does send that `User-Agent`, and one rule that holds everywhere is easier to trust
than two rules with an exception.

### Two things it opens that aren't network requests

Neither sends anything anywhere; both are listed because "what does it talk to" is a fair question
and the answer should be complete.

- **The release page in your browser**, when you click `Update Available` — and only then. The URL
  is checked to be `https://github.com/vickipetrova/cashew/…` when it arrives *and* again when it is
  read back from preferences, so editing the stored value by hand cannot redirect that click.
- **System Settings › Notifications**, via `x-apple.systempreferences:`, from the alerts-blocked
  message. Entirely local.

There is also a **Copy Setup Snippet** button under Settings › Claude Code, which puts a fixed block
of shell script on your clipboard. It is the same text printed in the docs, with nothing of yours
in it.

## What it stores

In `UserDefaults` (`com.vickipetrova.cashew`), eleven keys and one marker per limit window. The
full list, because a partial one isn't worth much:

**The settings you choose**, each one a control in the menu — refresh interval, alert threshold,
colour mode, which limits appear in the menu bar title, whether sessions are tracked, which menu bar
animation, whether status words show, and whether to check for updates.

**Two the update check keeps for itself** — when it last *tried*, successful or not, and the newest
release it has been offered (`tag_name` and `html_url`, nothing else). The first is a timestamp of
when Cashew was running; the second only ever holds a version newer than the one you have, so it is
empty until there is an update to tell you about.

**One developer switch with no menu item**, `allowHooksOutsideApplications`, which lets a build
outside `/Applications` install hooks. It exists for working on Cashew and is documented in
`CLAUDE.md`; you will not set it by accident.

**One marker per limit window**, recording which reset period was already alerted on and at what
threshold, so sitting at 85% doesn't alert on every poll.

Limit identifiers appear in two of those, and for a per-model weekly limit the identifier contains
the model's display name exactly as the API reported it. Your menu bar choices store them as values
(`scoped:Opus`); each alert marker puts one in its key (`notified.scoped:Opus`). So the model names
your plan reports do reach disk.

What is *not* there: no usage percentages, no history of your usage, and nothing that identifies
your account. The alert markers do carry one time — the reset the period belongs to, rounded to the
minute, which is the whole point of a marker. That rounding is deliberate: the endpoint re-stamps
`resets_at` with new fractional seconds on every single request, so a marker keyed on the raw value
would look like a new period each poll and alert you every time.

Launch at Login is stored by macOS, not by Cashew. No credentials and no logs.

### On disk

Two files:

```
~/Library/Application Support/com.vickipetrova.cashew/history.json
~/Library/Application Support/com.vickipetrova.cashew/snapshot.json
```

Both are written whenever Cashew has a reading in hand — after a successful poll, and then on the
same once-a-minute tick that drives the countdowns, for the rest of that run. If you opted into the
Claude Code statusline feed, a reading arriving that way counts too, so these files can be written
on a run where no poll ever succeeded.

`history.json` is what the burn-rate forecast is computed from: a timestamp, a limit identifier, and
a utilization percentage, one entry per limit. Anything older than seven days is dropped on every
write.

`snapshot.json` is the single most recent reading kept whole — the percentages, each window's
identifier and kind, the display strings it is labelled with, and its reset time, plus the moment
the reading was taken — so that a launch which can't reach the API
can still show the numbers it last had, labelled with when they were from, instead of an error over
an empty panel.

As above, a per-model limit's identifier and heading contain the model's display name as the API
reported it, so those names appear in both files.

A third file may appear in the same directory, `statusline.json`, but **Cashew never writes it** —
it only reads it. It exists if you opted into the Claude Code statusline shortcut described in
[docs/LIVE-UPDATES.md](docs/LIVE-UPDATES.md), in which case your own statusline script writes it.
The snippet there filters the payload down to `rate_limits` before writing, so the working
directory, session id, transcript path and cost that Claude Code also passes stay out of it. If you
wrote your own variant that stores more than that, it stores what you told it to; Cashew reads only
`rate_limits` either way.

In `~/Library/Application Support/com.vickipetrova.cashew/sessions/`, one small file per live
Claude Code session, **named after the session's own id** (sanitized, and cut to 64 characters).
Each holds: the session's state and the plain phrase for what it is doing, the folder you're working
in, the transcript's path, the *name* of the tool in use, the Claude Code process id, two timestamps
— when the current turn started, and when the file was last touched — a flag for whether the session
has done anything yet, and a schema version. That is the complete list. Never prompt text, tool
input or output. Deleted when the session ends, when the Claude Code process is gone, or after a day
untouched.

One consequence of storing a tool's name worth spelling out: for an MCP tool the name is the whole
identifier, `mcp__<server>__<action>`. So these files can reveal **which MCP servers you have
configured** — still only names, never arguments or results.

In `~/.claude/settings.json`, Cashew's own hook entries for ten events (`SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`,
`PermissionRequest`, `Stop`, `StopFailure`, `SessionEnd`) — commands that run Cashew's bundled
`Contents/Helpers/cashew-hook` — with a one-time backup of the original at
`~/.claude/settings.json.bak-cashew`.

Cashew changes no other key, and no other tool's hooks. It does, on the first write, **reformat the
file**: it is rewritten indented and with the keys sorted alphabetically. Every value is preserved
exactly; only the layout and key order change. That is why the backup is taken before the first
write, and why a file Cashew cannot parse is reported rather than replaced.

That is everything. No token, nothing derived from a token, no account identifier, no request or
response bodies, and no prompt text, tool input or tool output.

Read plainly: the usage files say only how full each quota was and when. The session files do say
*where* you were working — the project folder and the transcript's path — which tool was running,
and which MCP servers you use. The branch is not among them: it is shown in the menu but never
written down, and Cashew re-reads it from `.git/HEAD` each time it needs it.

They do not say what the conversation contained, and although Cashew *reads* your transcript to spot
an interrupted turn, it keeps nothing from it but a yes-or-no. Delete any of these whenever you like; Cashew starts fresh and the forecast reappears
once there are samples to draw a line through.

## Reporting a problem

For anything non-sensitive, [open an issue](../../issues). For a vulnerability, use GitHub's
private vulnerability reporting on this repository (Security › Report a vulnerability).

**Never include your token, your credentials file, or a screenshot showing them in a report.** If
you think your token has been exposed, sign out of Claude Code and sign back in — that rotates it.

## Scope note

Cashew is unofficial and reads an undocumented endpoint. It cannot change your plan or spend
money, and the only thing it ever writes into your Claude Code setup is its own hook entries in
`~/.claude/settings.json`, toggled from Settings and removed the moment you turn tracking off. But
it is a side project maintained by one person and audited by whoever reads the source — which is the
point of keeping it this small.
