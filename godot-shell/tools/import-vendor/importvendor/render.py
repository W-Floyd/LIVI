"""Composites a resolved screen into a panel-sized PNG: a stand-in reference until the stock
screen can be captured on the unit."""
import os

from PIL import Image, ImageDraw, ImageFilter

from . import android, text


def _load(pack, entry):
    im = Image.open(os.path.join(pack, entry["file"])).convert("RGBA")
    s = entry.get("scale", 1.0)
    if s != 1.0:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    return im


def nine_slice(im, margins, w, h, scale=1.0):
    """Stretches the centre and edges of `im` to w × h, keeping the corners."""
    l, t, r, b = (round(m * scale) for m in margins)
    # Corners never overlap: shrink them proportionally when the target is smaller.
    if l + r > w:
        l, r = l * w // max(1, l + r), w - l * w // max(1, l + r)
    if t + b > h:
        t, b = t * h // max(1, t + b), h - t * h // max(1, t + b)
    W, H = im.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    xs = [(0, l, 0, l), (l, W - r, l, w - r), (W - r, W, w - r, w)]
    ys = [(0, t, 0, t), (t, H - b, t, h - b), (H - b, H, h - b, h)]
    for sx0, sx1, dx0, dx1 in xs:
        for sy0, sy1, dy0, dy1 in ys:
            if sx1 <= sx0 or sy1 <= sy0 or dx1 <= dx0 or dy1 <= dy0:
                continue
            part = im.crop((sx0, sy0, sx1, sy1)).resize((dx1 - dx0, dy1 - dy0), Image.LANCZOS)
            out.paste(part, (dx0, dy0))
    return out


def _fit(im, w, h, scale_type):
    st = scale_type or "fitCenter"
    if st == "fitXY":
        return im.resize((w, h), Image.LANCZOS), 0, 0
    if st == "center":
        return im, (w - im.width) // 2, (h - im.height) // 2
    f = min(w / im.width, h / im.height)
    if st == "centerCrop":
        f = max(w / im.width, h / im.height)
    elif st == "centerInside":
        f = min(1.0, f)
    nw, nh = max(1, round(im.width * f)), max(1, round(im.height * f))
    im = im.resize((nw, nh), Image.LANCZOS)
    if st == "fitStart":
        return im, 0, 0
    if st == "fitEnd":
        return im, w - nw, h - nh
    return im, (w - nw) // 2, (h - nh) // 2


def _rgba(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    a = int(h[6:8], 16) if len(h) == 8 else 255
    return (r, g, b, a)


class Renderer:
    def __init__(self, pack, drawables, fonts, panel, density):
        self.pack, self.dr, self.fonts, self.panel, self.density = pack, drawables, fonts, panel, density

    def image(self, key, mode, w, h, stretch=True, scale_type=None):
        e = self.dr.resolve(key, mode)
        if not e:
            return None, 0, 0
        im = _load(self.pack, e)
        if "nine_patch" in e:
            return nine_slice(im, e["nine_patch"]["texture_margins"], w, h, e.get("scale", 1.0)), 0, 0
        if stretch:
            return im.resize((max(1, w), max(1, h)), Image.LANCZOS), 0, 0
        return _fit(im, w, h, scale_type)

    def draw_text(self, canvas, v, mode, x, y, w, h):
        t = v["text"]
        pl, pt, pr, pb = v.get("padding", [0, 0, 0, 0])
        col = (t.get("color") or {}).get(mode) or ("#ffffff" if mode == "night" else "#000000")
        spec = {"string": t["string"], "weight": t["font"], "size_px": t["size_px"],
                "single_line": t.get("single_line"), "max_lines": t.get("max_lines"),
                "line_mult": t.get("line_mult", 1.0), "line_extra_px": t.get("line_extra_px", 0.0)}
        iw, ih = w - pl - pr, h - pt - pb
        lines, tw, th, asc, lh = text.block(self.fonts, spec, self.density, iw)
        font = self.fonts.get(t["font"], t["size_px"])
        g = set(t.get("gravity", []))
        ty = y + pt + ((ih - th) if "bottom" in g else (ih - th) / 2 if "center_vertical" in g else 0)
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        for i, line in enumerate(lines):
            lw = font.getlength(line)
            tx = x + pl + ((iw - lw) if "right" in g else (iw - lw) / 2 if "center_horizontal" in g else 0)
            d.text((tx, ty + i * lh), line, font=font, fill=_rgba(col))
        sh = t.get("shadow")
        if sh and (sh.get("color") or {}).get(mode):
            s = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
            sc = _rgba(sh["color"][mode])
            alpha = layer.split()[3]
            s.paste(Image.new("RGBA", canvas.size, sc), (round(sh["dx"]), round(sh["dy"])), alpha)
            if sh["radius"]:
                s = s.filter(ImageFilter.GaussianBlur(sh["radius"] / 2))
            canvas.alpha_composite(s)
        canvas.alpha_composite(layer)

    def screen(self, views, spec, mode):
        W, H = self.panel
        canvas = Image.new("RGBA", (W, H), (0, 0, 0, 255))
        sb = spec.get("status_bar")
        if sb:
            sh = round(sb["height_dp"] * self.density)
            im, _, _ = self.image(sb["image"], mode, W, sh)
            if im:
                canvas.alpha_composite(im, (0, 0))
        for v in views:
            if v.get("visibility") == "invisible":
                continue
            x, y, w, h = v["rect"]
            if w <= 0 or h <= 0:
                continue
            for k in ("background", "src"):
                val = v.get(k)
                if not val:
                    continue
                if isinstance(val, dict):
                    c = (val.get("color") or {}).get(mode)
                    if c:
                        canvas.alpha_composite(Image.new("RGBA", (w, h), _rgba(c)), (x, y))
                    continue
                if k == "background":
                    im, ox, oy = self.image(val, mode, w, h)
                else:
                    pl, pt, pr, pb = v.get("padding", [0, 0, 0, 0])
                    im, ox, oy = self.image(val, mode, w - pl - pr, h - pt - pb, False, v.get("scale_type"))
                    ox, oy = ox + pl, oy + pt
                if im:
                    _paste(canvas, im, x + ox, y + oy, (x, y, x + w, y + h) if k == "src" else None)
            if "text" in v:
                self.draw_text(canvas, v, mode, x, y, w, h)
        return canvas.convert("RGB")


def _paste(canvas, im, x, y, clip=None):
    l, t = max(0, x), max(0, y)
    r, b = min(canvas.width, x + im.width), min(canvas.height, y + im.height)
    if clip:
        l, t, r, b = max(l, clip[0]), max(t, clip[1]), min(r, clip[2]), min(b, clip[3])
    if r <= l or b <= t:
        return
    canvas.alpha_composite(im.crop((l - x, t - y, r - x, b - y)), (l, t))
