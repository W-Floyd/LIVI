# Godot shell: an alternative UI on LIVI's backend

A Godot 4 app as the head unit's whole UI. It embeds a Wayland compositor, so
LIVI's projection video, hosted apps (godot-maps, even LIVI's own Slint UI) and
our own pages are textures in one GPU scene. `livi-core` stays the backend,
unchanged.

Target: the Mobis G5W in a 2024 Kia EV6. That is armv7 with musl, postmarketOS
with GNOME, a Mali-G51 on panfrost (GLES 3, no Vulkan), and a 1920×720 panel.
Development happens in an arm64 postmarketOS VM on the Mac (see "Dev
environment").

## Why

- Slint (LIVI's UI) is good for system pages but weak for rich, animated, map-
  and 3D-heavy UI. Godot is strong there, and godot-maps already runs on it.
- No toolkit can embed other processes' windows by itself. A compositor has to
  sit under or inside the UI. Simula shows a Godot app can be that compositor.
- LIVI is already split into a backend and a UI process, so a second UI is a
  client, not a fork of the backend.

## How LIVI fits (verified in this tree)

- **Backend/UI split.** `livi-core` is the backend. `livi-ui` (Slint) is a client
  over `livi-core-proto`; the Rust client is `livi-core-client`. Our car work
  lives in the core: telemetry, the energy model, preconditioning
  (`livi-core/src/precondition.rs`), the charging stop, night mode.
- **Projection video is a plain Wayland client.**
  - `livi-core` starts `livi-gst-host` with `WAYLAND_DISPLAY` set to the UI's
    compositor (`livi-core/src/services.rs:115-118`).
  - Video goes out through `waylandsink` with dmabuf, with the V4L2 decoders
    ranked first (`livi-video-player/src/lib.rs:58`). Each stream is its own
    toplevel.
- **The compositor control protocol** is what our compositor must implement
  to stand in for `livi-compositor`.
  - `livi-compositor` learns a video surface's **tag** on its control socket
    before the window maps (`livi-compositor/src/ctrl.rs:244-256`,
    `pending_video_tags`), and matches it to the next toplevel
    (`shell.rs:126`).
  - Placement comes from `VideoCfg`: screen, crop, visible area and tier
    (`state.rs:36-46`), applied by `layout.rs:17-60`.
- **Touch to the phone goes through the core.** A UI sends
  `Message::Input { input: Input::Pointer { screen, points } }`
  (`livi-core-proto/src/message.rs:17`), with points normalised 0–1 over the
  projection area. The core turns them into phone touches
  (`livi-core/src/projection/input.rs`). Keys are `Input::Key`. No core change
  is needed.
- **`livi-compositor`** is smithay-based. It serves `xdg_shell`,
  `linux-dmabuf`, `drm_syncobj`, `wl_seat`, `viewporter`, `cursor_shape` and
  `data_device`. It has no `text_input`, popups or XWayland. Its client, dmabuf
  and seat code is the base to reuse in Rust.
- **Android Auto margins.** `projectionViewAreaRight` and the content insets
  (`livi-aa-stack/src/discovery.rs`) let Android Auto use part of the screen,
  for a split layout with a side panel. Whether the phone honours them is
  unverified.

## Precedent: Simula (SimulaVR/Simula, MIT)

- Simula is a Godot 3 fork (`3.x-simula`) with an engine module, `gdwlroots`
  (C++, SimulaVR/gdwlroots), that embeds wlroots. Godot runs the Wayland
  server; `WlrBackend`, `WlrCompositor`, `WlrXdgShell`, `WlrSeat` and
  `WlrXWayland` are nodes.
- It implements wlroots' renderer on Godot's GLES3 rasterizer
  (`gles3_renderer.cpp`), so client buffers become `WlrGLES3Texture`
  (`WlrSurface.get_texture()`). It uses dmabuf when the EGL Wayland bind
  works, tracks damage, and paces clients with `send_frame_done()`.
- Input goes through `WlrSeat`/`WlrKeyboard` with a keycode map. XWayland is
  supported.
- It runs on the GLES3 path, the same as our Mali. It's a daily-driver window
  manager.

## Architecture

```
godot-shell (Godot 4, GLES3 compatibility renderer)
├── gdext extension (Rust, godot-rust/gdext)
│   ├── compositor: smithay, from livi-compositor's code
│   │     clients' dmabuf/shm -> EGLImage -> GL texture
│   │     -> RenderingServer.texture_create_from_native_handle
│   ├── livi-compositor control protocol (video tags, VideoCfg)
│   └── core client: livi-core-client (state, actions, Input::Pointer/Key)
├── scenes: home, projection view (full or split), side panel, maps, stats,
│   car pages
└── hosted apps as textures: godot-maps, LIVI's Slint UI (settings and media at
    first), anything else that speaks Wayland
livi-core (unchanged), started with WAYLAND_DISPLAY = the shell's socket
livi-gst-host (unchanged) -> waylandsink -> the shell's compositor
```

Hosting LIVI's own Slint UI as a window lets the shell start small: it does
home, maps, the dashboard and projection layout, and shows LIVI's settings and
media pages until (if ever) they are rewritten.

## Theming

Everything that varies by car, driver or taste is data, not code. No scene
holds a color, font, size or position of its own; it reads them from the
resolved theme, and a theme change applies live, with no restart.

**What LIVI already has** (`livi-core-proto`): a `Theme` with palettes (accent
for dark and light), per-display layouts made of zones, and an
`AppearancePreference` (automatic, light or dark). The config also carries
`hand` (LHD or RHD), `darkMode`, the speed and temperature units, `carName` and
`oemName`. The shell reads these from the core and does not keep its own copies.
What the shell needs beyond them lives in its theme files until the core takes
them over.

**Layers**, each overriding the one before:
1. The shell's built-in default.
2. The car theme: branding, the car's 3D model, the panel, the default
   handedness.
3. The user's chosen theme.
4. The driver's profile: their preferences.
5. Accessibility settings.
6. Runtime state: day or night, from the core's appearance and night sensor.

A theme is a folder (or a `.pck`) with a `theme.yaml` manifest and its assets.
A `ThemeManager` autoload resolves the layers into a Godot `Theme` for the
controls, plus a token table for whatever is not a control (3D materials,
shaders, the compositor's backdrop). It emits `changed` when the result
changes.

**What a theme covers:**
- **Colors:** semantic tokens (surface, on-surface, accent, warning,
  critical, charging, and so on), each with a day and a night value. LIVI's
  palette fills the accent tokens.
- **Typography:** bundled font files, a type scale (display, title, body,
  caption, and numerals with tabular figures for speed and charge), and a
  global text scale.
- **Icons:** a named set of symbolic SVGs, tinted by token, falling back to
  the default set. The launcher uses freedesktop icon themes.
- **3D:** the car as glTF, with named nodes (doors, charge port, lights), a
  paint-color parameter and camera presets. A generic car is the default.
- **Layouts:** regions (projection, side panel, app area, status bar) as data,
  per display and per mode (full, split, apps), the same model as LIVI's
  layouts and zones.
- **Handedness:** from the core's `hand`. It mirrors each layout so the
  driver's controls sit on the driver's side, and it decides which side the
  projection's margin goes on (`projectionViewAreaRight` or `Left`).
- **Driver preferences:** which content sits nearer the driver (map or media),
  what the side panel shows, the start page, a 12- or 24-hour clock, and the
  units and language from the core's config. Preferences that only the shell
  uses are kept per driver profile in the shell's own settings.
- **Branding:** the OEM and car name and logo, the boot splash and the accent.
- **Materials:** each surface role (panels floating over the map, the status
  bar, sheets, the parked-only cover) has a material:
  - `solid`;
  - `frosted`: a background blur, a tint, a saturation boost and optional
    grain;
  - `glass`, which is frosted plus an edge highlight and a slight refraction
    and lensing at the edges, in the "liquid glass" style.
  How it's done:
  - It's a shader on a `BackBufferCopy`, sampling the screen texture's
    mipmaps. That's cheap and works in the GLES3 compatibility renderer.
  - Anything already in the scene can be blurred behind a panel: the
    projection, hosted windows and the 3D car.
  - Each material falls back to `solid` (the tint, made opaque) when the
    quality profile turns blur off, when the user asks for reduced
    transparency, or for high contrast.
  - The contrast check for text on glass uses the worst backdrop the panel
    can sit over (the tint mixed with the lightest and the darkest of what's
    behind it), not the tint alone.
- **Density (DPI):**
  - Sizes in a theme are physical: millimeters for touch targets and spacing,
    and points at a stated viewing distance for type. Each display's DPI turns
    them into pixels, so a page reads the same on the G5W's 1920×720 panel, a
    smaller head unit, the cluster, or a desktop window.
  - DPI comes from the panel's physical size. The compositor learns it from
    the output (as `livi-compositor` does: `panel <role> <mm_w> <mm_h> <w>
    <h>`), and the cluster's from the core's `clusterDpi`. A per-display
    override covers panels that report a wrong size.
  - It's applied per display through Godot's `content_scale_factor`, so
    layouts are written once in density-independent units.
  - Hosted Wayland clients are told the same scale (`wl_output` scale and
    `wp_fractional_scale`) and are rendered at it, not stretched.
  - The minimum touch target is a size in millimeters (on the order of 9 mm),
    checked after scaling.
- **Accessibility:** text scale, a high-contrast palette, reduced motion (no
  animated transitions or camera moves), a minimum touch-target size, and
  status never shown by color alone (always an icon or text as well).

**Tests:**
- A scenario's `theme:` key picks the variant it renders under:
  `{ name, hand, appearance, text_scale, contrast, reduced_motion, dpi }`.
  `appearance` moves under it, and `dpi` goes with the scenario's
  `viewport`.
- Key pages have goldens across a matrix: LHD and RHD, day and night, text
  scale 1.0 and 1.4, high contrast, and at least two densities (the G5W's
  panel and a smaller, denser one).
- The runner checks every scenario automatically:
  - each text and background token pair meets WCAG AA contrast;
  - every pressable control is at least the minimum touch-target size;
  - no label is clipped or overflows;
  - an RHD layout is the mirror of its LHD layout.
- `cargo test` validates `theme.yaml` against its schema.

## What the cluster already shows

The car's own instrument cluster shows some of what the shell could show:
speed, gear, charge and range, the time, the outside temperature, warning
lights, and sometimes the next turn or what's playing. Showing it twice costs
space on the center panel and pulls the driver's eyes away from the road
twice. So it is part of the car's config, next to the car theme.

**The vehicle config declares:**
- `cluster.shows`: what the cluster already displays, as tags from a fixed
  set: `speed`, `gear`, `charge`, `range`, `clock`, `outside_temp`,
  `telltales`, `next_turn`, `now_playing`, `trip`, `efficiency`. Where LIVI
  drives the cluster screen itself, its cluster layout adds its own tags.
- `cluster.show_anyway`: tags shown on the center panel even so (for
  example, `charge` while a charging stop is planned, or `clock` for the
  passenger). The driver's profile can extend or override this list.

**Components** declare the tags they duplicate (the charge stat duplicates
`charge` and `range`; the status bar's clock duplicates `clock`). A
component whose tags are all in `cluster.shows` and none in
`cluster.show_anyway` is left out, and its layout region collapses or
gives the space to its neighbors. A component that duplicates only some
of its tags stays.

**Tests:** scenarios set the vehicle config like a theme variant
(`vehicle: { cluster: { shows: [...], show_anyway: [...] } }`). Goldens are
kept with and without the duplicates, and the runner checks that no element
shows a tag the config hides.

## Quality profiles

Rendering cost is set by the device, not the theme. A theme says what a
page looks like; a quality profile says how much the GPU may spend drawing
it. The Mali-G51 has a different budget from llvmpipe or a desktop.

**What a profile sets:**
- Materials: whether `frosted` and `glass` may blur, the blur's mip level,
  and how often a still backdrop is blurred again. Off means the solid
  fallback.
- Anti-aliasing: MSAA for 2D and 3D, FXAA, or none. The panel's own pixels
  matter here; text is already anti-aliased.
- Textures:
  - mipmaps and filtering (linear or nearest, anisotropy) for theme assets;
  - a cap on texture size for the 3D car and other assets;
  - for hosted windows, nearest filtering when a window is shown 1:1, and
    mipmaps only when it is scaled down a lot, since every frame a client
    sends would need them generated again.
- 3D: render scale, shadows (off, or one baked shadow), the car model's LOD,
  and the reflection and lighting model.
- Motion: the animation and transition budget (full, reduced, or none), and
  whether the 3D camera may move on its own.
- Frame pacing: the target fps, and an idle mode that redraws only on change
  (Godot's low-processor mode, woken by core events and client commits).
  Video, when it shows, sets the rate.
- Memory: limits on texture and mesh memory, and how many window textures
  are kept.

**Profiles:** `unit` (the G5W), `vm` (llvmpipe), `desktop`, and `low` for when
the unit is under load. A profile is a file. Godot's feature-tag overrides
pick the default per build (`arm32` gets `unit`), and the settings can switch
it at run time.

**Adaptive:** if frame time stays over budget (for example, p95 over 16 ms
for a few seconds while projection video plays), the shell steps down a
profile, and it steps back up after a quiet period. It never changes inside
an animation, and it logs each change.

**Tests:**
- `measure` steps run under a named profile (`SHELL_PERF_PROFILE` selects
  both the profile and its limits).
- On the unit, every profile's numbers are recorded, so a setting's cost is
  measured, not guessed.
- Goldens are rendered under `vm`. A profile change that changes pixels
  shows up in the goldens' diff.

## App launcher

The shell can start any installed Wayland app and host its window, and it
treats its own pages (home, maps, stats, LIVI's settings) as entries in the
same launcher.

**Discovery:**
- Apps are found from XDG desktop entries in `XDG_DATA_DIRS`, which includes
  Flatpak's exports.
- `NoDisplay`, `Hidden`, `OnlyShowIn` and `NotShowIn` are honored. The shell
  claims the desktop name `LIVI`, so an entry can be shown or hidden for it.
- The shell's own keys:
  - `X-LIVI-DriveSafe`: may be used while moving;
  - `X-LIVI-Region`: full, split, or panel widget;
  - `X-LIVI-Hidden`.
- A file watch picks up installs and removals while the shell runs, so
  there's no rescan or restart.
- X11-only apps run through XWayland (see "XWayland") when the quality
  profile allows it. Otherwise they are hidden. An entry can be marked
  `X-LIVI-Wayland=false`, or is found to be X11-only by its first launch.

**Icons:**
- Icons are looked up by the freedesktop icon theme rules: inherited
  themes, sizes and scales, then `hicolor`, then the pixmaps folder. The
  shell's theme picks which icon theme is used.
- SVG is preferred, rendered at the display's DPI and cached.
- Symbolic icons are tinted with the theme's tokens.
- A missing icon falls back to a monogram on an accent tile.

**Launching** (in Rust, not `OS.create_process`, so the shell owns every
child it starts):
- `Exec` is run with its field codes stripped or filled, in the entry's
  `Path`, with `WAYLAND_DISPLAY` set to the shell's socket.
  `DBusActivatable` apps are started over D-Bus.
- Each app gets its own `systemd-run --user --scope`, so it has its own
  cgroup for CPU and memory limits and its usage can be measured. Where
  there is no systemd user session, a process group is used instead.
- An `xdg-activation-v1` token is passed in `XDG_ACTIVATION_TOKEN`. The
  window that presents the token belongs to that launch. Otherwise a window
  is matched by `app_id` to the desktop file's ID, then by
  `StartupWMClass`, then by the client's PID (`SO_PEERCRED`) within the
  launched cgroup.
- The launcher shows that an app is starting until its first frame,
  and reports a failure if no window appears within a timeout.
- Each app's stdout and stderr go to a per-app log.

**Lifecycle:**
- One instance per app by default. Launching an app that is running
  brings its window forward.
- Closing an app sends `xdg_toplevel.close`, then SIGTERM, then SIGKILL,
  each after a grace period.
- An app that crashes is reported, not restarted. Pinned panel widgets are
  the exception and are restarted, with backoff.
- Under memory pressure, which is likely on the unit, background apps are
  first frozen (cgroup freezer) and then closed, oldest first. The
  foreground app and projection video are never touched.
- Recent apps can be switched between from the launcher or with a
  side-panel gesture.

**While driving:**
- Apps not marked `DriveSafe` are limited once the car moves. Moving means
  speed above a threshold, or the parking brake off, from the core's
  telemetry.
- A limited app's window is covered (it keeps running) and its launcher
  icon is greyed, with the reason shown.
- Which apps count as safe is a driver setting, with the entry's key as the
  default.

**Arrangement:**
- A paged grid of icons, with favorites pinned to the home page or the
  side panel. The order, folders and hidden apps are kept per driver profile.
- The grid's sizes come from the theme and the display's DPI, and its
  layout mirrors for RHD.
- Search waits for the on-screen keyboard (see "Open questions").

**Tests:**
- A fixture data dir (`tests/fixtures/apps/`) is set as `XDG_DATA_DIRS`. It
  holds desktop entries for test clients, an icon theme with inheritance
  and missing sizes, an X11-only entry, a hidden entry and a `DriveSafe`
  entry.
- Rust unit tests cover desktop-entry parsing and field codes, icon lookup,
  and window matching (token, `app_id`, `StartupWMClass`, PID), all
  table-driven.
- Scenarios:
  - tap an icon → `wait: { window }` → screenshot;
  - launching a running app focuses it;
  - a launch that fails is reported;
  - setting `speedKph` limits an app that isn't `DriveSafe`;
  - an app that crashes is reported;
  - a desktop entry installed during the run appears in the launcher.
- `measure` records the time from tap to first frame for each app, and each
  app's cgroup CPU and memory, against limits for each profile.

## XWayland

Optional, for the X11-only apps (some games, older tools, Wine). Most apps
on pmOS are GTK or Qt and run on Wayland natively.

**How:** smithay's `xwayland` feature starts Alpine's `Xwayland`, and its
`X11Wm` is the X11 window manager (smithay's `anvil` compositor is the
reference).
- An X11 window arrives as a `wl_surface` from Xwayland. It takes the same
  texture path and the same `wl_seat` as any other client, so input and
  rendering need nothing new.
- **Started lazily:** the shell listens on the X display socket and starts
  Xwayland when the first X client connects. It stops Xwayland after a
  quiet period with no X clients, so nothing is paid until an X app runs.
- **Window matching:** X11 has no `app_id`, so `WM_CLASS` is matched against
  the desktop entry's `StartupWMClass`, with the PID as a fallback, as the
  launcher already does.
- **Override-redirect windows** (menus, tooltips) are placed from X root
  coordinates into their app's hosting region. Focus and stacking are kept
  in step with X.
- **Clipboard:** X and Wayland selections are bridged with smithay's
  selection helpers.
- **Scaling:** X11 apps don't know about DPI and render at scale 1. On a
  display scaled above 1 they're stretched; that's accepted, as
  1920×720 is scale 1.
- **Buffers:** Xwayland sends dmabufs (glamor), so it follows the dmabuf
  step of milestone 2, with shm as a fallback.

**Cost:** an Xwayland server takes on the order of tens of MB. It's allowed
by the `vm` and `desktop` profiles and off in `low`. Whether `unit` allows
it is decided by its memory on the unit.

**Tests:**
- A scenario launches an X11 test client (`xeyes`, or our test client built
  for X11). It waits for the window by `WM_CLASS`, then takes a screenshot,
  taps the window and checks the input arrives.
- Another checks that a menu opens at the right place in the hosting region.
- Another checks that Xwayland starts on the first X client and stops when
  the last one has gone.
- `measure` records Xwayland's RSS and its time to first frame.

## Milestones

Every milestone lands with its scenarios.

### 1. Toolchain and test harness

- [x] Build gdext for the arm64 VM, and cross-build it for armv7-musl
      (`scripts/build-armv7.sh`, macOS or Linux, no pmbootstrap).
- [x] Load it in Alpine's Godot 4.7.
- [x] Check that `livi-core-client` links from the extension.
- [x] Stand up the test harness (see "Testing") before any UI work: the fake
      core, the scenario runner, goldens, and the runner in the VM.

### 2. Compositor in Godot

- [x] A minimal smithay server in the extension, with `xdg_shell` and shm.
      `weston-terminal` shows as a texture.
- [x] Test clients, `fixtures.clients`, and the `measure` step.
- [ ] dmabuf, through EGLImage and a native GL texture.
- [ ] Input: pointer, touch and keyboard, through `wl_seat`.

### 3. LIVI's video

- [ ] Implement `livi-compositor`'s control protocol (the tags and
      `VideoCfg`).
- [ ] Start `livi-core` against the shell's socket.
- [ ] Show Android Auto as a texture; send touches as `Input::Pointer`.

### 4. Layout and theming

- [ ] Full-screen projection, a split with a side panel (the
      `projectionViewAreaRight` margin), and switching between them.
- [ ] The `ThemeManager` and the token, type and layout model (see
      "Theming"), with handedness, day and night, text scale and DPI
      working first. The placeholder page moves onto tokens.
- [ ] The theme checks (contrast, touch targets, clipping, mirroring) run in
      every scenario from here on.
- [ ] Quality profiles (see "Quality profiles") and idle redraw, with `vm`
      and a first guess at `unit`.

### 5. Hosting and the launcher

- [ ] godot-maps, then LIVI's Slint UI, as windows in a region.
- [ ] The launcher (see "App launcher"): discovery, icons, launching in its
      own scope, and matching windows to launches.
- [ ] The launcher's lifecycle, driving limits and per-driver arrangement.
- [ ] XWayland (see "XWayland"), lazily started, for X11-only apps.

### 6. Pages

- [ ] Home.
- [ ] Side panel: drive stats, and the preconditioning toggle (the core's
      `PreconditionBattery`) with its status.
- [ ] Stats and graphs, from the core's telemetry.
- [ ] Built-in pages as launcher entries.

### 7. On the unit

- [ ] armv7 package.
- [ ] Measure Android Auto decode plus Godot compositing on the Mali-G51
      (frame rate and latency), idle CPU and GPU with low-processor mode,
      and memory.
- [ ] Run every quality profile on the unit, set the `unit` limits from the
      results, and tune the adaptive step-down.

Go or no-go after 7: if the Mali can't composite the projection and Godot at a
usable rate, stop; the work up to 6 is still usable as hosted pages under
`livi-compositor`.

## Testing

Regression tests and screenshots come from the same scenarios, written in YAML
and run headless, in the VM and in CI. No test needs a phone, a car or a GPU.

**Layers:**
- **Rust unit tests** (`cargo test`) for the extension's logic: the control
  protocol, `VideoCfg` layout maths, touch mapping to `Input::Pointer`'s 0–1
  coordinates, and the core client's state handling. Table-driven, like the
  rest of LIVI.
- **Compositor tests:**
  - smithay's server under a test client (`wayland-client` in the test, or
    `weston-simple-shm`/`-egl`);
  - checks that a buffer becomes a texture of the right size, damage is
    tracked, frame callbacks pace, and input reaches the focused surface at the
    right surface-local coordinates.
- **Scenario and screenshot tests:** the YAML-driven runner below. These are
  the regression net and the source of every screenshot in the docs.
  - Scene-level checks (node state, signals, actions sent to the fake core)
    are scenario steps too.
  - A `gdscript` step embeds code for what the other steps can't express.
  - A Godot unit-test framework (gdUnit4) comes in only if logic written in
    GDScript outgrows that; such logic should go in the Rust extension
    first.
- **On the unit:** a smoke run of the same scenarios, recording frame times,
  CPU, GPU and memory against thresholds. On-device runs check performance,
  not pixels.

**Determinism:**
- **The fake core:** an in-process stand-in for `livi-core` that speaks
  `livi-core-proto`. It replays fixture state (telemetry, `/navigation`
  including `chargingStop` and `precondition`, settings) and records every
  action and `Input` the shell sends, for assertions. Fixtures come from real
  captures (micom-livi's posts, LIVI's state), checked in as JSON.
- **Fake clients:** test Wayland clients that draw known frames, a test
  pattern with a frame counter, stand in for the Android Auto video
  (`waylandsink`) and for hosted apps. They're tagged through the same control
  protocol.
- **Time:** run Godot with a fixed frame rate (`--fixed-fps`, Movie Maker
  timing) and an injected clock, so animations, the clock and "N min left" are
  identical on every run. Waits are counted in frames, not seconds.
- **Rendering:** goldens are rendered with Mesa llvmpipe at 1920×720 with the
  bundled fonts. Keep one golden set per renderer, and regenerate only on
  purpose.

**Scenario file** (`tests/scenarios/*.yaml`):

```yaml
name: split-precondition
viewport: { width: 1920, height: 720 }
theme: { appearance: night, hand: rhd }   # see "Theming"; appearance: day | night | auto
fixtures:
  core: fixtures/driving-to-charger.json   # telemetry, navigation, chargingStop
  clients:
    - { role: projection, tag: aa-main, pattern: grid }
    - { role: app, app_id: org.godot.maps, pattern: bars }
steps:
  - layout: split                         # full | split | apps
  - wait: { frames: 30 }
  - screenshot: split-idle                # golden: goldens/split-idle.webp
  - tap: { node: SidePanel/Precondition }  # or { x: 1700, y: 420 }
  - expect_action: { PreconditionBattery: { on: true } }
  - set: { core: { telemetry: { batteryConditioning: true } } }
  - wait: { frames: 10 }
  - screenshot: split-conditioning
  - tap: { x: 640, y: 360 }               # on the projection
  - expect_input: { pointer: { screen: main, x: 0.5, y: 0.5, phase: down } }
```

- Steps are tap or drag (by node path or coordinates), key, wait (frames or a
  condition), `set` (change fixture state mid-run), `expect_action`,
  `expect_input`, `expect_node` (property checks), `screenshot`, `measure`,
  and `gdscript`.
- A `gdscript` block is the body of `func run(shell, runner)`. It can use
  the autoloads, can `await runner.frames(n)`, and returns an error string
  to fail:

  ```yaml
  - gdscript: |
      var shown: String = shell.get_node("Home/Soc").text
      if shown != "%d %%" % roundi(Core.get_value("/telemetry/fuelPct")):
          return "shows %s" % shown
  ```
- Coordinates are the panel's, the same as touch on the unit.

**Runner:**
- `godot-shell --test tests/scenarios/` runs every scenario, or one by name.
- It compares each screenshot with its golden, per pixel with a tolerance and
  a maximum differing area, or with a mask for regions that may vary.
- It writes `out/<scenario>/<shot>.png` and a diff image for each mismatch
  (a pass compares in memory and writes nothing), and one HTML report with
  golden, new and diff side by side.
- `--update-goldens` rewrites the goldens (lossless WebP) on purpose; they
  are reviewed in the diff like code.
- `--shots-only` renders screenshots without comparing, for docs and review
  (day and night, every page).
- `--record` turns a scenario's `record` steps into MP4s of the flow, for
  review and docs, never compared. They're captured from the panel's own
  viewport, with taps marked and a pause after each step.

**Where it runs:**
- In the VM, under its GNOME session or a headless compositor (`weston
  --backend=headless`, or the shell's own compositor with no output).
- In CI in a Linux container: the same, with llvmpipe and no display.
- Before each merge: `cargo test` and all scenarios.

## Open questions

- gst-host's toplevels: what `app_id` and title they carry, and how the control
  socket's tag handshake runs end to end. Read `livi-compositor/src/ctrl.rs`
  in full.
- Whether `livi-ui` also drives the compositor's control socket, or only the
  core does. That decides what the shell must answer.
- Godot 4 interop: `texture_create_from_native_handle` with GL textures made
  from EGLImages on panfrost, and the sync with Godot's render thread.
- Text input and an on-screen keyboard for hosted apps (no `text_input` yet).
  Godot's own controls need their own keyboard.
- Running directly on DRM/KMS without GNOME later: smithay can, Godot would
  need to run on our compositor's output. That's out of scope until the above
  works.

## Dev environment

An arm64 postmarketOS GNOME VM on the Mac, running in QEMU with HVF, Mesa
llvmpipe and ssh. Scripts are in [vm/qemu-aarch64/](vm/qemu-aarch64/), with
the image beside them (not in git); see its README. The image is built with
nura-G5W-Android's pmbootstrap container, under a separate config that leaves
the unit's untouched. The shell runs nested inside the VM's GNOME. The VM is for
functional work only; performance is measured on the unit.

## References

- Simula: https://github.com/SimulaVR/Simula, https://github.com/SimulaVR/gdwlroots
- godot-rust gdext: https://github.com/godot-rust/gdext
- smithay: https://github.com/Smithay/smithay (livi-compositor's base)
- Godot `RenderingServer.texture_create_from_native_handle`
- LibGodot (experimental since 4.6): Godot as a library, if the shell should
  embed Godot rather than be a Godot app
- godot-maps: ../godot-maps, branch `armv7`
