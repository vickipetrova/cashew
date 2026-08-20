# Security

Headroom handles one sensitive thing: your Claude Code OAuth token. Here is exactly what happens
to it.

## What it reads

The access token Claude Code already stores, from either of:

- The macOS login Keychain, generic password, service `Claude Code-credentials`
- `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`

When both exist Headroom compares their expiry timestamps and uses whichever lives longest, so a
stale leftover file can't shadow the login Claude Code is actively refreshing.

The Keychain read goes through `Security.framework` in-process (`SecItemCopyMatching`), not by
shelling out to `/usr/bin/security` — so the token never crosses a pipe or appears in any
subprocess's output.

Headroom reads the token fresh for each request and drops it. It never caches it, writes it to
disk, or copies it anywhere. Nothing in the source prints or logs it, and CI fails the build if a
`print`/`NSLog` mentioning a token appears in `Sources/`.

## Where it goes

One destination, one request:

```
GET https://api.anthropic.com/api/oauth/usage
```

That's the entire network surface. No telemetry, no analytics, no crash reporting, no update
checks, no third-party services. The URLSession is ephemeral, so no response is cached to disk, and
it refuses every redirect — the token cannot be forwarded to another host even if the endpoint
starts returning one.

## What it stores

In `UserDefaults` (`com.vickipetrova.headroom`) only:

- your four preferences: refresh interval, alert threshold, colour mode, and which limits you chose
  to show in the menu bar title
- one marker per limit window, recording which reset period was already alerted on and at what
  threshold, so you don't get the same alert twice

Both of those involve limit identifiers, and for a per-model weekly limit the identifier contains the
model's display name exactly as the API reported it. Your menu bar choices store them as values
(`scoped:Opus`); each alert marker puts one in its key (`notified.scoped:Opus`). So the model names
your plan reports do reach disk. That is the whole extent of it: no percentages, no reset times, no
history of your usage, and nothing that identifies your account.

Launch at Login is stored by macOS, not by Headroom. No credentials and no logs.

### On disk

Two files, both written after a successful poll and only after a successful poll:

```
~/Library/Application Support/com.vickipetrova.headroom/history.json
~/Library/Application Support/com.vickipetrova.headroom/snapshot.json
```

`history.json` is what the burn-rate forecast is computed from: a timestamp, a limit identifier, and
a utilization percentage, one entry per limit per poll. Anything older than seven days is dropped on
every write.

`snapshot.json` is the single most recent reading kept whole — the same percentages plus each
window's heading and reset time — so that a launch which can't reach the API can still show the
numbers it last had, labelled with when they were from, instead of an error over an empty panel.

As above, a per-model limit's identifier and heading contain the model's display name as the API
reported it, so those names appear in both files.

That is everything. No token, nothing derived from a token, no account identifier, no request or
response bodies, and nothing that says what you were working on — only how full each quota was and
when. Delete them whenever you like; Headroom starts fresh and the forecast reappears once there are
samples to draw a line through.

## Reporting a problem

For anything non-sensitive, [open an issue](../../issues). For a vulnerability, use GitHub's
private vulnerability reporting on this repository (Security › Report a vulnerability).

**Never include your token, your credentials file, or a screenshot showing them in a report.** If
you think your token has been exposed, sign out of Claude Code and sign back in — that rotates it.

## Scope note

Headroom is unofficial and reads an undocumented endpoint. It cannot change your plan, spend money,
or modify anything in your Claude Code setup; it only reads. But it is a side project maintained by
one person and audited by whoever reads the source — which is the point of keeping it this small.
