"""Unit tests for xcbuild.py: build settings like Xcode, header maps clang can read."""
import ipaddress, json, os, shutil, struct, subprocess, sys, tempfile, time, unittest
from unittest import mock
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

    def test_unchanged_not_rewritten(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.hmap")
            x.write_hmap(p, {"a.h": "/s/a.h"})
            os.utime(p, ns=(1, 1))
            x._hmaps.clear()  # as in the next build
            x.write_hmap(p, {"a.h": "/s/a.h"})
            self.assertEqual(os.stat(p).st_mtime_ns, 1)
            x.write_hmap(p, {"b.h": "/s/b.h"})
            self.assertNotEqual(os.stat(p).st_mtime_ns, 1)

    def test_same_map_built_once_per_run(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.hmap")
            m = {"a.h": "/s/a.h"}
            x.write_hmap(p, m)
            with mock.patch.object(x, "write_if_changed") as w:
                x.write_hmap(p, dict(m))
                w.assert_not_called()
                m["b.h"] = "/s/b.h"  # the memo holds a copy, not the caller's dict
                x.write_hmap(p, m)
                w.assert_called_once()
            self.assertEqual(self.lookup(p, "b.h"), None)  # mocked write left the old file


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
            self.assertEqual(tool("lipo", f, "-verify_arch", "arm64").returncode, 0)
            self.assertNotEqual(tool("lipo", f, "-verify_arch", "x86_64").returncode, 0)
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
            self.assertEqual(tool("lipo", f, "-verify_arch", "arm64").returncode, 0)
            self.assertEqual(tool("lipo", f, "-verify_arch", "arm64", "x86_64").returncode, 0)
            self.assertNotEqual(tool("lipo", f, "-verify_arch", "arm64", "armv7").returncode, 0)


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


class Ipconfig(unittest.TestCase):
    """The ipconfig stand-in that gives React Native's Debug builds their dev server host."""
    tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "ipconfig")

    def run_tool(self, *args, host=None):
        env = {k: v for k, v in os.environ.items() if k != "APPLE_DEV_DEV_SERVER_HOST"}
        if host is not None:
            env["APPLE_DEV_DEV_SERVER_HOST"] = host
        return subprocess.run([sys.executable, self.tool] + list(args), env=env, capture_output=True, text=True)

    def test_host_override(self):
        r = self.run_tool("getifaddr", "en0", host="dev.example.net")
        self.assertEqual((r.returncode, r.stdout), (0, "dev.example.net\n"))

    def test_other_interfaces_fail(self):
        r = self.run_tool("getifaddr", "en1", host="dev.example.net")
        self.assertEqual((r.returncode, r.stdout), (1, ""))

    def test_usage(self):
        self.assertNotEqual(self.run_tool("ifcount").returncode, 0)

    def test_default_route(self):
        # With a default route: an IPv4 address. Without one (as in a build sandbox): nothing, exit 1.
        r = self.run_tool("getifaddr", "en0")
        if r.stdout:
            self.assertEqual(r.returncode, 0)
            ipaddress.IPv4Address(r.stdout.strip())
        else:
            self.assertEqual(r.returncode, 1)

    def test_no_route(self):
        unshare = shutil.which("unshare")
        if not unshare or subprocess.run([unshare, "-rn", "true"], capture_output=True).returncode != 0:
            self.skipTest("no unshare -rn here")
        env = {k: v for k, v in os.environ.items() if k != "APPLE_DEV_DEV_SERVER_HOST"}
        r = subprocess.run([unshare, "-rn", sys.executable, self.tool, "getifaddr", "en0"],
                           env=env, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout), (1, ""))


