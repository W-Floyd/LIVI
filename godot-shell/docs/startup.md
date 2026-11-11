# Shell startup

How long the shell takes from its process starting to home drawn with the core's data, what it
spends that on, and what to measure on the unit.

## Markers

Every start logs one `[startup] <mark> <ms> ms` line per mark on stdout (the journal under
`livi-shell.service`), in ms since the process started (from `/proc/self/stat`, ±10 ms), and once
home is drawn with the core's state, all of them in one line in `~/.local/state/livi-shell/shell.log`
with when the process started after boot. `project/startup.gd`, called from `core.gd` and `boot.gd`.

| mark | when |
|---|---|
| `engine` | the first autoload's `_init` (Core): engine, display, EGL, extension and project settings up |
| `main` | `boot.gd` `_ready`: autoloads loaded and ready, the main scene and the scripts it names compiled |
| `compositor` | the shell's Wayland socket listening |
| `look` | the driver's saved look applied |
| `shell` | home's nodes built and in the tree |
| `first_frame` | the first frame drawn |
| `core` | the core's first welcome (its whole state) |
| `home` | the first frame drawn after it: home with real data |
| `touch` | the first touch or click (as late as the driver's first tap) |

With `LIVI_SHELL_TIMING=1` (in `/etc/livi-shell.conf`) shell.log also gets `[warm] built N ms,
frames at ...`: the EV page's compile, build and first draws, 2 s after start, on the main thread.
A tap in that window waits for it.

## VM timeline

`vm/qemu-aarch64`, 12 vCPU under HVF, llvmpipe (software GL) on a headless weston; the shell
started by `boot.gd` as on the unit, against a stand-in core that sends the `parked.json` state.
Median of 5 starts, page cache warm. ms since the process started:

| mark | before (4f51600f, with the marks) | after | after, `DRI_PRIME=0` (as packaged) |
|---|---|---|---|
| engine | 340 | 360 | 210 |
| main | 800 | 598 | 450 |
| shell | 825 | 620 | 471 |
| first_frame | 854 | 662 | 502 |
| home | 854 | 663 | 515 |
| `[warm] built` (at 2 s) | 37 | 220 | 220 |

Where the time went before (`--verbose`, which logs each resource load):

- 0-55 ms: engine, TextServer, Wayland connection.
- 55-240 ms: **GPU detection**: with `DRI_PRIME` unset Godot forks children that each bring up EGL
  on a DRM device, looking for a discrete GPU. Skipped with `DRI_PRIME=0`, the default device,
  which is what it picks with one GPU.
- 240-290 ms: the renderer's own shaders (from Godot's shader cache after the first run).
- 290-340 ms: extension and class registration (the editor build registers its editor classes too).
- 340-400 ms: the autoload scripts.
- 400-800 ms: **compiling `shell.gd` and every script it names**: a `class_name` used in a script
  is compiled with it, so the EV page (with its shaders and settings), Settings, media, apps and
  pack pages were compiled before the first frame, as were the scenario runner and the live tuning
  server that `boot.gd` preloaded.
- 800-855 ms: home built, styled and drawn; the core's state lands in the same frame.

## What changed

- `boot.gd` loads the scenario runner and the tuning server only when asked for.
- `shell.gd` names the off-home pages by path (`PAGE_SCRIPTS`), loaded at first use; the EV
  page's compile moves into the warm-up at 2 s. `CarStatus.blower_running` (was EvLive's) so
  home's Precondition card no longer pulls in the EV page through CarStatus.
- `livi-shell.sh` sets `DRI_PRIME=0`.
- `livi-shell.service` is no longer ordered after `livi-shell-core` (which waits for
  `bluetooth.service` and `network.target`); the shell retries the core's socket at 0.25 s,
  doubling to 2 s (was 2 s flat), so a core starting beside it is picked up at once.

The unit's numbers will be larger and differently shaped: an A53 in AArch32 compiles GDScript
several times slower than the VM's host core, the eMMC reads the 128 MB editor build and the
project cold, and panfrost compiles shaders on a first run. Script compile is the share that
scales most with CPU, so the deferral should matter more there.

## Release template and pack (VM)

