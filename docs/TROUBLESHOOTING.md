# Troubleshooting

Mostly things that look broken and aren't.

## "Cashew wants to access key 'Claude Code-credentials'"

Expected, once. Claude Code creates its Keychain item so that only Claude Code itself is trusted,
so every other app — Cashew included — has to ask you. Click Allow.

**"Always Allow" won't stick if you built from source.** An ad-hoc signature's designated
requirement is nothing but `cdhash H"..."` — no bundle identifier, no team — so every rebuild is a
different app as far as macOS is concerned, the stored grant matches nothing, and you are asked
again. A release build, signed with a Developer ID, only asks once.

If you build from source often and have a Developer ID, sign with it and the grant survives
rebuilds, because the requirement is then keyed to your identifier and team rather than to the
compiled bytes:

```bash
CASHEW_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

Expect one more prompt the first time — it is a new identity — and none after that.

## The menu says my token has expired

Open Claude Code. It refreshes the token itself while you work, and Cashew will pick the new one up
on its next poll. Nothing to configure.

If you've genuinely signed out, sign back in.

## My sessions don't appear

**Hooks load when a Claude Code session starts.** A session that was already open when you turned
tracking on won't appear until you restart it. Start a new `claude` session and it shows up.

If no session ever appears, check **Settings › Claude Code › Track sessions** — the line underneath
says what Cashew thinks the state is.

## "Move Cashew to Applications"

Cashew only installs its hooks when it's running from `/Applications` or `~/Applications`. Anywhere
else — a DMG you never copied out of, a Downloads folder, a `build/` directory — the path would go
away and the hooks would point at nothing.

Drag it to Applications and relaunch.

## It can't find my login and I use CLAUDE_CONFIG_DIR

That's the one setup Cashew can't handle. Claude Code moves both the credentials file *and* the
Keychain service name to match the variable, and an app launched from Finder doesn't inherit
environment variables set in your shell — so Cashew has no way to learn where you put it.

## The numbers disagree with /usage

Check `/usage` inside Claude Code. If they genuinely disagree,
[open an issue](https://github.com/vickipetrova/cashew/issues) — the endpoint is undocumented and
community-discovered, and it has already changed shape once. Cashew treats every field as optional
and renders `–` rather than guessing, so a disagreement usually means the shape moved again.

## The dropdown didn't add a row while I had it open

Known and deliberate. Rows are updated in place while the menu is open — rebuilding it mid-use would
re-target a click already in flight and destroy keyboard state — but in-place updates can't add or
remove rows. A limit that appears or disappears waits for the next time you open the menu. The menu
bar title stays correct meanwhile.

## Nothing at all in the menu bar

Cashew is `LSUIElement`: no Dock icon, no window. If the menu bar item isn't there, it isn't
running. `open -a Cashew`, or check Login Items if you expected it to start itself.

If your menu bar is full, macOS hides items silently — try quitting something else in the bar, or
use an item manager.
