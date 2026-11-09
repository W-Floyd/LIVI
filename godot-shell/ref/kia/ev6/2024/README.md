# Kia EV6 owner's manual: UI reference

The stock UI as the owner's manual draws it, for matching a vendor theme (see PLAN.md,
"Vendor themes"). Kept locally only: the manual and its images are Kia's copyright, so
`ref/.gitignore` keeps everything here out of git but this README.

- **Source:** <https://www.kia.com/content/dam/kia2/in/en/our-vehicles/showroom/Kia-EV6-Owners-Manual.pdf>
  (`Kia-EV6-Owners-Manual.pdf`, 542 pages). Its internal title is
  `CV_EV_General_for_EUROPE`, dated October 2022, so it's the European general edition, not
  specific to the 2024 car.
- **What the images are:** greyscale illustrations, not screen captures. They show layout,
  content and wording, not colors, and aren't pixel-exact. Pixel-exact references come from
  the unit (`screencap`), as the plan says.

## Contents

- `screens/`: 238 images. Infotainment pages, cluster views and pop-ups, head-up display,
  and settings menus.
- `symbols/`: 148 images. Telltales and indicator symbols: warning lights, driver
  assistance, parking, HOLD, LIMIT, CRUISE, and so on.

File names are `p<page>-<n>.png`: the manual page, then the image's index in the PDF. The text
around each figure is on that page.

## Where the screens come from, by manual page

- **14–23:** the EV pages of the infotainment system:
  - the home menu;
  - the "Electric vehicle" screen;
  - next departure, scheduled charging and target temperature, off-peak hours;
  - EV charge transfer (V2L), charging stations;
  - EV settings: charging limit, AC charging current, utility mode, battery conditioning.
- **27–54:** charging: the cluster while charging, charge-time pop-ups, EV warnings, energy
  information.
- **160–188:** the cluster's layout, trip info, user settings and pop-ups; the head-up display
  (179–180).
- **196–236:** gear and driving pop-ups.
- **245–402:** driver assistance: cluster warnings, the settings menus, and parking views.

## From the stock firmware (V015.012, 2026-05)

The real assets, from the EV6's own stock `/system`. These are the source a vendor pack is
built from.

- **Source:** `kia-ev6/data/new_system_package_ECOKMC.USA.1000.V015.012.260507.095425.tar`,
  `enc_system/enc_system.ext4`, decrypted with the EV6 key in `kia-ev6/secrets`. The
  decrypted image is `kia-ev6/scratch/ev6_fw/V015/system.ext4`.
- **Extracted with go-unbrick:**

  ```sh
  unbrick extract -r --depth 3 --match '<apps>\.apk/res/.*\.(png|webp|jpg)$|fonts/Mobis-.*\.ttf$' \
    -o firmware-V015 system.ext4
  ```

  go-unbrick can also take the encrypted package directly with `--secrets kia-ev6/secrets`.

**Folders:**
- `firmware-V015/`: 25,508 images from the apps below, as `<app>.apk/res/<drawable…>/<name>`;
  the stock fonts `Mobis-Regular.ttf` and `Mobis-Bold.ttf`; the welcome animation
  `welcome_kia_jong_e_1920.mp4` (the other Kia MP4s are 5-byte stubs); each app's
  `resources.arsc`.
- `apks/`: the APKs themselves, plus `framework-res` and `hkmc-res`.
- `decoded/`: the apps decoded with apktool (resources only, `-s`), against a local framework
  folder in `decoded/.framework`. `res/values/` has colors, dimensions and styles;
  `res/layout/` has every screen's exact layout. It holds the images again, so
  `firmware-V015/` is a duplicate kept for name searches. `framework-res` and `hkmc-res` are
  decoded here too.
- `work/dex/`: the EV app's DEX class signatures and string constants (no bytecode).
- `pack/`: the vendor theme pack, built from all of the above by `tools/import-vendor`
  (see its README), with composited references of the "Electric vehicle" screen in
  `pack/reference/`.

**The apps that make up the stock look:**
- `Launcher_WP3`: home and launcher.
- `RightScreenHome`: the right-hand split-screen widgets.
- `HKMC_TAppEV3`: the EV screens.
- `SystemUI`: the status bar.
- `HKMC_Climate`, `HKMC_VehicleSetting`, `HKMC_HomeSetting_WP`, `ThemeSettings`,
  `Mobis_SystemPopup`.
- `hkmc-res`: Hyundai/Kia's shared resources, values only.

**The "Electric vehicle" screen** is pre-rendered images, not 3D. Its layout is `layout_main.xml`
(title bar, then `layout_evmain_view.xml` and its includes); the `drivemode_wide_*` layouts are the
drive-mode settings screen.
- `HKMC_TAppEV3/res/drawable-nodpi/ev_etc_main_case{1..4}_NN.webp`: 1920 × 540 frames of the
  range road for each range state;
- `ev_ic_battery_bg_hatch_nor.webp` and `ev_ic_battery_cover_hatch.webp`: the car, under and
  over the battery badge (the layout's default body style; code may pick another). No layout
  uses `ev_etc_eu_vehicle_{l,s}`: code sets them, if anything does;
- `ev_etc_battery_00`–`_20`: the battery badge.

  `drawable-night-nodpi` has the night versions. The bottom tiles are
  `layout_evmain_view_bottom_widgets.xml`; the `layout_ev_eco_main_*.xml` layouts are the pages
  the tiles open.

## How it was made

```sh
pdfimages -png -p Kia-EV6-Owners-Manual.pdf images/p
```

That extracts 1,146 images. They were sorted by tone, then deduplicated by pixel content:

- **Screens:** mostly near-black (UI on a dark background).
- **Symbols:** black on white with almost no mid-tones, or small (300 px or less) and mostly
  flat.
- **Everything else:** photos and drawings of the car's hardware, removed. It can be
  extracted again from the PDF if needed.
