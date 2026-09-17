#!/bin/bash
# Builds build/Headroom.app. Optionally packages a DMG too:
#
#   ./build.sh              app only
#   ./build.sh --dmg        app, then DMG
#   ./build.sh --dmg-only   DMG around the existing app, without rebuilding it
#
# --dmg-only exists for the release procedure: the app has to be signed with a Developer ID,
# notarized and stapled *before* it goes into the image, and rebuilding at that point would discard
# the signature and the ticket. See docs/RELEASING.md.
#
# Requires the Xcode Command Line Tools (xcode-select --install). No Xcode project, no third-party
# dependencies. Compilation goes through SwiftPM so `swift test` works on the same sources.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Headroom"
VERSION="0.1.0"
BUNDLE_ID="com.vickipetrova.headroom"
MIN_MACOS="13.0"

MODE="${1:-}"
APP="build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
# The Claude Code hook helper. Contents/Helpers is Apple's documented home for helper tools.
HOOK_NAME="headroom-hook"
HOOK="$APP/Contents/Helpers/$HOOK_NAME"

if [[ "$MODE" == "--dmg-only" ]]; then
  [[ -d "$APP" ]] || { echo "error: $APP not found — run ./build.sh first." >&2; exit 1; }
  echo "Reusing the existing $APP (not rebuilding)."
else

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

echo "Compiling universal binary (arm64 + x86_64)…"
# Universal so it runs natively on Apple Silicon and Intel without Rosetta. SwiftPM builds one arch
# per invocation, so this is two builds joined by lipo.
#
# --triple twice rather than `--arch arm64 --arch x86_64`: passing --arch more than once silently
# switches SwiftPM to the XCBuild backend, which lives inside Xcode.app and does not exist under the
# Command Line Tools. That would break the build for CLT-only contributors while still passing in CI.
#
# -debug-info-format none because `swift build -c release` compiles with -g by default, and the
# resulting debug map embeds absolute paths from this machine's .build directory into the shipped
# binary.
#
# The deployment target comes from `platforms:` in Package.swift, not from the triple — SwiftPM
# rewrites the version component on Darwin, so the build machine's OS cannot leak in.
SPM_FLAGS=(-c release -debug-info-format none)
SLICES=()
HOOK_SLICES=()
for TRIPLE in arm64-apple-macosx x86_64-apple-macosx; do
  swift build "${SPM_FLAGS[@]}" --triple "$TRIPLE"
  # Ask SwiftPM where it put things rather than hardcoding a path. Note .build/release is a
  # compatibility symlink pointing at whichever triple built last — using it would lipo one slice
  # with itself. The flags must match the build exactly, hence the shared array.
  BIN_PATH="$(swift build "${SPM_FLAGS[@]}" --triple "$TRIPLE" --show-bin-path)"
  SLICES+=("$BIN_PATH/$APP_NAME")
  HOOK_SLICES+=("$BIN_PATH/$HOOK_NAME")
done
lipo -create "${SLICES[@]}" -output "$BIN"
lipo -create "${HOOK_SLICES[@]}" -output "$HOOK"

# --- App icon ---------------------------------------------------------------------------------
#
# Headroom is LSUIElement, so it has no Dock tile and no window: the icon is seen in Finder, in the
# DMG, on notification banners, in Login Items, and on the Keychain permission prompt. Those are the
# whole surface area, which is why this is worth a build step rather than nothing.
#
# Two tiers, and the boundary between them is deliberately *additive*: the .icns is always the one
# built here from the flattened export, byte for byte, whether or not Xcode is installed. Xcode only
# ever adds the layered icon on top. A contributor with the Command Line Tools alone and CI therefore
# ship the same icon, so "it looks different on my machine" cannot happen.
ICON_PNG="assets/icon-1024.png"
ICON_DOC="assets/Headroom.icon"
ICONSET="build/$APP_NAME.iconset"
# Empty on the CLT-only path. Interpolated into the plist below, so the layered icon is only claimed
# when it is actually in the bundle — a CFBundleIconName pointing at an absent Assets.car makes
# macOS fall back with a console complaint rather than silently.
ICON_NAME_KEY=""

