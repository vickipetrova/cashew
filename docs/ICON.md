# The app icon

Everything about how Headroom's icon is authored, rendered and packaged. `CLAUDE.md` keeps the
short version — the two tiers and the one trap that reaches beyond this file. This is the reference
for actually editing the icon or touching `build.sh`'s packaging.

Headroom is `LSUIElement`: no Dock tile, no window. The bundle icon is what Finder, the DMG, the
notification banner, Login Items and the Keychain permission prompt show — that is its whole surface
area, which is why `build.sh` renders one rather than shipping the generic placeholder.

`build.sh` builds it in two tiers, and **the boundary between them is additive on purpose**:

- **Tier 1, always.** `sips` and `iconutil` — both in `/usr/bin` — turn `assets/icon-1024.png` into
  `Contents/Resources/Headroom.icns`, and the plist gets `CFBundleIconFile`. No Xcode.
- **Tier 2, when `xcrun --find actool` succeeds.** `actool` compiles `assets/Headroom.icon` into
  `Assets.car` and the plist also gets `CFBundleIconName`, so macOS 26+ renders the layered icon with
  its own material and specular treatment instead of a flat bitmap. Skipped silently otherwise, and
  never fatal — a future `actool` that rejects the document must cost the layered icon, not the build.

The `.icns` is therefore byte-identical whether or not Xcode is installed (verified by `shasum` across
both paths), so a CLT-only contributor and CI ship the same icon and "it looks different on my
machine" cannot happen.

## Editing the icon

`assets/Headroom.icon` is the source of truth, and **`assets/icon-1024.png` is a committed render of
it**, not a hand-exported picture. Change the document, then run `./assets/render-icon.sh` and commit
both. The script needs Xcode, which is not a new burden — Icon Composer, the only thing that edits the
document, ships with Xcode too.

It renders through `actool` rather than Icon Composer's *File ▸ Export* on purpose. The export is
full-bleed, because on macOS 26 the system supplies the mask and the shadow; `actool` instead renders
the icon the way macOS composites it, already on Apple's 824-of-1024 grid and with the shadow baked
in. Committing the on-grid render means `build.sh` only has to downscale. **Do not add an inset step
to `build.sh`** — the source is already inset, and doing it twice makes the icon visibly small.

## Traps, each measured

- **The `.icns` geometry only matters on macOS 13–15.** Those draw the `.icns` as authored, so a
  full-bleed source really does render about a quarter larger than every other app. macOS 26 does
  **not**: it re-masks legacy `.icns` content into the system tile, and inset, full-bleed and
  deliberately over-inset bundles all render to an identical 83.59% bounding box there, the same as
  Calculator's. So this regression is invisible on a current Mac, which is exactly why CI asserts the
  artwork spans ~80% of its tile. Don't "verify" the inset by looking at your own Dock.
- **`sips` reports success on input it never read.** It exits 0 when the file does not exist (printing
  only a warning) *and* on a truncated PNG, rendering partial data at the requested size. Neither
  shows up in an exit status or in the output's dimensions. `build.sh` therefore validates the source
  up front: it exists, its last 8 bytes are the PNG `IEND` chunk and its constant CRC
  (`49454e44ae426082` — truncation is what that catches), and it is 1024 wide.
- **`actool` exits 0 when it renders nothing, so `Assets.car` is not the signal.** If `--app-icon`
  names an asset the document doesn't contain — rename `Headroom.icon`, or change `APP_NAME`, and it
  will — `actool` still writes an `Assets.car` full of layers with no icon in it, and an *empty*
  partial plist. Guarding on the file's existence passes there and sets `CFBundleIconName` pointing at
  nothing. The guard is `plutil -extract CFBundleIconName` on the partial plist, and the value written
  into `Info.plist` is the one `actool` reports rather than an assumed `$APP_NAME`.
- **`actool` must compile to a staging directory.** It also writes its own `Headroom.icns`, so
  compiling straight into `Contents/Resources` would overwrite the complete ten-size family with a
  four-size subset. `--standalone-icon-behavior` does not turn that output off — `none` still emits
  it, only smaller. Only `Assets.car` is copied out. Taking `actool`'s `.icns` instead would also make
  the bundle differ by build machine: its `Assets.car` is not even reproducible between two runs on
  one machine, since it embeds a fresh timestamp and fresh rendition UUIDs each time. The `.icns`
  determinism claim above is about the `.icns` alone.
- **The DMG volume icon needs the flag, not just the file.** `.VolumeIcon.icns` at the volume root
  does nothing on its own; the root also needs Finder's custom-icon bit. `SetFile -a C` on the
  *staging folder* sets it there, but `hdiutil create -srcfolder` builds a fresh filesystem and does
  not carry that FinderInfo onto the volume, so it is silently lost — `GetFileInfo -a` on the mounted
  result comes back all-lowercase. It has to be set on the mounted image, which is why the DMG is
  built read-write, flagged, then converted to UDZO.
- **Bash-only word splitting was removed, not documented around.** The size table used `set -- $SPEC`,
  which splits under bash but *not* under zsh — pasting that loop into a shell silently writes one
  file named `.png`. It is now `while read -r SIZE NAME`, which also stops clobbering the script's own
  positional parameters.

Intermediates land in `build/`, which `.gitignore` already covers.

Cost, since it is a large fraction of a small app: the binary is ~579 KB, the `.icns` ~607 KB and
`Assets.car` ~1.4 MB, so the icon is roughly three quarters of a ~2.6 MB bundle. That is inherent to a
soft gradient render, not a packaging mistake.

## Checking what macOS actually resolves

To check what macOS actually resolves rather than what is merely on disk, ask the icon services —
`NSWorkspace.shared.icon(forFile:)` on the built bundle, in a scratch script. A bundle with no icon
still returns an image (the generic placeholder), so compare against
`NSWorkspace.shared.icon(for: .application)` instead of null-checking. `open build/Headroom.app` is the
by-eye version: the icon then shows up in Login Items and on any notification. Don't reach for
`qlmanage -t` — it hangs indefinitely from a non-GUI session rather than returning.

On macOS 26 a bundle containing `Assets.car` renders the *layered* icon, so the `.icns` fallback is
only exercised by a CLT-only build. `DEVELOPER_DIR=/Library/Developer/CommandLineTools ./build.sh`
produces one without uninstalling anything, and is how both tiers get tested on one machine.

## Light and dark

`icon.json` declares no dark or tinted variant and does not need to: `"fill": {"automatic-gradient":
…}` is the feature that derives them. `assetutil --info` on the compiled car shows all three
appearances registered, with Aqua and Tintable referencing the declared cream gradient while
**DarkAqua references a two-stop grey ramp 0.192 → 0.078 that `actool` generated itself**. The layer
group is shared byte-for-byte across all three.

What you cannot conclude from that is how it looks on screen, and the obvious checks don't work.
`NSWorkspace.shared.icon(forFile:)` returns the default rendition no matter the appearance — verified
against Notes, Reminders and System Settings, which come back byte-identical with
`NSApp.appearance` genuinely flipped, so a headless script cannot observe the switch at all. A `.icns`
has no appearance variants in the first place, so on macOS 13–25 the icon is necessarily the same in
both modes.
