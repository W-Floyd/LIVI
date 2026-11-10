# Godot shell

A Godot 4 UI on livi-core; see [PLAN.md](PLAN.md).

- `ext/`: the GDExtension (Rust, gdext). `CoreLink` (the core client, or an in-process fake
  core), `WaylandCompositor` (smithay, shm so far; Linux only), `ShellTest` (scenario YAML,
  golden comparison), and `livi-shell-test-client`, a Wayland client that draws known
  patterns.
- `project/`: the Godot project. `boot.gd` runs the shell, or the scenario runner with
  `-- --test`.
- `tests/`: scenarios, core fixtures (partial states, filled like the core fills them) and
  goldens.

## Test

```sh
scripts/vm.sh scripts/test.sh                   # in the VM: cargo test, then every scenario
scripts/vm.sh scripts/test.sh home-night        # one scenario
scripts/vm.sh scripts/test.sh --update-goldens  # rewrite goldens, then review them in the diff
scripts/vm.sh scripts/test.sh --shots-only      # render without comparing
scripts/vm.sh scripts/test.sh --record          # also record flows to MP4, for review and docs
```

`vm.sh` syncs `godot-shell/` and `native/` into the VM, runs the command, and copies `out/`
(`report.html`, metrics, and shots where they failed or were asked for) and `tests/goldens/`
back. Scenarios render in a 1920×720 SubViewport under a headless weston with llvmpipe, at
`--fixed-fps 60` and a fixed clock, with the extension built in release. `check-gd.sh` runs
first and prints GDScript errors as `res://file:line`; a script that still fails to load in
the run stops it at once.

Goldens are lossless WebP, a third of PNG's size. Captures are compared in memory and written
(as PNG) only on a mismatch, `--update-goldens`, `--shots-only` or `compare: false`.

Scenario fixtures: `core` (a partial state) and `clients`: `{ role: app, app_id, pattern:
grid|bars, size: WxH, animate: N, buffer: shm|dmabuf, events: true }` runs the test client
(`events` logs the input it gets, for `expect_client`), `{ role: command, run: [...] }` any
Wayland program.