# Tier 1: the classic .icns, from sips and iconutil, both of which are in /usr/bin.
#
# `assets/icon-1024.png` is a committed render of the Icon Composer document, produced by
# `assets/render-icon.sh` — so it already sits on Apple's 824-of-1024 grid, with the shadow, and it is
# only downscaled here. Do not add an inset step: it is already inset, and doing it twice makes the
# icon visibly small. Re-run render-icon.sh, don't compensate in this file.
#
# Guarded rather than trusted, because `sips` exits 0 when its input does not exist — it only prints a
# warning — so without this a missing or unreadable source silently reuses whatever the previous build
# left behind, and ships the wrong icon under a green build.
echo "Rendering the app icon…"
# The source is validated up front, because sips reports success on inputs it did not really read:
# it exits 0 when the file does not exist at all (printing only a warning), and exits 0 on a truncated
# PNG, rendering whatever partial data it got at the requested size. Neither shows up in an exit
# status or in the output's dimensions, so a corrupt source would sail through and ship a broken icon
# under a green build.
[[ -f "$ICON_PNG" ]] || { echo "error: $ICON_PNG is missing. Run ./assets/render-icon.sh." >&2; exit 1; }
# Every valid PNG ends with the same 12-byte IEND chunk, whose last 8 bytes — the type and its CRC
# over zero-length data — are this constant. Truncation is what this catches, and nothing else does.
[[ "$(tail -c 8 "$ICON_PNG" | xxd -p)" == "49454e44ae426082" ]] \
  || { echo "error: $ICON_PNG is truncated or not a PNG. Re-run ./assets/render-icon.sh." >&2; exit 1; }
[[ "$(sips -g pixelWidth "$ICON_PNG" | tail -1 | awk '{print $2}')" == "1024" ]] \
  || { echo "error: $ICON_PNG must be 1024x1024." >&2; exit 1; }
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# IFS-read rather than `set --`: this splits without clobbering the script's own positional
# parameters, and without depending on the shell being bash for word splitting (it does not split
# under zsh, which silently yields a single file named ".png").
while read -r SIZE NAME; do
  sips -z "$SIZE" "$SIZE" "$ICON_PNG" --out "$ICONSET/$NAME.png" >/dev/null
done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"

# Tier 2: the layered Icon Composer document, so macOS 26 and later can render it with the material
# and specular treatment instead of a flat bitmap. actool lives inside Xcode.app, not the Command Line
# Tools, so this is skipped silently when it is absent — the check is `xcrun --find`, which exits
# non-zero under a CLT-only DEVELOPER_DIR.
#
# It compiles into a staging directory and only Assets.car is taken. actool also writes its own
# Headroom.icns, and compiling straight into Contents/Resources would overwrite the complete one built
# above with a four-size subset: --standalone-icon-behavior does not turn that output off, only
# resizes it. Taking actool's instead would also make the bundle differ by build machine, which is the
# one thing this tier boundary exists to prevent — its Assets.car is not even reproducible between two
# runs on one machine, since it embeds a fresh timestamp and fresh rendition UUIDs each time.
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
  ICON_STAGE="build/icon-actool"
  rm -rf "$ICON_STAGE"
  mkdir -p "$ICON_STAGE"
  # Not fatal. A future actool that rejects this document must cost the layered icon, not the build.
  # Diagnostics go to a log rather than /dev/null: actool exits 0 even when it renders nothing, so
  # without keeping them the --errors/--warnings/--notices flags would be decorative and a failure
  # would carry no cause.
  "$ACTOOL" "$ICON_DOC" \
    --compile "$ICON_STAGE" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" \
    --app-icon "$APP_NAME" \
    --output-partial-info-plist "$ICON_STAGE/partial.plist" \
    --errors --warnings --notices > "$ICON_STAGE/actool.log" 2>&1 || true
  # The partial plist, not the presence of Assets.car, is the signal that an app icon was actually
  # selected and compiled. actool writes an Assets.car regardless — if --app-icon names an asset the
  # document does not contain (rename Headroom.icon, or change APP_NAME, and it will), it exits 0 with
  # a car full of layers, no icon in it, and an empty partial plist. Guarding on the file would pass
  # there and set CFBundleIconName pointing at nothing.
  if ICON_NAME="$(plutil -extract CFBundleIconName raw "$ICON_STAGE/partial.plist" 2>/dev/null)"; then
    cp "$ICON_STAGE/Assets.car" "$APP/Contents/Resources/"
    ICON_NAME_KEY="  <key>CFBundleIconName</key><string>$ICON_NAME</string>"
    echo "Compiled the layered icon for macOS 26+ (Assets.car)."
  else
    echo "warning: actool produced no app icon from $ICON_DOC — shipping the .icns only." >&2
    echo "         see $ICON_STAGE/actool.log" >&2
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>$APP_NAME</string>
$ICON_NAME_KEY
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict>
</plist>
PLIST

