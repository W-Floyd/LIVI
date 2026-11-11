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

## Remaining options, ranked

| option | expected gain | cost |
|---|---|---|
| Release export template instead of the editor build: ~half the binary to read and relocate, no editor class registration | likely the largest left on the unit cold (engine mark); 0.3-1 s guessed | Alpine's templates take no `--path`/`--main-pack`, only `<exe>.pck` beside the executable: ship a copy of the template as `/usr/lib/livi-shell/livi-shell` with `livi-shell.pck`, or build our own template. Changes `unit-sync.sh`'s workflow |
| Export a `.pck` with binary-token scripts | tokenizing skipped (parse, analyze and compile remain), one file instead of ~55 scripts and their resources on eMMC; 10-30 % of script load | export preset, `--export-pack` in the APKBUILD; unit-sync would push a pack instead of files |
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
