# GNSS, fake positions, and the stock navigation's map data

Findings only; nothing here is built. "Confirmed" is read from the code or the V015 firmware; "inferred"
is not yet checked on the unit or in the emulator.

## Where the position comes from today

The GNSS module is on its own UART, not behind the micom. The micom carries the car's speed, never a position.

| stage | stock (Android 4.4) | LIVI |
|---|---|---|
| UART | `ttyTCC3`, 115200 (`init.tcc803x.rc`: `setprop ro.kernel.android.gps ttyTCC3`; on the unit `ro.kernel.android.gps=[ttyTCC3]`) | `/dev/ttyAMA3` (mainline PL011 numbering) |
| protocol | binary "hippo" frames (`81 .. csum 82`): 0x30 DR position, 0x31 GNSS fix, 0x32 UTC/DOP, 0x33 channels (go-hippod README, from the HAL's disassembly) | same |
| decoder | `gps.tcc803x.so` (opens `/dev/ttyGPS0`, `hippo_parse`, formats its own NMEA for LocationManager) | `hippod` (go-hippod), `mobis-g5w-hippod.service` |
| fan-out | the HAL, and the nav engine's own "EXTGPS" driver (below) | ptys `/run/gps0` (gpsd) and `/run/gps-livi` (livi-core), tap `/run/hippod.sock`; `-speed-tap /run/micomd.sock` puts the micom's speed into RMC/VTG |

LIVI's consumers, all fed from those two ptys (confirmed in code):

- livi-core: `gnss::run` reads NMEA/UBX from config `gpsDevice` (`/run/gps-livi` in the device preset
  `50-mobis-g5w.json`; default `/dev/ttyAMA0`) and publishes `telemetry.gps` (`GpsFix`: lat, lng, alt,
  heading, speedMs, accuracyM, fixTs) and `telemetry.gnss`. It also steps the system clock from GNSS time and
  sets and **saves** the timezone from the position (`gnss/mod.rs` `on_info`, `publish_fix`).
- Android Auto: `aa_telemetry.rs` turns `telemetry.gps` into a `Sensor::Gps` location batch.
- CarPlay: `cp_telemetry.rs` re-encodes `telemetry.gps` as NMEA for the helper (iAP2 location).
- godot-maps: `services/location_service.gd` reads `telemetry/gps` over the core socket; a core fix wins over
  the device's own source for `CORE_FIX_MS` (5 s).
- Cluster: `micom-livi -gpsd 127.0.0.1:2947` sends gpsd's track (compass) and position to the cluster.
- `telemetry.gps` can also be pushed from outside: `livi-core telemetry set gps.lat=…`, `POST :4000/telemetry`.

## Stock navigation: how it loads maps, and how it gets position

MnSoft "ExSL" engine, app `HKMC_Navi_ExSL` (`/system/app`, package `com.mnsoft.navi`), native
`libExSLNavi.so` + `libExSLAndroidJNI.so` + `libgnustl_shared.so`.

**Where the data lives (confirmed).** By-name partitions `navi` and `navi2`, ext4, mounted read-only at
`/storage/navi` and `/storage/navi2` by `fstab.tcc803x` (the unit's `/proc/mounts` agrees). The app's
strings name `/storage/navi/navi` and `/storage/navi2/navi`, and `/oem_data/map_index.cfg`
("Default DB Path Use! Because (map_index.cfg) File Not Exist!"): inferred an A/B pair with
`map_index.cfg` choosing, and `navi` the default, so one partition with the data is enough. Not vold, not SD:
SD and USB (`/storage/sdcard1`, `/storage/usb*`) are vold-managed vfat, for updates only.

**Layout and format (confirmed from the update package).** The USB package splits it into
`navi_backup.tar1..9` (32.7 GB) and `sw_backup.tar` (0.53 GB), listed in the `.ver` manifest:

- `navi_backup/Data/Nation/NA/…`: MnSoft data, `.mpd` (search/POI, e.g. `NA_BUNJI_*.mpd`), `Map/VIT_NA.haftlt`,
  SQLite (`RealtimeChargingStation_ECO30.db`); the engine names it `$MAPDATA/...`.
- `navi_backup/BIN/`: per-board `G40` (Kia) and `G45` (Hyundai) `enc_lib*.so` (AES-128-CBC with a key published
  for all HKMC units), `.npkg` resource packs, `Navi_Version.txt` (`STD5W.NAM.KIA.260119.b7b3a44`),
  `Navi_OTAVersion.txt`, and `Config/PRM6/NAM/*.bin` engine settings (a "ConB" binary of XML with UTF-16 strings).
- The app decrypts the libraries itself (`decodeNaviBinary()`, into `/data/data/com.mnsoft.navi/BIN/`).

**Checks.**

- Licence: `AuthenticationManager.isNeedAuthentication()` logs "It is eMMC model. Do not authentication."; only
  SD-card models need a `.p12` UID file. The EV6 is an eMMC model: no device-bound licence expected (inferred
  from the strings).
- Signatures: the package's `NEW_TarList.txt` (XOR 0x11) carries a chunked SHA-224 per file and an `.rsa`
  signature; the app's `checkNaviValidation` (`[DSV] rsa_path`, `USBEncdecjni.so`) runs on the OTA validation
  intents. Both guard the update path; a pre-built partition skips them (inferred).
- Versions: the app keeps a `NaviVersion` table (App/Map/Gps/OTA versions) and compares
  `Navi_Version.txt` files; a mismatch should mean an update prompt, not a refusal (inferred).
- Secure files under `/securedata/com.mnsoft.navi/` (`taKeyFileJava.sec`, `sqlKeyFileJava.sec`, the latter for
  the SQLCipher passphrase of its own DBs) are created on the unit; whether the app recreates them on an empty
  `/securedata` is unknown.

**Position (confirmed config, inferred plumbing).** `Config/PRM6/NAM/dev_gps.bin` lists four GPS drivers:
`SERIAL` (`drv_serial`: `/dev/ttyGPS1`, 115200), `PLAYER` (`drv_player_gps`: replays `$MAPDATA/test.hip`),
`LOGGER` (`drv_gps_recorder`: `$USERDATA/HippoLog/HippoLog_*`), `EXTGPS` (`drv_ext_gps`), and
`DRIVER_SELECT = 4`: EXTGPS. The engine has `CExternalNaviEngineManager::setGpsCallBackFunction`,
`CDriverExtGps` and a hippo parser (`CHippoData`), and the app's odex names no LocationManager call. So the engine is
handed hippo data by a callback from the platform's GPS stack, not by Android's location API: **a mock
location provider would not move it.** Feeding hippo frames on the UART would.

## Loading the stock map in the emulator (tcc803x-qemu)

What it takes, given the 9 tars:

1. A `navi` partition of ≥ 34 GB holding the tree at `/navi/` (`BIN/`, `Data/`; `navi_backup/` renamed: the exact
   top-level name is inferred from `/storage/navi/navi`). Build it as an ext4 image with `mke2fs -d` from the
   extracted tree. Disk: ~33 GB tars + ~33 GB tree + ~33 GB image (the tree can go once the image is built).
2. The eMMC image grown to 64 GiB (QEMU eMMC sizes are powers of two; sparse, attached `snapshot=on`) with the
   `navi` partition resized in the GPT builder (`tools/gen5w-stock/build-emmc.sh` has `DATA_MIB`/`CACHE_MIB`; a
   `NAVI_MIB` the same way), or the `navi` partition pointed at a second image.
3. Nothing to decrypt by hand (the app does it), no licence (eMMC model).

**OpenGL ES 2.** `libExSLNavi.so` links `libGLESv2.so` and compiles shaders; Android 4.4's software `libGLES_android`
(the emulator hides the Mali EGL) is GLES 1.x only, and the app's `eglCreateContext` threw. Solved by
`tools/tcc803x-qemu/gles/` (SwiftShader GLES 3.0 for the nav process, README "OpenGL ES 2"): on the empty
partition the GL thread now creates its contexts and window surface, then waits 15 s for
`/storage/navi/navi/HKMC_Navi.apk` and finishes the activity. The map data is what is left. Speed: a full-screen
shaded draw runs at 3-8 fps under TCG, so expect a slow but drawn map.

**Effort.** Steps 1-3: a day, mostly copying 33 GB, worth it for the engine's non-drawing behaviour (routing,
guidance, cluster turn-by-turn frames over the micom link, which micom-fake can record). A drawn map: GLES 2 is
there (above); untested with data.

## Fake positions: proposal

One injection point, the GNSS stream itself, so every consumer above sees the same fake, and the fake is marked
as such.

**The source.** A replay mode in hippod: `hippod -gpx route.gpx [-speed x] -out /run/gps0 -out /run/gps-livi`
instead of `-dev`, writing the same ptys and NMEA as the real module, with:

- GGA quality 8 (simulation), which livi-core already decodes as `FixQuality::Simulated`;
- the current UTC time in every sentence, never the GPX's (livi-core steps the clock from it);
- speed and course from the track, 1 Hz (10 Hz like the module is not needed).

GPX in, so a route drawn in any tool replays. Later, the same replayer can
emit hippo frames instead of NMEA (go-hippod already has `Encode`) for the stock emulator, below.

**On the unit (parked).** A unit `mobis-g5w-gps-fake.service`, never enabled, started by hand with the GPX:

- `Conflicts=mobis-g5w-hippod.service`: the real feed stops while the fake runs, so they never mix; stopping the
  fake (`ExecStopPost`) starts hippod again.
- It runs only parked: it reads micomd's tap and exits on gear out of P or speed > 0, so the real GNSS is back
  within seconds of moving off.
- Nothing persists: not enabled, no config change, so a reboot (any ACC cycle) is always the real GNSS.
- livi-core ignores `Simulated` fixes for the clock step and the timezone save (a change in livi-core: today
  a route in another zone would save that zone), and the shell shows a "Simulated GPS" badge while
  `telemetry.gnss.fixQuality` is `simulated`.

**In the VM.** No `/dev/ttyAMA3`, so hippod's unit is skipped. The same replayer writes a pty, and the VM's
livi-core preset sets `gpsDevice` to it (VM-only config). For a one-off, `livi-core telemetry set gps.lat=… gps.lng=…`
in a loop needs no new code, but it bypasses the GNSS reader (no clock, no `gnss`, no gpsd).

**Map-only testing** needs none of this: godot-maps' Menu → Trips replays a recorded trip inside the app.

**Stock nav (emulator).** Model the GNSS UART: a `uart3` PL011 node (`serial3` alias, so it is `ttyTCC3`) in
`tcc803x-qemu.dts` and a fourth `-serial` chardev in `run.sh`, fed by the replayer in hippo mode. The HAL then
feeds LocationManager and (inferred) the engine's EXTGPS driver. It must answer the HAL's queries (version 0x11,
protocol mask 0x23 = 3; the frames are in go-hippod's `Stock`). Without a UART model: set `DRIVER_SELECT` to the
PLAYER driver in our own `navi` image's `dev_gps.bin` and put a hippo log at `$MAPDATA/test.hip` (format
inferred to be the engine's own HippoLog recording, unverified).

## To verify on the unit

- `hippod -dev /dev/ttyAMA3 -dump` while parked: frames decode, the 0x30 DR flag, plausible lat/lon.
- With the fake: `gpspipe -w` shows mode 3 at the GPX's points; `telemetry.gnss.fixQuality` is `simulated`;
  godot-maps follows the route; the cluster compass turns.
- Android Auto: Maps on the phone follows the car's position, not the phone's own (it may prefer the phone's
  GNSS; note which).
- Shift out of P: the fake exits, hippod restarts, and real fixes are back in `telemetry.gps` within 5 s
  (godot-maps' `CORE_FIX_MS`).
- After a reboot: no fake unit running, `gpsDevice` unchanged, timezone and clock as before the test.
