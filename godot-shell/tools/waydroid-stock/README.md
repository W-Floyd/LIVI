# waydroid-stock

Runs the stock Kia EV6 head-unit EV app (`HKMC_TAppEV3`, Android 4.x Dalvik odex) in Waydroid (Android 13, aarch64 VM).
Needs the local firmware assets under `ref/` (never committed); everything derived lands in `ref/kia/ev6/2024/waydroid/`.

    ./01-fetch.sh     # baksmali/smali jars (Maven Central); extract framework + app odex from system.ext4
    ./03-target.sh    # pull Waydroid's framework/apex jars from the VM; class + member inventory (a13/)
    ./02-deodex.sh    # baksmali deodex (api 16) of the app and the framework odex that hold vendor classes
    ./04-build.sh     # stubs + patched smali + helpers -> signed HKMC_TAppEV3-patched.apk
    ./05-install.sh   # install into the VM's Waydroid and launch; prints crashes
    # then: wm size 1920x720; wm density 160  (inside Waydroid), relaunch

What the build does:
- Stubs every class the firmware defines that Waydroid lacks (`com.hkmc.*`, `com.mobis.*`, `com.broadcom.bt.*`, `android.dipo.*`,
  `android.widget.Dropdown`, ...): signatures and constants kept, bodies return defaults, interface returns are dynamic proxies.
  Layout tags are seeded from the decoded resources. `stub-values.example` shows how to pin return values (`$OUT/stub-values.txt`).
- Rewrites call sites: `getSystemService` and `VehicleInfoManager.getService` fall back to stubs; vendor-added methods on AOSP
  classes (`Notification.Builder.set*`, ...) become no-ops; `startForeground` gets a notification icon.
- Manifest: `<uses-library>` elements disabled (the libs are bundled as stubs), targetSdk raised 19 -> 23 (below that Android 13
  forces a permission-review screen). Re-signed with a debug key.

Known not to work / caveats:
- No vehicle data: every manager is a stub, so the UI shows placeholder values. Return values that gate the app need pinning
  (e.g. ignition status, else the app opens its ignition popup and finishes).
- The Waydroid in this VM needed `ro.hardware.gralloc=default` (with `egl=mesa`) in `/var/lib/waydroid/waydroid_base.prop` and
  `waydroid.prop`; with `gbm` surfaceflinger aborts ("output buffer not gpu writeable") and Android never boots.
- Very slow under QEMU TCG: allow ~1 min after launch before the first frame.
- `MainActivity.onDestroy` throws "Receiver not registered" (the app unregisters a receiver it never registered).
- Only the EV app is handled; other apps need their own odex deodexed and stubs generated (`APP=...`).

`scripts/waydroid.sh` manages it from the host: `start`, `launch`, `ui`, `size`, `shot`, `logs`, `sh`, `stop`, `status`, `build` (the five scripts above in order).
