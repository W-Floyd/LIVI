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
grid|bars, size: WxH, animate: N }` runs the test client, `{ role: command, run: [...] }` any
Wayland program.

Steps: `wait: { frames } | { window: app_id }`, `tap: { node } | { x, y }`, `key`,
`set: { core: {...} }`, `expect_action`, `expect_input`, `expect_node: { path, <property>:
value }`, `screenshot: name` or `{ name, tolerance, max_pixels, mask: [[x, y, w, h]], compare
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

## The unit's build

```sh
scripts/build-armv7.sh [--release]   # macOS or Linux -> project/bin/linux-arm32/
```

A cross build against a sysroot of Alpine edge's armv7 musl, libgcc and libxkbcommon (fetched
once), linked with clang and lld; needs rustup and `ld.lld`. No pmbootstrap. Packaging for the
unit is milestone 7.
