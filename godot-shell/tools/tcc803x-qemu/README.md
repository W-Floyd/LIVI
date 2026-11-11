# tcc803x-qemu

Experiment: boot the **stock** Kia EV6 Gen5W kernel (Telechips TCC803x, Linux 3.18.24-tcc, Android 4.4.2)
on a small custom QEMU machine that models the SoC, instead of on `virt`. Independent of
`tools/gen5w-stock` (Linux 4.4 on `virt`), which is untouched.

Nothing Kia-derived is committed. The scripts read the firmware from local paths.

| file | role |
|---|---|
| `qemu-tcc803x.patch` | diff against QEMU `v10.0.3`: `hw/arm/tcc803x.c`, SiP-SMC hook, SDHCI tweaks |
| `Dockerfile`, `build.sh` | build `qemu-system-arm` into the docker volume `tcc803x-qemu-build` |
| `build-native.sh` | build the same QEMU natively (no docker); prints the binary, use it as `QEMU=` |
| `tcc803x-qemu.dts` | DT for the stock kernel (own file, from the mainline `tcc803x.dtsi` + stock driver strings) |
| `extract-boot.sh` | split `boot.img` into `kernel` + `ramdisk.gz` |
| `make-emmc.sh` | pad a GPT by-name image to 8 GiB (QEMU eMMC must be a power of two) |
| `run.sh` | run the machine; serial console on stdout (docker, or native with `QEMU=`) |
| `bench.py` | cold-boot timing: wall to `sys.boot_completed`, guest/wall clock, `input tap` latency |

## Run

```sh
K=/path/to/kia-ev6/scratch
./build.sh                                              # ~15 min first time, incremental after
./extract-boot.sh $K/boot_decrypt/boot.img $W/boot      # W: any dir outside the repo
# eMMC: GPT with by-name partitions around the decrypted V015 system.ext4 (tools/gen5w-stock/build-emmc.sh)
./make-emmc.sh $W/image/emmc.img $W/emmc8g.img
EMMC=$W/emmc8g.img BOOT_DIR=$W/boot TIMEOUT=100 ./run.sh
```

`run.sh` knobs: `SMP` (vCPUs, default 4), `QEMU` (native binary, see Performance), `APPEND` (kernel cmdline), `DEBUG` (qemu `-d`
flags, default none; `guest_errors,unimp` logs the unimplemented accesses and SiP calls to `qemu.log`, printed as a summary),
`EXTRA` (more qemu args, e.g. `-trace sdhci_*`). The eMMC is attached with `snapshot=on`: nothing is written back.

## Machine

4x Cortex-A15 (stand-in for the A53 cluster in AArch32; `-smp` defaults to 4, PSCI `CPU_ON` brings the others up),
RAM at `0x20000000`, GIC-400 distributor/CPU interface at `0x17301000`/`0x17302000` (224 SPIs, the stock
`NR_IRQS` is 256), armv8 generic timer (PPIs 13/14/11/10), PSCI over SMC, PL011 x4 at `0x16600000 + n*0x10000`
(SPI 88..91), `generic-sdhci` at `0x16440000` (SPI 74) with an `emmc` card, and `unimplemented-device` over
`0x00000000-0x1fffffff` (reads 0, writes ignored, logged with `-d unimp`).

## What is known about the stock kernel

- It is DT-based (`CONFIG_OF`, `ARM_APPENDED_DTB`, `ATAGS`+compat) but the boot image carries **no DTB**; the
  bootloader loads it from a separate partition we do not have. `tcc803x-qemu.dts` is written from scratch.
- `ARM_PATCH_PHYS_VIRT` without `AUTO_ZRELADDR`: the zImage decompresses to its fixed address and runs fine when
  loaded at `0x20008000`.
- Console: `console=ttyTCC0` is the PL011 driver (vendor patched to the name `ttyTCC`) on `0x16600000`;
  `earlycon=pl011,mmio32,0x16600000` also works. The stock cmdline has `console=null`; override it.
- Secure monitor: the kernel makes SiP SMC calls (`0x8200xxxx`); they are logged and answered `0`
  (see the patch, `target/arm/tcg/psci.c`). Seen at boot: `0x8200ff03` (TF version query, args 0..2),
  `0x82007000`, `0x82000011/13` (IOBUS enable/is), `0x8200000a/0c` (PERI set/get): all benign with `0`.
- The stock clock/pinctrl/GPIO drivers want vendor DT bindings: see the comments in the DTS.
- eMMC: the stock `sdhci-tcc` uses Auto CMD23 (TRNMOD bit 3) and gates SDCLK between commands; stock QEMU
  `generic-sdhci` supports neither, hence the two SDHCI changes in the patch.

