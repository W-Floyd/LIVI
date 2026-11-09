import unittest

from importvendor import yamlout


class Scalars(unittest.TestCase):
    def test_quoting(self):
        for v, want in [
            ("plain_name", "plain_name"), ("HKMC_TAppEV3/co_bg", "HKMC_TAppEV3/co_bg"),
            # Strings YAML would read as something else are quoted.
            ("On", '"On"'), ("off", '"off"'), ("null", '"null"'), ("#17beb0", '"#17beb0"'),
            ("12", '"12"'), ("a: b", '"a: b"'), ("", '""'),
            (True, "true"), (None, "null"), (3, "3"), (2.0, "2"), (1.23456, "1.235"),
        ]:
            with self.subTest(v=v):
                self.assertEqual(yamlout.scalar(v), want)

    def test_dump(self):
        doc = {"a": {"b": [1, 2], "c": {"d": "x"}}, "l": [{"k": 1, "m": {"z": [1]}}, [1, 2]]}
        self.assertEqual(yamlout.dump(doc, width=20),
                         "a:\n  b: [1, 2]\n  c: { d: x }\nl:\n  - k: 1\n    m:\n      z: [1]\n  - [1, 2]\n")


if __name__ == "__main__":
    unittest.main()
