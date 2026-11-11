# Packaging the shell for the unit (armv7)

The unit is a Mobis DAudio Plus Gen5 Wide: Telechips TCC8031, Cortex-A53 in AArch32, so
`armv7-unknown-linux-musleabihf` on postmarketOS (Alpine edge, musl, hard float; the interpreter
is `/lib/ld-musl-armhf.so.1`). Its aports are in `pmaports-kia-ev6` (branch `2024-kia-ev6`,
`device/testing/`), built with pmbootstrap in a builder container; the image runs
systemd (OpenRC units are shipped too).

What the shell needs there:

| piece | from | package |
|---|---|---|
| Godot 4.7 runtime | Alpine testing `godot` 4.7.2 (armv7 exists; see Engine) | `godot` |
| `liblivi_godot_shell.so`, the project, launcher, units | `ext/`, `project/`, this directory | `livi-shell` |
| `livi-core`, `livi-gst-host`, `livi-helperd` | `native/` | `livi-core` |
| a host compositor for the DRM device | Alpine `cage` | `cage` |

## Cross build on the Mac (or Linux), no Docker

```sh
packaging/scripts/build-armv7.sh            # ext + core -> packaging/out/armv7/      (both)
packaging/scripts/build-armv7.sh ext        # the extension and the test client
packaging/scripts/build-armv7.sh core       # livi-core, livi-gst-host, livi-helperd
```

Prerequisites: rustup, clang, `ld.lld`, pkg-config, cmake, perl, python3, curl (on a Mac:
`brew install lld llvm cmake pkgconf`). `alpine-sysroot.py` unpacks Alpine edge's armv7 apks
(musl, libgcc, GStreamer, eudev, libxkbcommon, openssl, ... 170 packages, ~550 MB, about 2 min on
a slow link) into `packaging/out/work/sysroot`; the linker is clang + lld against it. The native
workspace pins a beta toolchain (`rust-toolchain.toml`); rustup installs it. Built in 7 s (ext,
warm) and 46 s on 10 cores (core, 432 CPU-s).

Output (`readelf -d`): ELF32, ARM, EABI5 hard float (flags `0x5000400`), interpreter
`/lib/ld-musl-armhf.so.1`, NEEDED limited to `libc.musl-armv7.so.1`, `libgcc_s.so.1` and, per
binary, `libxkbcommon.so.0` (ext, test client), `libssl.so.3`/`libcrypto.so.3` (livi-core),
GStreamer/GLib (livi-gst-host). `-z defs` makes an unresolved symbol a link error.

## Import the project, and test, in Docker

```sh
packaging/scripts/import-project.sh   # -> packaging/out/project (the project with .godot/), 1.5 min
packaging/scripts/smoke-armv7.sh      # the smoke test, 3-5 min (mostly apk downloads)
packaging/scripts/apk-armv7.sh        # the APKBUILDs' package() through abuild, ~2 min
```

`import-project.sh` runs Alpine's aarch64 `godot --headless --import` in an arm64 container
(native speed on Apple silicon); the `.godot/` cache is architecture-independent.

