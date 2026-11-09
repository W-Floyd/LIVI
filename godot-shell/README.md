# Godot shell

A Godot 4 UI on livi-core; see [PLAN.md](PLAN.md).

- `ext/`: the GDExtension (Rust, gdext). `CoreLink` (the core client, or an in-process fake
  core) and `ShellTest` (scenario YAML, golden comparison).
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
```

`vm.sh` syncs `godot-shell/` and `native/` into the VM, runs the command, and copies `out/`
(shots, diffs, `report.html`) and `tests/goldens/` back. Scenarios render in a 1920×720
SubViewport under a headless weston with llvmpipe, at `--fixed-fps 60` and a fixed clock.

Scenario steps: `wait: { frames }`, `tap: { node } | { x, y }`, `key`, `set: { core: {...} }`,
`expect_action`, `expect_input`, `expect_node: { path, <property>: value }`, and
`screenshot: name` or `{ name, tolerance, max_pixels, mask: [[x, y, w, h]] }`.

## The unit's build

```sh
scripts/build-armv7.sh [--release]   # macOS or Linux -> project/bin/linux-arm32/
```

A cross build against a sysroot of Alpine edge's armv7 musl and libgcc (fetched once), linked
with clang and lld; needs rustup and `ld.lld`. No pmbootstrap: the extension has no C
dependencies. Packaging for the unit is milestone 7.