class Steps(unittest.TestCase):
    """Up-to-date checks: rerun on a new command, a missing output or new input content."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.src, self.out = os.path.join(self.d, "a.c"), os.path.join(self.d, "a.o")
        write(self.src, "int a;\n")
        write(self.out, "obj")
        self.db = os.path.join(self.d, "steps.json")

    def tearDown(self):
        self.tmp.cleanup()

    def steps(self, env="tools"):
        return x.Steps(self.db, env)

    def recorded(self, cmd=("cc", "a.c")):
        s = self.steps()
        s.record(self.out, cmd, [self.src], time_ns_later(), [self.out])
        s.save()

    def test_unchanged(self):
        self.recorded()
        self.assertTrue(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_same_content_rewritten(self):
        self.recorded()
        write(self.src, "int a;\n")
        os.utime(self.src, ns=(1, 1))
        self.assertTrue(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_rerun(self):
        self.recorded()
        self.assertFalse(self.steps().fresh(self.out, ("cc", "-O2", "a.c"), [self.out]))
        self.assertFalse(self.steps("new tools").fresh(self.out, ("cc", "a.c"), [self.out]))
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out, self.out + ".d"]))
        write(self.src, "int b;\n")
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))
        os.remove(self.src)
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_input_changed_during_step(self):
        s = self.steps()
        s.record(self.out, ("cc",), [self.src], 0, [self.out])  # the input is newer than the step
        self.assertFalse(s.fresh(self.out, ("cc",), [self.out]))

    def test_missing_input_and_directory(self):
        s = self.steps()
        s.record(self.out, ("cc",), [os.path.join(self.d, "gone.h"), self.d], time_ns_later(), [self.out])
        self.assertFalse(s.fresh(self.out, ("cc",), [self.out]))

    def test_forget(self):
        self.recorded()
        s = self.steps()
        s.forget(self.out)
        self.assertFalse(s.fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_forget_on_disk_before_save(self):
        # a build killed while the step runs: the next one reads the record without it
        self.recorded()
        self.steps().forget(self.out)
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))
        s = self.steps()
        s.record(self.out, ("cc", "a.c"), [self.src], time_ns_later(), [self.out])
        s.save()
        self.assertFalse(os.path.exists(self.db + ".forget"))
        self.assertTrue(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_output_written_after_record(self):
        # the step ran again but its new record was lost: the output is not the recorded one
        self.recorded()
        tmp = self.out + ".tmp"
        write(tmp, "obj")
        st = os.stat(self.out)
        os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
        os.replace(tmp, self.out)  # same bytes and mtime, new inode
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))
        self.recorded()
        write(self.out, "objv2")
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_old_record_without_outputs(self):
        self.recorded()
        db = json.load(open(self.db))
        del db[self.out]["out"]
        write(self.db, json.dumps(db))
        self.assertFalse(self.steps().fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_rehashed_input_trusted_after(self):
        # an input touched with the same content is hashed once, then trusted by mtime
        self.recorded()
        time.sleep(0.05)
        t = time.time_ns() - 10**7  # after the record
        os.utime(self.src, ns=(t, t))
        s = self.steps()
        with mock.patch.object(x, "RACY_NS", 0):
            self.assertTrue(s.fresh(self.out, ("cc", "a.c"), [self.out]))
            with mock.patch.object(x, "file_digest", side_effect=AssertionError("rehashed")):
                self.assertTrue(s.fresh(self.out, ("cc", "a.c"), [self.out]))

    def test_clean(self):
        self.recorded()
        self.steps().forget("other")
        s = x.Steps(self.db, "tools", clean=True)
        self.assertFalse(s.fresh(self.out, ("cc", "a.c"), [self.out]))
        self.assertFalse(os.path.exists(self.db) or os.path.exists(self.db + ".forget"))


def time_ns_later():
    return time.time_ns() + 10**9


class DepFiles(unittest.TestCase):
    def test_clang(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.o.d")
            write(p, "/o/a.o: /s/a.m /s/My\\ Dir/b.h \\\n  /s/c$$.h\n")
            self.assertEqual(x.read_depfile(p), ["/s/a.m", "/s/My Dir/b.h", "/s/c$.h"])
            self.assertIsNone(x.read_depfile(os.path.join(d, "none.d")))

    def test_swift_rules(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.d")
            write(p, "/o/a.o : /s/a.swift /m/Foo.swiftmodule\n/o/a.swiftdeps : /s/a.swift /h/x.h\n")
            self.assertEqual(x.read_depfile(p), ["/s/a.swift", "/m/Foo.swiftmodule", "/s/a.swift", "/h/x.h"])

    def test_dependency_info(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "dep.dat")
            # lld lists archive members (b.o of libB.a) by bare name
            write(p, b"\x00lld\x00\x10/o/a.o\x00\x11/missing.a\x00\x10/l/libB.a\x00\x10b.o\x00\x40/app/App\x00")
            self.assertEqual(x.read_dependency_info(p), ["/o/a.o", "/l/libB.a"])

    def test_hmap_inputs(self):
        cmd = ["clang", "-iquote", "/t/gen.hmap", "-I/t/own.hmap", "-Xcc", "-I/t/all.hmap", "-I/inc"]
        self.assertEqual(x.hmap_inputs(cmd), ["/t/gen.hmap", "/t/own.hmap", "/t/all.hmap"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
