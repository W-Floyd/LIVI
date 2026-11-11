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
- **Handedness:** from the core's `hand`.
  - Panels and controls move to the driver's side. Reading order, headers,
    full-screen views and the status bar's order stay the same. That's the
    practice of TomTom's guidance and Google Maps on Android Auto; no
    standard requires mirroring (see `docs/car-ux.md` §7).
  - It also decides which side the projection's margin goes on
    (`projectionViewAreaRight` or `Left`).
- **Driver preferences:** which content sits nearer the driver (map or media),
  what the side panel shows, the start page, a 12- or 24-hour clock, and the
  units and language from the core's config. Preferences that only the shell
  uses are kept per driver profile in the shell's own settings.
- **Branding:** the OEM and car name and logo, the boot splash and the accent.
- **Powertrain:** from the core's `carType` (gasoline, the diesels, LPG, CNG, LNG, E85,
  hydrogen, electric, hybrids); with none set, battery telemetry means electric.
  - Combustion cars show fuel instead of charge, and have no preconditioning and no charging
    stop.
  - Hybrids show fuel plus electric range.
  - Pages, components and scenarios cover both kinds (`tests/fixtures/gasoline.json`).
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
- The runner checks every scenario automatically, against the rule table
  below:
  - each text and icon pair meets the contrast minimum (4.5:1, and 5:1 at
    night);
  - every pressable control meets the touch-target size and gap;
  - no label is clipped or overflows, and no number wraps away from its unit;
  - in RHD, the driver-side panels have moved and the reading order has not.
- `cargo test` validates `theme.yaml` against its schema, and validates each
  chart series palette (lightness band, chroma, separation under color-vision
  deficiency, contrast) against its surfaces.

**Rule table:** the sizes and limits every component is built from, each
with its source in `docs/car-ux.md`. Components take these as parameters,
so a rule can change without a component changing.

| Rule | Default | Source |
|---|---|---|
| Touch target | 10 × 10 mm | Euro NCAP 2026 |
| Gap between targets | 4 mm | Euro NCAP 2026 |
| Character height | 20′ arc (16′ floor) | ISO 15008, secondary |
| Text and icon contrast | 4.5:1; 5:1 at night | Android Auto; ISO 15008 |
| Response to a touch | ≤ 250 ms; busy shown after 2 s | NHTSA, Alliance |
| Characters at once while driving | ≤ 30 | JAMA |
| List rows while driving | ≤ 12 | CarPlay |
| Task depth | ≤ 2 steps from home for car functions; ≤ 5 for others | Euro NCAP; Android Auto, CarPlay |
| Driving | not in Park | NHTSA |
| Locked while driving | video, auto-scrolling text, text entry, reading web or messages, non-driving images | NHTSA, ESoP, JAMA |
| Viewing distance | 750 mm (to be measured in the EV6) | assumption |

**Charts** are components too, drawn by a Godot `Control` (`_draw`), with
history kept and downsampled in the extension (telemetry has no history of
its own):
- A sparkline (one series beside its value, no axes) may show while driving.
- Charts with axes, such as the charge curve from the car config's
  `evChargeCurve`, show when parked, with a one-line summary while driving.
- Splits show at most four segments, with a legend and values, never color
  alone.
- Series take the theme's validated series palette in a fixed order. Text
  uses text tokens, and status colors are never used for series.

## What the law and the car decide

These override the theme, the layout and the driver's preferences. Sources
are in `docs/car-ux.md`.

**Reversing camera** (FMVSS 111 in the US, UN R158 in the EU; both are
law):
- When the car goes into reverse (`reverse` or `gear` from the core's
  telemetry), the camera takes the whole panel within 2.0 s. It comes from
  LIVI's `camera` video plane, which `livi-compositor` already ranks above
  all other video.
- Each time it opens on the default view. It stays until the driver changes
  the view or leaves reverse. In the US it must not stay up once the
  backing event ends (forward past 10 mph, 10 m or 10 s; for UN R158,
  16 km/h).
