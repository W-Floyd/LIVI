#!/usr/bin/env python3
"""Draws the synthetic vendor pack in synth/: tiny images of our own, 9-patches read back through
the importer's own 9-patch parser, a screen with a few views, and a font from project/fonts/.
No vendor assets. Run from anywhere. The references in synth/reference/ are renders by the shell
afterwards: `ev_main_{day,night}.png` copied from out/pack-synth/pack-synth-page-{day,night}.png
(compare_reference writes the render even when the reference is missing), and
`ev_main_day_edited.png` is the day one with a magenta box at 1650,120 (200 x 120) drawn over it.

  python3 -I make-synth.py
"""
import os
import shutil
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "import-vendor"))
from importvendor import ninepatch  # noqa: E402

OUT = os.path.join(HERE, "synth")
BLACK = (0, 0, 0, 255)


def raw_nine_patch(inner, border, fill, stretch=(6, 18), content=(4, 20)):
    """A `.9.png` as Android authors it: `inner` px square, marks on the 1-px border."""
    im = Image.new("RGBA", (inner + 2, inner + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((1, 1, inner, inner), radius=5, fill=border)
    d.rounded_rectangle((3, 3, inner - 2, inner - 2), radius=3, fill=fill)
    for i in range(stretch[0] + 1, stretch[1] + 1):
        im.putpixel((i, 0), BLACK)
        im.putpixel((0, i), BLACK)
    for i in range(content[0] + 1, content[1] + 1):
        im.putpixel((i, inner + 1), BLACK)
        im.putpixel((inner + 1, i), BLACK)
    return im


def save(path, im):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    img = {}

    def nine(name, mode, border, fill):
        m, stripped = ninepatch.from_image(raw_nine_patch(24, border, fill))
        sub = "night/" if mode == "night" else ""
        save(f"{OUT}/images/synth/{sub}{name}.png", stripped)
        img.setdefault(f"synth/{name}", {})[mode] = {
            "file": f"images/synth/{sub}{name}.png", "size": m["size"],
            "nine_patch": {"texture_margins": m["texture"], "content_margins": m["content"]}}

    def bitmap(name, mode, im, scale=None):
        sub = "night/" if mode == "night" else ""
        save(f"{OUT}/images/synth/{sub}{name}.png", im)
        e = {"file": f"images/synth/{sub}{name}.png", "size": list(im.size)}
        if scale:
            e["scale"] = scale
        img.setdefault(f"synth/{name}", {})[mode] = e

    tints = {"day": ((120, 160, 210, 255), (225, 236, 250, 255)), "night": ((60, 90, 140, 255), (24, 36, 60, 255))}
    for mode, (border, fill) in tints.items():
        nine("card", mode, border, fill)
        nine("btn_nor", mode, border, fill)
        nine("btn_push", mode, (240, 170, 40, 255), (250, 215, 130, 255) if mode == "day" else (120, 80, 10, 255))
        nine("btn_dis", mode, (150, 150, 150, 255), (200, 200, 200, 255) if mode == "day" else (50, 50, 50, 255))
        bitmap("bg", mode, Image.new("RGBA", (8, 8), (244, 246, 250, 255) if mode == "day" else (10, 14, 22, 255)))
        road = Image.new("RGBA", (64, 32))
        for x in range(64):
            for y in range(32):
                road.putpixel((x, y), (40 + x * 2, 80 + y * 3, 200 - x, 255) if mode == "day" else (20 + x, 40 + y, 120, 255))
        bitmap("road", mode, road)
    # Battery badge steps by 5 %: only these three exist, the page keeps its own when one is missing.
    for step, share in ((5, 0.25), (10, 0.5), (13, 0.65)):
        for mode in ("day", "night"):
            im = Image.new("RGBA", (48, 16), (0, 0, 0, 0))
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 47, 15), outline=(30, 30, 30, 255))
            d.rectangle((2, 2, 2 + int(44 * share), 13), fill=(30, 190, 120, 255) if mode == "day" else (20, 150, 90, 255))
            bitmap(f"battery_{step:02d}", mode, im)
    # Stored at half size with a density scale of 2: drawn at 40 px.
    icon = Image.new("RGBA", (20, 20), (0, 0, 0, 0))
    ImageDraw.Draw(icon).polygon([(10, 1), (19, 19), (1, 19)], fill=(200, 60, 60, 255))
    bitmap("icon", "day", icon, scale=2.0)
    img["synth/button"] = {"day": {"selector": [
        {"state": {"pressed": True}, "image": "synth/btn_push"},
        {"state": {"enabled": False}, "image": "synth/btn_dis"},
        {"state": {}, "image": "synth/btn_nor"}]}}

    font_dir = os.path.join(OUT, "fonts")
    os.makedirs(font_dir)
    for f in ("SairaSemiCondensed-Medium.ttf", "SairaSemiCondensed-SemiBold.ttf", "OFL-SairaSemiCondensed.txt"):
        shutil.copy(os.path.join(ROOT, "project", "fonts", f), font_dir)

    with open(f"{OUT}/images/index.yaml", "w") as f:
        f.write("# Synthetic: drawn by make-synth.py. Same shape as the importer's.\n")
        dump(f, img, 0)
    with open(f"{OUT}/theme.yaml", "w") as f:
        f.write(THEME)
    os.makedirs(f"{OUT}/screens")
    with open(f"{OUT}/screens/ev_main.yaml", "w") as f:
        f.write(SCREEN)


