"""Android's measure and layout passes for FrameLayout, LinearLayout and RelativeLayout, in dp.

Nodes are built elsewhere from layout XML; this module only knows sizes, margins, gravity and
rules, so it can be tested on synthetic trees.
"""
from dataclasses import dataclass, field

EXACTLY, AT_MOST, UNSPECIFIED = "exactly", "at_most", "unspecified"
MATCH, WRAP = "match", "wrap"


@dataclass(eq=False)
class Node:
    cls: str = "View"
    kind: str = "leaf"                 # leaf | frame | linear | relative
    id: str | None = None
    width: object = WRAP               # MATCH, WRAP or dp
    height: object = WRAP
    margin: tuple = (0, 0, 0, 0)       # left, top, right, bottom
    padding: tuple = (0, 0, 0, 0)
    gravity: frozenset = frozenset()
    layout_gravity: frozenset = frozenset()
    orientation: str = "horizontal"
    baseline_aligned: bool = True
    weight: float = 0.0
    rules: dict = field(default_factory=dict)
    visibility: str = "visible"
    min_size: tuple = (0, 0)
    max_size: tuple = (None, None)
    # (avail_w or None, avail_h or None) -> content (w, h), padding excluded.
    content: object = None
    # node -> baseline offset from the node's top, after measure; None for no baseline.
    baseline_fn: object = None
    children: list = field(default_factory=list)
    attrs: dict = field(default_factory=dict)
    mw: float = 0
    mh: float = 0
    x: float = 0
    y: float = 0

    def baseline(self):
        return self.baseline_fn(self) if self.baseline_fn else None


def resolve_size(desired, spec):
    mode, size = spec
    if mode == EXACTLY:
        return size
    if mode == AT_MOST:
        return min(desired, size)
    return desired


def child_spec(spec, used, dim):
    """Android's ViewGroup.getChildMeasureSpec."""
    mode, size = spec
    size = max(0, size - used)
    if dim not in (MATCH, WRAP):
        return (EXACTLY, max(0.0, float(dim)))
    if dim == MATCH:
        return {EXACTLY: (EXACTLY, size), AT_MOST: (AT_MOST, size)}.get(mode, (UNSPECIFIED, 0))
    return (AT_MOST, size) if mode in (EXACTLY, AT_MOST) else (UNSPECIFIED, 0)


def _visible(n):
    return [c for c in n.children if c.visibility != "gone"]


def _clamp(v, lo, hi):
    v = max(v, lo or 0)
    return min(v, hi) if hi is not None else v


def measure(n, ws, hs):
    {"leaf": _measure_leaf, "frame": _measure_frame, "linear": _measure_linear,
     "relative": _measure_relative}[n.kind](n, ws, hs)


def _measure_leaf(n, ws, hs):
    pl, pt, pr, pb = n.padding
    cw = ch = 0
    if n.content:
        aw = ws[1] - pl - pr if ws[0] != UNSPECIFIED else None
        ah = hs[1] - pt - pb if hs[0] != UNSPECIFIED else None
        if aw is not None and n.max_size[0] is not None:
            aw = min(aw, n.max_size[0] - pl - pr)
        cw, ch = n.content(aw, ah)
    n.mw = resolve_size(_clamp(cw + pl + pr, n.min_size[0], n.max_size[0]), ws)
    n.mh = resolve_size(_clamp(ch + pt + pb, n.min_size[1], n.max_size[1]), hs)


def _measure_frame(n, ws, hs):
    pl, pt, pr, pb = n.padding
    mw = mh = 0
    for c in _visible(n):
        ml, mt, mr, mb = c.margin
        measure(c, child_spec(ws, pl + pr + ml + mr, c.width), child_spec(hs, pt + pb + mt + mb, c.height))
        mw, mh = max(mw, c.mw + ml + mr), max(mh, c.mh + mt + mb)
    n.mw = resolve_size(_clamp(mw + pl + pr, n.min_size[0], n.max_size[0]), ws)
    n.mh = resolve_size(_clamp(mh + pt + pb, n.min_size[1], n.max_size[1]), hs)
    # A frame that wasn't exact re-measures match_parent children against its final size.
    for c in _visible(n):
        ml, mt, mr, mb = c.margin
        if (c.width == MATCH and ws[0] != EXACTLY) or (c.height == MATCH and hs[0] != EXACTLY):
            cws = (EXACTLY, max(0, n.mw - pl - pr - ml - mr)) if c.width == MATCH else \
                child_spec((EXACTLY, n.mw), pl + pr + ml + mr, c.width)
            chs = (EXACTLY, max(0, n.mh - pt - pb - mt - mb)) if c.height == MATCH else \
                child_spec((EXACTLY, n.mh), pt + pb + mt + mb, c.height)
            measure(c, cws, chs)


