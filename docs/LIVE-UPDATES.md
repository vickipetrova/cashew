# Live usage from Claude Code

Optional, and off until you add one line.

Claude Code already knows your plan usage — it hands `rate_limits.five_hour` and
`rate_limits.seven_day` to whatever statusline command you've configured, every time it renders,
which is far more often than Cashew polls. Let Cashew read that and **your session and weekly
numbers become live instead of up to fifteen minutes old**, updating as you work rather than on a
timer.

Cashew will **not** edit the `statusLine` in `~/.claude/settings.json` (the only thing it ever
changes there is its own session-tracking hooks). Your statusline is yours, and quietly replacing
it to install a helper would be a bad trade for a menu bar app. So opting in is something you do, in
one of two ways depending on whether you already have a statusline.

## You already have a statusline script

Add this right after the line that reads stdin (usually `input=$(cat)`).
**Settings › Claude Code › Set Up Live Updates…** shows the same line with a button to copy it:

```bash
{ mkdir -p "$HOME/Library/Application Support/com.vickipetrova.cashew" \
  && printf '%s' "$input" | jq -c '{rate_limits}' \
     > "$HOME/Library/Application Support/com.vickipetrova.cashew/statusline.json"; } 2>/dev/null || true
```

If your script stores stdin under a different name than `input`, change `$input` to match.

## You don't have one yet

Most people don't. Save this as `~/.claude/cashew-statusline.sh` — it shows the model and the
current folder, and hands the usage numbers to Cashew:

```bash
#!/bin/bash
input=$(cat)

{ mkdir -p "$HOME/Library/Application Support/com.vickipetrova.cashew" \
  && printf '%s' "$input" | jq -c '{rate_limits}' \
     > "$HOME/Library/Application Support/com.vickipetrova.cashew/statusline.json"; } 2>/dev/null || true

printf '%s' "$input" | jq -r '"\(.model.display_name // "Claude") · \(.workspace.current_dir // "" | split("/") | last // "")"'
```

Then point Claude Code at it by adding this to `~/.claude/settings.json` (merge it into the existing
object if the file already has settings in it):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/cashew-statusline.sh"
  }
}
```

The statusline appears the next time Claude Code renders one — send a message in any session.

## Checking it works

**Settings › Claude Code › Live updates** shows what Cashew sees:

| Status | Meaning |
|---|---|
| On · updated 1m ago | Working. |
| On · last reading 3h ago | Set up, but Claude Code hasn't rendered a statusline in the last five minutes — normal when it's closed. Cashew falls back to polling. |
| Off | No reading has ever arrived. The line isn't in your script, or the script isn't the one in `settings.json`. |
| Not working — is jq installed? | The script runs but writes nothing. The snippet needs `jq`, which macOS 15 and later include; on macOS 13 or 14, `brew install jq`. |
| On · no plan limits reported | Readings arrive but carry no usage — an account without plan limits, or a session that hasn't made a request yet. |

Only `rate_limits` is written — not the working directory, session id, transcript path or cost that
the rest of the payload carries. Every failure is swallowed, so a broken snippet can never break your
statusline, which is also why the status above exists. Delete the line to opt out.

## Why it supplements polling rather than replacing it

The statusline payload has no per-model breakdown, so a `WEEKLY · OPUS` row can only come from the
API — and an earlier version of this that used the statusline *instead of* polling made that row
blink in and out depending on whether a Claude Code session happened to be open, which was worse
than either source alone. Cashew keeps polling on your normal schedule and overlays the live numbers
on top, matched by limit, so no row ever disappears.

Once the file is more than five minutes old Cashew stops trusting it and shows the polled numbers
alone — an idle session isn't refreshing the file, but idle usage isn't moving either. Nothing to
configure either way, and nothing changes if you skip this entirely.