def dump(f, v, depth):
    """Block YAML for the nested maps and lists above; scalars and short lists inline."""
    pad = "  " * depth
    for k, x in v.items():
        if isinstance(x, dict):
            f.write(f"{pad}{k}:\n")
            dump(f, x, depth + 1)
        elif isinstance(x, list) and x and isinstance(x[0], dict):
            f.write(f"{pad}{k}:\n")
            for item in x:
                f.write(f"{pad}  - state: {flow(item['state'])}\n{pad}    image: {item['image']}\n")
        else:
            f.write(f"{pad}{k}: {flow(x)}\n")


def flow(x):
    if isinstance(x, dict):
        return "{" + ", ".join(f"{k}: {flow(v)}" for k, v in x.items()) + "}"
    if isinstance(x, list):
        return "[" + ", ".join(flow(v) for v in x) + "]"
    if isinstance(x, bool):
        return "true" if x else "false"
    return str(x)


THEME = """\
# Synthetic vendor pack for the test suite: drawn by make-synth.py, no vendor assets.
name: "Synth"
about: "Tiny pack with 9-patches, selector states and one screen."
fonts:
  display: { file: SairaSemiCondensed-SemiBold.ttf }
  body: { file: SairaSemiCondensed-Medium.ttf }
  strong: { file: SairaSemiCondensed-SemiBold.ttf }
shape: { radius_mm: 1, gap_mm: 2.5, cards: flat, display_ratio: 2.2 }
colors:
  night: { bg: "#0a0e16", surface: "#18243c", surface2: "#1c2c48", line: "#3c5a8c", text: "#dbe6f5", dim: "#8ea3c0", accent: "#f0aa28", on_accent: "#201400", ok: "#74c69d", warn: "#e9c46a", crit: "#ff8a80", proj: "#101826" }
  day:   { bg: "#f4f6fa", surface: "#e1ecfa", surface2: "#d2e0f2", line: "#78a0d2", text: "#14202e", dim: "#4c6078", accent: "#b06e00", on_accent: "#ffffff", ok: "#2e7d4f", warn: "#8a6700", crit: "#b42318", proj: "#e4eaf2" }
series:
  night: ["#1798bf", "#c97a30", "#b25fae"]
  day: ["#00779e", "#c4631a", "#a2479a"]
skins: { card: synth/card, button: synth/button }
images: images/index.yaml
screens: { ev_main: screens/ev_main.yaml }
"""


def _view(id, rect, **kw):
    out = f"  - id: {id}\n    type: View\n    depth: 1\n    rect: {flow(list(rect))}\n"
    for k, v in kw.items():
        out += f"    {k}: {v}\n"
    return out


def _text(id, rect, string, size, font="regular", gravity="[center_horizontal, center_vertical]", extra="", **kw):
    t = (f"    text:\n      string: \"{string}\"\n      font: {font}\n      size_px: {size}\n"
         f"      gravity: {gravity}\n      color: {{ day: \"#14202e\", night: \"#dbe6f5\" }}\n{extra}")
    return _view(id, rect, **kw) + t


SCREEN = (
    "# Synthetic screen in the importer's shape: views in draw order, rects in panel pixels.\n"
    "screen: ev_main\npanel: [1920, 720]\ndensity: 1.5\nwindow: [0, 30, 1920, 690]\n"
    "status_bar: { image: synth/btn_nor, height_dp: 20 }\nviews:\n"
    + _view("backdrop", (0, 30, 1920, 690), background="synth/bg")
    + _text("layout_main_title", (660, 40, 600, 80), "Synth Vehicle", 48, "bold")
    + _view("road", (0, 400, 1920, 200), background="synth/road")
    + _view("mainview_energyinformation_battery_image", (100, 450, 240, 75), background="synth/battery_10")
    + _text("mainview_text_battery_percentage_value", (117, 405, 120, 95), "50", 63, gravity="[right]",
            extra="      single_line: true\n")
    + _text("mainview_text_climateon_range_value", (1260, 426, 109, 91), "243", 60, gravity="[right, top]",
            extra="      single_line: true\n")
    + _text("mainview_text_nearyby_station_range_value", (408, 261, 108, 91), "740", 60,
            gravity="[center_horizontal, center_vertical, left]", extra="      single_line: true\n")
    + _text("mainview_text_nearyby_station_range_unit", (516, 293, 40, 46), "m", 30, gravity="[bottom, left]",
            extra="      single_line: true\n")
    + _text("mainview_text_nearyby_station_location", (570, 278, 360, 58), "Placeholder Charging Hub", 30,
            gravity="[center_horizontal, center_vertical, left]",
            extra="      max_lines: 2\n      ellipsize: end\n      line_mult: 0.7\n", padding="[0, 0, 0, 12]")
    + _text("tile", (20, 620, 540, 80), "Tile", 27, background="synth/button", padding="[110, 0, 10, 0]",
            extra="      single_line: true\n")
    + _view("tile_icon", (50, 630, 60, 60), src="synth/icon", scale_type="fitCenter", padding="[5, 5, 5, 5]")
    + _text("clipped", (1300, 620, 150, 45), "Electricity Use Settings", 27, extra="      single_line: true\n")
    + _view("hidden", (700, 100, 200, 100), background="synth/btn_push", visibility="invisible")
    + _view("swatch", (1700, 100, 100, 100), background="{ color: { day: \"#c8501e\", night: \"#7a2f10\" } }")
)

if __name__ == "__main__":
    main()
