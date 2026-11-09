"""An apktool-decoded resource tree (`res/values*`, `res/<type>*/name.ext`), resolved the way
the device would: qualifiers, `@[pkg:]type/name` references, styles and their parents."""
import os
import re
import xml.etree.ElementTree as ET

from . import android

NS = "{http://schemas.android.com/apk/res/android}"
_REF = re.compile(r"^@(?:\+)?(?:\*)?(?:([\w.]+):)?(\w+)/([\w.]+)$")
_VALUE_TAGS = {"color", "dimen", "string", "integer", "bool", "fraction", "drawable"}


def parse_ref(s):
    """`@android:drawable/co_bg` to ("android", "drawable", "co_bg"); None if not a reference."""
    m = _REF.match(s.strip()) if isinstance(s, str) else None
    return (m.group(1), m.group(2), m.group(3)) if m else None


def attr_name(key):
    """An attribute key from ElementTree to `android:name` / `name` form."""
    if key.startswith(NS):
        return "android:" + key[len(NS):]
    if key.startswith("{"):
        return key.split("}", 1)[1]
    return key


class Package:
    def __init__(self, name, root):
        self.name = name
        self.root = root
        self.values = {}   # (type, name) -> [(qualifiers, value)]
        self.files = {}    # (type, name) -> [(qualifiers, path)]
        self._load()

    def _load(self):
        res = os.path.join(self.root, "res")
        for d in sorted(os.listdir(res)):
            kind, q = android.parse_qualifiers(d)
            if q is None:
                continue
            path = os.path.join(res, d)
            if kind == "values":
                for f in sorted(os.listdir(path)):
                    if f.endswith(".xml") and f != "public.xml":
                        self._load_values(os.path.join(path, f), q)
                continue
            for f in os.listdir(path):
                name = f.split(".", 1)[0]
                self.files.setdefault((kind, name), []).append((q, os.path.join(path, f)))

    def _load_values(self, path, q):
        for e in ET.parse(path).getroot():
            name = e.get("name")
            if not name:
                continue
            tag = e.tag
            if tag == "item":
                tag = e.get("type") or ""
            if tag == "style":
                items = {i.get("name"): (i.text or "").strip() for i in e if i.tag == "item"}
                parent = e.get("parent")
                if parent is None and "." in name:
                    parent = "@style/" + name.rsplit(".", 1)[0]
                v = {"parent": parent or None, "items": items}
            elif tag in _VALUE_TAGS or tag == "id":
                v = "".join(e.itertext()).strip() if tag == "string" else (e.text or "").strip()
            else:
                continue
            self.values.setdefault((tag, name), []).append((q, v))

    def names(self, kind):
        return sorted({n for (t, n) in self.values if t == kind} | {n for (t, n) in self.files if t == kind})


class Resources:
    """An app's resources over the framework's (`android`); every lookup takes a Config."""

    def __init__(self, app, framework=None, extra=()):
        self.app = app
        self.packages = {app.name: app}
        if framework:
            self.packages["android"] = framework
        for p in extra:
            self.packages.setdefault(p.name, p)

    def pkg(self, name, ctx):
        return self.packages.get(name or ctx or self.app.name)

    def value(self, kind, name, cfg, pkg=None):
        p = self.pkg(pkg, None)
        if p is None:
            return None
        hit = android.select(p.values.get((kind, name), []), cfg)
        return hit[1] if hit else None

    def file(self, kind, name, cfg, pkg=None):
        """(qualifiers, path) the device would load, or None."""
        p = self.pkg(pkg, None)
        return android.select(p.files.get((kind, name), []), cfg) if p else None

    def deref(self, s, cfg, ctx=None, kinds=None, depth=0):
        """Follows value references (`@color/a` -> `@color/b` -> `#fff`) down to a literal or a
        file-backed reference; returns (pkg, kind, name or literal)."""
        r = parse_ref(s) if isinstance(s, str) else None
        if r is None or depth > 20:
            return (ctx, None, s)
        pkg, kind, name = r
        pkg = pkg or ctx or self.app.name
        p = self.packages.get(pkg)
        if p is None:
            return (pkg, kind, name)
        if (kind, name) in p.values:
            v = self.value(kind, name, cfg, pkg)
            if isinstance(v, str) and v.startswith("@"):
                return self.deref(v, cfg, pkg, kinds, depth + 1)
            if v is not None:
                return (pkg, None, v)
        return (pkg, kind, name)

    def literal(self, s, cfg, ctx=None):
        _, kind, v = self.deref(s, cfg, ctx)
        return v if kind is None else None

    def dimen_dp(self, s, cfg, ctx=None):
        v = self.literal(s, cfg, ctx)
        try:
            return android.to_dp(v) if v is not None else None
        except ValueError:
            return None

    def string(self, s, cfg, ctx=None):
        v = self.literal(s, cfg, ctx) if isinstance(s, str) and s.startswith("@") else s
        if v is None:
            return None
        return _unescape(v)

    def color(self, s, cfg, ctx=None):
        """A color attribute to {"default": rgba, "states": [(state dict, rgba)]} or None."""
        pkg, kind, v = self.deref(s, cfg, ctx)
        if kind is None:
            try:
                rgba = android.parse_color(v)
            except (ValueError, AttributeError):
                return None
            return {"default": rgba, "states": [({}, rgba)], "ref": _refname(s, ctx)}
        if kind in ("color", "drawable"):
            hit = self.file(kind, v, cfg, pkg)
            if hit and hit[1].endswith(".xml"):
                root = ET.parse(hit[1]).getroot()
                if root.tag == "selector":
                    states = []
                    for item in root:
                        c = item.get(NS + "color")
                        if c is None:
                            continue
                        sub = self.color(c, cfg, pkg)
                        if sub:
                            states.append((_states(item), sub["default"]))
                    if states:
                        default = next((c for st, c in states if not st), states[-1][1])
                        return {"default": default, "states": states, "ref": f"{pkg}:{kind}/{v}"}
        return None

    def style(self, s, cfg, ctx=None, depth=0):
        """A style's items with its parents' merged beneath, as {attr: value}."""
        r = parse_ref(s)
        if r is None or depth > 20:
            return {}
        pkg = r[0] or ctx or self.app.name
        v = self.value("style", r[2], cfg, pkg)
        if not isinstance(v, dict):
            return {}
        out = self.style(v["parent"], cfg, pkg, depth + 1) if v["parent"] else {}
        out.update(v["items"])
        return out


def _states(item):
    out = {}
    for k, v in item.attrib.items():
        k = attr_name(k)
        if k.startswith("android:state_"):
            out[k[len("android:state_"):]] = v == "true"
    return out


def _refname(s, ctx):
    r = parse_ref(s) if isinstance(s, str) else None
    return f"{r[0] or ctx or ''}:{r[1]}/{r[2]}".lstrip(":") if r else None


def _unescape(s):
    s = s.replace('\\"', '"').replace("\\'", "'").replace("\\n", "\n")
    if len(s) >= 2 and s[0] == s[-1] == '"':
        s = s[1:-1]
    return s
