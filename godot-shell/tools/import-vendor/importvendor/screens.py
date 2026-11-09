"""Stock layout XML to a screen: every view's rectangle in panel pixels, its images and text."""
import xml.etree.ElementTree as ET

from . import android, layout, text
from .layout import MATCH, WRAP, Node
from .resources import attr_name, parse_ref

FRAMES = {"FrameLayout", "ScrollView", "HorizontalScrollView", "ViewFlipper", "ViewAnimator",
          "TabHost", "ViewSwitcher", "ImageSwitcher", "TextSwitcher"}
LINEARS = {"LinearLayout", "RadioGroup", "TableLayout", "TableRow"}
RELATIVES = {"RelativeLayout"}
TEXTS = {"TextView", "Button", "EditText", "CheckBox", "RadioButton", "ToggleButton", "Switch",
         "CheckedTextView", "Chronometer", "DigitalClock", "TextClock"}
RULES = ["toRightOf", "toEndOf", "toLeftOf", "toStartOf", "alignLeft", "alignStart", "alignRight",
         "alignEnd", "below", "above", "alignTop", "alignBottom", "alignBaseline",
         "alignParentLeft", "alignParentStart", "alignParentRight", "alignParentEnd",
         "alignParentTop", "alignParentBottom", "centerHorizontal", "centerVertical", "centerInParent"]


def kind_of(cls, attrs, has_children):
    base = cls.rsplit(".", 1)[-1]
    if base in FRAMES:
        return "frame", False
    if base in LINEARS:
        return "linear", False
    if base in RELATIVES:
        return "relative", False
    if not has_children:
        return "leaf", base not in TEXTS | {"View", "ImageView", "ImageButton", "ProgressBar", "SeekBar", "Space"}
    # Custom view groups: guess from the name, then from the attributes their children use.
    if "Relative" in base:
        return "relative", True
    if "Linear" in base or "android:orientation" in attrs:
        return "linear", True
    return "frame", True