## Result

## Status

Reaches the stock Android 4.4.2 userland: kernel boot log on `ttyTCC0`, SMP bring-up over PSCI (4 vCPUs),
ramdisk `/init` and `init.rc` run, `/system` (the decrypted V015 `system.ext4`) and every by-name partition
mount from the emulated eMMC (`mmcblk0p1..15`), property service, `rild`, `healthd`, input devices and the
console shell start (`shell@wp_daudioplus_ecokmc_us:/ $`). (Numbers in this paragraph and the next are from the first docker runs with `maxcpus=1`; see Performance for current ones.)

Stubs and what each was needed for:

| address / call | what the kernel wanted |
|---|---|
| `0x16600000` PL011 (SPI 88) | `DEBUG_LL`/earlycon, then the `ttyTCC0` console |
| `0x17301000`/`0x17302000` GIC | needs `num-irq` <= 256 (`NR_IRQS`), else `irq_domain_associate` WARN and a QEMU assert |
| PPI 13/14/11/10 | armv8 timer; clocksource `arch_sys_counter` (62.5 MHz in QEMU) |
| `0x14200000` pinctrl/GPIO (DT node `telechips,tcc803x-pinctrl` + `gpa-`..`gpsd2-` banks, `reg = <off pinbase npins>`, MMIO reads 0) | `daudio_info_init` -> `get_oemtype` -> `gpiod_get_raw_value` oopsed on a GPIO with no registered chip |
| `0x144001c0/c4` (PMU) | read at boot, 0 is accepted |
| SiP SMC `0x8200ff03`, `0x82007000` | chip/trusted-firmware info; `0` accepted (`system version 0x0`) |
| SiP SMC `0x8200000a/0c`, `0x82000011/13` | PERI/IOBUS clock set/enable queries from the vendor CKC driver; `0` accepted |
| DT `clk@14000008/14000400/16051000` (`telechips,clk-fbus/-peri/-iobus`) | `sdhci-tcc` calls `clk_set_rate` on its peri clock: a `fixed-clock` returns -EINVAL and the probe fails |
| `0x16440000` SDHCI (SPI 74) + `emmc` card | the root of `/system`, `/data`...; needs Auto CMD23 and SDCLK-gating tolerance (QEMU patch) |
| `0x16470000..` Telechips SDHC ext regs | unimplemented, read 0 |
| DT `lk-log-proc-match` + `reserved-memory` (`0x2f000000`) | the stock `klogd` reads `/proc/lk_log`; without a bound device the driver oopses -> panic -> reboot |

## Crash loop: SurfaceFlinger, and the display

Driving the console shell (a root console from `build-ramdisk.py`: `ro.secure=0`, `console` service as root) and
reading `logcat -d` showed the loop was `surfaceflinger` aborting every ~5 s (init restarts it and `zygote`):

```
E/mali (101): Failed creating base context during opening of kernel driver.
E/tc_hwc (101): tc_cfg_open(49): can't open[No such file or directory] '/dev/graphics/fb0'
E/SurfaceFlinger(101): ERROR: failed to open framebuffer (No such file or directory), aborting
```

(`mediaserver` also aborts once with `Unable to open the mixer`; `micomd` logs `/dev/ttyTCC2 open failed`; neither loops.)

The stock kernel has `FB_TCC` (Telechips VIOC) but no simplefb/bochs/DRM, the vendor source for it is not available and its
DT bindings are undocumented, so instead of modelling VIOC:

- `qfb/qfb.c`: a 100-line fbdev module (1920x720, 32 bpp, three y-panned buffers) over 32 MiB of VRAM at `0x70000000`
  plus a few registers at `0x72000000` (the QEMU device `tcc803x-qfb` in the patch scans out from them).
  `build-qfb.sh` builds it against vanilla linux-3.18.x with `SUBLEVEL=24` so the vermagic matches the stock kernel
  (no MODVERSIONS), cross-compiled in the `gen5w-build` image (`docker build -t gen5w-build ../gen5w-stock`).
- `build-ramdisk.py` + `overlay/init.emu.rc`: stock ramdisk plus `insmod /qfb.ko`, tmpfs over `/system/vendor/lib/egl`
  (hides the Mali EGL; the loader falls back to the software `libGLES_android`), the stock fbdev `gralloc.default`
  bind-mounted over `gralloc.tcc803x`, `/dev/null` over `hwcomposer.tcc803x`, `ro.kernel.qemu=1`. Same trick as `gen5w-stock`.
  Output goes next to the input ramdisk (Kia-derived, not committed). Select it with `RAMDISK=ramdisk.emu.gz run.sh`.
