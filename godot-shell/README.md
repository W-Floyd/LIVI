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
(`report.html`, metrics, and shots where they failed or were asked for) and the goldens the run
wrote back, so a run from another copy never reverts goldens written here meanwhile. Scenarios
render in a 1920×720 SubViewport under a headless weston with llvmpipe, at `--fixed-fps 60` and a
fixed clock, with the extension built in release. `check-gd.sh` runs
first and prints GDScript errors as `res://file:line`; a script that still fails to load in
the run stops it at once.

Each `VM_DEST` is a copy in the VM's home sharing one cargo target (`~/.cache/livi-target`);
`vm.sh` removes copies unused for 3 days and the target's debug build past 8 GB.
`scripts/clean.sh` reclaims the rest: the VM's and every worktree's debug targets, old extension
builds, and Docker's build cache older than 72 h (never its volumes).

Goldens are lossless WebP, a third of PNG's size. Captures are compared in memory and written
(as PNG) only on a mismatch, `--update-goldens`, `--shots-only` or `compare: false`.

Scenario fixtures: `core` (a partial state) and `clients`: `{ role: app, app_id, pattern:
grid|bars, size: WxH, animate: N, buffer: shm|dmabuf|nv12|i420, video: true, events: true,
honour: none|fractional|integer, scale: percent, text_input: <content purpose> }` runs the test client
(`events` logs the input it gets, for `expect_client`; `video` sends the picture as waylandsink does, a
viewporter-scaled subsurface under a placeholder toplevel; `scale` is what the compositor asks of it,
`honour` which protocol it draws by, `size` then in surface units; `size: 0x0` draws at each configure's size;
`text_input` binds zwp_text_input_v3 with that purpose, a tap in the window's top half enabling it and one in the bottom half
disabling it, and logs what is typed as `text commit …`; `popup: true` opens a grabbing xdg popup, 160×96
units of bars, below and right of each tap on the window, logging `popup configure X Y W H` and `popup done`), `{ role: command, run: [...] }` any
Wayland program. `apps: <dir under tests/>` is the launcher's only data dir, with its `apps.yaml`
(see "App launcher"). A scenario's `nav: true` docks the rail LIVI_SHELL_NAV turns on (`NavRail`),
which every page but the phone's lays out beside.