- Inside the required field of view, overlays show only rearward-driving
  or safety information: guide lines and distance warnings, no media or
  notifications.
- If the car's own system shows its camera instead, the shell gives up the
  screen and draws nothing over it.

**Always within reach** (Euro NCAP 2026; a rating, not law, but the
benchmark for any car):
- Volume and mute are always-visible touch controls, grouped together, on
  every page and over the projection. The steering-wheel keys reach them too
  (`Input::Key`).
- Next track, and answering or rejecting a call, take one touch from
  wherever the driver is.
- Car functions the shell offers (climate, seat heating, demisting, if they
  come) are at most two steps from home.
- Warning colors keep the meaning ISO 2575 gives them (red danger,
  amber caution, green on, blue high beam). The shell never uses them in a
  way that could be mistaken for the car's own telltales.

**What a screen visible to the driver may show** (California VC 27602, UK
reg 109, Australia ADR 42 and road rule 299, Japan art. 71; all law):
- While driving, nothing outside vehicle information, navigation and
  maps, the road around the car, and route guidance shows on the driver's
  screen: no video, no auto-scrolling text, no reading, no non-driving
  images.
- Album art is the grey area. NHTSA allows it during a selection that ends;
  UK reg 109's list arguably excludes it (that reading isn't tested in
  court). A **regional profile** in the car config (`region: us | us-ca | gb
  | eu | au | jp`) picks the strictest reading for where the car is driven.
  Strict profiles replace artwork with a plain icon while driving, and `jp`
  also enforces JAMA's 30 characters.
- The parked-only cover and the launcher's driving limits enforce this. The
  region profile only decides how far they go.

**Brightness** (FMVSS 101 S5.3.4; law in the US, on the vehicle):
- The panel has at least two brightness levels at night, through the core's
  `displayBrightness` and automatic brightness, and a way to turn it off
  (screen off, with a touch to wake it).
- The night palette is not a substitute for dimming.

**Responsiveness** (NHTSA, the Alliance):
- Every touch shows a visible response within 250 ms.
- Anything that takes longer than 2 s shows that it's busy.

**Tests:**
- A scenario sets `reverse` and expects the camera plane full screen within
  2.0 s of panel time (120 frames at 60 fps). It then checks that nothing
  else is drawn over it, that the default view returns each time, and that
  the camera goes when the backing event ends.
- Volume and mute are found on every page, in every scenario (a runner
  check).
- For every region profile, a scenario checks what hides while driving.
- The runner measures the frames from each tap to the first change on
  screen, and fails a tap that takes longer than 250 ms.

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

## Vendor themes

A theme can reproduce the car's stock UI as exactly as possible: its fonts, colors, icons,
artwork, layout positions, sounds and timings. The shell then looks native, so a driver sees
the car's own design, with LIVI's functions behind it.

**What stays out of the repo:** the vendor's fonts, icons, logos and artwork are its
copyright, and LIVI is public. The repo carries the mechanism, the importer and the schema,
but no vendor assets. A vendor theme is a **pack** built locally from the owner's own unit and
kept on it (`~/.local/share/livi-shell/themes/<pack>/`). The README says not to redistribute
packs.

**Where a pack comes from (the G5W):** stock Android 4.4 still boots first, so its
`/system` is on the unit: Mobis's launcher and system APKs, `framework-res`, `/system/fonts`.
`tools/import-vendor` (to write):
- takes a copy of those files from the owner's unit;
- decodes the APK resources (colors, dimensions, styles, drawables including 9-patches, fonts);
- writes a pack: a `theme.yaml`, plus the assets it refers to;
- maps the shell's icon names to the vendor's drawables, and lists what it couldn't map.

**What a pack can set, beyond a normal theme:**
- **Skins from images:** 9-patch and bitmap backgrounds for components and their states,
  as `StyleBoxTexture` and `TextureButton` states, instead of drawn boxes.
- **Exact layout:** absolute rectangles per page and component, taken from the stock screens.
  It's still the same components and logic, placed where the stock UI puts them.