- The stock SurfaceFlinger wants a third framebuffer buffer (gralloc itself asks for two), hence `NBUF 3`: with two it aborts
  with `GraphicBufferAlloc::createGraphicBuffer ... Out of memory`.
- `vmalloc=400M` on the cmdline: the default vmalloc area is too small for the 32 MiB `ioremap` plus binder
  (`binder_alloc_mmap_handler ... get_vm_area failed`).

`DOCKER_FLAGS="-i --name tccq"` plus `EXTRA="-monitor unix:/run/q/mon,server,nowait"` lets a script drive the console on stdin
and run `screendump` (PPM; this QEMU has no libpng) through `docker exec`.

## Result

With the overlay ramdisk, `qfb.ko` and `vmalloc=400M` the machine boots the stock userland to `sys.boot_completed=1` in
about 200 s of wall time (guest clock ~3x slower; kernel to init < 1 s, console prompt at ~10 s, `zygote`/`system_server` up, the
launcher reports `Displayed ... total +13s` guest). No more crash loop; `drive.py` runs a click-through like
`tools/gen5w-stock/screenshots.sh` (`am force-stop com.mobis.welcome`, `input tap`, `monkey -p ...`).

Compared with the Linux 4.4 screenshots (`ref/gen5w-stock`): consent, home settings and user profile are pixel-identical (apart from
the 8x16 px top-left corner, a clock stub) once red and blue are swapped; radio differs only in the top-left clock/animation area.
The 4.4 references are red/blue swapped: gralloc asks the fbdev for RGBA byte order and bochs ignores it. Fonts and layout do not differ.
Home screen: it is timing, not storage. With the click-through of `drive.py`, the launcher draws a flat `#121214` frame twice
(`logcat`: `Displayed com.android.launcher3/.view.Launcher: +58s347ms`, again `+5s180ms`; between them `mCurrentFocus=null`, the old
process a zombie, a new pid), and after each start the widgets are bound some 10-60 s later (background and page dots first). The same
capture taken >= 180 s after the last tap equals the 4.4 one except ~1100 px (page dots, EQ bars). What kills the launcher is not
established (no `am_kill`/`has died` in the main log). Partition size makes no difference: `data` 495 MiB (stock) and 2.9 GiB give the same
sequence. Voice Memo: the free-space check is not a filesystem check. `StatFs` is used only for the USB path; the internal "available"
is `0x8000000` (128 MiB) minus the DB-recorded usage, handed to the framework `VoiceMemoManager.setAvailableMemory` by the Voice Memo
service, and "Storage Full" is `getAvailableMemory() <= 0`. The 4.4 run logs `setAvailableMemory ... 134217728` on the first launch (the
reference shows `Available 128 MB`); the stock-kernel capture is the popup with the three per-user figures at 0 MB (an empty DB), presumably
the manager value was still 0 (not confirmed: the log buffer had rolled over). The popup appeared on a launch while the first-run
setup was in front.
`build-ramdisk.py` drops ext4 `discard` from the fstabs: the model's eMMC has no erase group size and every discard made the kernel
print `Division by zero in kernel` (`mmc_mmc_erase_timeout`, 70-130 times per run). `make-emmc.sh` clones with `cp -c` where possible.
`DATA_MIB`/`CACHE_MIB` for `tools/gen5w-stock/build-emmc.sh` resize the partitions (3072/512 still fits 8 GiB).
`drive.py`: `PROMPT_TIMEOUT` (default 120) for slow commands; `input tap` takes 30-120 s here, so wait before the next tap.
Not modelled: `/dev/ttyTCC2` (micomd), audio mixer, Mali/VPU/USB/ethernet.

## Performance

Measured on an Apple M-series Mac (TCG, 32-bit guests cannot use HVF), host otherwise idle, `bench.py` with the root-console
ramdisk, `-m 1024`. Wall seconds from QEMU start to `sys.boot_completed=1` (N runs), guest clock vs wall, `input tap` round trip:

| config | boot | guest/wall | tap |
|---|---|---|---|
| native QEMU 10.0.3, `maxcpus=1` (old default) | 78-86 s (N=9); 3 more runs stalled for minutes (see below) | 1.0 (0.56 in a stalled run) | 1.1-2.2 s |
| native, `-smp 2`, no `maxcpus` | 57 s (N=2) | 1.0 | 1.2 s |
| native, `-smp 4`, no `maxcpus` (new default) | 55-57 s (N=9) | 1.0 | 1.1-1.2 s |
| native `-smp 4` + `-loadvm` of a booted snapshot | 1.6 s to a working console, consent screen at once | n/a | 1.2 s |
| docker, `maxcpus=1`, `-d guest_errors,unimp` (previous agent) | ~200 s | ~0.33 | 30-120 s |

