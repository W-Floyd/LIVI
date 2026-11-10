# gen5w-stock

Boot the stock Kia EV6 (Mobis Gen5W, Android 4.4.2 `KVT49L`, armv7) firmware under
the third-party `gen5w-emulator` (QEMU `virt`, Cortex-A7, TCG in Docker) to take
golden-reference screenshots of the stock apps at 1920x720.

The emulator's firmware templates are private, so the three template files are
rebuilt here from local inputs. Nothing Kia-derived is committed; every script
generates its output under `$WORK` (keep it outside the repo or under the
gitignored `godot-shell/ref/`).

| file | role |
|---|---|
| `Dockerfile` | build image (Ubuntu 20.04, armhf gcc 9, e2fsprogs, gdisk) |
| `build-kernel.sh`, `gen5w.config`, `kernel-backports.sh` | Linux 4.4.302 `zImage` from kernel.org |
| `build-ramdisk.sh`, `ramdisk-overlay/` | stock `boot.img` ramdisk plus the emulator changes |
| `build-emmc.sh` | GPT eMMC around the decrypted V015 `system.ext4` |
| `emulator-macos.patch` | `emuctl image-import` on macOS (`cp -c` instead of GNU `cp` flags) |
| `screenshots.sh` | consent/first-run click-through and screenshots |

## Reproduce

```sh
W=/path/to/work; K=~/Documents/Personal/git/kia-ev6
export WORK=$W
./build-kernel.sh
BOOT_IMG=$K/scratch/boot_decrypt/boot.img ./build-ramdisk.sh
EMU=/path/to/gen5w-emulator SYSTEM_EXT4=$K/scratch/ev6_fw/V015/system.ext4 ./build-emmc.sh
mkdir -p $W/tpl && cp -c $W/image/emmc.img $W/tpl/ && cp $W/zImage $W/ramdisk.cpio.gz $W/tpl/
# in a copy of the emulator, with emulator-macos.patch applied (patch -p1):
export EMUCTL_STATE=/tmp/g5w/state EMUCTL_IMAGES=/tmp/g5w/images   # short: unix socket path limit
emuctl image-import ev6-V015 $W/tpl --firmware V015
emuctl build
./screenshots.sh ev6-V015 /path/to/out
```

## Why the kernel is 4.4, not the vendor 3.18.48

The vendor tree in `kia-ev6/scratch/ev6_opensource` is a stripped release: no
`arch/arm/Kconfig`, no `mach-virt`, no Telechips code. It cannot be configured.
Mainline 7.x has no `logger` or `alarm-dev`. The emulator requires modern
virtio-mmio (`force-legacy=false`) and `virtio-input`, which 3.18 lacks, so the
kernel is 4.4 LTS with `logger` and `alarm-dev` backported from 3.18.140
(`kernel-backports.sh`). The stock liblog also opens `/dev/log/mobis`, so a fifth
log buffer is added; without it every `ALOG*` call from a non-root process is
silently dropped.

## What the ramdisk changes

- `fstab.tcc803x`/`init.*.rc`: `/dev/block/platform/bdm/by-name/X` becomes `/dev/block/vdaN` (GPT order of `build-full-emmc.sh`); `discard`, `check`, `encryptable` dropped.
- `/sbin/busybox` (Ubuntu static armhf) for `emuctl exec`; `init_wrap.sh` just execs `/init`.
- `console` service runs as root (emuctl exec talks to it).
- `default.prop`: `ro.kernel.qemu=1`, `ro.kernel.qemu.gles=0` (libEGL then falls back to the software `libGLES_android`), `ro.secure=0`.
- `init.emu.rc`: tmpfs over `/system/vendor/lib/egl` (hides the Mali EGL, which aborts SurfaceFlinger without `/dev/mali`); `gralloc.default` bind-mounted over `gralloc.tcc803x`, `/dev/null` over `hwcomposer.tcc803x` so SurfaceFlinger composes into the bochs fbdev.
- `build-emmc.sh` additionally formats the `log` partition: the stock fstab mounts it and `mount_all` stops at the first failure, leaving `/data` unmounted.

Kernel needs `FRAMEBUFFER_CONSOLE`: without it nothing programs the bochs mode and QMP screendumps are 640x480 black.

## State

Boots to the launcher in about 45 s with `emuctl` (4 vCPUs). Consent screen, first-run
setup, EV home widget, FM radio, home settings, voice memo, user profile all render.

- `com.mobis.welcome` covers everything with a black overlay until the micom reports
  in; `screenshots.sh` force-stops it.
- `com.hkmc.daudio.app.ev3/.MainActivity` starts and finishes at once: TAppEV3 logs
  `Ignore Ev Data Update. Service is not in ignition on`, i.e. it wants the vehicle
  service (`com.hkmc.telematics.service`, fed by `micomd` over `/dev/ttyTCC2` and the
  CAN managers) to report ignition on. Battery shows 0 % and range `--- km` meanwhile.
- No netfilter beyond basics, no audio, no GPS/BT/radio hardware; `netd` logs iptables errors.