`smoke-armv7.sh` runs in an arm64 Alpine container: Docker Desktop on Apple silicon cannot exec
AArch32, so `qemu-arm` (user mode) runs the armv7 ELFs against a throwaway armv7 root that
`apk --arch armv7` populates (godot 4.7.2, musl, libxkbcommon, GStreamer, ...). It checks that
every NEEDED library resolves (musl's `ld --list`), starts `livi-core` (it opens `core.sock`),
runs the armv7 `godot --headless --path` on the armv7 extension, and checks that the core logs
`godot-shell connected` and that the test client connects to the shell's Wayland socket. It
proves loading and wiring on an AArch32 userland. It does not prove GL, speed, or anything with
the kernel (DRM, input, Mali). Two limits of qemu-user: it redirects only the loader (`-L`), so
data files such as xkeyboard-config are read from the container itself, and it cannot exec a child
ELF, so livi-core's "cannot start gst-host ... No such file" in its log is the emulation, not the
package (the child needs binfmt or a real armv7 system, e.g. the gen5w QEMU guest).

## Packages

`alpine/livi-core/APKBUILD` and `alpine/livi-shell/APKBUILD`, in the style of `livi-headunit`
(`pmb:cross-native2`: the native chroot cross-compiles with rustup's toolchain, the armv7
buildroot is the sysroot; Alpine's armv7 rust lags). The source is a `git archive` of this
repository's HEAD, pinned and checksummed by `make-source.sh`:

```sh
git commit ...                                # the tarball is of HEAD
packaging/scripts/make-source.sh              # -> packaging/out/aports/{livi-core,livi-shell}/
cp -r packaging/out/aports/* /path/to/pmaports/device/testing/    # the builder's pmaports tree
pmbootstrap build --arch armv7 livi-core livi-shell                # in the builder container
```

`livi-core` installs beside `livi-headunit`, under `/usr/lib/livi-core`. `livi-shell` installs
the project (with `.godot/`) and the extension at `/usr/lib/livi-shell/project`, where
`livi_shell.gdextension` finds `res://bin/linux-arm32/liblivi_godot_shell.so`;
`/usr/bin/livi-shell`; `/etc/livi-shell.conf`; the systemd units `livi-shell-core` and
`livi-shell` (and OpenRC scripts) in `-systemd` / `-openrc` subpackages. They are not enabled
by default, as the kiosk takes the display from GNOME:

```sh
sudo apk add livi-shell
sudo systemctl enable --now livi-shell     # starts livi-shell-core first
```

`livi-shell-core` runs `livi-core` with `LIVI_NO_UI=1` and `WAYLAND_DISPLAY=livi-shell`;
`livi-shell` runs `cage -d -s -- godot --path ... --display-driver wayland --rendering-method
gl_compatibility --rendering-driver opengl3 --fullscreen --resolution 1920x720`, and the shell
listens on the Wayland socket `$LIVI_SHELL_SOCKET` (`livi-shell`, in `/run/livi-shell`), which
`livi-gst-host` draws into. Run from inside a Wayland session, `livi-shell` skips cage and is a
fullscreen window of that session. `/etc/livi-shell.conf` has the panel size and the cage/GL
switches.

Status: the APKBUILDs' `package()` and subpackages are checked by `apk-armv7.sh` (abuild,
prebuilt binaries); the from-source pmbootstrap build, which fetches a Rust toolchain and ~600
crates and imports the project with the native chroot's `godot`, has not been run (it needs the
builder container's pmaports tree).

## Engine

Alpine edge has `godot` 4.7.2 for armv7 (testing: `godot`, 75 MB apk, and `godot-templates`,
54 MB). Musl-linked (`libc.musl-armv7.so.1`, `ld-musl-armhf.so.1`), Wayland and X11 drivers, GLES3
(`opengl3`) and Vulkan compiled in (glslang is linked, but Vulkan is only a loadable driver;
`gl_compatibility` never loads it), Mesa/GL via the usual dlopen. GDExtension works: the armv7
extension loads in it (godot-rust: "runtime v4.7.2.stable.alpine_linux"). Built with
`lto=none` for RAM. No custom engine build was needed to get this far.

Two things about it:

- `godot-templates` (`template_release`, no editor code) is built without
  `disable_path_overrides=no`, so it refuses `--path` and `--main-pack`. It runs a `.pck` named
  after the executable and finds the extension at `bin/linux-arm32/...` beside the executable, so
  it needs its own copy of the 54 MB binary next to the project pck. Tried here: the pck exports
  with `godot --export-pack` (a `Unit` Linux/arm32 preset with `include_filter="*.yaml, *.ttf"`;
  the theme loader reads the fonts raw, which an export strips unless their `.import` is
  `importer="keep"`) and the shell then boots; not packaged.
- `godot` (the editor build) takes `--path`, so `livi-shell` runs it on the imported project:
  the same command the VM tests use. The cost is a bigger binary and its startup; it does not
  start the editor.

A lean custom build is the follow-up if the unit's memory or start time demands it; the command
is below, untested here (a full armv7 engine compile was not attempted: Alpine's package covers
the need, and it is hours on this machine).

```sh
# in the builder container, or any Linux with an armv7 musl sysroot and clang or gcc cross
scons platform=linuxbsd arch=arm32 target=template_release production=yes \
    disable_path_overrides=no lto=none use_static_cpp=no \
    vulkan=no x11=no wayland=yes opengl3=yes \
    module_openxr_enabled=no module_mono_enabled=no module_webxr_enabled=no
```

## Left for the unit

- Whether the kernel (`linux-tcc803x`) exposes the Mali-G51 through panfrost (`/dev/dri/renderD*`);
  without it GL is llvmpipe and the shell is not usable at 1920x720. Cage needs a KMS device
  (`/dev/dri/card0`) with GBM; with only a fbdev console it falls back to nothing
  (`WLR_RENDERER=pixman` still needs KMS).
- `wl_buffer` formats: livi-gst-host's decoder (CODA) gives NV12; the shell imports dmabuf
  only when an EGL context is current ("dmabuf off" in the log under qemu), and panfrost's
  NV12 import is the PLAN's open risk.
- Godot's `wayland` driver under cage: fullscreen, 1920x720 mode of the connector, touch
  through cage's seat (libinput on `/dev/input/event*`; the `input` group).
- Audio: Godot's PulseAudio driver talks to the unit's PipeWire-pulse.
- Hard keys: micomd's virtual keyboard reaches the shell through cage's libinput. The volume
  keys step the core's `huVolume`, which the core sets on the default sink with `pactl`, and
  mobis-g5w-amp mirrors that sink onto the amp: both need the user's PipeWire-pulse, whose
  socket is not under the units' `XDG_RUNTIME_DIR=/run/livi-shell`, and mobis-g5w-amp is a
  user unit that needs a user session (GNOME's, under stock).
- The user (`user`), `seat`/`video`/`input`/`render` groups, and whether GNOME's gdm has to be
  stopped (the unit `Conflicts=` it) are the unit image's.