Alpine's `godot-templates` 4.7.2 (`/usr/bin/godot-template-release`, the same build as the
`godot` editor) run on a pack from `scripts/export-release.sh`, against the editor on the project
directory as packaged today. Same VM and method as above (216a5943's tree), median of 8 starts.
"cold" drops the guest's page cache before each start; the qcow2 is still in macOS's cache, so
those reads run at memory speed (~2 GB/s): cold here shows what is read, not what eMMC costs.

| variant | page cache | engine | main | shell | first_frame | home | RSS at home |
|---|---|---|---|---|---|---|---|
| editor, project dir (as packaged) | warm | 210 | 455 | 483 | 516 | 516 | 422 MB |
| editor, pack, text scripts | warm | 210 | 439 | 467 | 504 | 504 | 422 MB |
| editor, pack, compressed tokens | warm | 200 | 350 | 379 | 413 | 413 | 420 MB |
| template, pack, text scripts | warm | 190 | 313 | 339 | 369 | 369 | 390 MB |
| template, pack, tokens | warm | 185 | 293 | 317 | 343 | 343 | 390 MB |
| template, pack, compressed tokens | warm | 185 | 299 | 322 | 349 | 349 | 389 MB |
| editor, project dir (as packaged) | cold | 270 | 515 | 549 | 581 | 581 | 418 MB |
| editor, pack, text scripts | cold | 260 | 492 | 524 | 555 | 555 | 418 MB |
| editor, pack, compressed tokens | cold | 270 | 434 | 468 | 504 | 504 | 416 MB |
| template, pack, text scripts | cold | 240 | 361 | 389 | 418 | 418 | 386 MB |
| template, pack, tokens | cold | 230 | 346 | 375 | 407 | 407 | 385 MB |
| template, pack, compressed tokens | cold | 230 | 344 | 370 | 400 | 400 | 384 MB |

- The template takes ~30 % off home (516 → 369 ms warm), nearly all of it in `main`: the
  editor build's GDScript compiler also extracts docs and runs the warning checks, and it
  registers the editor's classes. Tokens then save another 20 ms; in the editor build they save
  90 ms, for the same reason. A pack of text scripts alone changes little (one file instead of
  ~100 is worth ~10 ms here).
- Read from storage on a cold start (`/proc/<pid>/io` `read_bytes`): 145 MB with the editor
  (107 MB of its 128 MB binary), 99 MB with the template (all of its 60 MB). The extension
  (15.5 MB) is read whole either way; the project or pack is under 1 MB. Mesa's libraries are not
  counted: weston holds them.
- Sizes (aarch64): editor 128.2 MB, template 59.7 MB, extension 15.5 MB; pack 0.97 MB (text),
  1.83 MB (tokens), 0.86 MB (compressed tokens, Godot's default). armv7 (Alpine testing, same
  4.7.2-r0): `godot` 115 MB installed, `godot-templates` 112 MB for debug and release together,
  so ~56 MB for the release one; the armv7 extension is 14.9 MB.

### What changes with a template

- Alpine's templates take no `--path` or `--main-pack`: the binary has to be a copy (not a link:
  the path resolves through symlinks) named like its pack, `livi-shell` beside `livi-shell.pck`,
  with `liblivi_godot_shell.so` beside them (a pack's `res://bin/...` misses, and Godot then
  looks next to the executable). `livi_shell.gdextension` needs no release entries: its
  `linux.arm32`/`linux.arm64` keys match the template's features.
- stdout is buffered: `application/run/flush_stdout_on_print` is off outside debug builds, so the
  `[startup]` lines (and every `print`) reach the journal late and in blocks. Needs
  `run/flush_stdout_on_print=true` in `project.godot` (set for these measurements).
- The built-in fonts: `ThemeManager._font` reads `res://fonts/*.ttf` with
  `FontFile.load_dynamic_font`, but a pack holds only the imported font data, so every built-in
  theme's fonts fail to load. Measured with `load(path)` as the fallback when the file is missing;
  vendor packs' fonts (files under `~/.local/share`) are unaffected. `theme_manager.gd` also hands
  hosted apps `globalize_path("res://fonts/...")`, a file that does not exist in a pack: apps lose
  the shell's fonts unless the fonts are installed as files too.
- The scenario runner and the tuning server read `../tests` beside the project: they stay on the
  editor build (the VM), as now.
- `unit-sync.sh` copies the project for the editor to run: with a template it would export
  (~3 s in the VM) and push the pack (~1 MB) instead; the class cache rides in the pack.
- Nothing at runtime needs the editor build: no `is_editor_hint`, and the runner's runtime
  `GDScript.new()` works in a template too.

### On the unit, estimated

- CPU: the template's ~30 % (~33 % with tokens) is compile and registration work, which an A53 in
  AArch32 does several times slower than the VM, so expect at least that share of the unit's
  warm start.
