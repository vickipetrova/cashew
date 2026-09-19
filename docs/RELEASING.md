# Releasing

Cashew's `build.sh` deliberately knows nothing about signing identities or Apple credentials — it
only ad-hoc signs. Producing a release that opens without a Gatekeeper warning is a manual step on
the maintainer's Mac, documented here.

## 1. Prepare

- Bump `VERSION` in `build.sh`.
- Add the release section to `CHANGELOG.md`.
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

   `YOURTEAMID` is the parenthesised code in `security find-identity -v -p codesigning`.

Then, per release:

```bash
./build.sh --dmg

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

(Equivalent: `CASHEW_SIGN_ID="$SIGN_ID" ./build.sh --dmg` now signs both correctly; the manual lines
stay for the existing procedure.)

Verify before publishing:

```bash
spctl -a -t open --context context:primary-signature -v build/Cashew-$VERSION.dmg   # expect: accepted
xcrun stapler validate build/Cashew-$VERSION.dmg                                     # expect: validated
```

## 4. Publish

Replace the draft release's asset with the notarized `build/Cashew-$VERSION.dmg`, paste the CHANGELOG
section as the release notes, and publish.

## Why notarization matters here

Without it, a downloaded DMG trips Gatekeeper and users have to right-click › Open the first time —
which, for an app that asks to read their Claude credentials, is exactly the wrong first impression.
