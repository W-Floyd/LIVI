"""Colors, dimensions and text styles from the stock apps, ranked by how much the stock UI uses
them, and a first guess at the shell's semantic color slots for a human to review."""
import colorsys
import math
import os
import re
import xml.etree.ElementTree as ET
from collections import Counter

from PIL import Image

from . import android
from .resources import attr_name, parse_ref

_LITERAL = re.compile(r"^#[0-9a-fA-F]{3,8}$")


def _xml_files(pkg_root):
    res = os.path.join(pkg_root, "res")
    for d in sorted(os.listdir(res)):
        kind, q = android.parse_qualifiers(d)
        if q is None or kind not in ("layout", "drawable", "color", "values"):
            continue
        for f in sorted(os.listdir(os.path.join(res, d))):
            if f.endswith(".xml") and f != "public.xml":
                yield kind, os.path.join(res, d, f)


def usage(packages):
    """Counts color and dimension references and text styles across every package's XML."""
    colors, dims, styles = Counter(), Counter(), Counter()
    for name, p in packages.items():
        for kind, path in _xml_files(p.root):
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError:
                continue
            if kind == "values" and not os.path.basename(path).startswith("styles"):
                continue
            for e in root.iter():
                vals = list(e.attrib.items())
                if kind == "values" and e.tag == "item":
                    vals.append((e.get("name"), (e.text or "").strip()))
                for k, v in vals:
                    if not isinstance(v, str):
                        continue
                    r = parse_ref(v)
                    if r and r[1] == "color":
                        colors[f"{r[0] or name}:{r[2]}"] += 1
                    elif r and r[1] == "dimen":
                        dims[f"{r[0] or name}:{r[2]}"] += 1
                    elif _LITERAL.match(v):
                        colors["#" + v[1:].lower()] += 1
                    elif kind == "layout" and re.fullmatch(r"-?[0-9.]+dp", v):
                        dims[v] += 1
                if kind == "layout":
                    a = {attr_name(k): v for k, v in e.attrib.items()}
                    if "android:textSize" in a:
                        styles[(name, a["android:textSize"], a.get("android:textStyle", "normal"),
                                a.get("android:textColor"))] += 1
    return colors, dims, styles


def color_table(res_by_pkg, day, night):
    """Every <color> resource in every package: "pkg:name" -> {day, night} rgba."""
    out = {}
    for pname, res in res_by_pkg.items():
        p = res.app
        for (kind, name), _ in p.values.items():
            if kind != "color":
                continue
            ref = f"@{pname}:color/{name}" if pname != "android" else f"@android:color/{name}"
            d, n = res.color(ref, day, pname), res.color(ref, night, pname)
            if d or n:
                out[f"{pname}:{name}"] = {"day": (d or n)["default"], "night": (n or d)["default"]}
    return out


def _hsv(rgba):
    return colorsys.rgb_to_hsv(*(c / 255 for c in rgba[:3]))


def _hue_in(h, lo, hi):
    deg = h * 360
    return lo <= deg <= hi if lo <= hi else deg >= lo or deg <= hi


def text_colors(text_styles):
    """Text colors as (day, night) pairs, weighted by how many text views use each."""
    pairs = {}
    for s in text_styles:
        c = s["color"]
        if not c["day"] or not c["night"]:
            continue
        k = (c["day"], c["night"])
        e = pairs.setdefault(k, {"ref": c["ref"], "day": c["day"], "night": c["night"], "uses": 0})
        e["uses"] += s["uses"]
    return sorted(pairs.values(), key=lambda e: -e["uses"])


def text_slots(colors):
    """text: the most-used opaque text color that is light at night; dim: the most-used one
    clearly darker than it at night, still readable."""
    def lum(h):
        return android.luminance(android.parse_color(h))

    def opaque(h):
        return len(h) == 7
    text = [c for c in colors if opaque(c["night"]) and opaque(c["day"]) and lum(c["night"]) > 0.3]
    top = lum(text[0]["night"]) if text else 1.0
    dim = [c for c in colors if opaque(c["night"]) and opaque(c["day"]) and 0.03 < lum(c["night"]) < top * 0.6]
    return {"text": ("most-used opaque text color, light at night (by text views using it)", text),
            "dim": ("most-used text color well darker than `text` at night, still above black", dim)}


SLOTS = {
    "accent": ("most-used saturated color outside the warning hues",
               lambda n, c: _hsv(c)[1] > 0.5 and _hsv(c)[2] > 0.45 and c[3] == 255 and _hue_in(_hsv(c)[0], 60, 300)),
    "warn": ("orange or yellow, or named warning",
             lambda n, c: c[3] == 255 and (re.search(r"war|caution", n) or (_hsv(c)[1] > 0.5 and _hue_in(_hsv(c)[0], 15, 60)))),
    "crit": ("red, saturated",
             lambda n, c: c[3] == 255 and _hsv(c)[1] > 0.55 and _hsv(c)[2] > 0.5 and _hue_in(_hsv(c)[0], 345, 12)),
    "ok": ("green, saturated",
           lambda n, c: c[3] == 255 and _hsv(c)[1] > 0.4 and _hsv(c)[2] > 0.4 and _hue_in(_hsv(c)[0], 85, 165)),
    "line": ("named line, divider or separator",
             lambda n, c: re.search(r"line|divider|separ", n) and c[3] > 0),
}

# Surfaces are images in the stock UI: these slots are sampled from the model's named drawables.
IMAGE_SLOTS = ("bg", "surface", "surface2", "proj")


def rank_slot(rule, table, uses, mode="night"):
    out = []
    for key, v in table.items():
        name = key.split(":", 1)[1]
        if rule(name, v[mode]):
            out.append({"ref": key, "day": android.color_hex(v["day"]), "night": android.color_hex(v["night"]),
                        "uses": uses.get(key, 0)})
    out.sort(key=lambda c: (-c["uses"], c["ref"]))
    return out


def sample_image(path, scale_box=(0.25, 0.25, 0.75, 0.75)):
    """Mean color of an image's central area (a 9-patch's border marks fall outside it)."""
    with Image.open(path) as im:
        im = im.convert("RGBA")
        w, h = im.size
        box = tuple(round(f * s) for f, s in zip(scale_box, (w, h, w, h)))
        c = im.crop(box).resize((1, 1), Image.BOX).getpixel((0, 0))
    return (c[0], c[1], c[2], 255)


def series(table, uses, n=3):
    """Distinct saturated hues, most used first, at least 40° apart."""
    picks = []
    for c in rank_slot(lambda nm, c: _hsv(c)[1] > 0.45 and _hsv(c)[2] > 0.4 and c[3] == 255, table, uses):
        h = _hsv(android.parse_color(c["night"]))[0] * 360
        if all(min(abs(h - p[0]), 360 - abs(h - p[0])) >= 40 for p in picks):
            picks.append((h, c))
        if len(picks) == n:
            break
    return [p[1] for p in picks]


def px_per_mm(panel_w, panel_h, diag_in):
    diag = math.hypot(panel_w, panel_h)
    return panel_w / (diag_in * 25.4 * panel_w / diag)


def min_font_px(rules, ppmm):
    cap_mm = 2.0 * rules["view_mm"] * math.tan(math.radians(rules["char_arcmin"] / 60.0) / 2.0)
    return cap_mm * ppmm / 0.7
