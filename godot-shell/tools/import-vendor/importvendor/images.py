"""Drawables to pack images: bitmaps per appearance, 9-patches stripped with their margins,
selectors as per-state maps, and the other XML drawables described."""
import os
import shutil
import xml.etree.ElementTree as ET

from PIL import Image

from . import android, ninepatch
from .resources import NS, attr_name, parse_ref

BITMAP_EXT = (".png", ".webp", ".jpg", ".jpeg", ".gif")


def key(pkg, name):
    return f"{pkg}/{name}"


class Drawables:
    """Resolves drawables across packages and exports them into `<pack>/images/`."""

    def __init__(self, packages, app_names, day, night, out_dir):
        self.packages = packages          # name -> resources.Package
        self.app_names = app_names
        self.cfg = {"day": day, "night": night}
        self.out = out_dir
        self.index = {}
        self._queue = []

    def _file(self, pkg, name, mode):
        p = self.packages.get(pkg)
        return android.select(p.files.get(("drawable", name), []), self.cfg[mode]) if p else None

    def ref_key(self, s, ctx):
        """`@drawable/x` in package ctx to a pack image key, queued for export."""
        r = parse_ref(s)
        if not r or r[1] not in ("drawable", "mipmap", "color"):
            return None
        pkg = r[0] or ctx
        k = key(pkg, r[2])
        if r[1] != "color" and k not in self.index and pkg in self.packages:
            self._queue.append((pkg, r[2]))
        return k if r[1] != "color" else None

    def export_all(self, pkg):
        for (kind, name) in sorted(self.packages[pkg].files):
            if kind == "drawable":
                self._queue.append((pkg, name))
        self.drain()

    def drain(self):
        while self._queue:
            pkg, name = self._queue.pop()
            if key(pkg, name) not in self.index:
                self.export(pkg, name)

    def export(self, pkg, name):
        k = key(pkg, name)
        entry = {}
        self.index[k] = entry
        seen = {}
        for mode in ("day", "night"):
            hit = self._file(pkg, name, mode)
            if not hit:
                continue
            q, path = hit
            if path in seen:
                continue
            seen[path] = mode
            if path.endswith(".xml"):
                entry[mode] = self._xml(pkg, path)
            elif path.lower().endswith(BITMAP_EXT):
                entry[mode] = self._bitmap(pkg, name, mode, q, path)
        if not entry:
            del self.index[k]
        return entry

    def _bitmap(self, pkg, name, mode, q, path):
        sub = os.path.join(pkg, "night") if mode == "night" else pkg
        os.makedirs(os.path.join(self.out, sub), exist_ok=True)
        scale = android.density_scale(q, self.cfg[mode])
        if path.endswith(".9.png"):
            rel = os.path.join(sub, name + ".png")
            dst = os.path.join(self.out, rel)
            with Image.open(path) as im:
                m, stripped = ninepatch.from_image(im)
                if not _fresh(path, dst):
                    stripped.save(dst)
            out = {"file": "images/" + rel, "size": m["size"], "nine_patch": {
                "texture_margins": m["texture"], "content_margins": m["content"]}}
            if m["multi_stretch"]:
                out["nine_patch"].update(stretch_x=m["stretch_x"], stretch_y=m["stretch_y"],
                                         multi_stretch=True)
        else:
            rel = os.path.join(sub, os.path.basename(path))
            dst = os.path.join(self.out, rel)
            if not _fresh(path, dst):
                shutil.copyfile(path, dst)
            with Image.open(path) as im:
                out = {"file": "images/" + rel, "size": list(im.size)}
        if scale != 1.0:
            out["scale"] = round(scale, 4)
        return out

    def _xml(self, pkg, path):
        root = ET.parse(path).getroot()
        tag = root.tag
        if tag == "selector":
            states = []
            for item in root:
                d = item.get(NS + "drawable")
                st = {attr_name(k)[len("android:state_"):]: v == "true"
                      for k, v in item.attrib.items() if attr_name(k).startswith("android:state_")}
                if d is not None:
                    k = self.ref_key(d, pkg)
                    states.append({"state": st, "image": k} if k else {"state": st, "value": d})
                else:
                    states.append({"state": st, "unsupported": "inline drawable"})
            return {"selector": states}
        if tag == "animation-list":
            frames = []
            for item in root:
                d = item.get(NS + "drawable")
                frames.append({"image": self.ref_key(d, pkg) if d else None,
                               "ms": self._int(pkg, item.get(NS + "duration"))})
            return {"animation": frames, "oneshot": root.get(NS + "oneshot") == "true"}
        if tag in ("bitmap", "nine-patch"):
            src = root.get(NS + "src")
            return {"alias": self.ref_key(src, pkg) if src else None,
                    "attrs": {attr_name(k): v for k, v in root.attrib.items()}}
        if tag == "color":
            return {"color": root.get(NS + "color")}
        if tag == "layer-list":
            layers = []
            for item in root:
                d = item.get(NS + "drawable")
                layers.append({"image": self.ref_key(d, pkg) if d else None,
                               "attrs": {attr_name(k): v for k, v in item.attrib.items() if k != NS + "drawable"}})
            return {"layers": layers}
        return {"unsupported": tag, "source": os.path.relpath(path, self.packages[pkg].root)}

    def _int(self, pkg, v):
        r = parse_ref(v) if v else None
        if r:
            p = self.packages.get(r[0] or pkg)
            hit = android.select(p.values.get(("integer", r[2]), []), self.cfg["day"]) if p else None
            v = hit[1] if hit else None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    def resolve(self, k, mode, state=None, depth=0):
        """A pack key to the bitmap entry drawn for `state` (default: no state set)."""
        e = self.index.get(k)
        if e is None or depth > 8:
            return None
        v = e.get(mode) or e.get("day") or e.get("night")
        if v is None:
            return None
        if "file" in v:
            return v
        if "selector" in v:
            st = state or {}
            for item in v["selector"]:
                if all(st.get(s, False) == want for s, want in item["state"].items()) and item.get("image"):
                    return self.resolve(item["image"], mode, state, depth + 1)
            return None
        if "alias" in v and v["alias"]:
            return self.resolve(v["alias"], mode, state, depth + 1)
        if "animation" in v and v["animation"] and v["animation"][0]["image"]:
            return self.resolve(v["animation"][0]["image"], mode, state, depth + 1)
        return None


def _fresh(src, dst):
    return os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)
