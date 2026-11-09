"""Android 9-patch border marks to Godot StyleBoxTexture margins."""

BLACK = (0, 0, 0, 255)


def _runs(marks):
    """Indices of marked pixels to [start, end) runs."""
    runs, start = [], None
    for i, m in enumerate(marks + [False]):
        if m and start is None:
            start = i
        elif not m and start is not None:
            runs.append((start, i))
            start = None
    return runs


def parse(width, height, pixel):
    """Reads the 1-px border of a raw `.9.png` (`pixel(x, y)` -> RGBA).

    Returns margins in the stripped image's pixels, as [left, top, right, bottom]:
    `texture` (the fixed corners around the stretch area, Godot's texture margins) and
    `content` (the padding lines, Godot's content margins; the stretch area when absent,
    as Android does). Godot stretches one area per axis, so `stretch_x`/`stretch_y` keep
    every run and `multi_stretch` flags those it can't reproduce exactly.
    Red layout-bound marks are not black and are ignored.
    """
    if width < 3 or height < 3:
        raise ValueError("too small for a 9-patch")
    w, h = width - 2, height - 2
    top = [pixel(x, 0) == BLACK for x in range(1, width - 1)]
    left = [pixel(0, y) == BLACK for y in range(1, height - 1)]
    bottom = [pixel(x, height - 1) == BLACK for x in range(1, width - 1)]
    right = [pixel(width - 1, y) == BLACK for y in range(1, height - 1)]
    sx, sy = _runs(top), _runs(left)
    if not sx:
        sx = [(0, w)]
    if not sy:
        sy = [(0, h)]
    texture = [sx[0][0], sy[0][0], w - sx[-1][1], h - sy[-1][1]]
    cx, cy = _runs(bottom), _runs(right)
    content = [
        cx[0][0] if cx else texture[0],
        cy[0][0] if cy else texture[1],
        w - cx[-1][1] if cx else texture[2],
        h - cy[-1][1] if cy else texture[3],
    ]
    return {
        "size": [w, h],
        "texture": texture,
        "content": content,
        "stretch_x": [list(r) for r in sx],
        "stretch_y": [list(r) for r in sy],
        "multi_stretch": len(sx) > 1 or len(sy) > 1,
    }


def from_image(img):
    """Parses a PIL image; returns (margins, the image with its border stripped)."""
    img = img.convert("RGBA")
    px = img.load()
    m = parse(img.width, img.height, lambda x, y: px[x, y])
    return m, img.crop((1, 1, img.width - 1, img.height - 1))
