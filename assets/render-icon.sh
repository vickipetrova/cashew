#!/bin/bash
# Regenerates assets/icon-1024.png from assets/Cashew.icon.
#
# `Cashew.icon` is the source of truth, but it can only be *rendered* by actool, which lives inside
# Xcode.app. `build.sh` must work with the Command Line Tools alone, so the render is committed as a
# flat PNG and build.sh downscales that into the .icns. This script is what keeps the two in step —
# run it whenever the Icon Composer document changes, and commit the result alongside it.
#
# Requires Xcode. That is not a new burden: Icon Composer, the only thing that edits the document in
# the first place, ships with Xcode too.
#
# Why actool rather than Icon Composer's own File ▸ Export: actool renders the icon the way macOS 26
# actually composites it — the material treatment, the drop shadow, and Apple's 824-of-1024 grid —
# whereas the Icon Composer export is full-bleed, because on macOS 26 the system supplies the mask
# and shadow itself. A full-bleed source has to be inset again before it can become a .icns, and
# getting that inset wrong is invisible until the icon is a quarter too large next to other apps on
# macOS 13-15. Taking actool's already-on-grid render removes that whole step.
set -euo pipefail
cd "$(dirname "$0")/.."

DOC="assets/Cashew.icon"
OUT="assets/icon-1024.png"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v xcrun >/dev/null && ACTOOL="$(xcrun --find actool 2>/dev/null)" || ACTOOL=""
if [[ -z "$ACTOOL" ]]; then
  echo "error: actool not found. This script needs full Xcode, not just the Command Line Tools." >&2
  echo "       (xcode-select -p currently points at: $(xcode-select -p 2>/dev/null || echo unknown))" >&2
  exit 1
fi

# --standalone-icon-behavior all is what widens actool's loose .icns from a four-size subset to the
# full family; the 1024 member is the one taken here.
"$ACTOOL" "$DOC" \
  --compile "$STAGE" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon Cashew \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$STAGE/partial.plist" \
  --errors --warnings --notices > "$STAGE/actool.log" 2>&1 || true

# actool exits 0 even when it renders nothing, so the partial plist is what gets checked: it only
# carries CFBundleIconName when an app icon was actually selected and compiled.
if ! plutil -extract CFBundleIconName raw "$STAGE/partial.plist" >/dev/null 2>&1; then
  echo "error: actool did not produce an app icon from $DOC." >&2
  sed 's/^/  /' "$STAGE/actool.log" >&2
  exit 1
fi

rm -rf "$STAGE/x.iconset"
iconutil -c iconset "$STAGE/Cashew.icns" -o "$STAGE/x.iconset"
cp "$STAGE/x.iconset/icon_512x512@2x.png" "$OUT"

echo "Wrote $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/w=/;s/pixelHeight:/ h=/'))"
echo "Commit it together with $DOC — build.sh reads the PNG, not the document, on the CLT-only path."