- **Fonts by file:** the vendor's own faces, at the vendor's sizes.
- **Icons:** the vendor's drawables in place of the shell's symbols.
- **Sounds:** touch clicks and chimes.
- **Motion:** transition timings and curves.
- **Boot splash and wallpaper.**
- Pages the stock UI never had (LIVI's own) use the pack's colors, fonts and icon style
  through the normal token path, so they don't look foreign.

**How close it is, measured:**
- The pack carries reference screenshots of the stock UI. On the G5W they're taken with
  `screencap` from stock Android, at the same 1920 × 720, so it can be pixel for pixel.
- A `compare_reference` scenario step renders the matching shell page and reports the share
  of pixels within tolerance. It writes a diff, an onion-skin overlay and a flicker GIF, with
  a mask for live content (clock, map, values).
- A `--reference` run mode draws the reference over the live shell at 50 %, for aligning a
  layout by eye.
- References and results stay local with the pack. They're never goldens in the repo.

**Worked example: the EV6's "Electric vehicle" screen.** Matching it shows what a pack needs
beyond colors and fonts.
- **Header:** back, home and menu on the left; time and date; title; a profile icon on the
  right. That's a vendor header component with the vendor's icons and font.
- **Car:** the car in perspective, with a battery badge at the charge level. It needs the
  scene path: a car model (glTF, or the stock UI's own pre-rendered frames if that's how it
  draws it), a fixed camera and lighting matched to the stock render.
- **Range road:** a perspective road with markers placed by distance: the next charger
  (740 m), range with climate on (243 km) and off (253 km). That's a new component, a range
  ribbon, which every theme can use. It is built as a 3D scene (`ev_live`) that every theme
  gets, with the pack's colors, strings and layout; the pack's stock images stay available as
  the image page (`ev_main`), and `ev_page` chooses.
- **Bottom tiles:** next departure, scheduled charging and target temperature, and EV charge
  transfer (V2G/V2L), plus a settings gear. These are tile components with the vendor's
  9-patches.
- **Data it needs that the core doesn't have yet:**
  - range with climate off, as well as on;
  - the car's departure schedule, scheduled charging and target temperature;
  - V2L state.
  These come from the car (micom-livi) into the core's telemetry, each a task for the
  core, not the shell. Until then, the tiles show what is known and say what isn't.
- **Reference:** the stock screen captured on the unit, compared with `compare_reference`,
  masking the clock and the live values.

**Rules still hold:**
- A pack may relax the rule table (stock targets are sometimes smaller than 10 mm) only with
  an explicit `rules_override`. The report lists every place it does, with the size it uses.
- The legal constraints are never overridable: the driving lockouts, the reversing camera,
  and what a driver-visible screen may show.

## Scene themes

A theme may draw the UI as a real 3D scene: buttons as machined aluminum
keys, panels as smoked glass over a leather-grained dash, the car model
behind the stats, with lights, PBR materials, normal maps and glTF models.
It's the same UI with the same rules, drawn another way.

**Components are logic plus a skin.** From milestone 4 every standard
component is split:
- **Logic:** state, actions to the core, and its hit areas. These are plain
  `Control`s, laid out in panel pixels from the rule table. They take all
  input and are what the tests and the touch-target checks measure.
- **Skin:** how it looks. The default skin is 2D (theme tokens and
  `StyleBox`es). A scene theme gives a component a 3D skin, a scene that
  receives the same parameters and state and draws over the logic's exact
  rectangle.

So a 3D theme can't move a touch target, shrink a hit area or change a
flow. It changes only pixels.

**How a 3D skin is drawn:**
- One 3D scene per display, behind and around the 2D layer. Its camera is
  set so the panel plane maps 1:1 to panel pixels: orthographic, or a
  perspective camera within a small field of view, with the plane at the
  focal distance.
- Assets are glTF models and `StandardMaterial3D` / `ShaderMaterial`
  (albedo, normal, roughness and metallic, emission), with a lighting rig
  and an environment map per appearance (day, night).
- Materials take their colors from the theme's tokens (albedo tint,
  emission for lit elements), so day and night, the accent and high
  contrast still come from one place.
