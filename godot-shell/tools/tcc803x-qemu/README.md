# tcc803x-qemu

Experiment: boot the **stock** Kia EV6 Gen5W kernel (Telechips TCC803x, Linux 3.18.24-tcc, Android 4.4.2)
on a small custom QEMU machine that models the SoC, instead of on `virt`. Independent of
`tools/gen5w-stock` (Linux 4.4 on `virt`), which is untouched.

Nothing Kia-derived is committed. The scripts read the firmware from local paths.

| file | role |
|---|---|
| `qemu-tcc803x.patch` | diff against QEMU `v10.0.3`: `hw/arm/tcc803x.c`, SiP-SMC hook, SDHCI tweaks |
| `Dockerfile`, `build.sh` | build `qemu-system-arm` into the docker volume `tcc803x-qemu-build` |
| `tcc803x-qemu.dts` | DT for the stock kernel (own file, from the mainline `tcc803x.dtsi` + stock driver strings) |
| `extract-boot.sh` | split `boot.img` into `kernel` + `ramdisk.gz` |
| `make-emmc.sh` | pad a GPT by-name image to 8 GiB (QEMU eMMC must be a power of two) |
| `run.sh` | run the machine; serial console on stdout |

## Run

```sh
K=~/Documents/Personal/git/kia-ev6/scratch
./build.sh                                              # ~15 min first time, incremental after
./extract-boot.sh $K/boot_decrypt/boot.img $W/boot      # W: any dir outside the repo
# eMMC: GPT with by-name partitions around the decrypted V015 system.ext4 (tools/gen5w-stock/build-emmc.sh)
./make-emmc.sh $W/image/emmc.img $W/emmc8g.img
EMMC=$W/emmc8g.img BOOT_DIR=$W/boot TIMEOUT=100 ./run.sh
```

`run.sh` knobs: `APPEND` (kernel cmdline), `DEBUG` (qemu `-d` flags, default `guest_errors,unimp`),
`EXTRA` (more qemu args, e.g. `-trace sdhci_*`). The eMMC is attached with `snapshot=on`: nothing is written back.
The qemu log (unimp accesses, SiP calls) is in docker volume `tcc803x-qemu-run` as `qemu.log`; `run.sh` prints a summary.

## Machine

4x Cortex-A15 (stand-in for the A53 cluster in AArch32; `-smp` defaults to 4 but the cmdline uses `maxcpus=1`),
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

Reaches the stock Android 4.4.2 userland: kernel boot log on `ttyTCC0`, SMP bring-up skipped (`maxcpus=1`),
ramdisk `/init` and `init.rc` run, `/system` (the decrypted V015 `system.ext4`) and every by-name partition
mount from the emulated eMMC (`mmcblk0p1..15`), property service, `rild`, `healthd`, input devices and the
console shell start (`shell@wp_daudioplus_ecokmc_us:/ $`). 100 s of wall time is about 34 s of guest time.

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

## Next blocker

A native service crash-loops from about 12 s guest time (`Core dump to |/bin/false pipe failed`,
`init: untracked pid N exited` every ~5 s, then `sched: RT throttling activated`); there is no logcat on the
serial console, so which one is unidentified. Not attempted: display (VIOC/LVDS/HDMI), Mali, VPU (`no-reserved
memory`, the stock DT's pmap regions are not modelled), USB, ethernet, SMP (needs `maxcpus` > 1 and PSCI CPU_ON
is only exercised by QEMU's generic handler), the real extint SPIs of the pinctrl node, and the audio/I2C
devices (`serdes_init`, `tcc_adc_getdata: failed to find adc device`).
