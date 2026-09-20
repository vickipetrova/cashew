# Releasing

Cashew's `build.sh` deliberately knows nothing about signing identities or Apple credentials — it
only ad-hoc signs. Producing a release that opens without a Gatekeeper warning is a manual step on
the maintainer's Mac, documented here.

## 1. Prepare

- Bump `VERSION` in `build.sh`.
- Add the release section to `CHANGELOG.md`.
- **Set that section's date to the day you are actually tagging.** A version being prepared carries
  `- unreleased` rather than a guessed date, precisely so this cannot go out stale — a changelog
  dated three weeks before the release is a small, permanent inaccuracy, and the release is the only
  moment the real date is known.
- Commit, then tag and push:

```bash
git tag v0.1.0
git push origin main --tags
```

## 2. CI builds a draft

`.github/workflows/release.yml` runs on any `v*` tag: it builds the app and DMG on a
`macos-latest` runner and opens a **draft** GitHub Release with `Cashew-$VERSION.dmg` attached.

That asset is ad-hoc signed — CI never sees a Developer ID, by design. It is fine for testing and
wrong to publish. Replace it with a properly signed one below.

## 3. Sign and notarize locally

One-time setup on your Mac:

1. A **Developer ID Application** certificate in your Keychain (Xcode › Settings › Accounts ›
   Manage Certificates). Note: an *Apple Development* certificate is not enough for distribution.
2. A notarytool credential profile, using an
   [app-specific password](https://support.apple.com/en-us/102654) — not your Apple ID password.

   Run this from anywhere; it writes to your login Keychain, not to the working directory. Note the
   absence of `--password`: leaving it off makes notarytool prompt for the password invisibly, which
   keeps it out of your shell history and out of `ps` output, where any local process could read it.
   The command validates against Apple before saving, so a typo fails here rather than at release
   time.

```bash
xcrun notarytool store-credentials "cashew" \
  --apple-id you@example.com \
  --team-id YOURTEAMID
```

   `YOURTEAMID` is the parenthesised code on the **Developer ID Application** line of
   `security find-identity -v -p codesigning` — and only that line. On an *Apple Development* line
   the parentheses hold your personal developer ID, not a team, so copying from the wrong row yields
   something that looks like a team ID and is rejected. If you have more than one team, read the
   `OU` instead, which is always the team: `security find-certificate -c "Developer ID Application"
   -p | openssl x509 -noout -subject`.

   `--apple-id` must be the Apple ID that **generated the app-specific password**, and that account
   must belong to `--team-id`. A password made on one Apple ID and passed with another fails with
   `HTTP status code: 401. Invalid credentials`, which reads like a typo and isn't one.

   An App Store Connect API key works instead of a password, if you'd rather not manage one:
   `--key AuthKey_XXXX.p8 --key-id XXXX`, plus `--issuer <uuid>` for a Team key but *not* for an
   Individual key. The key must come from the same team and hold a role of Developer or higher.
   Note that APNs and MusicKit keys are also named `AuthKey_<id>.p8` and are also P-256, so the file
   alone can't tell you what you have — the validation step is what settles it.

   `store-credentials` needs a real terminal: it prompts interactively, so it can't be driven from a
   script or a tool that gives it no TTY.

Then, per release:

```bash
# Not --dmg: the DMG is packaged further down, after the app has been stapled, so an image
# built here would only be thrown away by the --dmg-only run below.
./build.sh

SIGN_ID="Developer ID Application: Your Name (YOURTEAMID)"

# The DMG filename carries the version, so read it from the same place build.sh does rather than
# typing it twice — a mismatch here signs one file and notarizes another, and the failure surfaces
# as a confusing "file not found" three commands later.
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' build.sh)"

# Sign and notarize the .app first, so a copy dragged out of the DMG carries its own ticket.
# Inside-out: the Claude Code hook helper before the app. The notary service requires the hardened
# runtime on every executable in the bundle, helpers included, and rejects the app otherwise.
xattr -cr build/Cashew.app
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Cashew.app/Contents/Helpers/cashew-hook
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Cashew.app
ditto -c -k --keepParent build/Cashew.app build/app-notarize.zip
xcrun notarytool submit build/app-notarize.zip --keychain-profile "cashew" --wait
xcrun stapler staple build/Cashew.app
rm build/app-notarize.zip

# Package the DMG around the now-signed app, then sign and notarize the image itself — that's the
# check a downloader actually hits. --dmg-only, NOT --dmg: rebuilding here would recompile the app
# and re-sign it ad-hoc, throwing away the Developer ID signature and the ticket just stapled to it.
./build.sh --dmg-only
codesign --force --timestamp --sign "$SIGN_ID" build/Cashew-$VERSION.dmg
xcrun notarytool submit build/Cashew-$VERSION.dmg --keychain-profile "cashew" --wait
xcrun stapler staple build/Cashew-$VERSION.dmg
```

`CASHEW_SIGN_ID="$SIGN_ID" ./build.sh` signs the app and the hook helper during the build, so the
two `codesign` lines above become redundant. It is not a shortcut for the whole procedure: it never
signs the DMG, and the app still has to be notarized and stapled *before* the image is packaged
around it.

Verify before publishing:

```bash
spctl -a -t open --context context:primary-signature -v build/Cashew-$VERSION.dmg   # expect: accepted
xcrun stapler validate build/Cashew-$VERSION.dmg                                     # expect: validated
```

## 4. Publish

Replace the draft release's asset with the notarized `build/Cashew-$VERSION.dmg`, paste the CHANGELOG
section as the release notes, and publish. From the CLI that is:

```bash
gh release upload "v$VERSION" "build/Cashew-$VERSION.dmg" --clobber
gh release edit "v$VERSION" --notes-file notes.md --draft=false --latest
```

**Then download what you actually published and check it.** Shipping CI's ad-hoc asset is the one
mistake here that looks fine from the release page and fails on every user's Mac:

```bash
curl -sL -o /tmp/v.dmg \
  "https://github.com/vickipetrova/cashew/releases/download/v$VERSION/Cashew-$VERSION.dmg"
shasum -a 256 /tmp/v.dmg                                          # expect: the local DMG's hash
spctl -a -t open --context context:primary-signature -v /tmp/v.dmg  # expect: accepted, Notarized Developer ID
```

`rejected` with `source=Unnotarized Developer ID` means the draft's original asset went out.

## Why notarization matters here

Without it, a downloaded DMG trips Gatekeeper and users have to right-click › Open the first time —
which, for an app that asks to read their Claude credentials, is exactly the wrong first impression.