def _measure_linear(n, ws, hs):
    vertical = n.orientation == "vertical"
    pl, pt, pr, pb = n.padding
    main_spec, cross_spec = (hs, ws) if vertical else (ws, hs)
    main_pad = pt + pb if vertical else pl + pr
    cross_pad = pl + pr if vertical else pt + pb
    total, cross, weight = 0.0, 0.0, 0.0
    kids = _visible(n)
    deferred = set()
    for c in kids:
        ml, mt, mr, mb = c.margin
        cm = (mt + mb) if vertical else (ml + mr)
        cc = (ml + mr) if vertical else (mt + mb)
        main_dim = c.height if vertical else c.width
        cross_dim = c.width if vertical else c.height
        weight += c.weight
        if c.weight > 0 and main_spec[0] == EXACTLY and main_dim == 0:
            deferred.add(c)
            total += cm
            continue
        # Android passes the length used so far only while no child has had weight.
        mspec = child_spec(main_spec, main_pad + cm + (total if weight == 0 else 0), main_dim)
        xspec = child_spec(cross_spec, cross_pad + cc, cross_dim)
        measure(c, *((xspec, mspec) if vertical else (mspec, xspec)))
        total += (c.mh if vertical else c.mw) + cm
        cross = max(cross, (c.mw if vertical else c.mh) + cc)
    main_size = resolve_size(_clamp(total + main_pad, n.min_size[1 if vertical else 0], None), main_spec)
    if weight > 0:
        spare = main_size - main_pad - total
        for c in kids:
            if c.weight <= 0:
                continue
            ml, mt, mr, mb = c.margin
            cc = (ml + mr) if vertical else (mt + mb)
            base = 0 if c in deferred else (c.mh if vertical else c.mw)
            share = max(0.0, base + spare * c.weight / weight)
            spare -= share - base
            weight -= c.weight
            mspec = (EXACTLY, share)
            xspec = child_spec(cross_spec, cross_pad + cc, c.width if vertical else c.height)
            measure(c, *((xspec, mspec) if vertical else (mspec, xspec)))
            cross = max(cross, (c.mw if vertical else c.mh) + cc)
        total = sum((c.mh + c.margin[1] + c.margin[3]) if vertical else (c.mw + c.margin[0] + c.margin[2])
                    for c in kids)
    n._ascent = None
    if not vertical and n.baseline_aligned:
        asc = desc = None
        for c in kids:
            b = _top_baseline(c, n)
            if b is not None:
                asc, desc = max(asc or 0, b), max(desc or 0, c.mh - b)
        if asc is not None:
            n._ascent = asc
            cross = max(cross, asc + desc)
    cross_size = resolve_size(_clamp(cross + cross_pad, n.min_size[0 if vertical else 1], None), cross_spec)
    n.mw, n.mh = (cross_size, main_size) if vertical else (main_size, cross_size)
    n._total = total
    # match_parent children in a cross axis that wasn't exact get the final size (forceUniform).
    if cross_spec[0] != EXACTLY:
        for c in kids:
            if (c.width if vertical else c.height) == MATCH:
                ml, mt, mr, mb = c.margin
                cc = (ml + mr) if vertical else (mt + mb)
                xspec = (EXACTLY, max(0, cross_size - cross_pad - cc))
                mspec = (EXACTLY, c.mh if vertical else c.mw)
                measure(c, *((xspec, mspec) if vertical else (mspec, xspec)))


