"""Gets the stock files out of the OTA (go-unbrick) and decodes their resources (apktool),
reusing whatever is already in the reference folder."""
import glob
import os
import shutil
import subprocess


def log(msg):
    print(f"import-vendor: {msg}", flush=True)


def find_tool(name, explicit=None, env=None):
    for cand in (explicit, os.environ.get(env) if env else None, shutil.which(name)):
        if cand and os.access(cand, os.X_OK):
            return cand
    return None


def apk_path(ref, sub, name):
    return os.path.join(ref, "apks", sub, name + ".apk")


def font_path(ref, name):
    for d in ("apks/fonts", "firmware-V015/fonts"):
        p = os.path.join(ref, d, name)
        if os.path.exists(p):
            return p
    return None


def _wanted(model, ref):
    """(path inside system, local destination) for every input not already present."""
    out = []
    for app, sub in model["apps"].items():
        out.append((f"{sub}/{app}.apk", apk_path(ref, sub, app)))
    for fw in model["framework"]:
        out.append((f"framework/{fw}.apk", apk_path(ref, "framework", fw)))
    for f in model["fonts"].values():
        out.append((f"fonts/{f}", font_path(ref, f) or os.path.join(ref, "apks", "fonts", f)))
    return [(src, dst) for src, dst in out if not os.path.exists(dst)]


def _secrets_subset(secrets, pattern, work):
    """A folder holding only this model's key and IV, so unbrick tries no other car's."""
    d = os.path.join(work, "secrets")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    found = glob.glob(os.path.join(secrets, pattern))
    if not found:
        raise SystemExit(f"no {pattern} in {secrets}")
    for f in found:
        os.symlink(os.path.abspath(f), os.path.join(d, os.path.basename(f)))
    return d


def extract(model, ref, ota, secrets, unbrick):
    missing = _wanted(model, ref)
    dex_dir = os.path.join(ref, "work", "dex")
    want_dex = not glob.glob(os.path.join(dex_dir, "**", "classes.txt"), recursive=True)
    if not missing and not want_dex:
        log("firmware: all inputs present, not extracting")
        return
    if not ota:
        if missing:
            raise SystemExit("missing inputs and no --ota: " + ", ".join(s for s, _ in missing))
        return
    if not unbrick:
        raise SystemExit("go-unbrick not found: put `unbrick` on PATH, set UNBRICK or pass --unbrick")
    work = os.path.join(ref, "work")
    os.makedirs(work, exist_ok=True)
    args = [unbrick, "extract", "-r", "-f"]
    if secrets:
        args += ["--secrets", _secrets_subset(secrets, model["secrets_glob"], work)]
    stage = os.path.join(work, "extract")
    sysdir = model["system"]
    if missing:
        alts = "|".join(src.replace(".", r"\.") for src, _ in missing)
        log(f"firmware: extracting {len(missing)} files from the OTA")
        _run(args + ["--depth", "3", "--match", f"^{sysdir}/({alts})$", "-o", stage, ota])
        for src, dst in missing:
            got = os.path.join(stage, sysdir, src)
            if not os.path.exists(got):
                raise SystemExit(f"unbrick did not produce {src}")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(got, dst)
        shutil.rmtree(stage, ignore_errors=True)
    if want_dex:
        # Only signatures and string constants: kept for finding where code picks resources.
        apps = "|".join(sorted({s["app"] for s in model["screens"].values()}))
        _run(args + ["--depth", "6", "--match", rf"^{sysdir}/(app|priv-app)/({apps})\.odex/.*\.dex/(classes|strings)\.txt$",
                     "-o", dex_dir, ota])


def _run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"{os.path.basename(args[0])} failed ({r.returncode}):\n{r.stderr[-2000:]}")
    return r.stdout


def decode(model, ref, apktool):
    """apktool, resources only, against the device's own framework (installed locally)."""
    dec = os.path.join(ref, "decoded")
    fwdir = os.path.join(dec, ".framework")
    os.makedirs(fwdir, exist_ok=True)
    if not apktool:
        raise SystemExit("apktool not found")
    if not os.path.exists(os.path.join(fwdir, "1.apk")):
        for fw in model["framework"]:
            _run([apktool, "if", "-p", fwdir, apk_path(ref, "framework", fw)])
    jobs = [(fw, apk_path(ref, "framework", fw)) for fw in model["framework"]]
    jobs += [(app, apk_path(ref, sub, app)) for app, sub in model["apps"].items()]
    for name, apk in jobs:
        out = os.path.join(dec, name)
        stamp = os.path.join(out, "apktool.yml")
        if os.path.exists(stamp) and os.path.getmtime(stamp) >= os.path.getmtime(apk):
            continue
        log(f"decode: {name}")
        _run([apktool, "d", "-s", "-f", "-p", fwdir, "-o", out, apk])
    return dec
