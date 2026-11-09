"""import-vendor: stock firmware to a vendor theme pack."""
import argparse
import os
import re
import shutil
import time
from collections import Counter

from . import android, firmware, render, screens, text, tokens, yamlout
from .images import Drawables
from .models import MODELS
from .resources import Package, Resources

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL = os.path.dirname(os.path.dirname(HERE))
NOTICE = """This pack holds the vendor's fonts, images and layouts, extracted from the owner's own
firmware by tools/import-vendor. They are the vendor's copyright: keep the pack local and do not
redistribute it."""


def _rules():
    out = {}
    with open(os.path.join(SHELL, "project", "rules.yaml")) as f:
        for line in f:
            m = re.match(r"^(\w+):\s*([0-9.]+)", line)
            if m:
                out[m.group(1)] = float(m.group(2))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="import-vendor", description=__doc__)
    ap.add_argument("--model", default="ev6", choices=sorted(MODELS))
    ap.add_argument("--ota", help="the stock OTA package (tar); needed only for inputs not already extracted")
    ap.add_argument("--secrets", help="folder of firmware keys; only the model's are used")
    ap.add_argument("--ref", help="reference folder for extracted and decoded files (default: the model's under godot-shell/ref)")
    ap.add_argument("-o", "--out", help="pack folder (default: <ref>/pack)")
    ap.add_argument("--unbrick", help="go-unbrick binary (default: UNBRICK, then PATH)")
    ap.add_argument("--apktool", help="apktool (default: PATH)")
    ap.add_argument("--clean", action="store_true", help="empty the pack folder first")
    args = ap.parse_args(argv)

    model = MODELS[args.model]
    ref = os.path.abspath(args.ref or os.path.join(SHELL, model["ref"]))
    pack = os.path.abspath(args.out or os.path.join(ref, "pack"))
    t0 = time.time()
    if args.clean:
        shutil.rmtree(pack, ignore_errors=True)
    for d in ("fonts", "images", "screens", "reference"):
        os.makedirs(os.path.join(pack, d), exist_ok=True)

    firmware.extract(model, ref, args.ota, args.secrets, firmware.find_tool("unbrick", args.unbrick, "UNBRICK"))
    dec = firmware.decode(model, ref, firmware.find_tool("apktool", args.apktool))
    t_dec = time.time()

    packages = {app: Package(app, os.path.join(dec, app)) for app in model["apps"]}
    fw = Package("android", os.path.join(dec, "framework-res"))
    extra = [Package(f, os.path.join(dec, f)) for f in model["framework"] if f != "framework-res"]
    allpk = dict(packages, android=fw, **{p.name: p for p in extra})
    day, night = android.Config(night=False), android.Config(night=True)
    density = model["density"]
    firmware.log(f"resources loaded ({time.time() - t_dec:.1f}s)")

    fonts = {}
    for role, f in model["fonts"].items():
        src = firmware.font_path(ref, f)
        if not src:
            raise SystemExit(f"font {f} missing")
        shutil.copyfile(src, os.path.join(pack, "fonts", f))
        fonts[role] = os.path.join(pack, "fonts", f)
    tf = text.Fonts(fonts["regular"], fonts["bold"])

    dr = Drawables(allpk, list(packages), day, night, os.path.join(pack, "images"))
    for app in model["image_apps"]:
        dr.export_all(app)
        _queue_framework_refs(dr, packages[app])
    dr.drain()
    t_img = time.time()
    firmware.log(f"images: {len(dr.index)} ({t_img - t_dec:.1f}s)")

    screen_files, refs = {}, {}
    rnd = render.Renderer(pack, dr, tf, model["panel"], density)
    for sname, spec in model["screens"].items():
        res = Resources(packages[spec["app"]], fw, extra)
        droot, notes = screens.build(res, day, dr, tf, spec, density)
        nroot, _ = screens.build(res, night, dr, tf, spec, density)
        views = screens.describe(droot, nroot, spec, density)
        doc = {"screen": sname, "app": spec["app"], "layout": spec["layout"],
               "panel": model["panel"], "density": density,
               "window": [round(v * density) for v in spec["window_dp"]],
               "status_bar": spec.get("status_bar"),
               "state": spec.get("state", {}),
               "notes": sorted(set(notes)), "views": views}
        path = os.path.join(pack, "screens", f"{sname}.yaml")
        yamlout.write(path, doc, header=f"{sname}: the stock {spec['layout']} resolved to panel pixels "
                      "(x, y, w, h).\nThe state block is a hand-picked representative state: the stock "
                      "app sets it from code.")
        screen_files[sname] = f"screens/{sname}.yaml"
        refs[sname] = {}
        for mode in ("day", "night"):
            out = os.path.join(pack, "reference", f"{sname}_{mode}.png")
            rnd.screen(views, spec, mode).save(out)
            refs[sname][mode] = f"reference/{sname}_{mode}.png"
        firmware.log(f"screen {sname}: {len(views)} views")
    dr.drain()
    t_scr = time.time()

    theme, token_map = _tokens(model, packages, allpk, fw, extra, day, night, dr, pack, tf)
    theme.update(images="images/index.yaml", screens=screen_files, references=refs)
    yamlout.write(os.path.join(pack, "images", "index.yaml"), dr.index,
                  header="Pack images by <package>/<name>: per appearance (day, night when it differs) a "
                         "file, its size, its density scale\nwhen not 1, and 9-patch margins in the "
                         "stripped image's pixels ([left, top, right, bottom]).\nSelectors map states to "
                         "images, first match wins (Android's order).")
    yamlout.write(os.path.join(pack, "theme.yaml"), theme,
                  header="Vendor theme pack: generated by tools/import-vendor. Not for redistribution.")
    yamlout.write(os.path.join(pack, "token-map.yaml"), token_map,
                  header="NEEDS HUMAN REVIEW. Semantic slots guessed from the stock resources: each slot's "
                         "pick, the rule that made it,\nand ranked candidates (uses = references in the "
                         "stock XML). A re-run overwrites this file and theme.yaml:\nkeep reviewed choices elsewhere.")
    with open(os.path.join(pack, "NOTICE"), "w") as f:
        f.write(NOTICE + "\n")
    firmware.log(f"done in {time.time() - t0:.1f}s (decode {t_dec - t0:.1f}s, images {t_img - t_dec:.1f}s, "
                 f"screens {t_scr - t_img:.1f}s, tokens {time.time() - t_scr:.1f}s): {pack}")


