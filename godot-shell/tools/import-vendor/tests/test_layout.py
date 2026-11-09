import unittest

from importvendor import layout
from importvendor.layout import MATCH, WRAP, Node


def leaf(id, w, h, **kw):
    return Node(id=id, width=w, height=h, **kw)


def fixed(cw, ch, baseline=None):
    """A leaf content of a fixed size, with a baseline measured from the content's top."""
    kw = {"content": lambda aw, ah: (cw, ch)}
    if baseline is not None:
        kw["baseline_fn"] = lambda n: n.padding[1] + baseline
    return kw


def rects(root):
    return {n.id: (x, y, n.mw, n.mh) for n, x, y, _ in layout.walk(root) if n.id}


CASES = [
    ("frame: margins, negative margin, gravity",
     Node(kind="frame", id="root", width=MATCH, height=MATCH, children=[
         leaf("bg", 100, 50, margin=(0, -10, 0, 0)),
         leaf("c", 20, 10, layout_gravity=frozenset({"center_horizontal", "center_vertical"})),
         leaf("br", 10, 10, layout_gravity=frozenset({"right", "bottom"}), margin=(0, 0, 5, 5)),
         leaf("gone", 10, 10, visibility="gone"),
     ]), (100, 40),
     {"root": (0, 0, 100, 40), "bg": (0, -10, 100, 50), "c": (40, 15, 20, 10), "br": (85, 25, 10, 10)}),

    ("frame: wrap takes the largest child plus padding; match_parent child fills it",
     Node(kind="frame", id="root", width=WRAP, height=WRAP, padding=(2, 3, 4, 5), children=[
         leaf("a", 30, 20, margin=(1, 0, 0, 0)), leaf("m", MATCH, MATCH),
     ]), (100, 100),
     {"root": (0, 0, 37, 28), "a": (3, 3, 30, 20), "m": (2, 3, 31, 20)}),

    ("linear vertical: stacking, margins, weights",
     Node(kind="linear", id="root", orientation="vertical", width=50, height=100, children=[
         leaf("a", MATCH, 20, margin=(0, 5, 0, 5)),
         leaf("b", MATCH, 0, weight=1),
         leaf("c", MATCH, 0, weight=3),
     ]), (100, 100),
     {"a": (0, 5, 50, 20), "b": (0, 30, 50, 17.5), "c": (0, 47.5, 50, 52.5)}),

    ("linear horizontal: gravity centres the row and its children",
     Node(kind="linear", id="root", width=100, height=40,
          gravity=frozenset({"center_horizontal", "center_vertical"}), children=[
              leaf("a", 20, 10), leaf("b", 30, 20, margin=(10, 0, 0, 0)),
          ]), (100, 100),
     {"a": (20, 15, 20, 10), "b": (50, 10, 30, 20)}),

    ("linear horizontal: wrap children aligned on their baselines",
     Node(kind="linear", id="root", width=WRAP, height=WRAP, children=[
         leaf("big", WRAP, WRAP, **fixed(30, 40, baseline=32)),
         leaf("unit", WRAP, WRAP, **fixed(10, 15, baseline=12)),
     ]), (100, 100),
     {"root": (0, 0, 40, 40), "big": (0, 0, 30, 40), "unit": (30, 20, 10, 15)}),

    ("relative: toRightOf, below, alignParentRight, centerInParent",
     Node(kind="relative", id="root", width=200, height=100, padding=(5, 5, 5, 5), children=[
         leaf("a", 40, 20, margin=(10, 0, 0, 0)),
         leaf("b", 30, 20, rules={"toRightOf": "a"}, margin=(4, 0, 0, 0)),
         leaf("c", 30, 20, rules={"below": "a", "alignLeft": "b"}, margin=(0, 2, 0, 0)),
         leaf("r", 20, 10, rules={"alignParentRight": "true", "alignParentBottom": "true"}),
         leaf("mid", 20, 10, rules={"centerInParent": "true"}),
     ]), (300, 300),
     {"a": (15, 5, 40, 20), "b": (59, 5, 30, 20), "c": (59, 27, 30, 20), "r": (175, 85, 20, 10),
      "mid": (90, 45, 20, 10)}),

    ("relative: forward reference, both edges constrain width",
     Node(kind="relative", id="root", width=100, height=50, children=[
         leaf("left", 10, 10, rules={"toLeftOf": "right"}),
         leaf("right", 20, 10, rules={"alignParentRight": "true"}),
         leaf("first", 10, 10),
         leaf("span", WRAP, 10, rules={"toRightOf": "first", "toLeftOf": "left"}, **fixed(5, 5)),
     ]), (100, 50),
     {"left": (70, 0, 10, 10), "right": (80, 0, 20, 10), "span": (10, 0, 60, 10)}),

    ("relative wrap: value and unit on one baseline, the box hugs them",
     Node(kind="relative", id="root", width=WRAP, height=WRAP, children=[
         leaf("value", WRAP, WRAP, **fixed(60, 40, baseline=30)),
         leaf("unit", WRAP, WRAP, rules={"toRightOf": "value", "alignBaseline": "value"},
              margin=(4, 0, 0, 0), **fixed(20, 16, baseline=12)),
     ]), (500, 500),
     {"root": (0, 0, 84, 40), "value": (0, 0, 60, 40), "unit": (64, 18, 20, 16)}),
]


class Layout(unittest.TestCase):
    def test_cases(self):
        for name, root, (w, h), want in CASES:
            with self.subTest(name):
                layout.run(root, w, h)
                got = rects(root)
                for id, r in want.items():
                    self.assertIn(id, got)
                    for a, b in zip(got[id], r):
                        self.assertAlmostEqual(a, b, places=4, msg=f"{id}: {got[id]} != {r}")
                self.assertNotIn("gone", got)

    def test_child_spec(self):
        E, A, U = layout.EXACTLY, layout.AT_MOST, layout.UNSPECIFIED
        for spec, used, dim, want in [
            ((E, 100), 10, MATCH, (E, 90)), ((E, 100), 10, WRAP, (A, 90)), ((E, 100), 10, 30, (E, 30)),
            ((A, 100), 0, MATCH, (A, 100)), ((U, 0), 0, MATCH, (U, 0)), ((U, 0), 0, WRAP, (U, 0)),
            ((E, 5), 10, MATCH, (E, 0)),
        ]:
            with self.subTest(spec=spec, dim=dim):
                self.assertEqual(layout.child_spec(spec, used, dim), want)


if __name__ == "__main__":
    unittest.main()
