# import-vendor

Builds a vendor theme pack from a car's stock head-unit firmware, so the shell can look like the
stock UI (PLAN.md, "Vendor themes"). The pack holds the vendor's fonts, images and layouts: it is
built locally and never committed or redistributed. Only this tool is in the repo.

## Run

```sh
tools/import-vendor/import-vendor --model ev6 \
  --ota new_system_package_ECOKMC.USA.1000.V015.012.260507.095425.tar \
  --secrets /path/to/secrets
```

- `--ota`, `--secrets`: the stock OTA package and a folder of firmware keys. Only the model's
  key and IV are used (`2022_2024-usa-ev6_*` for the EV6). Both are needed only for inputs not
  already in the reference folder: with everything extracted and decoded, a bare
  `import-vendor` rebuilds the pack in a few seconds.
- `--ref`: where extracted and decoded files go; default `ref/kia/ev6/2024/` (gitignored).
- `-o`: the pack; default `<ref>/pack/`. `--clean` empties it first.
- `--unbrick`, `--apktool`: the tools, if not on `PATH` (`UNBRICK` also works).

Needs Python 3.10+ with Pillow (`pip install -r requirements.txt`),
[go-unbrick](https://github.com/W-Floyd/go-unbrick) for decrypting and reading the OTA, and apktool.

## What it does

1. **Extract** (go-unbrick): from the encrypted `system.ext4` inside the OTA, the stock apps,
   `framework-res` and `hkmc-res`, and the Mobis fonts, into `<ref>/apks/`. Also the screen
   apps' DEX class signatures and strings, into `<ref>/work/dex/`, for finding what code decides.
2. **Decode** (apktool, resources only): each APK against the device's own framework, installed
   into `<ref>/decoded/.framework`, into `<ref>/decoded/<app>/`.
3. **Resolve** resources as the device would: a 1920 × 720 panel at hdpi (1 dp = 1.5 px), long,
   landscape, English, day or night, with Android's qualifier precedence.
4. **Images**: every drawable of the image apps, plus the framework drawables they use. Day and
   night files; 9-patches stripped of their border, with Godot texture and content margins;
   selectors as per-state maps; animation lists, layer lists and aliases described.
5. **Screens**: a layout inflated (includes, merges, styles), then measured and laid out like
   Android's FrameLayout, LinearLayout (weights, baseline alignment) and RelativeLayout. Every view
   gets its rectangle in panel pixels, images and text style. What the stock app sets from code
   (which views show, the range-road frame, the numbers) is a representative state in
   `importvendor/models.py`.
6. **Reference**: each screen composited to a panel-sized PNG, day and night, until the stock
   screen can be captured on the unit.
7. **Tokens**: colors ranked by how often the stock XML uses them, text styles, dimensions, and
   a guess at the shell's semantic color slots.

## The pack

```
theme.yaml         the shell's theme schema (name, fonts, shape, colors.day/night, series),
                   plus text_styles, dimensions, and pointers to images, screens, references
token-map.yaml     NEEDS REVIEW: each semantic slot's pick, its rule, ranked candidates
fonts/             the stock fonts
images/index.yaml  <package>/<name> -> day/night file, size, density scale, 9-patch margins,
                   selector states
images/<package>/  the files; night/ for night variants
screens/<name>.yaml
reference/<name>_{day,night}.png
NOTICE             not for redistribution
```

## Tests

```sh
cd tools/import-vendor && python3 -m unittest
```

Synthetic fixtures only: no vendor files.
