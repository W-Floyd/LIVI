import unittest

from importvendor import ninepatch

K, R, W = (0, 0, 0, 255), (255, 0, 0, 255), (200, 200, 200, 255)
CLEAR = (0, 0, 0, 0)


def grid(rows):
    """'k' black mark, 'r' red layout bound, '.' clear border, any other: image pixel."""
    lut = {"k": K, "r": R, ".": CLEAR}
    px = [[lut.get(ch, W) for ch in row] for row in rows]
    return len(rows[0]), len(rows), lambda x, y: px[y][x]


class Parse(unittest.TestCase):
    def test_margins(self):
        for name, rows, texture, content, multi in [
            ("one stretch pixel, padding lines",
             [".....k.....",
              ".#########.",
              ".#########.",
              "k#########k",
              ".#########k",
              ".#########.",
              "..kkkkkk..."], [4, 2, 4, 2], [1, 2, 2, 1], False),
            ("no padding lines: content is the stretch area",
             ["..kkk..",
              ".#####.",
              "k#####.",
              "k#####.",
              ".#####.",
              "......."], [1, 1, 1, 1], [1, 1, 1, 1], False),
            ("two stretch runs",
             [".kk..kk.",
              ".######.",
              "k######.",
              ".######.",
              "........"], [0, 1, 0, 1], [0, 1, 0, 1], True),
            ("red layout bounds are not marks",
             ["..kk..",
              ".####.",
              "k####.",
              ".####.",
              ".rrrr."], [1, 1, 1, 1], [1, 1, 1, 1], False),
            ("no marks at all: everything stretches",
             [".....",
              ".###.",
              ".###.",
              "....."], [0, 0, 0, 0], [0, 0, 0, 0], False),
        ]:
            with self.subTest(name):
                w, h, px = grid(rows)
                m = ninepatch.parse(w, h, px)
                self.assertEqual(m["size"], [w - 2, h - 2])
                self.assertEqual(m["texture"], texture)
                self.assertEqual(m["content"], content)
                self.assertEqual(m["multi_stretch"], multi)
                # Invariant: margins never exceed the stripped image.
                for a, b in ((0, 2), (1, 3)):
                    self.assertLessEqual(m["texture"][a] + m["texture"][b], m["size"][a % 2])

    def test_too_small(self):
        with self.assertRaises(ValueError):
            ninepatch.parse(2, 5, lambda x, y: CLEAR)


if __name__ == "__main__":
    unittest.main()