_H_RULES = ("toRightOf", "toEndOf", "toLeftOf", "toStartOf", "alignLeft", "alignStart",
            "alignRight", "alignEnd")
_V_RULES = ("below", "above", "alignTop", "alignBottom", "alignBaseline")


def _true(v):
    return v is True or v == "true"


def _measure_relative(n, ws, hs):
    pl, pt, pr, pb = n.padding
    kids = _visible(n)
    by_id = {c.id: c for c in kids if c.id}
    W = ws[1] if ws[0] != UNSPECIFIED else None
    H = hs[1] if hs[0] != UNSPECIFIED else None

    def place(W, H):
        box = {}

        def h_bounds(c, seen=()):
            r, (ml, mt, mr, mb) = c.rules, c.margin
            left = right = None
            for rule in _H_RULES:
                a = by_id.get(r.get(rule))
                if a is None or a in seen:
                    continue
                if a not in box:
                    resolve(a, seen + (c,))
                al, _, ar, _ = box[a]
                aml, _, amr, _ = a.margin
                if rule in ("toRightOf", "toEndOf"):
                    left = ar + amr + ml
                elif rule in ("toLeftOf", "toStartOf"):
                    right = al - aml - mr
                elif rule in ("alignLeft", "alignStart"):
                    left = al + ml
                else:
                    right = ar - mr
            if _true(r.get("alignParentLeft")) or _true(r.get("alignParentStart")):
                left = pl + ml
            if (_true(r.get("alignParentRight")) or _true(r.get("alignParentEnd"))) and W is not None:
                right = W - pr - mr
            return left, right

        def v_bounds(c, seen=()):
            r, (ml, mt, mr, mb) = c.rules, c.margin
            top = bottom = None
            for rule in _V_RULES[:-1]:
                a = by_id.get(r.get(rule))
                if a is None or a in seen:
                    continue
                if a not in box:
                    resolve(a, seen + (c,))
                _, at, _, ab = box[a]
                _, amt, _, amb = a.margin
                if rule == "below":
                    top = ab + amb + mt
                elif rule == "above":
                    bottom = at - amt - mb
                elif rule == "alignTop":
                    top = at + mt
                else:
                    bottom = ab - mb
            if _true(r.get("alignParentTop")):
                top = pt + mt
            if _true(r.get("alignParentBottom")) and H is not None:
                bottom = H - pb - mb
            return top, bottom

        def spec(lo, hi, dim, start_pad, end_pad, total, m0, m1):
            if lo is not None and hi is not None:
                return (EXACTLY, max(0, hi - lo))
            if dim not in (MATCH, WRAP):
                return (EXACTLY, float(dim))
            a = lo if lo is not None else start_pad + m0
            b = hi if hi is not None else (total - end_pad - m1 if total is not None else None)
            if b is None:
                return (UNSPECIFIED, 0)
            return (EXACTLY if dim == MATCH else AT_MOST, max(0, b - a))

        def resolve(c, seen=()):
            ml, mt, mr, mb = c.margin
            left, right = h_bounds(c, seen)
            top, bottom = v_bounds(c, seen)
            wspec = spec(left, right, c.width, pl, pr, W, ml, mr)
            hspec = spec(top, bottom, c.height, pt, pb, H, mt, mb)
            measure(c, wspec, hspec)
            r = c.rules
            if left is None and right is None:
                if (_true(r.get("centerHorizontal")) or _true(r.get("centerInParent"))) and W is not None:
                    left = (W - c.mw) / 2
                else:
                    left = pl + ml
            if left is None:
                left = right - c.mw
            right = left + c.mw
            if top is None and bottom is None:
                if (_true(r.get("centerVertical")) or _true(r.get("centerInParent"))) and H is not None:
                    top = (H - c.mh) / 2
                else:
                    top = pt + mt
            if top is None:
                top = bottom - c.mh
            bottom = top + c.mh
            a = by_id.get(r.get("alignBaseline"))
            if a is not None and a is not c:
                if a not in box:
                    resolve(a, seen + (c,))
                ab, cb = a.baseline(), c.baseline()
                if ab is not None and cb is not None:
                    top = box[a][1] + ab - cb
                    bottom = top + c.mh
            box[c] = (left, top, right, bottom)

        for c in kids:
            if c not in box:
                resolve(c)
        return box

    box = place(W if ws[0] == EXACTLY else None, H if hs[0] == EXACTLY else None)
    right = max([b[2] + c.margin[2] for c, b in box.items()], default=0) + pr
    bottom = max([b[3] + c.margin[3] for c, b in box.items()], default=0) + pb
    n.mw = resolve_size(_clamp(right, n.min_size[0], n.max_size[0]), ws)
    n.mh = resolve_size(_clamp(bottom, n.min_size[1], n.max_size[1]), hs)
    if ws[0] != EXACTLY or hs[0] != EXACTLY:
        # Now that the size is known, rules against the parent's far edge or centre can apply.
        box = place(n.mw, n.mh)
    for c, (l, t, _, _) in box.items():
        c.x, c.y = l, t
    n._placed = True