What matters:

- **vCPUs.** The guest is CPU-bound for its whole boot (`top`: Idle 0 %; `surfaceflinger` composing in software at a steady 50-57 %
  of a CPU, Launcher3 13 %, `system_server`, a dozen app starts), and a TCG vCPU is one host thread. Bring-up over the existing PSCI
  handler works unmodified: remove `maxcpus=1` and pass `-smp 4` (`run.sh` default). 83 -> 55 s, and no more of the stalls
  below. 2 vCPUs are as fast as 4 (boot is only partly parallel), 4 are cheaper in tail latency.
- **Single-vCPU stalls.** With `maxcpus=1` 3 of 12 runs went into a mode where the guest soft-locked up
  (`BUG: soft lockup - CPU#0 stuck for 49s! [surfaceflinger]`, 149 s `system_server`), `am`/`input` hung for minutes, QEMU used
  70 % of a core instead of 100 % and the guest clock ran at 0.56x wall. Not reproduced on demand (the healthy runs pass the same point) and not seen in 9 runs with 4
  vCPUs. This, plus docker-for-Mac, is what the earlier "3x slow clock, 30-120 s taps" were; the clock itself is not slow
  (kernel timestamps match wall time in every healthy run, TCG is not `-icount`).
- **Native, not docker.** `build-native.sh` builds the patched QEMU on the Mac (about 3 minutes); no docker VM in between.
  Docker Desktop was unusable during this work, so the docker number above is the earlier measurement, not re-run.
- **Snapshots** (below) make everything after the first boot cost seconds.

What does not matter (measured, 4 vCPUs): `-d guest_errors,unimp -D` (the log is 11 KB: 57 s vs 55 s), `tb-size=2048`
(57 s), `-display none` vs scan-out (the QFB device only converts when a display listener asks, none with `-display none`),
dexopt (the stock apps are odexed; `logcat` has no dexopt activity at boot), the 5 `tcc_adc_getdata` log lines per
second (kernel/serial noise only). Host profile of the vCPU thread (`sample`): 60 % in generated code, 25 % softmmu TLB
fills/flushes (`get_phys_addr`, `tlb_flush`), 4 % `helper_lookup_tb_ptr`; no device model shows up, so the rest is TCG itself.

Not done: `surfaceflinger` composing every frame is the largest single guest cost. `qfb.c` leaves `pixclock` and the margins at
0, so the fbdev gralloc assumes 60 Hz; giving it a 15-20 Hz `pixclock` (`1e12 / (hz * 1920 * 720)` ps) should cut that load by
3-4x. Needs a rebuild of `qfb.ko` (docker was unavailable), so untried.

### Snapshot: boot once, then resume in seconds

`savevm`/`loadvm` work with the custom devices (the `tcc803x-qfb` registers have a `vmstate` in the patch; the VRAM is a RAM block and
migrates itself). They need a qcow2 disk; a backing-file overlay keeps the raw image untouched:

```sh
qemu-img create -f qcow2 -b $W/emmc8g.img -F raw $W/ov.qcow2
# drive.py script: boot, wait, dismiss the black com.mobis.welcome overlay, save
#   am force-stop com.mobis.welcome
#   #sleep 10
#   #savevm booted
QEMU=... EMMC=$W/ov.qcow2 BOOT_DIR=$W/boot RAMDISK=ramdisk.emu.gz ./drive.py script.txt out.log
# later, each run on a copy (loadvm writes to the overlay; cp -c is a clone on APFS)
cp -c $W/ov.qcow2 $W/run.qcow2
QEMU=... EMMC=$W/run.qcow2 LOADVM=booted BOOT_DIR=$W/boot RAMDISK=ramdisk.emu.gz ./run.sh
```

The state file is about 650 MiB (RAM) in the overlay. After `loadvm` the console answers in about a second, the consent screen is on
the display immediately and the whole consent -> home click-through takes under 10 s (taps 1-3 s each). The first command typed
into the serial console in the first second after `loadvm` can be lost; send a newline first.
Recommended for golden screenshots: one cold boot to `boot_completed` + `am force-stop com.mobis.welcome`, `savevm`, then
`loadvm` per capture session (or simply keep one machine running and use `#shot`/QMP `screendump`: the guest clock is real time).