- **Text stays sharp and flat:** labels are drawn by the 2D layer, or as
  MSDF text on a plane facing the camera, never lit, bent or put in
  perspective beyond a set angle.
- **Video and hosted windows stay unlit and screen-aligned:** the
  projection, apps and the reversing camera are never shaded, distorted or
  covered by scene effects. They may sit in a 3D frame, but their pixels
  map 1:1.
- **Motion:** idle animation (light sweeps, a turning car) stops while
  driving and under reduced motion. Transitions follow the motion budget.

**Godot's GLES3 compatibility renderer** (all the Mali-G51 has) does PBR
with per-object light limits. It has no SDFGI, SSR or SSAO, so scene themes
use baked lighting, reflection probes and lightmaps where they need depth.

**Cost and fallback:**
- A scene theme declares a budget (draw calls, triangles, texture memory,
  lights), and `cargo test` checks its assets against it.
- Quality profiles decide what runs: normal maps, shadows, the
  environment map, MSAA, texture size. `low` drops to the 2D skins, which
  exist for every component.
- High contrast and reduced transparency drop to 2D skins as well.

**Checks:** with a 3D skin, the rules are checked on what is rendered, not
on tokens:
- contrast is sampled from the frame's pixels around each label;
- legibility is checked on the drawn text's size;
- touch targets still come from the logic layer, so they hold whatever
  the skin does.

**Tests:**
- Goldens for each scene theme at the key pages, under `vm`.
- `measure` runs under each quality profile and fails over its budget.
- A scenario switches 3D and 2D skins at run time and checks that no
  logic, hit area or flow changed.

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
  whether the 3D camera may move on its own. (So far: `reduced_motion` turns the live "Electric
  vehicle" page's easing off.)
- Frame pacing: the target fps, and an idle mode that redraws only on change
  (Godot's low-processor mode, woken by core events and client commits).
  Video, when it shows, sets the rate.
- Memory: limits on texture and mesh memory, and how many window textures
  are kept.

**So far** `ThemeManager.quality` is `normal` or `low`, and only the live "Electric vehicle"
page reads it: `low` drops its fill and under-car lights, the sky's reflections and
multisampling. Nothing picks it automatically yet.

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

**Scale:**
- Each launched app has a scale, so desktop apps are legible on the panel.
  The default makes a logical pixel subtend CSS's reference pixel (1/96 in at
  28 in) from `view_mm`: `px_per_mm × 25.4 / 96 × view_mm / 711.2`, to the
  nearest 25 % from 100 to 200: 1.83, so 175 %, for this panel at 750 mm.
- Settings → Look → "App size" overrides it; apps.yaml's `scale: <percent>`
  sets one app's, and holding its tile picks one over that (kept in
  look.json's `app_scales`). A change reaches running windows at once.
- The compositor scales per client, matched by the launch's PID or process
  group: `wp_fractional_scale_v1` with viewporter (GTK ≥ 4.14, Qt ≥ 6.5,
  Firefox, Chromium), else `wl_surface.preferred_buffer_scale` and the
  client's own `wl_output.scale` at the nearest whole scale (GTK 3, Qt 5,
  SDL). Windows are configured at the panel's size divided by the scale, so
  a client that honours neither still gets that layout, stretched. Frames are
  in buffer pixels and input is mapped back to surface units by what each
  window's buffer turned out to be.
- No toolkit env (`GDK_SCALE`, `QT_SCALE_FACTOR`): those multiply with the
  protocol's scale rather than stand in for it.

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
- Apps not marked `DriveSafe` are limited while driving. Driving means not in
  Park, from the core's telemetry (`gear`, or `reverse`), as NHTSA defines
  it; a car stopped at a light is still driving. Where the gear is unknown,
  the parking brake and a speed above 0 stand in.
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
- [x] dmabuf, through EGLImage and a native GL texture.
- [x] Planar YUV dmabuf (NV12, I420) and dmabuf subsurfaces: per-plane EGLImages, converted and
      composited on the GPU into the window's texture (`gl_scene.rs`). Verified in the VM with
      udmabuf clients; the Mali and the CODA's buffers are untested.