# Ad-hoc by default. Set HEADROOM_SIGN_ID to a signing identity in your Keychain to use that
# instead — no secret ever lives in this repo, and this script still knows nothing about
# notarization, which stays a manual maintainer step (docs/RELEASING.md).
#
# Worth doing while developing: an ad-hoc signature's designated requirement is the binary's own
# hash, so every code change makes Headroom a different app to macOS and the Keychain re-asks for
# permission to read your Claude Code login. A real identity gives a stable, identity-based
# requirement, so "Always Allow" sticks across rebuilds:
#
#   HEADROOM_SIGN_ID="Apple Development: Your Name (TEAMID)" ./build.sh
#
# xattr first: extended attributes (quarantine, Finder info) make codesign refuse the bundle, and
# that is the one benign failure this step used to swallow.
#
# Nothing else may be swallowed. Apple Silicon refuses to launch a binary carrying no signature at
# all, so hiding a codesign failure here does not produce an unsigned-but-working app — it produces
# a build that dies at launch as "Headroom is damaged", with the actual error discarded.
# Inside-out: the helper is signed before the app that contains it, because signing the app seals
# its contents. Never --deep, which Apple names as the most common cause of notarization failures.
xattr -cr "$APP"
if [[ -n "${HEADROOM_SIGN_ID:-}" ]]; then
  echo "Signing with: $HEADROOM_SIGN_ID"
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_ID" "$HOOK"
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_ID" "$APP"
else
  codesign --force --sign - "$HOOK"
  codesign --force --sign - "$APP"
fi

echo "Built $APP"

fi  # end of the build-the-app branch

if [[ "$MODE" == "--dmg" || "$MODE" == "--dmg-only" ]]; then
  echo "Packaging DMG…"
  DMG="build/$APP_NAME.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  # Volume icon, so the window the user drags from shows Headroom rather than a generic white disk.
  # Two things are required and neither works alone: a file named `.VolumeIcon.icns` at the volume
  # root, *and* Finder's custom-icon flag on the root itself.
  #
  # The flag is why this is not a one-liner. `SetFile -a C` on the staging folder does set it there —
  # measured — but `hdiutil create -srcfolder` builds a fresh filesystem and does not carry the source
  # folder's FinderInfo onto the volume root, so the flag is silently lost and the icns sits there
  # doing nothing. It has to be set on the mounted volume instead.
  cp "$APP/Contents/Resources/$APP_NAME.icns" "$STAGE/.VolumeIcon.icns"

  # The contents still come from the folder, not from a mounted read-write image: macOS's fseventsd
  # creates a hidden .fseventsd on a writable volume it sees activity on, and deleting it does not
  # stick (the deletion is itself an event). What follows mounts the image only to flip one attribute
  # and writes no files there, which is a much smaller exposure than laying out the whole payload —
  # verified, the finished image contains .VolumeIcon.icns and nothing else hidden.
  if SETFILE="$(xcrun --find SetFile 2>/dev/null)"; then
    RW="build/$APP_NAME-rw.dmg"
    rm -f "$RW"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
    MOUNT="$(hdiutil attach "$RW" -nobrowse -mountrandom /tmp | grep -oE '/tmp/[A-Za-z0-9.]+$' | tail -1)"
    if [[ -n "$MOUNT" ]]; then
      "$SETFILE" -a C "$MOUNT"
      hdiutil detach "$MOUNT" >/dev/null
    fi
    hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
    rm -f "$RW"
  else
    # Cosmetic, so it must not cost the DMG. Falls back to the direct, never-mounted path.
    echo "warning: SetFile not found — the DMG will use the generic volume icon." >&2
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  fi
  rm -rf "$STAGE"
  echo "Built $DMG"
fi

echo
echo "Run:      open $APP"
echo "Install:  cp -R $APP /Applications/"
