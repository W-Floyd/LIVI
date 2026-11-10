#!/usr/bin/env python3
"""A binary STL of a car to the shell's `car.mesh`: decimated, in metres, centred, on the ground.

    python3 convert.py car.stl car.mesh [--length 4.7] [--tris 24000] [--front=-y] [--wheels] [--up z]

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


def remesh(w, f, voxel, close, sigma):
    """The outer surface as a clean closed mesh: voxelise the soup, close its gaps, fill it, and
    march a smoothed volume. Drops the interior and the thin detail a decimator shreds."""
    from scipy import ndimage
    from skimage import measure

    tri = w[f]
    n = np.ceil(np.linalg.norm(tri - np.roll(tri, 1, axis=1), axis=2).max(axis=1) / voxel).astype(int).clip(1, 64)
    pts = [w]
    for k in np.unique(n):
        t = tri[n == k]
        g = np.arange(k + 1) / k
        for i in range(k + 1):
            for j in range(k + 1 - i):
                b = np.array([g[i], g[j], 1 - g[i] - g[j]])
                pts.append((t * b[None, :, None]).sum(axis=1))
    p = np.concatenate(pts)
    lo = p.min(0) - voxel * (close + 4)
    idx = np.floor((p - lo) / voxel).astype(int)
    vol = np.zeros(idx.max(0) + close + 5, bool)
    vol[idx[:, 0], idx[:, 1], idx[:, 2]] = True
    # A car is a solid between its underbody and its top: fill each column from its lowest
    # sample to its highest, so a leaky or hollow model still gives one clean skin.
    lo_y = np.full(vol.shape[::2], vol.shape[1], int)
    hi_y = np.full(vol.shape[::2], -1, int)
    np.minimum.at(lo_y, (idx[:, 0], idx[:, 2]), idx[:, 1])
    np.maximum.at(hi_y, (idx[:, 0], idx[:, 2]), idx[:, 1])
    yy = np.arange(vol.shape[1])[None, :, None]
    vol = (yy >= lo_y[:, None, :]) & (yy <= hi_y[:, None, :])
    sm = ndimage.gaussian_filter(vol.astype(np.float32), sigma)
    v, ff, _, _ = measure.marching_cubes(sm, 0.5, spacing=(voxel,) * 3)
    return v + lo + voxel * 0.5, ff


def feature_edges(w, f, skin, angle, keep):
    """The model's crease and panel-gap lines that lie on its outer skin, longest `keep` of them,
    as segments (n, 2, 3). The skin is dense points of the remeshed surface."""
    from scipy.spatial import cKDTree

    tri = w[f]
    nrm = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    ln = np.linalg.norm(nrm, axis=1)
    ok = ln > 1e-12
    nrm[ok] /= ln[ok, None]
    e = np.concatenate([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]])
    face = np.tile(np.arange(len(f)), 3)
    key = np.sort(e, axis=1)
    order = np.lexsort((key[:, 1], key[:, 0]))
    key, face, e = key[order], face[order], e[order]
    same = (key[1:] == key[:-1]).all(axis=1)
    first = np.flatnonzero(same)
    pair = np.zeros(len(key), bool)
    pair[first] = pair[first + 1] = True
    sharp = np.zeros(len(key), bool)
    cos = (nrm[face[first]] * nrm[face[first + 1]]).sum(axis=1)
    sharp[first] = cos < np.cos(np.radians(angle))
    # An edge with one face is a boundary: a panel gap or an open seam.
    pick = sharp | ~pair
    seg = w[e[pick]]
    mid = seg.mean(axis=1)
    d, _ = cKDTree(skin).query(mid)
    seg = seg[d < 0.04]
    length = np.linalg.norm(seg[:, 1] - seg[:, 0], axis=1)
    seg = seg[length > 0.012]
    length = length[length > 0.012]
    return seg[np.argsort(-length)[:keep]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stl")
    ap.add_argument("out")
    ap.add_argument("--length", type=float, default=4.7, help="metres")
    ap.add_argument("--tris", type=int, default=24000)
    ap.add_argument("--agg", type=int, default=3, help="simplifier aggressiveness 1-10; low keeps thin parts")
    ap.add_argument("--wheels", action="store_true", help="cut the model's wheels out (the shell draws its own)")
    ap.add_argument("--wheel-x", type=float, default=1.4)
    ap.add_argument("--wheel-r", type=float, default=0.42)
    ap.add_argument("--wheel-z", type=float, default=0.74)
    ap.add_argument("--remesh", type=float, default=0.0, help="voxel size in metres: rebuild the outer surface (try 0.02)")
    ap.add_argument("--close", type=int, default=3, help="--remesh: voxels of gap to close")
    ap.add_argument("--smooth", type=float, default=1.5, help="--remesh: blur of the volume, in voxels")
    ap.add_argument("--edges", type=int, default=0, help="also keep the N longest crease lines on the outer skin")
    ap.add_argument("--edge-angle", type=float, default=30.0, help="--edges: degrees between faces that make a crease")
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
    lo, hi = w.min(0), w.max(0)
    w = (w - np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2])) * (a.length / (hi[0] - lo[0]))
    if a.wheels:
        # Wheels do not survive decimation (thin, curved, many facets): cut them out where the
        # shell draws its own, as cylinders on x = +-wheel_x, radius wheel_r.
        c = w[f].mean(axis=1)
        inside = np.zeros(len(f), bool)
        for sx in (-1, 1):
            d = np.hypot(c[:, 0] - sx * a.wheel_x, c[:, 1] - a.wheel_r)
            inside |= (d < a.wheel_r * 1.08) & (np.abs(c[:, 2]) > a.wheel_z - 0.2)
        f = f[~inside]
        used, inv = np.unique(f, return_inverse=True)
        w, f = w[used], inv.reshape(-1, 3)
    src_w, src_f = w, f
    if a.remesh:
        w, f = remesh(w, f, a.remesh, a.close, a.smooth)
    skin = w
    ratio = 1.0 - a.tris / len(f)
    if ratio > 0:
        w, f = fast_simplification.simplify(w.astype(np.float32), f.astype(np.int32), target_reduction=ratio, agg=a.agg)
    with open(a.out, "wb") as o:
        o.write(b"LCAR" + struct.pack("<II", len(w), f.size))
        o.write(w.astype("<f4").tobytes())
        o.write(f.astype("<u4").tobytes())
        if a.edges:
            seg = feature_edges(src_w, src_f, skin, a.edge_angle, a.edges)
            o.write(b"LINE" + struct.pack("<I", len(seg)))
            o.write(seg.astype("<f4").tobytes())
            print(f"{len(seg)} edge segments")
    print(f"{len(f)} triangles, {len(w)} vertices, size {(w.max(0) - w.min(0)).round(3)} m")


main()