- [x] Input: pointer, touch and keyboard, through `wl_seat`.
- [ ] Scroll (pointer axis), and explicit sync (`drm_syncobj`) for clients that use it.

### 3. LIVI's video

- [ ] Implement `livi-compositor`'s control protocol (the tags and
      `VideoCfg`).
- [ ] Start `livi-core` against the shell's socket.
- [ ] Show Android Auto as a texture; send touches as `Input::Pointer`.
- [ ] The reversing camera: full screen within 2.0 s of reverse, its
      default view each time, no overlays but driving aids, gone after the
      backing event (see "What the law and the car decide").

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
- [x] Theme packs from outside the repo, with image skins (9-patch, `TextureButton`
      states) and absolute per-page layout in the schema (see "Vendor themes").
      Packs load from `$LIVI_SHELL_THEMES` or `~/.local/share/livi-shell/themes/`; `skins:`
      in `theme.yaml` give cards and buttons (every state, from a selector) `StyleBoxTexture`s;
      a pack screen is a page of views at their rectangles (`PackScreen`).
- [x] A pack page built from the shell's components and a live 3D scene instead of the stock
      images: the "Electric vehicle" page, `ev_live`, beside the image page, which stays (see the
      README). Other pack screens still go through `PackScreen`.
- [ ] Pack pages built from the shell's components, not drawn by a dedicated page; the
      `--reference` run mode and the onion-skin and flicker output of `compare_reference`.
- [ ] Components as logic plus skin (see "Scene themes"), with 2D skins
      only, so 3D skins can come later without a rewrite.

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
- [ ] Volume and mute always visible; next track and calls one touch away.
- [ ] Regional profiles for what shows while driving, with their scenarios.
- [ ] Brightness levels and screen off; the tap-response check in the runner.
- [ ] `tools/import-vendor` and an EV6 pack from the unit's stock `/system`; the "Electric
      vehicle" page with its range ribbon and tiles, matched against a stock capture with
      `compare_reference` (see "Vendor themes").

### 7. On the unit

- [x] armv7 cross build of the extension, `livi-core` and its children
      (`packaging/scripts/build-armv7.sh`), and a smoke test of them with Alpine's armv7 `godot`
      under qemu-user (`packaging/scripts/smoke-armv7.sh`): the extension loads, the shell
      connects to the core.
- [ ] armv7 package: `packaging/alpine/{livi-core,livi-shell}/APKBUILD` are written and their
      `package()` checked with abuild, and built from source with pmbootstrap
      (`packaging/scripts/pmb-armv7.sh`); installing on the unit is not done.
- [ ] Measure Android Auto decode plus Godot compositing on the Mali-G51
      (frame rate and latency), idle CPU and GPU with low-processor mode,
      and memory.
- [ ] Run every quality profile on the unit, set the `unit` limits from the
      results, and tune the adaptive step-down.

Go or no-go after 7: if the Mali can't composite the projection and Godot at a
usable rate, stop; the work up to 6 is still usable as hosted pages under
`livi-compositor`.

### 8. Scene themes

After the go or no-go, as the unit's numbers decide how much 3D it can
afford.

- [x] A 3D page outside the scene themes: the "Electric vehicle" range scene (road, car, charger
      pin) with the `normal` and `low` profiles, measured in the VM. It uses a perspective camera
      fitted to a stock screen, not the panel-plane camera.
- [ ] The 3D layer, its panel-plane camera, and 3D skins for a few
      components, with the rendered-pixel checks.
- [ ] One full scene theme, with its asset budget and goldens.
- [ ] Measure it on the unit under each quality profile; set `unit`'s
      budget from that.

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
the repo's pmbootstrap container (`tools/pmb`), under a separate config that leaves
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