Steps: `page: home | ev | ev_live | <pack screen>` (see "Electric vehicle page"), `compare_reference` (below), `wait: { frames } | { window: app_id }`, `tap: { node } | { x, y }` (add `with: touch`
for a finger), `key`, `expect_client: { app_id, lines: [...] }`,
`theme: { theme_name, appearance, hand, near, text_scale, material, reduced_motion, quality, ev_page }`,
`set: { core: {...} }`, `expect_action`, `expect_input`, `expect_node: { path, <property>:
value }` (`rect: [x, y, w, h]` for a control's panel rectangle), `screenshot: name` or `{ name, tolerance, max_pixels, mask: [[x, y, w, h]], compare
}`, `measure: { name, frames, expect: { <profile>: { <metric>: max } } }`, and `gdscript: |`
with a block that is the body of `func run(shell, runner)`: it can use the autoloads, `await
runner.frames(n)`, and returns an error string to fail.

`record: name` (or `{ name, hold_frames }`) records the flow from there to `record: stop` or the
scenario's end, for review and docs; recordings are never compared. They are made only with
`--record`: every drawn frame of the panel, with a ring where each tap lands and a half-second
hold after each step, encoded to `out/<scenario>/<name>.mp4` (ffmpeg) and shown in the report.

`measure` runs frames unthrottled and writes `out/<scenario>/<name>.metrics.json`: fps, frame
time p50/p95/max, the viewport's CPU render time, process CPU % and RSS, the compositor's
dispatch and upload times and bytes, and each client's frame rate. Limits are per profile
(`SHELL_PERF_PROFILE`, default `vm`); the VM's are regression limits only, the unit's come
with milestone 7.

## Vendor packs

A pack is a folder with a `theme.yaml`, as `tools/import-vendor` writes it (see its README), and
is the vendor's copyright: build it locally and never commit it. The shell finds packs in
`$LIVI_SHELL_THEMES`, else `~/.local/share/livi-shell/themes/`, one folder per pack, next to the
built-in `project/themes/`; a theme is picked by its folder name (`theme_name: kia-ev6`, or
`ThemeManager.set_look`). With no pack there, nothing changes.

- The pack's colors, sizes and fonts (`fonts/`, hinted as the stock UI renders them; a font may
  say `hinting: none | light | normal`) resolve like a built-in theme's.
- `skins: { card: <image key>, button: <image key> }` in `theme.yaml` replaces the drawn boxes of
  cards and buttons with the pack's images: 9-patches as `StyleBoxTexture` with the importer's
  margins, a selector's state map for a button's states (padding stays at least the component's
  own). Solid surfaces only; frosted, glass and scene themes ignore skins.
- `ThemeManager.pack` gives code the rest: `texture(key, mode, state)`, `box(key, mode, state)`,
  and the screens. Images are keyed `<package>/<name>`, day or night by the appearance.
- `Shell.open_page("ev_main")`, or the `page:` step, shows a
  pack screen (`PackScreen`) in place of the home page: every view at its rectangle in panel
  pixels, with its image and its text in the pack's font, size, color and gravity. The
  "Electric vehicle" screen binds the charge (`/telemetry/fuelPct`), the range (`rangeKm`) and the
  charging stop (`/navigation/chargingStop`: distance, and `name` if there is one); the rest
  stays at the pack's static values. This is the image page: the stock artwork, composited.
- Optional color tokens `road` and `road_far` (day and night) in a pack's `colors` give the live
  page's road its stock blue; without them the road is the accent. The importer does not
  write them yet: the EV6 pack's were added by hand from the reference.

`compare_reference: { name, reference, tolerance, min, mask: [[x, y, w, h]] }` renders the page
and passes when the share of pixels within `tolerance` (default 8) of the reference image is at
least `min` (default 0.98); masked regions are left out of the share. A relative `reference` is
read from the active pack's folder. It prints the share, and writes the render and the diff
(red: differs, blue: masked) to `out/<scenario>/`. A reference is never a golden and never
committed.

## Electric vehicle page

Two pages show the car's charge, range and next charger, and a look setting chooses between
them:

| `page:` | What it is |
|---|---|
| `ev_main` | the pack's image page (`PackScreen`), above; needs a pack with the screen |
| `ev_live` | the same screen drawn live by Godot, in every theme (`EvLive`) |
| `ev` | whichever the look chooses: `ev_page: image`, `live`, or `auto` (the default) |

`auto` is the image page where the active pack has an `ev_main` screen, else the live page, so a
built-in theme gets the live page and the EV6 pack its stock one. A theme can set `ev_page:` in
its `theme.yaml`; `ThemeManager.set_look({ev_page: ...})` and a scenario's `theme:` override it.

The live page is a 3D scene (`EvScene`, `EvCar`) behind the shell's own components, with the
labels projected from it:

- **Road:** one strip with a shader (`ev_road.gdshader`), `ROAD_UNITS` long, always ending at the range with climate off (the whole road is that range). Lit to the
  range with climate on (`/telemetry/rangeKm`), paler to the range with climate off, 50 km ticks, a
  warning segment over the last 25 km when the range is 50 km or less, a ring where the charger
  is, and a bright cap at the end. The charger (`/navigation/chargingStop.distanceM`) is a 3D pin;
  past the end of the road it stops there in the warning color, and nearer than a car length
  ahead of the nose it is drawn a car length ahead.
- **Range with climate off** has no telemetry field yet: it is `rangeClimateOffKm` when the core
  has one, else the range with climate on plus `EvLive.RANGE_OFF_FALLBACK` (12 %).
- **Car:** built from meshes, no model file and so no licence to carry: a translucent shell
  lofted from a side profile (`ev_glass.gdshader`: tint, sky reflection, a rim), over a battery
  block (`ev_battery.gdshader`) lit from the rear up to the charge (`/telemetry/fuelPct`) in
  the accent, four wheels, a floor plate and headlamps. A blob stands in for its shadow.
- **Camera:** a perspective camera fitted to the stock screen's road (edges, far end, markers),
  with a frustum offset that lifts the picture when large text makes the target row taller.
- **Theme:** day or night, the accent, the pack's `road` tokens; lights and the sky follow.
- **Motion:** changes ease in 0.6 s, except under reduced motion (`theme: { reduced_motion: true }`),
  where they are immediate.
- **Handedness:** the world is reflected across the camera's vertical plane for RHD, so the scene
  is the screen's mirror; the settings gear goes to the other edge and the three targets keep
  their order. Labels follow their anchors, and are moved clear of each other, the title and
  the targets; numerals shrink when the room is short.
- **Layout:** with a pack that has the stock `ev_main` views for the title and the targets, those
  rectangles, strings, type, skins and title bar; otherwise sizes from the theme's tokens (targets
  at least the rule table's size and gap, titles wrapping to two lines before they are trimmed).
- **Targets** (next departure, scheduled charging and climate, electricity use (V2L), settings)
  are real buttons with pressed states. The core has no action behind any of them, so a tap
  only emits `Shell.ev_action(id)`; their details ("Not available", "–") say what the
  core does not tell yet.
- **Quality:** `quality: normal` (the default) has a key light, a fill, a light under the car,
  the sky's reflections and 2x multisampling; `quality: low` has the key light only, no
  reflections and no multisampling. Selected with `ThemeManager.set_look({quality: low})`; nothing
  picks it automatically yet. On llvmpipe in the VM the page costs about 19 ms a frame under
  `normal` (about half of it multisampling) and 8 ms under `low`, against 10 ms for the home page
  (`perf-ev-live`); the unit's numbers wait for milestone 7.

A scenario's `fixtures: { packs: <dir under tests/> }` points the packs directory at its own
folder, and `requires: { theme: <name> }` skips it when that theme is missing.
`tests/fixtures/packs/synth/` is a synthetic pack drawn by `make-synth.py` (no vendor assets),
used by `pack-synth`; its `reference/` images are renders of its own page. `kia-ev6` runs only
where the EV6 pack is installed. To get one into the VM:

```sh
SHELL_PACK=godot-shell/ref/kia/ev6/2024/pack scripts/vm.sh scripts/test.sh kia-ev6
```

`kia-ev6` renders both pages: the image page against the reference as before (99 %), and the live
page against the same reference at 0.80 (it measures 0.85: the road, the car and the pin are drawn,
not the stock artwork).

`SHELL_PACK` is rsynced to `~/.local/share/livi-shell/themes/$SHELL_PACK_NAME` there (default
`kia-ev6`) before the command runs, and stays; `scripts/vm.sh "LIVI_SHELL_THEMES=/nonexistent scripts/test.sh"`
runs the suite as someone without it would.

## Tuning live

```sh
scripts/live.sh        # then open http://localhost:8765/
SHELL_PACK=godot-shell/ref/kia/ev6/2024/pack SHELL_CAR=godot-shell/ref/models/car.mesh LIVE_THEME=kia-ev6 scripts/live.sh
```

Runs the shell in the VM (`project/live/live_server.gd`, `-- --live`) and serves a page: the live
frame, sliders for the page's camera, road, data and look, and an overlay of the stock
screenshot (when the pack has one). Drag the picture to move the car, shift-drag to turn the camera,
wheel for the lens. "copy values" prints the `static var` lines to paste into `ev_scene.gd`
(`EvScene.tunables()` lists what a slider can change). The VM forwards host port 8765 to the
guest's (`run.sh`; `vm/qemu-aarch64/overlay` opens it in the guest's firewall). A VM started
before that needs `echo "hostfwd_add tcp:127.0.0.1:8765-:8765" | nc -U vm/qemu-aarch64/monitor.sock`.

## The unit's build

```sh
scripts/build-armv7.sh [--release]   # macOS or Linux -> project/bin/linux-arm32/
```

A cross build against a sysroot of Alpine edge's armv7 musl, libgcc and libxkbcommon (fetched
once), linked with clang and lld; needs rustup and `ld.lld`. No pmbootstrap. Packaging for the
unit is milestone 7.

## A car model

The EV page draws a procedural car. `car: auto` (the default outside tests; scenarios use
`procedural` unless a `theme:` step says otherwise) uses a model instead when
`$LIVI_SHELL_CAR` or `~/.local/share/livi-shell/car.mesh` exists. Make one from a binary STL:

```sh
python3 tools/car-mesh/convert.py car.stl ref/models/car.mesh --front=-y --wheels --remesh 0.03 --smooth 1.2 --agg 3 --tris 20000 --edges 12000   # needs numpy, scipy, scikit-image, fast-simplification
SHELL_CAR=ref/models/car.mesh scripts/vm.sh scripts/test.sh ev-live-car
```

`--edges N` keeps the N longest crease and panel lines on the outer skin and the shell draws them as thin lines (the look of a glass body with its seams), at the cost of one more draw call. `--wheels` cuts the model's wheels out and the shell draws its own, and `--remesh` rebuilds the outer skin as one clean closed surface (voxelised, filled column by column, smoothed): the model's thin parts and interior do not survive plain decimation.
The model is someone's work, so it is never committed (`ref/` is ignored); `ev-live-car` skips
without it and compares nothing. The shell draws it as the same translucent shell with the
battery block inside. Axes: front +x, up +y; `--front` and `--up` name the STL's.
