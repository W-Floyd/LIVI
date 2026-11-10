#!/usr/bin/env python3
"""A binary STL of a car to the shell's `car.mesh`: decimated, in metres, centred, on the ground.

    python3 convert.py car.stl car.mesh [--length 4.7] [--tris 24000] [--front -y] [--up z]

Needs numpy and fast-simplification. Output axes are the shell's: length along x (front at +x),
up y, width z. `--front` and `--up` name the STL's axes (default: front +y, up +z).
File: "LCAR", u32 vertex count, u32 index count, vertices as 3 x f32, indices as u32.
The model is somebody's work: keep the output out of git (see README, "A car model").
"""
import argparse
import struct
import sys

import fast_simplification
import numpy as np


def read_stl(path):
    d = open(path, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    if 84 + 50 * n != len(d):
        sys.exit("binary STL only")
    rec = np.frombuffer(d, dtype=np.dtype([("n", "<3f4"), ("v", "<9f4"), ("a", "<u2")]), count=n, offset=84)
    v = rec["v"].reshape(-1, 3).astype(np.float64)
    uniq, inv = np.unique(np.round(v, 5), axis=0, return_inverse=True)
    return uniq, inv.reshape(-1, 3)


def axis(spec):
    sign = -1.0 if spec.startswith("-") else 1.0
    return "xyz".index(spec.lstrip("+-")), sign


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stl")
    ap.add_argument("out")
    ap.add_argument("--length", type=float, default=4.7, help="metres")
    ap.add_argument("--tris", type=int, default=24000)
    ap.add_argument("--front", default="+y")
    ap.add_argument("--up", default="+z")
    a = ap.parse_args()

    v, f = read_stl(a.stl)
    fi, fs = axis(a.front)
    ui, us = axis(a.up)
    wi = ({0, 1, 2} - {fi, ui}).pop()
    # right-handed: x = front, y = up, z = right of the car, so z = x cross y.
    ws = fs * us * (1.0 if (fi, ui, wi) in [(0, 1, 2), (1, 2, 0), (2, 0, 1)] else -1.0)
    w = np.stack([v[:, fi] * fs, v[:, ui] * us, v[:, wi] * ws], axis=1)
    ratio = 1.0 - a.tris / len(f)
    if ratio > 0:
        w, f = fast_simplification.simplify(w.astype(np.float32), f.astype(np.int32), target_reduction=ratio, agg=10)
    w = w.astype(np.float64)
    lo, hi = w.min(0), w.max(0)
    s = a.length / (hi[0] - lo[0])
    w = (w - np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2])) * s
    with open(a.out, "wb") as o:
        o.write(b"LCAR" + struct.pack("<II", len(w), f.size))
        o.write(w.astype("<f4").tobytes())
        o.write(f.astype("<u4").tobytes())
    print(f"{len(f)} triangles, {len(w)} vertices, size {(w.max(0) - w.min(0)).round(3)} m")


main()
