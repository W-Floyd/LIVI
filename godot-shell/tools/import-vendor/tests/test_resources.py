import os
import tempfile
import unittest

from importvendor import layout
from importvendor.android import Config
from importvendor.images import Drawables
from importvendor.resources import Package, Resources, parse_ref
from importvendor.screens import Inflater

A = 'xmlns:android="http://schemas.android.com/apk/res/android"'

APP = {
    "res/values/colors.xml": """<resources>
        <color name="text">#62797f</color>
        <color name="alias">@color/text</color>
        <color name="fw_alias">@android:color/white</color>
    </resources>""",
    "res/values-night-v8/colors.xml": """<resources><color name="text">#b6c1c8</color></resources>""",
    "res/values/dimens.xml": """<resources>
        <dimen name="gap">10.0dp</dimen><dimen name="gap_alias">@dimen/gap</dimen>
    </resources>""",
    "res/values/strings.xml": """<resources><string name="title">Electric \\"EV\\"</string></resources>""",
    "res/values-de/strings.xml": """<resources><string name="title">Elektro</string></resources>""",
    "res/values/styles.xml": """<resources>
        <style name="Base"><item name="android:textSize">20.0sp</item><item name="android:textColor">@color/text</item></style>
        <style name="Base.Big"><item name="android:textSize">40.0sp</item></style>
        <style name="Shadow" parent="@style/Base.Big"><item name="android:shadowDx">1.5</item></style>
    </resources>""",
    "res/color/sel.xml": f"""<selector {A}>
        <item android:state_pressed="true" android:color="#ff0000" />
        <item android:color="@color/text" />
    </selector>""",
    "res/layout/screen.xml": f"""<FrameLayout {A} android:layout_width="match_parent" android:layout_height="match_parent">
        <include android:id="@id/bar" android:layout_width="match_parent" android:layout_height="60.0dp" layout="@layout/bar" />
        <include android:layout_width="wrap_content" layout="@layout/body" />
        <include layout="@layout/parts" />
    </FrameLayout>""",
    "res/layout/bar.xml": f"""<FrameLayout {A} android:id="@id/inner" android:layout_width="10.0dp" android:layout_height="10.0dp">
        <View android:id="@id/bar_line" android:layout_width="match_parent" android:layout_height="2.0dp" android:layout_gravity="bottom" />
    </FrameLayout>""",
    "res/layout/body.xml": f"""<LinearLayout {A} android:id="@id/body" android:orientation="vertical"
            android:layout_width="match_parent" android:layout_height="match_parent" android:layout_marginTop="@dimen/gap_alias">
        <View android:id="@id/b1" android:layout_width="30.0dp" android:layout_height="20.0dp" />
        <View android:id="@id/b2" android:layout_width="30.0dp" android:layout_height="20.0dp" android:visibility="gone" />
    </LinearLayout>""",
    "res/layout/parts.xml": f"""<merge {A}>
        <View android:id="@id/m1" android:layout_width="5.0dp" android:layout_height="5.0dp" android:layout_gravity="right" />
    </merge>""",
}

FRAMEWORK = {
    "res/values/colors.xml": """<resources><color name="white">#ffffffff</color></resources>""",
}


def tree(root, files):
    for rel, text in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)


class Fixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        tree(os.path.join(cls.tmp.name, "app"), APP)
        tree(os.path.join(cls.tmp.name, "fw"), FRAMEWORK)
        cls.app = Package("app", os.path.join(cls.tmp.name, "app"))
        cls.fw = Package("android", os.path.join(cls.tmp.name, "fw"))
        cls.res = Resources(cls.app, cls.fw)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()


class Values(Fixture):
    def test_refs(self):
        for s, want in [
            ("@android:drawable/co_bg", ("android", "drawable", "co_bg")),
            ("@+id/x", (None, "id", "x")),
            ("@drawable/a.b", (None, "drawable", "a.b")),
            ("#fff", None), ("12dp", None),
        ]:
            with self.subTest(s):
                self.assertEqual(parse_ref(s), want)

    def test_colors(self):
        day, night = Config(night=False), Config(night=True)
        for ref, cfg, default, n_states in [
            ("@color/text", day, (0x62, 0x79, 0x7f, 255), 1),
            ("@color/text", night, (0xb6, 0xc1, 0xc8, 255), 1),
            ("@color/alias", night, (0xb6, 0xc1, 0xc8, 255), 1),
            ("@color/fw_alias", day, (255, 255, 255, 255), 1),
            ("@color/sel", night, (0xb6, 0xc1, 0xc8, 255), 2),
            ("#80ff0000", day, (255, 0, 0, 0x80), 1),
        ]:
            with self.subTest(ref=ref, night=cfg.night):
                c = self.res.color(ref, cfg)
                self.assertEqual(c["default"], default)
                self.assertEqual(len(c["states"]), n_states)

    def test_values(self):
        day = Config()
        self.assertEqual(self.res.dimen_dp("@dimen/gap_alias", day), 10.0)
        self.assertEqual(self.res.string("@string/title", day), 'Electric "EV"')

    def test_style_inheritance(self):
        day = Config()
        for name, want in [
            ("@style/Base", {"android:textSize": "20.0sp", "android:textColor": "@color/text"}),
            # A dotted name inherits from its prefix when it names no parent.
            ("@style/Base.Big", {"android:textSize": "40.0sp", "android:textColor": "@color/text"}),
            ("@style/Shadow", {"android:textSize": "40.0sp", "android:textColor": "@color/text",
                               "android:shadowDx": "1.5"}),
        ]:
            with self.subTest(name):
                self.assertEqual(self.res.style(name, day), want)


class Includes(Fixture):
    def test_include_merge_and_overrides(self):
        cfg = Config()
        dr = Drawables({"app": self.app, "android": self.fw}, ["app"], cfg, Config(night=True),
                       os.path.join(self.tmp.name, "out"))
        inf = Inflater(self.res, cfg, dr, fonts=None, density=1.5)
        root = inf.inflate("screen")
        layout.run(root, 200, 100)
        got = {n.id: (x, y, n.mw, n.mh) for n, x, y, _ in layout.walk(root) if n.id}
        for id, want in {
            # The include's id and layout size replace the included root's.
            "bar": (0, 0, 200, 60), "bar_line": (0, 58, 200, 2),
            # With only one of width and height, the include's layout attributes are ignored.
            "body": (0, 10, 200, 90), "b1": (0, 10, 30, 20),
            # A merge's children join the including parent.
            "m1": (195, 0, 5, 5),
        }.items():
            with self.subTest(id):
                self.assertEqual(got.get(id), want)
        self.assertNotIn("inner", got)
        self.assertNotIn("b2", got)


if __name__ == "__main__":
    unittest.main()
