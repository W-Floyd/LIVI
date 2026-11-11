#!/usr/bin/env python3
"""Unpack Alpine packages and their dependencies into a directory, for cross-linking.

  alpine-sysroot.py [--arch armv7] [--branch edge] DEST PKG...

No apk-tools: reads the APKINDEX of main, community and testing, resolves `D:` through
`P:`/`p:` (so:, pc:, cmd:) and unpacks each apk (signatures are not checked; this is a
link-time sysroot, not an install). Rerun with more packages to extend DEST.
"""
import io, os, subprocess, sys, tarfile, urllib.request

args = sys.argv[1:]
arch, branch = "armv7", "edge"
while args and args[0].startswith("--"):
    k = args.pop(0)
    if k == "--arch": arch = args.pop(0)
    elif k == "--branch": branch = args.pop(0)
dest, want = args[0], args[1:]
mirror = os.environ.get("ALPINE_MIRROR", "https://dl-cdn.alpinelinux.org/alpine")
cache = os.environ.get("ALPINE_CACHE", os.path.join(dest, ".apk-cache"))
os.makedirs(cache, exist_ok=True)

pkgs, provides = {}, {}
for repo in ("main", "community", "testing"):
    idx = os.path.join(cache, f"APKINDEX-{branch}-{repo}-{arch}")
    if not os.path.exists(idx):
        raw = urllib.request.urlopen(f"{mirror}/{branch}/{repo}/{arch}/APKINDEX.tar.gz", timeout=60).read()
        with open(idx, "wb") as f:
            f.write(tarfile.open(fileobj=io.BytesIO(raw)).extractfile("APKINDEX").read())
    for blk in open(idx, encoding="utf-8").read().split("\n\n"):
        e = {}
        for line in blk.split("\n"):
            if len(line) > 2 and line[1] == ":":
                e.setdefault(line[0], line[2:])
        if "P" not in e: continue
        e["repo"] = repo
        pkgs.setdefault(e["P"], e)  # main before community before testing
        for p in [e["P"]] + e.get("p", "").split():
            provides.setdefault(p.split("=")[0], e["P"])

def resolve(dep):
    dep = dep.split("=")[0].split(">")[0].split("<")[0].split("~")[0]
    return provides.get(dep) or (dep if dep in pkgs else None)

seen, order, todo = set(), [], list(want)
while todo:
    n = todo.pop()
    if n in seen: continue
    seen.add(n)
    if n not in pkgs: sys.exit(f"no such package: {n}")
    order.append(n)
    for d in pkgs[n].get("D", "").split():
        if d.startswith("!"): continue
        r = resolve(d)
        if r: todo.append(r)

for n in sorted(order):
    e = pkgs[n]
    fn = f"{n}-{e['V']}.apk"
    path = os.path.join(cache, fn)
    if not os.path.exists(path):
        # curl: it times out a stalled connection and resumes; urllib hangs.
        subprocess.run(["curl", "-fsSL", "--retry", "5", "--speed-limit", "20000", "--speed-time", "20",
                        "-C", "-", "-o", path + ".part", f"{mirror}/{branch}/{e['repo']}/{arch}/{fn}"], check=True)
        os.rename(path + ".part", path)
    with tarfile.open(path) as t:
        members = [m for m in t.getmembers() if not m.name.startswith(".") and not m.isdev()]
        t.extractall(dest, members=members, filter="tar")
print(f"{len(order)} packages in {dest}")