def _queue_framework_refs(dr, pkg):
    pat = re.compile(r"@android:drawable/([\w.]+)")
    for kind, path in tokens._xml_files(pkg.root):
        with open(path, encoding="utf-8", errors="replace") as f:
            for m in pat.finditer(f.read()):
                dr.ref_key(m.group(0), pkg.name)


def _tokens(model, packages, allpk, fw, extra, day, night, dr, pack, tf):
    res_by_pkg = {name: Resources(p, fw, extra) for name, p in allpk.items()}
    table = tokens.color_table(res_by_pkg, day, night)
    scan = {n: p for n, p in allpk.items() if n != "android"}
    uses, dim_uses, style_uses = tokens.usage(scan)
    # Framework colors count only when the stock apps use them.
    table = {k: v for k, v in table.items() if not k.startswith("android:") or uses.get(k)}

    density = model["density"]
    rules = _rules()
    ppmm = tokens.px_per_mm(*model["panel"], 12.3)
    min_font = tokens.min_font_px(rules, ppmm)
    text_styles = []
    for (pkg, size, style, color), n in style_uses.most_common():
        res = res_by_pkg[pkg]
        dp = res.dimen_dp(size, day, pkg)
        if dp is None:
            continue
        cd = res.color(color, day, pkg) if color else None
        cn = res.color(color, night, pkg) if color else None
        text_styles.append({"app": pkg, "size_px": round(dp * density, 2), "font": "bold" if "bold" in style else "regular",
                            "color": {"ref": color, "day": android.color_hex(cd["default"]) if cd else None,
                                      "night": android.color_hex(cn["default"]) if cn else None},
                            "uses": n})
    merged = {}
    for s in text_styles:
        k = (s["size_px"], s["font"], s["color"]["day"], s["color"]["night"])
        if k in merged:
            merged[k]["uses"] += s["uses"]
        else:
            merged[k] = dict(s)
    text_styles = sorted(merged.values(), key=lambda s: -s["uses"])
    text_colors = tokens.text_colors(text_styles)
    text_styles = text_styles[:60]
    for s in text_styles:
        s["name"] = f"t{s['size_px']:g}_{s['font']}" + (f"_{s['color']['ref'].split('/')[-1]}" if s["color"]["ref"] else "")

    slots, chosen = {}, {"day": {}, "night": {}}
    for slot, (rule_text, rule) in tokens.SLOTS.items():
        cands = tokens.rank_slot(rule, table, uses)
        pick = next((c for c in cands if c["uses"]), cands[0] if cands else None)
        slots[slot] = {"chosen": pick, "rule": rule_text, "candidates": cands[:8]}
        if pick:
            chosen["day"][slot], chosen["night"][slot] = pick["day"], pick["night"]
    for slot, (rule_text, cands) in tokens.text_slots(text_colors).items():
        pick = cands[0] if cands else None
        slots[slot] = {"chosen": pick, "rule": rule_text, "candidates": cands[:8]}
        if pick:
            chosen["day"][slot], chosen["night"][slot] = pick["day"], pick["night"]
    samples = model.get("token_samples", {
        "bg": "android/co_bg", "proj": "android/co_bg",
        "surface": "HKMC_TAppEV3/ev_btn_main_nor", "surface2": "HKMC_TAppEV3/ev_btn_bottom_bg_nor"})
    for slot, key in samples.items():
        got = {}
        for mode in ("day", "night"):
            e = dr.resolve(key, mode)
            if e:
                got[mode] = android.color_hex(tokens.sample_image(os.path.join(pack, e["file"])))
                chosen[mode][slot] = got[mode]
        slots[slot] = {"chosen": {"image": key, **got}, "rule": "mean of the image's centre"}
    for mode in ("day", "night"):
        acc = chosen[mode].get("accent", "#888888")
        rgba = android.parse_color(acc)
        on = "#000000" if android.contrast(rgba, (0, 0, 0, 255)) >= android.contrast(rgba, (255, 255, 255, 255)) else "#ffffff"
        chosen[mode]["on_accent"] = on
    slots["on_accent"] = {"chosen": {"day": chosen["day"]["on_accent"], "night": chosen["night"]["on_accent"]},
                          "rule": "black or white, whichever contrasts more with accent"}
    for mode in ("day", "night"):
        for slot in ("bg", "surface", "surface2", "line", "text", "dim", "accent", "on_accent", "ok", "warn", "crit", "proj"):
            chosen[mode].setdefault(slot, "#808080")
    ser = tokens.series(table, uses)

    literal_dp = Counter()
    for k, n in dim_uses.items():
        if k.endswith("dp"):
            literal_dp[float(k[:-2])] += n
    gaps = [(dp, n) for dp, n in literal_dp.most_common() if 6 <= dp <= 24]
    gap_dp = gaps[0][0] if gaps else 8.0
    big = max((s["size_px"] for s in text_styles if s["uses"] >= 2), default=min_font * 2)
    theme = {
        "name": model["name"],
        "about": model["about"],
        "vendor": {"model": [k for k, v in MODELS.items() if v is model][0], "density": density,
                   "token_review": "token-map.yaml", "notice": "NOTICE"},
        "fonts": {"display": {"file": model["fonts"]["bold"]},
                  "body": {"file": model["fonts"]["regular"], "weight": 400},
                  "strong": {"file": model["fonts"]["bold"], "weight": 700}},
        "shape": {"radius_mm": 1, "gap_mm": round(gap_dp * density / ppmm, 2), "cards": "flat",
                  "display_ratio": round(big / min_font, 2)},
        "colors": {"night": chosen["night"], "day": chosen["day"]},
        "series": {"night": [c["night"] for c in ser], "day": [c["day"] for c in ser]},
        "text_styles": text_styles,
        "dimensions": {
            "common_dp": [{"dp": dp, "px": round(dp * density, 2), "uses": n} for dp, n in literal_dp.most_common(30)],
            "named": {k: {"px": round(res_by_pkg[k.split(":")[0]].dimen_dp(f"@dimen/{k.split(':')[1]}", day, k.split(":")[0]) * density, 2),
                          "uses": n}
                      for k, n in dim_uses.most_common(60) if ":" in k and k.split(":")[0] in res_by_pkg
                      and res_by_pkg[k.split(":")[0]].dimen_dp(f"@dimen/{k.split(':')[1]}", day, k.split(":")[0]) is not None},
        },
    }
    token_map = {
        "review": "required",
        "colors_ranked": [{"ref": k, "day": android.color_hex(v["day"]), "night": android.color_hex(v["night"]),
                           "uses": uses.get(k, 0)} for k, v in sorted(table.items(), key=lambda kv: -uses.get(kv[0], 0))][:60],
        "slots": slots,
        "series": ser,
        "derived": {"gap_mm": f"most used literal margin between 6 and 24 dp: {gap_dp:g} dp",
                    "display_ratio": f"largest text used twice or more ({big:g} px) over the rule table's minimum ({min_font:.1f} px)",
                    "radius_mm": "not derived: the stock UI's corners are in its 9-patch images"},
    }
    return theme, token_map


if __name__ == "__main__":
    main()