class Inflater:
    """Builds layout Nodes from XML, against one app's Resources under one Config."""

    def __init__(self, res, cfg, drawables, fonts, density, state=None):
        self.res, self.cfg, self.dr, self.fonts, self.density = res, cfg, drawables, fonts, density
        self.state = state or {}
        self.notes = []

    def inflate(self, layout_name, pkg=None):
        hit = self._layout(layout_name, pkg)
        if not hit:
            raise KeyError(f"layout {layout_name} not found")
        root = ET.parse(hit[1]).getroot()
        nodes = self._element(root, pkg or self.res.app.name)
        return nodes[0]

    def _layout(self, name, pkg):
        return self.res.file("layout", name, self.cfg, pkg)

    def _attrs(self, e, pkg):
        a = {}
        style = e.get("style")
        if style:
            a.update(self.res.style(style, self.cfg, pkg))
        for k, v in e.attrib.items():
            a[attr_name(k)] = v
        return a

    def _element(self, e, pkg):
        if e.tag == "include":
            ref = parse_ref(e.get("layout") or "")
            hit = self._layout(ref[2], ref[0]) if ref else None
            if not hit:
                self.notes.append(f"include {e.get('layout')} not found")
                return []
            root = ET.parse(hit[1]).getroot()
            if root.tag == "merge":
                return [n for c in root for n in self._element(c, pkg)]
            over = {attr_name(k): v for k, v in e.attrib.items() if k != "layout"}
            if "android:layout_width" in over and "android:layout_height" in over:
                for k in list(root.attrib):
                    if attr_name(k).startswith("android:layout_"):
                        del root.attrib[k]
                over_layout = {k: v for k, v in over.items() if k.startswith("android:layout_")}
            else:
                over_layout = {}
            for k, v in over_layout.items():
                root.set(k.replace("android:", "{http://schemas.android.com/apk/res/android}"), v)
            for k in ("android:id", "android:visibility"):
                if k in over:
                    root.set(k.replace("android:", "{http://schemas.android.com/apk/res/android}"), over[k])
            nodes = self._element(root, pkg)
            for n in nodes:
                n.attrs["include"] = ref[2]
            return nodes
        if e.tag == "merge":
            return [n for c in e for n in self._element(c, pkg)]
        if e.tag in ("requestFocus", "tag", "fragment"):
            return []
        return [self._node(e, pkg)]

    def _dim(self, a, key, pkg, default=WRAP):
        v = a.get(key)
        if v is None:
            return default
        if v in ("match_parent", "fill_parent"):
            return MATCH
        if v == "wrap_content":
            return WRAP
        d = self.res.dimen_dp(v, self.cfg, pkg)
        return d if d is not None else default

    def _num(self, a, key, pkg, default=None):
        v = a.get(key)
        if v is None:
            return default
        d = self.res.dimen_dp(v, self.cfg, pkg)
        if d is None:
            try:
                return float(self.res.literal(v, self.cfg, pkg))
            except (TypeError, ValueError):
                return default
        return d

    def _box(self, a, pkg, prefix):
        all_ = self._num(a, f"android:{prefix}", pkg, None)
        l = t = r = b = all_ or 0.0
        l = self._num(a, f"android:{prefix}Left", pkg, l)
        t = self._num(a, f"android:{prefix}Top", pkg, t)
        r = self._num(a, f"android:{prefix}Right", pkg, r)
        b = self._num(a, f"android:{prefix}Bottom", pkg, b)
        l = self._num(a, f"android:{prefix}Start", pkg, l)
        r = self._num(a, f"android:{prefix}End", pkg, r)
        return (l, t, r, b), any(f"android:{prefix}{s}" in a for s in ("", "Left", "Top", "Right", "Bottom", "Start", "End"))

    def _image(self, ref, pkg):
        """A drawable attribute to (pack key, entry drawn by default) or (color, None)."""
        if ref is None:
            return None, None
        ref_pkg, kind, v = self.res.deref(ref, self.cfg, pkg)
        if kind is None and isinstance(v, str) and v.startswith("#"):
            return {"color": v}, None
        if kind not in ("drawable", "mipmap", "color"):
            return None, None
        if kind == "color":
            c = self.res.color(ref, self.cfg, pkg)
            return ({"color": android.color_hex(c["default"])} if c else None), None
        k = self.dr.ref_key(f"@{ref_pkg}:{kind}/{v}", ref_pkg)
        self.dr.drain()
        mode = "night" if self.cfg.night else "day"
        return k, self.dr.resolve(k, mode)

    def _intrinsic_dp(self, entry):
        if not entry:
            return None
        s = entry.get("scale", 1.0)
        w, h = entry["size"]
        return (w * s / self.density, h * s / self.density)

    def _node(self, e, pkg):
        a = self._attrs(e, pkg)
        sid = a.get("android:id")
        vid = parse_ref(sid)[2] if sid and parse_ref(sid) else None
        st = self.state
        if vid in st.get("background", {}):
            a["android:background"] = st["background"][vid]
        vis = a.get("android:visibility", "visible")
        if vid in st.get("visible", []):
            vis = "visible"
        if vid in st.get("hidden", []):
            vis = "gone"
        kind, approx = kind_of(e.tag, a, len(e) > 0)
        margin, _ = self._box(a, pkg, "layout_margin")
        padding, has_padding = self._box(a, pkg, "padding")
        bg_key, bg_entry = self._image(a.get("android:background"), pkg)
        src_key, src_entry = self._image(a.get("android:src"), pkg)
        if bg_entry and "nine_patch" in bg_entry and not has_padding:
            s = bg_entry.get("scale", 1.0) / self.density
            padding = tuple(m * s for m in bg_entry["nine_patch"]["content_margins"])
        min_w = self._num(a, "android:minWidth", pkg, 0.0)
        min_h = self._num(a, "android:minHeight", pkg, 0.0)
        bi = self._intrinsic_dp(bg_entry)
        if bi:
            min_w, min_h = max(min_w, bi[0]), max(min_h, bi[1])
        n = Node(
            cls=e.tag, kind=kind, id=vid,
            width=self._dim(a, "android:layout_width", pkg),
            height=self._dim(a, "android:layout_height", pkg),
            margin=margin, padding=padding,
            gravity=android.parse_gravity(a.get("android:gravity")),
            layout_gravity=android.parse_gravity(a.get("android:layout_gravity")),
            orientation=a.get("android:orientation", "horizontal"),
            baseline_aligned=a.get("android:baselineAligned") != "false",
            weight=float(a.get("android:layout_weight", 0) or 0),
            visibility=vis,
            min_size=(min_w, min_h),
            max_size=(self._num(a, "android:maxWidth", pkg), self._num(a, "android:maxHeight", pkg)),
        )
        for r in RULES:
            v = a.get("android:layout_" + r)
            if v is not None:
                ref = parse_ref(v)
                n.rules[r] = ref[2] if ref else v
        n.attrs.update(approx=approx, background=bg_key, src=src_key,
                       scale_type=a.get("android:scaleType"), alpha=a.get("android:alpha"))
        base = e.tag.rsplit(".", 1)[-1]
        if kind == "leaf" and (base in TEXTS or "android:text" in a):
            self._text(n, a, pkg, vid)
        elif kind == "leaf" and src_entry:
            iw, ih = self._intrinsic_dp(src_entry)
            n.content = lambda aw, ah, iw=iw, ih=ih: (iw, ih)
        if kind != "leaf":
            for c in e:
                n.children.extend(self._element(c, pkg))
        return n

    def _text(self, n, a, pkg, vid):
        s = self.state.get("text", {}).get(vid)
        sample = s is not None
        if s is None:
            s = self.res.string(a.get("android:text", ""), self.cfg, pkg) or ""
        size_dp = self._num(a, "android:textSize", pkg, 14.0)
        style = a.get("android:textStyle", "normal")
        color = self.res.color(a["android:textColor"], self.cfg, pkg) if "android:textColor" in a else None
        shadow = None
        if "android:shadowColor" in a:
            sc = self.res.color(a["android:shadowColor"], self.cfg, pkg)
            if sc:
                shadow = {"color": sc, "dx": float(a.get("android:shadowDx", 0)),
                          "dy": float(a.get("android:shadowDy", 0)),
                          "radius": float(a.get("android:shadowRadius", 0))}
        max_lines = a.get("android:maxLines") or a.get("android:lines")
        spec = {
            "string": s,
            "sample": sample,
            "source": a.get("android:text"),
            "size_px": size_dp * self.density,
            "weight": "bold" if "bold" in style else "regular",
            "single_line": a.get("android:singleLine") == "true",
            "max_lines": int(max_lines) if max_lines else None,
            "line_mult": float(self.res.literal(a.get("android:lineSpacingMultiplier", "1"), self.cfg, pkg) or 1),
            "line_extra_px": (self._num(a, "android:lineSpacingExtra", pkg, 0.0) or 0.0) * self.density,
            "gravity": sorted(n.gravity) or ["left", "top"],
            "include_font_padding": a.get("android:includeFontPadding") != "false",
            "color": color,
            "shadow": shadow,
            "ellipsize": a.get("android:ellipsize"),
        }
        n.attrs["text"] = spec
        d = self.density

        def content(aw, ah):
            _, w, h, _, _ = text.block(self.fonts, spec, d, aw * d if aw is not None else None)
            return (w / d, h / d)

        def baseline(node):
            pl, pt, pr, pb = node.padding
            _, w, h, asc, _ = text.block(self.fonts, spec, d, max(0, node.mw - pl - pr) * d)
            inner = node.mh - pt - pb
            g = n.gravity
            off = (inner - h / d) if "bottom" in g else (inner - h / d) / 2 if "center_vertical" in g else 0
            return pt + off + asc / d

        n.content = content
        n.baseline_fn = baseline