Steps: `page: home | ev | ev_live | media | app | apps | projection | <pack screen>` (see "Electric vehicle page"), `compare_reference` (below), `wait: { frames } | { window: app_id }`, `tap: { node } | { x, y }` (add `with: touch`
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
- **The car's state** (`CarStatus`), under the title on the car's side, each once micom-livi
  reports it: what is open (`door*Open`, `trunkOpen`, `hoodOpen`) on a top view of the car (the
  driver's door on the driver's side) and in words, past two parts a count, in the warning color;
  the charge port (`chargePortOpen`) on its own, "Charge port open", only while no cable is in (the
  charge card covers it then); the 12 V battery (`auxBatteryPct`, warning under
  30 %); the climate while its blower runs (the same rule as the range's name) with its draw
  (`climatePowerW`); the battery heater while it draws (`batteryHeaterW`).
- **Charging** (`ChargeCard`), at the top beside it while `charging` or `chargerReady`: "Charging"
  with the time to full (`chargeTimeToFullMin`) or "Plugged in", and for AC and DC the limit,
  the range at it and the time estimate (`chargeLimit*Pct`, `rangeAtChargeLimit*Km`,
  `chargeTime*Min`), a row only when the car reports either. Scenario `ev-live-car-state`.
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
wheel for the lens (mode "tune"); in mode "use" the pointer is the screen's touch. "copy values" prints the `static var` lines to paste into `ev_scene.gd`
(`EvScene.tunables()` lists what a slider can change). The VM forwards host port 8765 to the
guest's (`run.sh`; `vm/qemu-aarch64/overlay` opens it in the guest's firewall). A VM started
before that needs `echo "hostfwd_add tcp:127.0.0.1:8765-:8765" | nc -U vm/qemu-aarch64/monitor.sock`.

## The unit's build

```sh
scripts/build-armv7.sh [--release]       # the extension only: macOS or Linux -> project/bin/linux-arm32/
packaging/scripts/build-armv7.sh         # ext, test client, livi-core + children -> packaging/out/armv7/
packaging/scripts/import-project.sh      # docker: the imported project
packaging/scripts/smoke-armv7.sh         # docker: the armv7 build under qemu-user
```

A cross build against Alpine edge's armv7 musl packages, linked with clang and lld; needs rustup
and `ld.lld`. No pmbootstrap. The unit's engine is Alpine's `godot` 4.7.2 for armv7, and the
APKBUILDs for `livi-core` and `livi-shell` (launcher, systemd and OpenRC units, 1920x720 config)
are in `packaging/alpine/`; see [packaging/README.md](packaging/README.md) for the commands,
what runs where, and what is left for the unit.

## Deploying to the unit

```sh
scripts/unit-deploy.sh -n            # what would change: the unit's hashes and versions against HEAD
scripts/unit-deploy.sh [-b] [-p] [shell|core|micomd|all] [host]    # -b: build and compare, install nothing
```

Builds from HEAD, never the working tree: `shell` and `core` from a clean worktree in
`~/.cache/livi-unit-deploy` (`LIVI_DEPLOY_CACHE`), `micomd` from `PMAPORTS_DIR`'s HEAD with
`tools/pmb`. Installs only what differs from the unit, then one root step (one sudo prompt, or
`LIVI_UNIT_SUDO_PASS`) installs, restarts and prints a check.

- `shell`: `scripts/unit-sync.sh` (project, extension, load check), then restarts livi-shell.
- `core`: livi-core, livi-output and livi-helperd whose sha256 differs from the unit's, with
  livi-shell and livi-shell-core stopped. Starts `livi-wifi-ap` if a new helper left it down.
- `micomd`: micomd, micom-livi and micom-precondition when the unit's are neither the APKBUILD's
  go-micomd version nor this build's sha256. By default built here with `go` from a worktree of
  `GO_MICOMD_DIR` at that commit (seconds) and copied over the package's files, `mkinitfs` only
  for a new micomd, micomd then micom-livi restarted; `apk audit` lists them modified until a
  package deploy. That is `-p`, and is taken anyway when the unit has no micomd package or
  device-mobis-g5w(-systemd) differs: apks built with tools/pmb (minutes), `apk add`, a drop-in
  whose ExecStart flags are now all packaged removed, `mkinitfs`, the restarts. A go-micomd commit
  on no remote branch of `GO_MICOMD_DIR` is built from that checkout.
- `all` (the default): micomd, core, shell.

## Video on the unit

The compositor takes planar YUV dmabufs (NV12, I420) from clients, as `livi-output`'s
`waylandsink` sends them from the CODA decoder. EGL lists NV12 external-only, which Godot's
canvas shaders cannot sample, so each plane is imported as its own plain image (R8 luma, GR88
chroma) and `gl_scene.rs` converts to RGB on the GPU (limited range; BT.709 from 720 lines up, else
BT.601; `LIVI_SHELL_YUV_MATRIX=601|709` forces one) into the window's texture, with viewporter
crop/scale and subsurface placement. No CPU copy. Dmabuf subsurfaces are drawn over any shm
layers. At startup the shell logs `compositor: planar YUV dmabuf: <fourcc>:<modifier> ...`; none
means EGL imports no R8/GR88 planes.

With the shell running on the unit:

```sh
export XDG_RUNTIME_DIR=/run/livi-shell WAYLAND_DISPLAY=livi-shell
gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! waylandsink
# the decoder's path: ... ! v4l2h264dec ! waylandsink
```

## Projection

livi-output's windows (app_id `livi-video*`) are the phone's picture. `waylandsink` fits its
video into the 1920x720 window it is given, but Android Auto sends a 16:9 tier (1920x1080 for a
1920x720 screen) and draws its UI in the middle, in the projection screen's shape; the core maps
touches over that area into the stream (`android_auto::to_stream`, with livi-media's `crop_for`).
So the compositor shows such a window as its video at the buffer's own size (`Wayland.set_native`),
and `WindowView` cuts that same centred area out (`projection_crop`, from the core's
`/config/projectionWidth`/`Height`, else the panel) and fits it to the view: on the full panel it
is 1:1, as stock LIVI placed it (1920x1080 at 0,-180). Touches go to the core normalised over that
area. In the home page's narrower slot the same area is letterboxed; asking the phone for a
layout that fits the slot is not done (stock sets `projectionViewArea*` per session).

`page: projection` (the rail's "Full") shows the newest projection window alone on the panel: no
status bar, side panel or rail. A back button shows in the top-left corner for 4 s when it opens,
and again on a tap there; that corner is not the phone's. The shell follows the core's main screen
as the stock UI does: opening the projection page (or `app` with a projection window) sends
`Show { main, projection }`, any other page `Show { main, livi }`; `/front/main` turning to
`projection` (the phone asks for the screen) opens the projection page, and turning to `livi`
(Android Auto's own exit, or the end of the phone's ask) leaves it for the page before. A core
`OpenPage` of `/projection` (or `/`) opens it too; other paths are logged, as the shell has no
such pages.

## Media

`NowPlaying` reads the core's `nowPlaying`, `sessions`, `dab` and `fm` for home's player and the
media page (rail item, or a tap on the player; the core's `/media`, `/media/phone|dabplus|fm`
open it). The cover (base64 PNG, JPEG or WebP) is decoded on a worker thread only when the string
changes. The position runs on between reports as stock's `Playback` does: held after 3 s without
progress, still for a second after a seek. As stock: seeking (`seek`) only under CarPlay and
AirPlay; with a DAB+ stick, Phone, DAB+ and FM tabs (`phoneResume`, `dabResume`, `fmResume`), a
band's stations (`dabPlay`/`fmPlay`, the tuned one playing `dabPause`) and favourite; transport
is `phoneMedia` on the phone's tab, a band's resume when it is not on air, else `media`. Volume
is `huVolume`, as the hard keys. The core has no shuffle or repeat. Scenario `media`.

Home's media card (`MiniPlayer`) leads home while something plays (`HomeCards.tall`): with the
phone hidden it takes the large slot on the driver's side and the other cards stack beside it at
their own heights, centred. Beside the phone the picture comes first: on their own the cards take
no more than a third of the body (`Shell.SIDE_SHARE`; side by side a half, `SIDE_SHARE_SPLIT`),
never less than their column, and a drag on the divider gives the picture a third, a half or two
thirds of it (`Shell._snaps`); a column with room for two (`TALL_SHARE`, `TALL_TOUCH`,
`REST_TOUCH`; a larger panel) gives it a column of its own on the driver's side (the card most
touched), the rest stacked from the top, as narrow as their widest card, else it fills what the
stacked cards leave, never shorter than the tallest of them (a row the battery card carries aside).
It is never left out: where the cards don't fit (`Shell._fit`), Precondition moves into the battery
card as its bottom row (`HomeCards.foot`, `StatTile.foot`), then goes to one line there
(`ToggleRow.compact`), then, with the status bar off, beside the <app> | <phone> toggle (its icon
and Auto where its words don't fit), then the battery card compact (`StatTile.compact`), then the
media card to one row without prev; only then do cards go, Precondition first; with nothing
playing, the compact media card goes first. It lays itself out by that room
(`HomeCards.child_rect`, shown or not): `wide` (cover the card's height beside title, artist,
album, a position bar and larger controls, as the Media page), `tall` (cover over them), one row,
or the controls in a row under the text when it would keep fewer than `MIN_CHARS` beside them.
Nothing playing: a compact "Nothing playing / Open Media" card. The cover is drawn square at every
size (`ArtView.square`); beside the text its top is the title's and the controls start at the
text's edge, under it they are centred. Scenario `media-player`.

Look's Home layout (`home_layout`) Side by side (`HomeCards.side_by_side`) puts the battery card in
a narrow column the panel's height away from the driver: the charge over a bar that fills upward,
the range under it (`StatTile.vertical`), Precondition one line in its foot (its icon and Auto
where its words don't fit), reaching down, with the status bar off, beside the <app> | <phone>
toggle, which then sits under the media card from its edge (across the foot, the column ending
above it, where the media card is narrower than the toggle). The media card takes the rest of the
width and the height on the driver's side, the charging stop over it: `wide` where its cover beside
the text gets `WIDE_TOUCH` touch targets, else its cover the card's width, cropped
(`ArtView.fill_rect`), over the title, artist, bar and controls (`cover`, prev going where three
don't fit); with nothing playing, the placeholder so. The same with no picture; a right-hand drive
mirrors it. Where the media card's controls want the width or the column the height, the battery's
type goes smaller (`StatTile.compact`), then Precondition goes. Cards never overlap: the
dashboard's stacked cards are at least as wide as the widest.

## App launcher

`page: apps` (the rail's grid) lists what the unit can run and starts it as a client of the
shell's compositor; its window opens on the `app` page, in front. The running windows sit in a
strip by the title: a tap brings one forward, its × asks it to close (`xdg_toplevel.close`, then
SIGTERM and SIGKILL to the app's process group, 3 s apart). A running app's tile shows its window
rather than starting another. Projection video (`livi-video*`) is not listed.

- **Desktop entries** from the XDG data dirs (`LIVI_SHELL_APPS_DIRS` replaces them): `NoDisplay`,
  `Hidden`, `OnlyShowIn`/`NotShowIn` (the shell is `LIVI`), `TryExec`, `X-LIVI-Hidden`; terminal
  apps are left out. `X-LIVI-DriveSafe=true` marks one usable while driving (see "While
  driving"). Icons from `hicolor` (SVG, else the PNG nearest above 128 px), then `pixmaps`; none is
  a monogram tile.
- **Waydroid's apps** (`waydroid app list`, read in the background while its session runs).
  Waydroid also writes desktop entries, by the same IDs (`waydroid.<package>`), which win.
- **`~/.config/livi-shell/apps.yaml`** (`LIVI_SHELL_APPS` replaces it):
  `order: [id, ...]` first, the rest by name; `waydroid: false`; and per ID
  `apps: { <id>: { name, icon, exec, app_id, hidden, timeout_s, scale, drive_safe } }`, where an
  ID nothing provides and an `exec` (desktop `Exec` syntax) adds a command.

Apps start in Rust (`AppCatalog`), each in its own process group, with `WAYLAND_DISPLAY` set to
the shell's socket, `DISPLAY` unset and the toolkits told to use Wayland; output goes to
`~/.local/state/livi-shell/apps/<id>.log` (`LIVI_SHELL_APP_LOGS`). A window is the launch's when
its app_id is the entry's ID, `StartupWMClass` or apps.yaml `app_id` (whichever process shows it:
a single-instance app hands off to the instance owning its D-Bus name and exits 0), or its client
is in the launch's process group; failing that, the only launch waiting takes it. A launch that
exits non-zero, or shows no window in 60 s (Waydroid: 90 s; GTK4 apps' first start on the unit
compiles shaders and reads everything cold), is marked on its tile; after 10 s it says it is still
starting. The log says `launched <id> in <ms>` when the window maps. XWayland is not served, so
X11-only apps don't show.

Windows fill the app area over the app's scale, whatever they ask, maximized and tiled on every
edge (title bars, no shadows or rounded corners), or fullscreen when the app asks (a Leave
Fullscreen goes back) or its menu's Window choice says so (`app_window_modes` in the look,
applied at launch and live). Requests are answered with that size (Firefox maximizes before its
first commit). Menus
and popovers (xdg popups) are drawn into their window where the positioner puts them, slid or
flipped as it allows to stay inside it, and take input; a tap outside a grabbing popup closes it
and goes no further, as does leaving the app page (scenario `app-popup`). Keyboard focus stays
with the window.

The shell serves `org.freedesktop.portal.Settings` itself on the session bus (`portal.rs`;
`LIVI_SHELL_PORTAL=off` stops it): `org.freedesktop.appearance` `color-scheme` from the
appearance, `accent-color` from the theme's accent, `reduced-motion`, with `SettingChanged` when
they change, so GTK4/libadwaita apps (and Qt 6's portal-aware themes) follow day and night live;
`org.gnome.desktop.interface` `gtk-theme` does the same for GTK3. The real xdg-desktop-portal
cannot start for the kiosk (its user unit requires `graphical-session.target`). A thread keeps
it served: no bus yet, a lost connection or a name another portal owns are retried every 5 s.
Until it is served, apps get `ADW_DEBUG_COLOR_SCHEME` at launch instead, fixed for their life.
The launcher's lines, the portal's status among them, also go to
`~/.local/state/livi-shell/shell.log`: the kiosk service's stdout is the console, not the journal.

### Typing into apps

The compositor serves `zwp_text_input_v3` with the shell as the input method (`text_input.rs`;
smithay's own relays only to an input-method client). When the focused app enables its text
input (scenarios `app-keyboard-gtk` and `-godot` check GTK 4 and Godot's LineEdit; GTK 3,
Firefox and Qt 6 speak the same protocol), `AppKeyboard` slides in over
the driver's side of the app page, 55 % of its width, beside the rail, and the app is configured
to the rest (`Wayland.set_app_area`), so it lays its field and results out beside the keys: a
keyboard along the bottom would leave a 720 px panel's app a strip too short for a result list.
Letters go as `commit_string`; backspace and Done as keys (Backspace, Enter), which every client
takes. The content purpose picks the keys: digits, number, phone, PIN the keypad; email `_ - @`,
URL `/ : -`; a password (or the hidden or sensitive hint) shows no preview and no key pop. The
text the app reports around its cursor (GTK does, Godot does not) shows above the keys.

It goes on Done (after Enter), cancel, the app disabling its text input, its window losing focus
or closing, or another page. A tap on the field while the app still wants text brings it back.
An app with no text input (`Wayland.has_text_input`) gets a keyboard button in its driver-side
corner instead, and typing reaches it as key presses on a US layout. Projection windows never get
it: the phone draws its own.

On home, for the navigation app in the slot, it takes the cards' column widened to at least that
55 %, and the app is configured to what is left of the slot until it goes. Keys fit any width:
labels shrink to their key, and narrower than a finger's width per letter the letters' last row
drops `' - @` (the symbols layer has them). Each key takes a finger's touch only, not the mouse
Godot emulates from it, so it acts once and on the press. Built ahead and kept hidden, a keyboard
shows the frame its field asks (its layers beyond the first are built the frame after); with
`LIVI_SHELL_TIMING` the shell logs `[keyboard]` lines from the ask to the first frame and to in
place. Esc and Ctrl's toggle is an icon outside terminals.

Terminals get a row of Esc, Tab, Ctrl, Alt, Super, arrows and Fn (F1 to F12) between the bar and
the keys: by the terminal purpose (VTE sends it), a desktop entry with `Categories=TerminalEmulator`,
or a known app_id (`AppKeyboard.TERMINALS`); the bar's toggle shows it for any app. Ctrl, Alt and
Super are sticky (once for the next key, twice to lock, tinted and lit as shift is), and while one
is down letters go as keys under it rather than as commits: VTE ignores a committed control
character (`app-keyboard-console` checks Console's shell reads Ctrl+C as 0x03).

Terminals and multiline fields (the `multiline` hint) get Enter in Done's place: it sends Return
and the keyboard stays, and a hide key on the bar puts it away. A web address's field says Go;
the rest say Done (text-input-v3 has no search purpose, so a search field cannot say Search).

### The navigation app

Settings → Look → "Navigation app" (or "Use for navigation" in an app's menu) makes a launcher app,
godot-maps typically, home's other occupant of the phone's slot (`nav_app` in the look). While the
phone and it are both there, an "<app> | <phone>" toggle (`SourceToggle`) in the status bar, in
place of the phone's name (its segments icons only in a column; with the bar off, under the cards
on the slot's side, the cards above it), picks which the slot shows (`home_source`, kept). With no
phone the slot is the app's. Picked, the app starts without the app page if it is not running and
stays running when the phone is picked again; the phone keeps video focus only while it is shown.
Its window is configured to the slot (`Wayland.set_window_area`, a window's own area over the app
area) whenever the split settles, as the phone is asked for its area; opened from Apps, the same
window moves to the app page at the app area, and back to the slot on home. Its keyboard covers the
cards. It counts as DriveSafe. It is kept running while designated, whatever page shows: started
when the shell starts (once the launcher lists it), and after an exit again in 2 s, doubling to 60
s (reset after a minute up), unless the driver closed it from the switcher. Scenario
`home-phone-toggle`.

## While driving

`Drive` (an autoload) says whether the car is driven and what that locks, as PLAN.md's "What a
screen visible to the driver may show" asks. Driving is not being in Park (NHTSA): a car stopped
at a light is still driven. `DriveState` (Rust, `driving.rs`, table-tested) decides from the core's
telemetry, strongest first: `ignition` false is parked at once; `drivingRegulation`, the car's own
video and keyboard lockout (micom-livi's, out of Park in D, N and R alike); `reverse`; an
automatic's `gear` letter; the `parkingBrake` released or 5 km/h; speed alone from 5 km/h. It
locks at once and lifts only once parked has held 1.5 s (speed alone: under 1 km/h for 10 s), so a
shuffle through P does not flash the covers off. Nothing reported is parked.

While it locks:
- a hosted app not marked DriveSafe (nor the navigation app) is covered on the app page ("Available when parked"; the
  app keeps running and gets no touch or key) and greyed in the launcher, which says why;
  a window no launched app owns counts as not DriveSafe;
- typing is off: the app keyboard and Settings' text and number entry show the same cover, with
  Close; an app's keys button hides while its app is covered;
- the phone's projection is never covered: Android Auto and CarPlay apply their own limits.

Settings → Look → Driving, "While driving", chooses the override, kept in
`$XDG_CONFIG_HOME/livi-shell/driving.json` (not in tests):
- **Follow the car** (the default).
- **Passenger mode**: the cover offers "A passenger is using it"; a second tap confirms ("Only a
  passenger should use the screen while the car moves") and unlocks until the car parks, or at
  once when `ignition` or `vehicleReady` goes off; each drive asks again. A "Passenger" pill shows
  at the top while it lasts.
- **Always offroad**: never locks, for testing on a bench or in a car that reports driving wrongly;
  offered only once "Developer options" is on, and an "Always offroad" pill in the warning color
  shows for as long as it is chosen.

While the car is driven the choice can only go back to Follow the car, and the developer options
wait until it parks. The group's first row says what the shell thinks (Parked, Driving) and
what decided it. Not done yet: a per-app DriveSafe choice in Settings, the region profiles (album
art, JAMA's 30 characters), and the stock head unit's list of settings it locks while driving
(only typing is locked here). Scenarios `drive-lockout`, `drive-override`.

## Settings

`page: settings` (the rail's gear) is LIVI's settings and the shell's look, so the panel needs no
LIVI UI. LIVI's part is livi-ui-model's tree, the one stock LIVI's UI draws: `CoreLink.settings_*`
keeps the page stack, evaluates the screen against the core's state, and sends what stock sends
for each touch (`SetConfig`, `SetDongleRadio`, a row's action; `ApplySettings` from the Apply
button, shown while a restart-only key differs with a phone connected). Short choices are set in
place, longer ones open a list; numbers with few steps get a stepper. Text and colour need a
keyboard and are shown only, as are the calibration pages. Stock's Restart and Power Off pages act
as they open, so their rows ask for a second tap.

"Look" sets `ThemeManager`'s look and keeps it in `$XDG_CONFIG_HOME/livi-shell/look.json`
(`~/.config/...`), read at start (not in tests). Its day or night is Auto (the core's
`mainUiNightMode`, which follows LIVI's own appearance setting), Day or Night. Its Status bar
(`status_position`) runs along the top (stock), the bottom, as a column of stacked items down the
left or right, or is Off; in a row the clock and the outside temperature are in its middle. On home
with the picture shown, a top or bottom bar rides the cards: it spans their column only, over or
under them (their margin), and the picture has the panel's whole height (`Shell._riding`); where
its row does not fit that width the outside temperature goes first, then the slot toggle's app
segment is its icon alone, then both segments (`SourceToggle.squeeze`). Dismissed, and on other
pages, it spans the width; a column or Off is as before. Every page with the bar lays out in the
rest (`Shell.content_rect`); on the driver's side a docked rail stays at the edge and the column
sits beside it as one band. Its charge shows wherever home's battery card does not
(`StatusBar.charge_shown`); on home, while the phone and the navigation app share the slot, the
slot's toggle takes the phone's name's place (`StatusBar.source_slot`).

The docked rail's order is the look's too (`rail_order`, item ids top first; unknown ids are
dropped and missing ones follow in the default order). On the rail, a press held still for 400 ms
lifts an item, the others make room as it is dragged, and the release drops it; a press that moves
first does nothing, and a drag off the rail puts it back. With the rail docked, Look's "Navigation
rail" lists every item, one the rail hides (Phone, with no phone) dimmed with why, each moved by
its arrows, and "Reset order". Scenario `nav-rail`.

The look resolved is also written, on every change, to `tokens.json` beside `look.json`: the
contract for apps the shell hosts (godot-maps), so they need not read theme files. It holds
`version` (1), the look's choices (`theme_name`, `appearance` resolved to day or night, `hand`,
`near`, `text_scale`, `material`, `reduced_motion`, `quality`), `colors` (token to `#rrggbb[aa]`),
`series`, `px` (size token to panel pixels) and `fonts` (`display`, `body`, `strong`: `weight`,
and `path` when the font is a file on disk). It is replaced through a rename, never half-written.
Under Auto it waits for the core's night mode, then follows it (scenario `settings-apps`).

An app adds its settings as a section by installing a schema,
`<XDG data dir>/livi-shell/settings/<name>.json` (godot-maps: `/usr/share/livi-shell/settings/godot-maps.json`):
`id`, `title`, `icon` (an `Icons` name), `values` (its values file, relative to `$XDG_CONFIG_HOME`)
and `sections: [{ title, rows: [{ key, kind, label, detail, default, ... }] }]`, where `kind` is
`toggle`, `choice` (`options: [{ value, label }]`), `slider` (`min`, `max`, and `labels` for
evenly spaced stops), `text` or `info` (both shown only). The section's rows read and write the
values file, a JSON object of key to value (a key missing is its default), rewritten whole through
a rename; the app watches it, and the open section follows the app's own writes. Scenario
`settings-apps` (fixtures in `tests/fixtures/app-settings/`).

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
