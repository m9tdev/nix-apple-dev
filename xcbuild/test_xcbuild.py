"""Unit tests for xcbuild.py: build settings like Xcode, header maps clang can read."""
import os, struct, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcbuild as x
import xcode_version as xv

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")


def write(path, data):
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def tool(name, *args):
    """Run a stand-in from bin/ with this Python (the build sandbox has no /usr/bin/env)."""
    return subprocess.run([sys.executable, os.path.join(BIN, name)] + list(args),
                          capture_output=True, text=True)


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
            write(os.path.join(d, "base.xcconfig"), "A = 1 // comment\n")
            write(os.path.join(d, "t.xcconfig"),
                  '#include "base.xcconfig"\nB = "http://x" $(A)\nC[sdk=iphoneos*] = dev\n')
            items = x.parse_xcconfig(os.path.join(d, "t.xcconfig"))
            self.assertEqual(items, [("A", "", "1"), ("B", "", '"http://x" $(A)'), ("C", "[sdk=iphoneos*]", "dev")])


class HeaderMap(unittest.TestCase):
    def lookup(self, path, key):
        d = read(path)
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


def macho(cputype):
    """A thin 64-bit Mach-O header, little-endian as on disk."""
    return struct.pack("<IIiIIII", 0xfeedfacf, cputype, 0, 6, 0, 0, 0) + b"\0" * 100


class Lipo(unittest.TestCase):
    def test_thin(self):
        with tempfile.TemporaryDirectory() as d:
            f, out = os.path.join(d, "bin"), os.path.join(d, "out")
            write(f, macho(0x0100000c))
            self.assertEqual(tool("lipo", "-archs", f).stdout, "arm64\n")
            self.assertEqual(tool("lipo", "-info", f).stdout, "Non-fat file: %s is architecture: arm64\n" % f)
            self.assertEqual(tool("lipo", "-verify_arch", f, "arm64").returncode, 0)
            self.assertNotEqual(tool("lipo", "-verify_arch", f, "x86_64").returncode, 0)
            self.assertEqual(tool("lipo", "-thin", "arm64", f, "-output", out).returncode, 0)
            self.assertEqual(read(out), read(f))

    def test_fat(self):
        with tempfile.TemporaryDirectory() as d:
            f, out = os.path.join(d, "fat"), os.path.join(d, "out")
            x86, arm = macho(0x01000007), macho(0x0100000c)
            hdr = struct.pack(">II", 0xcafebabe, 2)
            hdr += struct.pack(">IIIII", 0x01000007, 3, 4096, len(x86), 12)
            hdr += struct.pack(">IIIII", 0x0100000c, 0, 8192, len(arm), 12)
            write(f, hdr.ljust(4096, b"\0") + x86.ljust(4096, b"\0") + arm)
            self.assertEqual(tool("lipo", "-archs", f).stdout, "x86_64 arm64\n")
            self.assertEqual(tool("lipo", "-thin", "arm64", f, "-output", out).returncode, 0)
            self.assertEqual(read(out), arm)
            self.assertNotEqual(tool("lipo", "-thin", "armv7", f, "-output", out).returncode, 0)


class XcodeVersion(unittest.TestCase):
    def test_xcodebuild_version(self):
        r = tool("xcodebuild", "-version")
        self.assertEqual(r.stdout, "Xcode %s\nBuild version %s\n" % (xv.XCODE_VERSION, xv.XCODE_BUILD))
        self.assertNotEqual(tool("xcodebuild", "build").returncode, 0)

    def test_number(self):
        self.assertEqual(xv.XCODE_VERSION_NUMBER, "%02d%s0" % tuple(int(n) for n in xv.XCODE_VERSION.split(".")[:2]))


class Supported(unittest.TestCase):
    def build(self, targets):
        b = x.Build.__new__(x.Build)
        b.targets = {t["name"]: t for t in targets}
        return b

    def test_static_bundle_app(self):
        b = self.build([{"name": "Pod", "type": "com.apple.product-type.library.static",
                         "phases": [{"isa": "PBXSourcesBuildPhase", "files": [{"path": "a.m"}]}]},
                        {"name": "App", "type": "com.apple.product-type.application",
                         "phases": [{"isa": "PBXCopyFilesBuildPhase", "files": []}]}])
        b.check_supported(["Pod", "App"])

    def test_frameworks_extensions_copy_files(self):
        b = self.build([{"name": "Pod", "type": "com.apple.product-type.framework", "phases": []},
                        {"name": "Ext", "type": "com.apple.product-type.app-extension", "phases": []},
                        {"name": "App", "type": "com.apple.product-type.application",
                         "phases": [{"isa": "PBXCopyFilesBuildPhase", "name": "Embed", "files": [{"path": "x"}]}]}])
        with self.assertRaises(SystemExit) as e:
            b.check_supported(["Pod", "Ext", "App"])
        msg = str(e.exception)
        for part in ("Pod: product type com.apple.product-type.framework",
                     "Ext: product type com.apple.product-type.app-extension",
                     "App: PBXCopyFilesBuildPhase Embed"):
            self.assertIn(part, msg)


if __name__ == "__main__":
    unittest.main(verbosity=1)