def build(res, cfg, drawables, fonts, spec, density):
    """Lays out one screen; returns (root node, notes)."""
    inf = Inflater(res, cfg, drawables, fonts, density, spec.get("state"))
    root = inf.inflate(spec["layout"])
    _, _, w, h = spec["window_dp"]
    layout.run(root, w, h)
    return root, inf.notes


def _color_modes(day, night):
    if not day and not night:
        return None
    out = {}
    for mode, c in (("day", day), ("night", night)):
        if c:
            out[mode] = android.color_hex(c["default"])
            if len(c["states"]) > 1:
                out.setdefault("states", {})[mode] = [
                    {"state": st, "color": android.color_hex(rgba)} for st, rgba in c["states"]]
    ref = (day or night).get("ref")
    if ref:
        out["ref"] = ref
    return out


def describe(day_root, night_root, spec, density):
    """The screen as data: views in draw order with panel-pixel rects (from the day layout;
    the stock values give both appearances the same geometry), colors for both appearances."""
    ox, oy, _, _ = spec["window_dp"]
    views = []
    pairs = zip(layout.walk(day_root, ox, oy), layout.walk(night_root, ox, oy))
    for (n, x, y, depth), (nn, nx, ny, _) in pairs:
        r = [round(x * density), round(y * density), round(n.mw * density), round(n.mh * density)]
        v = {"id": n.id or f"_{n.cls.rsplit('.', 1)[-1]}_{len(views)}", "type": n.cls.rsplit(".", 1)[-1],
             "depth": depth, "rect": r}
        rn = [round(nx * density), round(ny * density), round(nn.mw * density), round(nn.mh * density)]
        if rn != r:
            v["rect_night"] = rn
        if n.attrs.get("include"):
            v["include"] = n.attrs["include"]
        if n.visibility != "visible":
            v["visibility"] = n.visibility
        if n.attrs.get("approx"):
            v["approx_layout"] = True
        for k in ("background", "src"):
            val, nval = n.attrs.get(k), nn.attrs.get(k)
            if isinstance(val, dict) or isinstance(nval, dict):
                v[k] = {"color": {"day": (val or {}).get("color"), "night": (nval or {}).get("color")}}
            elif val:
                v[k] = val
        if n.attrs.get("scale_type"):
            v["scale_type"] = n.attrs["scale_type"]
        if n.padding != (0, 0, 0, 0):
            v["padding"] = [round(p * density) for p in n.padding]
        t, tn = n.attrs.get("text"), nn.attrs.get("text")
        if t:
            tv = {"string": t["string"], "font": t["weight"], "size_px": round(t["size_px"], 2),
                  "gravity": t["gravity"]}
            for k in ("sample", "single_line", "include_font_padding"):
                if t[k] != (k == "include_font_padding"):
                    tv[k] = t[k]
            for k in ("source", "max_lines", "ellipsize"):
                if t[k]:
                    tv[k] = t[k]
            if t["line_mult"] != 1:
                tv["line_mult"] = t["line_mult"]
            if t["line_extra_px"]:
                tv["line_extra_px"] = round(t["line_extra_px"], 2)
            col = _color_modes(t["color"], tn["color"] if tn else None)
            if col:
                tv["color"] = col
            if t["shadow"]:
                sh = {k: t["shadow"][k] for k in ("dx", "dy", "radius")}
                sh["color"] = _color_modes(t["shadow"]["color"], (tn or {}).get("shadow", {}) and tn["shadow"]["color"])
                tv["shadow"] = sh
            v["text"] = tv
        views.append(v)
    return views