- I/O: ~46 MB less to read cold (from the binaries' sizes, ~40 MB on armv7). The eMMC is a
  Samsung 128 GB part on HS200 (200 MB/s bus, 8 bit); at an assumed 100-150 MB/s through page
  faults and readahead that is 0.3-0.5 s less at a cold boot, on top of the CPU share.
- Only the unit says: the eMMC's real throughput under the loader's access pattern, how much of
  the binary the boot already cached, the CPU scale of `main`, and panfrost's share of `engine`.

### Reproduce

```sh
# in the VM, from a copy of godot-shell with the extension built (scripts/build-ext.sh --release)
apk fetch godot-templates && tar xzf godot-templates-*.apk usr/bin/godot-template-release
TEMPLATE=$PWD/usr/bin/godot-template-release scripts/export-release.sh --scripts compressed /path/to/rel
```

Start `/path/to/rel/livi-shell` (or `godot --path project` for the baseline) under a headless
weston with `livi-shell.sh`'s arguments, `--audio-driver Dummy`, `DRI_PRIME=0`, and
`LIVI_CORE_SOCKET` at a stand-in core: a socket that sends each client
`FromCore::Welcome { state: State::filled(tests/fixtures/parked.json) }` (livi-core-proto's
`frame::encode`). Read the marks from stdout, `VmRSS` and `read_bytes` from `/proc/<pid>` at
`home`; for cold starts, `sync; echo 3 >/proc/sys/vm/drop_caches` first.

## Remaining options, ranked

| option | expected gain | cost |
|---|---|---|
| Release template + pack with compressed tokens: `scripts/export-release.sh` | measured: home 516 → 349 ms in the VM (-32 %); on the unit that share of the warm start plus ~0.3-0.5 s of eMMC reads cold | flush_stdout and the fonts (above) first; then the APKBUILD installs a copy of `godot-template-release` (armv7 `godot-templates`) as `/usr/lib/livi-shell/livi-shell` with the pack and the extension, and `unit-sync.sh` pushes a pack |
| Defer `AppKeyboard` and `SceneSkin` in `shell.gd` as the pages are | ~35 ms in the VM, ~6 % of the remaining start | low: a few typed declarations in `shell.gd` |
| Spread the 2 s work: the EV warm-up and the spare keyboard both start at 2.0 s on the main thread | shortens the stall a first tap can hit (see `[warm]`) | low; or compile EvLive's scripts with `ResourceLoader.load_threaded_request` |
| Boot splash handoff: `application/boot_splash` as home's background colour, no logo, so cage's black and Godot's splash read as the shell coming up | perceived only | low |
| Earlier in boot: `systemd-analyze critical-chain livi-shell.service` decides whether `systemd-user-sessions` or `seatd` ordering is worth moving | unknown until measured | low |

Shader caching is on already: Godot keeps compiled programs in
`~/.local/share/godot/app_userdata/LIVI Shell/shader_cache`, Mesa in `~/.cache/mesa_shader_cache`.
Both need a persistent, writable home on the unit.

## On the unit

With a build that has the markers (and `LIVI_SHELL_TIMING=1` in `/etc/livi-shell.conf`):

```sh
# The marks, at seconds since boot, and the summary
journalctl -b -o short-monotonic -u livi-shell | grep -E '\[startup\]|core: connected|discrete GPU'
grep -E '\[startup\]|\[warm\]' ~/.local/state/livi-shell/shell.log | tail -3
# When systemd started what; what the shell waited for
systemd-analyze; systemd-analyze critical-chain livi-shell.service; systemd-analyze blame | head -20
journalctl -b -o short-monotonic -u seatd -u livi-shell-core -u livi-shell | head -30
```

- Cold boot vs `sudo systemctl restart livi-shell` (page cache warm): the difference in `engine`
  is the eMMC's share, the case for a template build.
- First run vs later runs with the shader caches moved aside
  (`mv ~/.local/share/godot/app_userdata/"LIVI Shell"/shader_cache ~/.cache/mesa_shader_cache /tmp/`):
  the shader-compile share of `engine`, `first_frame` and `[warm]`. Confirm both caches exist after
  a reboot.
- `discrete GPU` must not appear in an older build's journal: if Godot found one there,
  `DRI_PRIME=0` changes which GPU it uses.
- Tap the panel as soon as home shows and note when it answered: a `touch` mark later than the tap
  felt means the main thread was busy (around 2 s after `home`: the warm-up).
