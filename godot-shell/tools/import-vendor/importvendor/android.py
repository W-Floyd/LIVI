"""Android value formats and resource-qualifier matching, independent of any vendor."""
import re
from dataclasses import dataclass

DENSITIES = {"ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320,
             "xxhdpi": 480, "xxxhdpi": 640}
UI_MODES = {"car", "desk", "television", "appliance", "watch", "vrheadset"}
SIZES = {"small": 0, "normal": 1, "large": 2, "xlarge": 3}


def parse_color(s):
    """`#RGB`, `#ARGB`, `#RRGGBB` or `#AARRGGBB` to an (r, g, b, a) tuple of 0–255."""
    s = s.strip()
    if not s.startswith("#"):
        raise ValueError(f"not a color: {s!r}")
    h = s[1:]
    if len(h) in (3, 4):
        h = "".join(c * 2 for c in h)
    if len(h) == 6:
        h = "ff" + h
    if len(h) != 8 or not re.fullmatch(r"[0-9a-fA-F]{8}", h):
        raise ValueError(f"not a color: {s!r}")
    a, r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4, 6))
    return (r, g, b, a)


def color_hex(rgba):
    """Godot's order: `#rrggbb`, or `#rrggbbaa` when not opaque (Android puts alpha first)."""
    r, g, b, a = rgba
    return f"#{r:02x}{g:02x}{b:02x}" + ("" if a == 255 else f"{a:02x}")


_DIM = re.compile(r"^\s*(-?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)\s*(dp|dip|sp|px|pt|mm|in)?\s*$")


def parse_dimension(s):
    """`12.0dp` to (12.0, "dp"); a bare number is px."""
    m = _DIM.match(s)
    if not m:
        raise ValueError(f"not a dimension: {s!r}")
    unit = m.group(2) or "px"
    return float(m.group(1)), "dp" if unit == "dip" else unit


def to_dp(s, density=1.5, font_scale=1.0):
    v, unit = parse_dimension(s) if isinstance(s, str) else (float(s), "dp")
    xdpi = 160 * density
    return {
        "dp": v,
        "sp": v * font_scale,
        "px": v / density,
        "pt": v * xdpi / 72 / density,
        "in": v * xdpi / density,
        "mm": v * xdpi / 25.4 / density,
    }[unit]


def dp_to_px(dp, density=1.5):
    return dp * density


_GRAVITY_ALIASES = {"start": "left", "end": "right"}


def parse_gravity(s):
    """`left|center_vertical` to a set; `center` adds both axes; start/end map to LTR."""
    if not s:
        return frozenset()
    out = set()
    for part in s.split("|"):
        part = _GRAVITY_ALIASES.get(part.strip(), part.strip())
        if part == "center":
            out |= {"center_horizontal", "center_vertical"}
        elif part == "fill":
            out |= {"fill_horizontal", "fill_vertical"}
        elif part:
            out.add(part)
    return frozenset(out)


@dataclass(frozen=True)
class Config:
    """The device a resource is chosen for. Defaults: the G5W's 1920×720 panel at hdpi."""
    night: bool = False
    density: int = 240
    width_dp: int = 1280
    height_dp: int = 480
    long: bool = True
    orientation: str = "land"
    locale: str = "en"
    region: str = "US"
    ui_mode: str = ""
    size: str = "large"


def parse_qualifiers(dirname):
    """`drawable-long-night-nodpi-v8` to ("drawable", {...}); None if a token is unknown."""
    parts = dirname.split("-")
    kind, q = parts[0], {}
    for p in parts[1:]:
        if re.fullmatch(r"v\d+", p):
            q["version"] = int(p[1:])
        elif p in ("night", "notnight"):
            q["night"] = p == "night"
        elif p in DENSITIES:
            q["density"] = DENSITIES[p]
        elif p in ("nodpi", "anydpi"):
            q["density"] = p
        elif p in ("land", "port", "square"):
            q["orientation"] = p
        elif p in ("long", "notlong"):
            q["long"] = p == "long"
        elif m := re.fullmatch(r"(sw|w|h)(\d+)dp", p):
            q[m.group(1)] = int(m.group(2))
        elif p in ("ldrtl", "ldltr"):
            q["layout_dir"] = p
        elif p in UI_MODES:
            q["ui_mode"] = p
        elif p in SIZES:
            q["size"] = p
        elif re.fullmatch(r"[a-z]{2,3}", p) and "locale" not in q:
            q["locale"] = p
        elif re.fullmatch(r"r[A-Z]{2}", p):
            q["region"] = p[1:]
        else:
            return kind, None
    return kind, q


def matches(q, cfg):
    if q is None:
        return False
    if "locale" in q and q["locale"] != cfg.locale:
        return False
    if "region" in q and q["region"] != cfg.region:
        return False
    if q.get("layout_dir") == "ldrtl":
        return False
    if "ui_mode" in q and q["ui_mode"] != cfg.ui_mode:
        return False
    if q.get("sw", 0) > min(cfg.width_dp, cfg.height_dp):
        return False
    if q.get("w", 0) > cfg.width_dp or q.get("h", 0) > cfg.height_dp:
        return False
    if "size" in q and SIZES[q["size"]] > SIZES[cfg.size]:
        return False
    if "long" in q and q["long"] != cfg.long:
        return False
    if "orientation" in q and q["orientation"] != cfg.orientation:
        return False
    if "night" in q and q["night"] != cfg.night:
        return False
    return True


def _density_rank(d, want):
    """Lower is better: exact, then nodpi (drawn 1:1), then the nearest larger, then smaller."""
    d = 160 if d is None else d
    if d == want:
        return (0, 0)
    if d in ("nodpi", "anydpi"):
        return (1, 0)
    return (2, d - want) if d > want else (3, want - d)


# Android's precedence, most significant first; density is decided last, by nearness.
_AXES = ["locale", "region", "layout_dir", "sw", "w", "h", "size", "long", "orientation",
         "ui_mode", "night"]


def select(candidates, cfg):
    """Android's elimination: the candidate (qualifiers, item) the device would load, or None."""
    pool = [c for c in candidates if matches(c[0], cfg)]
    if not pool:
        return None
    for axis in _AXES:
        having = [c for c in pool if axis in c[0]]
        if having:
            if axis in ("sw", "w", "h"):
                best = max(c[0][axis] for c in having)
                having = [c for c in having if c[0][axis] == best]
            pool = having
    pool.sort(key=lambda c: (_density_rank(c[0].get("density"), cfg.density), -c[0].get("version", 0)))
    return pool[0]


def density_scale(q, cfg):
    """How much the device scales a bitmap from this folder: nodpi is 1:1."""
    d = q.get("density") if q else None
    if d in ("nodpi", "anydpi"):
        return 1.0
    return cfg.density / (d or 160)


def luminance(rgba):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in rgba[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