def layout(n):
    """Positions children (x, y relative to the parent) once measure() has run."""
    pl, pt, pr, pb = n.padding
    kids = _visible(n)
    if n.kind == "frame":
        for c in kids:
            c.x, c.y = _gravity_pos(c, c.layout_gravity or frozenset({"left", "top"}), n, 0, 0)
    elif n.kind == "linear":
        vertical = n.orientation == "vertical"
        total = getattr(n, "_total", 0)
        g = n.gravity
        if vertical:
            free = n.mh - pt - pb - total
            pos = pt + (free if "bottom" in g else free / 2 if "center_vertical" in g else 0)
        else:
            free = n.mw - pl - pr - total
            pos = pl + (free if "right" in g else free / 2 if "center_horizontal" in g else 0)
        for c in kids:
            ml, mt, mr, mb = c.margin
            cg = c.layout_gravity or g
            if vertical:
                c.x, _ = _gravity_pos(c, cg, n, 0, 0)
                c.y = pos + mt
                pos = c.y + c.mh + mb
            else:
                _, c.y = _gravity_pos(c, cg, n, 0, 0)
                b = _top_baseline(c, n) if getattr(n, "_ascent", None) is not None else None
                if b is not None:
                    c.y = pt + mt + n._ascent - b
                c.x = pos + ml
                pos = c.x + c.mw + mr
    # relative: positions were fixed during measure
    for c in kids:
        layout(c)


def _top_baseline(c, parent):
    """A child's baseline when a horizontal LinearLayout aligns it by baseline: top-gravity
    children only, as Android does (centred and bottom ones keep their gravity)."""
    g = c.layout_gravity or parent.gravity
    if "center_vertical" in g or "bottom" in g or c.height == MATCH:
        return None
    return c.baseline()


def _gravity_pos(c, g, parent, _x, _y):
    pl, pt, pr, pb = parent.padding
    ml, mt, mr, mb = c.margin
    if "center_horizontal" in g:
        x = pl + (parent.mw - pl - pr - c.mw) / 2 + ml - mr
    elif "right" in g:
        x = parent.mw - pr - c.mw - mr
    else:
        x = pl + ml
    if "center_vertical" in g:
        y = pt + (parent.mh - pt - pb - c.mh) / 2 + mt - mb
    elif "bottom" in g:
        y = parent.mh - pb - c.mh - mb
    else:
        y = pt + mt
    return x, y


def run(root, width, height):
    """Measures and lays out `root` in a window of width × height dp; returns root."""
    ws = child_spec((EXACTLY, width), root.margin[0] + root.margin[2], root.width)
    hs = child_spec((EXACTLY, height), root.margin[1] + root.margin[3], root.height)
    measure(root, ws, hs)
    root.x, root.y = root.margin[0], root.margin[1]
    layout(root)
    return root


def walk(n, ox=0.0, oy=0.0, depth=0):
    """Yields (node, absolute x, absolute y, depth) in draw order, gone nodes skipped."""
    if n.visibility == "gone":
        return
    ax, ay = ox + n.x, oy + n.y
    yield n, ax, ay, depth
    for c in n.children:
        yield from walk(c, ax, ay, depth + 1)
