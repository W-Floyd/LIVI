import unittest

from importvendor import android
from importvendor.android import Config


class Colors(unittest.TestCase):
    def test_parse_and_hex(self):
        for s, rgba, hexed in [
            ("#fff", (255, 255, 255, 255), "#ffffff"),
            ("#8f00", (255, 0, 0, 0x88), "#ff000088"),
            ("#17beb0", (0x17, 0xbe, 0xb0, 255), "#17beb0"),
            ("#33ffffff", (255, 255, 255, 0x33), "#ffffff33"),
            ("#FF004453", (0, 0x44, 0x53, 255), "#004453"),
        ]:
            with self.subTest(s):
                self.assertEqual(android.parse_color(s), rgba)
                self.assertEqual(android.color_hex(rgba), hexed)
                # Godot's order round-trips: alpha moves from first to last.
                self.assertEqual(android.parse_color("#" + (hexed[7:] or "ff") + hexed[1:7]), rgba)

    def test_rejects(self):
        for s in ["fff", "#ff", "#12345", "#gggggg", "@color/x"]:
            with self.subTest(s), self.assertRaises(ValueError):
                android.parse_color(s)


class Dimensions(unittest.TestCase):
    def test_to_dp_and_px(self):
        for s, dp, px in [
            ("12.0dp", 12, 18),
            ("10dip", 10, 15),
            ("28.0sp", 28, 42),
            ("30px", 20, 30),
            ("-60.0dp", -60, -90),
            ("1.2999878dp", 1.2999878, 1.9499817),
            ("1in", 160, 240),
        ]:
            with self.subTest(s):
                self.assertAlmostEqual(android.to_dp(s), dp, places=5)
                self.assertAlmostEqual(android.dp_to_px(android.to_dp(s)), px, places=5)

    def test_rejects(self):
        for s in ["", "dp", "12 em", "@dimen/x"]:
            with self.subTest(s), self.assertRaises(ValueError):
                android.parse_dimension(s)


class Gravity(unittest.TestCase):
    def test_parse(self):
        for s, want in [
            ("left|top", {"left", "top"}),
            ("center", {"center_horizontal", "center_vertical"}),
            ("end|center", {"right", "center_horizontal", "center_vertical"}),
            ("start|center_vertical", {"left", "center_vertical"}),
            (None, set()),
        ]:
            with self.subTest(s):
                self.assertEqual(set(android.parse_gravity(s)), want)


class Qualifiers(unittest.TestCase):
    def test_select(self):
        day, night = Config(night=False), Config(night=True)
        for dirs, cfg, want in [
            # The longest-precedence qualifier wins before night and density are looked at.
            (["drawable-hdpi-v4", "drawable-long-hdpi-v4", "drawable-night-hdpi-v8"], night, "drawable-long-hdpi-v4"),
            (["drawable-long-hdpi-v4", "drawable-long-night-nodpi-v8", "drawable-night-hdpi-v8"], night,
             "drawable-long-night-nodpi-v8"),
            (["drawable-nodpi-v4", "drawable-night-nodpi-v8"], day, "drawable-nodpi-v4"),
            (["drawable-nodpi-v4", "drawable-night-nodpi-v8"], night, "drawable-night-nodpi-v8"),
            # Density: exact, then nodpi, then the nearest larger.
            (["drawable-mdpi-v4", "drawable-xhdpi-v4", "drawable-nodpi-v4"], day, "drawable-nodpi-v4"),
            (["drawable-mdpi-v4", "drawable-xhdpi-v4", "drawable-xxhdpi-v4"], day, "drawable-xhdpi-v4"),
            (["drawable", "drawable-hdpi-v4"], day, "drawable-hdpi-v4"),
            # Not this device: other locales, sw600dp on a 480 dp-high panel, other UI modes.
            (["values", "values-de", "values-en-rGB", "values-sw600dp-v13", "values-watch-v20"], day, "values"),
            (["values", "values-w1280dp-v13", "values-w1024dp-v13"], day, "values-w1280dp-v13"),
            (["values-ar"], day, None),
        ]:
            with self.subTest(dirs=dirs, night=cfg.night):
                cands = [(android.parse_qualifiers(d)[1], d) for d in dirs]
                got = android.select(cands, cfg)
                self.assertEqual(got[1] if got else None, want)

    def test_unknown_token_rejects_folder(self):
        self.assertIsNone(android.parse_qualifiers("drawable-mcc310-hdpi")[1])

    def test_density_scale(self):
        cfg = Config()
        for d, want in [("drawable-nodpi-v4", 1.0), ("drawable-hdpi-v4", 1.0), ("drawable-mdpi-v4", 1.5),
                        ("drawable", 1.5), ("drawable-xhdpi-v4", 0.75)]:
            with self.subTest(d):
                self.assertAlmostEqual(android.density_scale(android.parse_qualifiers(d)[1], cfg), want)


if __name__ == "__main__":
    unittest.main()
