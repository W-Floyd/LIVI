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

Steps: `page: home | <pack screen>`, `compare_reference` (below), `wait: { frames } | { window: app_id }`, `tap: { node } | { x, y }` (add `with: touch`
for a finger), `key`, `expect_client: { app_id, lines: [...] }`,
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
  stays at the pack's static values.

`compare_reference: { name, reference, tolerance, min, mask: [[x, y, w, h]] }` renders the page
and passes when the share of pixels within `tolerance` (default 8) of the reference image is at
least `min` (default 0.98); masked regions are left out of the share. A relative `reference` is
read from the active pack's folder. It prints the share, and writes the render and the diff
(red: differs, blue: masked) to `out/<scenario>/`. A reference is never a golden and never
committed.

A scenario's `fixtures: { packs: <dir under tests/> }` points the packs directory at its own
folder, and `requires: { theme: <name> }` skips it when that theme is missing.
`tests/fixtures/packs/synth/` is a synthetic pack drawn by `make-synth.py` (no vendor assets),
used by `pack-synth`; its `reference/` images are renders of its own page. `kia-ev6` runs only
where the EV6 pack is installed. To get one into the VM:

```sh
SHELL_PACK=godot-shell/ref/kia/ev6/2024/pack scripts/vm.sh scripts/test.sh kia-ev6
```

`SHELL_PACK` is rsynced to `~/.local/share/livi-shell/themes/$SHELL_PACK_NAME` there (default
`kia-ev6`) before the command runs, and stays; `scripts/vm.sh "LIVI_SHELL_THEMES=/nonexistent scripts/test.sh"`
runs the suite as someone without it would.

## The unit's build

```sh
scripts/build-armv7.sh [--release]   # macOS or Linux -> project/bin/linux-arm32/
```

A cross build against a sysroot of Alpine edge's armv7 musl, libgcc and libxkbcommon (fetched
once), linked with clang and lld; needs rustup and `ld.lld`. No pmbootstrap. Packaging for the
unit is milestone 7.
