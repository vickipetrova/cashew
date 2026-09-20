Screenshots and the hero GIF (menu bar + open dropdown) live here, referenced from the root README.

- `cashew.gif` — the hero, 900x506 at 12fps, about 3.6 MB. It is a conversion of a screen recording
  (`cashew-demo.mp4`), which is deliberately **not** committed: 20 MB of video would sit in every
  clone forever, and GitHub will not play it anyway — its markdown sanitizer strips `<video>`, and
  raw.githubusercontent serves mp4 as `application/octet-stream`, so a committed video can only ever
  be a download link. An animated GIF is the only motion GitHub renders inline. Keep the recording
  somewhere outside the repo if you want to re-cut it.

The app icon's sources live here too:

- `Cashew.icon` — the Icon Composer document, and **the source of truth**. Edit this one. It holds
  a single layer, `Assets/cashew.png`: the character on a transparent background, at 1024², because
  macOS supplies the tile, the material and the shadow around it. Art with its own background baked
  in would fight all three.
- `icon-1024.png` — a committed *render* of that document, not a hand-made export. `build.sh`
  downscales it into the `.icns`, and on the Command-Line-Tools-only path it is the only icon input —
  `Cashew.icon` is never read there, because compiling it needs Xcode.
- `render-icon.sh` — regenerates the PNG from the document. Run it after any change to
  `Cashew.icon` and commit both, or the two build tiers will disagree about what the icon looks
  like.

`render-icon.sh` needs Xcode, which costs nothing extra: Icon Composer ships with Xcode, so anyone
able to edit the document can already run it.

See [`docs/ICON.md`](../docs/ICON.md) for why the render comes from `actool` rather than Icon
Composer's own export, why `build.sh` must not inset the result a second time, and the measured traps
in `sips`, `actool` and the DMG volume flag.
