"""Unit tests for xcbuild.py: build settings like Xcode, header maps clang can read."""
import os, struct, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcbuild as x


class Settings(unittest.TestCase):
    def test_inherited_and_conditions(self):
        s = x.Settings({"sdk": "iphoneos27.0", "arch": "arm64", "config": "Release"})
        s.layer_dict({"OTHER_CFLAGS": "-DA", "OTHER_CPLUSPLUSFLAGS": "$(OTHER_CFLAGS)"})
        s.layer([("OTHER_CFLAGS", "", "$(inherited) -DB"),
                 ("OTHER_CFLAGS", "[sdk=iphonesimulator*]", "-DSIM"),
                 ("CODE", "[sdk=iphoneos*]", "dev")])
        s.layer_dict({"OTHER_CPLUSPLUSFLAGS": ["$(inherited)", "-DC"]})
        self.assertEqual(s.get("OTHER_CFLAGS"), "-DA -DB")
        self.assertEqual(s.words("OTHER_CPLUSPLUSFLAGS"), ["-DA", "-DB", "-DC"])
        self.assertEqual(s.get("CODE"), "dev")

    def test_expansion_and_modifiers(self):
        s = x.Settings({})
        s.layer_dict({"PRODUCT_NAME": "My App-1", "ROOT": "/r", "P": "${ROOT}/$(PRODUCT_NAME:rfc1034identifier)",
                      "M": "$(PRODUCT_NAME:c99extidentifier)", "Q": "\"a b\" \"\" c"})
        self.assertEqual(s.get("P"), "/r/My-App-1")
        self.assertEqual(s.get("M"), "My_App_1")
        self.assertEqual(s.words("Q"), ["a b", "c"])

    def test_xcconfig(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "base.xcconfig"), "w").write("A = 1 // comment\n")
            open(os.path.join(d, "t.xcconfig"), "w").write(
                '#include "base.xcconfig"\nB = "http://x" $(A)\nC[sdk=iphoneos*] = dev\n')
            items = x.parse_xcconfig(os.path.join(d, "t.xcconfig"))
            self.assertEqual(items, [("A", "", "1"), ("B", "", '"http://x" $(A)'), ("C", "[sdk=iphoneos*]", "dev")])


class HeaderMap(unittest.TestCase):
    def lookup(self, path, key):
        d = open(path, "rb").read()
        magic, ver, _, soff, n, nb, _ = struct.unpack("<IHHIIII", d[:24])
        self.assertEqual(d[:4], b"pamh")  # clang reads the magic as a native uint32
        def string(o):
            e = d.index(b"\0", soff + o)
            return d[soff + o:e].decode()
        h = sum(ord(c.lower()) * 13 for c in key) & (nb - 1)
        while True:
            k, p, s = struct.unpack("<III", d[24 + 12 * h:36 + 12 * h])
            if k == 0:
                return None
            if string(k).lower() == key.lower():
                return string(p) + string(s)
            h = (h + 1) & (nb - 1)

    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            m = {"AnyMap.hpp": "/src/cpp/core/AnyMap.hpp", "React/RCTView.h": "/h/RCTView.h"}
            m.update({"f%d.h" % i: "/d/f%d.h" % i for i in range(50)})
            x.write_hmap(os.path.join(d, "t.hmap"), m)
            for k, v in m.items():
                self.assertEqual(self.lookup(os.path.join(d, "t.hmap"), k), v)
            self.assertEqual(self.lookup(os.path.join(d, "t.hmap"), "anymap.HPP"), "/src/cpp/core/AnyMap.hpp")
            self.assertIsNone(self.lookup(os.path.join(d, "t.hmap"), "missing.h"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
