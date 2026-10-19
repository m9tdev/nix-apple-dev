"""Unit tests for xcbuild.py: build settings like Xcode, header maps clang can read."""
import ipaddress, json, os, shutil, signal, struct, subprocess, sys, tempfile, time, types, unittest
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
            x.write_hmap(p, {"a.h": "/s/a.h"})
            self.assertEqual(os.stat(p).st_mtime_ns, 1)
            x.write_hmap(p, {"b.h": "/s/b.h"})
            self.assertNotEqual(os.stat(p).st_mtime_ns, 1)


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


class ProjectCache(unittest.TestCase):
    """A project is read again by a new dump-project.rb, told by its content: installed files
    all have the same mtime."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.d = self.tmp.name
        self.here = os.path.join(d, "libexec")
        os.makedirs(self.here)
        self.proj = os.path.join(d, "ios", "P.xcodeproj")
        os.makedirs(self.proj)
        write(os.path.join(self.proj, "project.pbxproj"), "// project\n")
        self.ruby = os.path.join(d, "ruby")
        # a stand-in for Ruby running the reader: the project, as dumped by this reader
        write(self.ruby, "#!%s\nimport json, sys\nopen(%r, 'a').write('run\\n')\n"
                         "print(json.dumps({'name': 'P', 'targets': [], 'reader': open(sys.argv[1]).read()}))\n"
              % (sys.executable, os.path.join(d, "runs")))
        os.chmod(self.ruby, 0o755)
        self.reader("v1")

    def tearDown(self):
        self.tmp.cleanup()

    def reader(self, text):
        p = os.path.join(self.here, "dump-project.rb")
        write(p, text)
        os.utime(p, ns=(10**9, 10**9))  # as in the Nix store

    def load(self):
        b = x.Build.__new__(x.Build)
        b.derived, b.config, b.projects, b.targets = os.path.join(self.d, "build"), "Debug", [], {}
        with mock.patch.object(x, "HERE", self.here), mock.patch.object(x, "RUBY", self.ruby):
            b.load(self.proj)
        runs = os.path.join(self.d, "runs")
        return b.projects[0]["reader"], len(read(runs).splitlines()) if os.path.exists(runs) else 0

    def test_new_reader(self):
        # a cache from before readers were told apart, by a reader without dependency_file
        cdir = os.path.join(self.d, "build", "projects")
        os.makedirs(cdir)
        write(os.path.join(cdir, "P.xcodeproj.Debug.json"), '{"name": "P", "targets": [], "reader": "v0"}')
        self.assertEqual(self.load(), ("v1", 1))
        self.assertEqual(self.load(), ("v1", 1))  # same reader, same project: the cache
        self.reader("v2")
        self.assertEqual(self.load(), ("v2", 2))
        self.assertEqual(len(os.listdir(cdir)), 1)  # the other readers' caches are gone
        self.assertEqual(self.load(), ("v2", 2))
        t = time.time_ns()
        os.utime(os.path.join(self.proj, "project.pbxproj"), ns=(t + 10**9, t + 10**9))
        self.assertEqual(self.load(), ("v2", 3))


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

    def test_input_changed_just_before_step(self):
        # written within the margin before the step's start: it may have been written after
        # the start with an earlier mtime, so it is not trusted
        t = time.time_ns() - 10**9 + 123  # an mtime as a file system with ns timestamps gives
        os.utime(self.src, ns=(t, t))
        s = self.steps()
        s.record(self.out, ("cc",), [self.src], t + 5 * 10**6, [self.out])
        self.assertFalse(s.fresh(self.out, ("cc",), [self.out]))
        # unless this build wrote it (another step's output): nothing else writes those
        s = x.Steps(self.db, "tools", ours={self.src})
        s.record(self.out, ("cc",), [self.src], t + 5 * 10**6, [self.out])
        self.assertTrue(s.fresh(self.out, ("cc",), [self.out]))
        # a moment later is past the margin
        s = self.steps()
        s.record(self.out, ("cc",), [self.src], t + 10**8, [self.out])
        self.assertTrue(s.fresh(self.out, ("cc",), [self.out]))
        # but not with whole-second timestamps (a coarse file system: FAT dates in 2 s steps)
        t = (time.time_ns() // 10**9 - 5) * 10**9
        os.utime(self.src, ns=(t, t))
        s.record(self.out, ("cc",), [self.src], t + 10**9, [self.out])
        self.assertFalse(s.fresh(self.out, ("cc",), [self.out]))

    def test_mtime_margin(self):
        lag = x.CLOCK_LAG_NS
        self.assertEqual(x.mtime_margin(1000000000123456789), lag + 2)
        self.assertEqual(x.mtime_margin(1000000000120000000), lag + 2 * 10**7)  # exFAT: 10 ms
        self.assertEqual(x.mtime_margin(1000000000000000000), lag + 2 * 10**9)  # whole seconds
        self.assertEqual(x.mtime_margin(0), lag + 2 * 10**9)

    def test_declared_output_never_written(self):
        gone = os.path.join(self.d, "never.txt")
        s = self.steps()
        s.record("script", ("sh",), [self.src], time_ns_later(), [self.out, gone])
        self.assertFalse(s.fresh("script", ("sh",), [self.out, gone]))

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
        db = json.loads(read(self.db))
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

    def test_skip_sdk(self):
        sdk = os.path.join(self.d, "sdk")
        os.mkdir(sdk)
        h = os.path.join(sdk, "UIKit.h")
        write(h, "x")
        s = self.steps()
        s.record(self.out, ("cc",), [self.src, h], time_ns_later(), [self.out], skip=(sdk + "/",))
        self.assertEqual(list(s.db[self.out]["in"]), [self.src])

    def test_forget_marks_files_only(self):
        s = self.steps()
        s.forget(self.out, "script:/t/Script-1.sh", outputs=[self.src])
        self.assertEqual(s.ours, {self.out, self.src})

    def test_prune_keeps_outputs_of_this_build(self):
        # a step renamed (its key changed, not its output): the old record goes, the file stays
        s = self.steps()
        s.record("old-name", ("sh",), [], time_ns_later(), [self.out])
        s.save()
        s = self.steps()
        s.record("new-name", ("sh", "-x"), [], time_ns_later(), [self.out])
        self.assertEqual(s.prune(), [])
        self.assertEqual(list(s.db), ["new-name"])

    def test_prune(self):
        self.recorded()
        s = self.steps()
        s.record("b.o", ("cc", "b.c"), [], time_ns_later(), ["b.o"])
        s.save()
        s = self.steps()
        self.assertTrue(s.fresh(self.out, ("cc", "a.c"), [self.out]))
        self.assertEqual(s.prune(), ["b.o"])
        self.assertEqual(list(s.db), [self.out])

    def test_remove_objects(self):
        objs = os.path.join(self.d, "obj")
        os.mkdir(objs)
        files = [os.path.join(objs, f) for f in ("b.o", "b.o.d", "b.d", "b.swiftdeps", "keep.txt")]
        for f in files:
            write(f, "")
        x.remove_objects([files[0], files[4], self.out], objs)
        self.assertEqual(os.listdir(objs), ["keep.txt"])
        self.assertTrue(os.path.exists(self.out))  # not in that directory

    def test_clean(self):
        self.recorded()
        self.steps().forget("other")
        s = x.Steps(self.db, "tools", clean=True)
        self.assertFalse(s.fresh(self.out, ("cc", "a.c"), [self.out]))
        self.assertFalse(os.path.exists(self.db) or os.path.exists(self.db + ".forget"))


def time_ns_later():
    """A step's start well after the files written now (past the timestamp margin)."""
    return x.RACY_NS + time.time_ns() + 10**9


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
            os.mkdir(os.path.join(d, "lib"))
            write(os.path.join(d, "lib", "libC.a"), "!<arch>\n")
            # lld lists archive members (b.o of libB.a) by bare name, and inputs given by a
            # relative path as given
            write(p, b"\x00lld\x00\x10/o/a.o\x00\x11/missing.a\x00\x10/l/libB.a\x00\x10b.o\x00"
                     b"\x10lib/libC.a\x00\x40/app/App\x00")
            self.assertEqual(x.read_dependency_info(p, d), ["/o/a.o", "/l/libB.a", os.path.join(d, "lib/libC.a")])
            self.assertIsNone(x.read_dependency_info(os.path.join(d, "none.dat"), d))

    def test_xcode_bool(self):
        for v, want in (("0", False), ("1", True), (None, False), ("", False), (True, True), ("YES", True)):
            self.assertEqual(x.xcode_bool(v), want, v)

    def test_hmap_inputs(self):
        cmd = ["clang", "-iquote", "/t/gen.hmap", "-I/t/own.hmap", "-Xcc", "-I/t/all.hmap", "-I/inc"]
        self.assertEqual(x.hmap_inputs(cmd), ["/t/gen.hmap", "/t/own.hmap", "/t/all.hmap"])


class Signals(unittest.TestCase):
    def test_ignored_signal_stays_ignored(self):
        # nohup: SIGHUP ignored before the build starts
        old = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
        try:
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            x.stop_on_signals()
            self.assertIs(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)
            self.assertTrue(callable(signal.getsignal(signal.SIGTERM)))
            with self.assertRaises(SystemExit):
                signal.raise_signal(signal.SIGTERM)
        finally:
            for sig, h in old.items():
                signal.signal(sig, h)


def make_build(root, settings, sources, phases=(), clean=False):
    """A Build of one static library target, Lib, in root (src/, build/), as main() makes
    one from a workspace, without the project reader or the iOS SDK."""
    src = os.path.join(root, "src")
    b = x.Build.__new__(x.Build)
    b.a = types.SimpleNamespace(clean=clean, bundle_id=None)
    b.config, b.clean = "Debug", clean
    b.devdir = os.path.join(root, "Developer")
    b.sdkroot = os.path.join(b.devdir, "SDKs", "iPhoneOS27.0.sdk")
    os.makedirs(b.sdkroot, exist_ok=True)
    b.toolchain = os.path.join(b.devdir, "Toolchains/XcodeDefault.xctoolchain")
    b.toolchain_include = os.path.join(b.toolchain, "usr/include")
    b.derived = os.path.join(root, "build")
    b.build_dir = os.path.join(b.derived, "Build/Products")
    b.obj_root = os.path.join(b.derived, "Build/Intermediates.noindex")
    b.module_cache = os.path.join(b.derived, "ModuleCache.noindex")
    b.step_env = "test tools"
    b.skip = (os.path.join(b.devdir, ""),)
    proj = {"name": "P", "path": os.path.join(src, "P.xcodeproj"), "srcroot": src,
            "project": {"settings": {}}, "header_refs": [], "targets": []}
    t = {"name": "Lib", "type": "com.apple.product-type.library.static", "project": proj, "deps": [],
         "headers": [], "config": {"settings": dict(settings)},
         "phases": list(phases) + [{"isa": "PBXSourcesBuildPhase",
                                    "files": [{"path": os.path.join(src, f)} for f in sources]}]}
    b.ws = src
    b.ours = set()
    b.projects, b.targets, b.all_headers = [proj], {"Lib": t}, {}
    return b


@unittest.skipUnless(shutil.which("clang") and shutil.which("llvm-ar"), "needs clang and llvm-ar on PATH")
class Incremental(unittest.TestCase):
    """Builds with clang through the real compile, archive and record steps (arm64 objects,
    no SDK headers): a step is redone exactly when its inputs changed."""

    SETTINGS = {"HEADER_SEARCH_PATHS": "$(SRCROOT)/include", "GCC_PREPROCESSOR_DEFINITIONS": "VALUE=1",
                "OTHER_CFLAGS": "-isystem $(SRCROOT)/pods/Pod"}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.src = os.path.join(self.root, "src")
        for d in ("include", "pods/Pod"):
            os.makedirs(os.path.join(self.src, d))
        self.put("include/a.h", "#define A 1\n")
        self.put("pods/Pod/pod.h", "#define POD 1\n")  # on an -isystem path
        self.put("a.c", '#include "a.h"\n#include <pod.h>\nint a(void) { return A + POD; }\n')
        self.put("b.c", "int b(void) { return VALUE; }\n")
        self.settings = dict(self.SETTINGS)
        self.sources = ["a.c", "b.c"]
        self.phases = []

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, rel, text):
        """An edit made a while before the next build (one just before it may be redone)."""
        p = os.path.join(self.src, rel)
        write(p, text)
        t = time.time_ns() - 2 * x.RACY_NS
        os.utime(p, ns=(t, t))

    def build(self, clean=False):
        """Builds; returns the objects that were compiled (by name)."""
        before = {o: x.output_sig(self.obj(o)) for o in ("a.o", "b.o")}
        b = make_build(self.root, self.settings, self.sources, self.phases, clean)
        with mock.patch.object(x, "log"):
            b.build_target("Lib")
        return sorted(o for o in before if os.path.exists(self.obj(o)) and x.output_sig(self.obj(o)) != before[o])

    def temp(self, name):
        return os.path.join(self.root, "build/Build/Intermediates.noindex/P.build/Debug-iphoneos/Lib.build", name)

    def obj(self, name):
        return self.temp(os.path.join("Objects-normal/arm64", name))

    def lib(self):
        return os.path.join(self.root, "build/Build/Products/Debug-iphoneos/libLib.a")

    def members(self):
        return subprocess.run(["llvm-ar", "t", self.lib()], capture_output=True, text=True, check=True).stdout.split()

    def test_edit_then_build_at_once(self):
        # an edit made a moment before the build (not backdated) is compiled once, not again
        # by the next build
        self.build()
        write(os.path.join(self.src, "include/a.h"), "#define A 2\n")
        time.sleep(0.1)
        self.assertEqual(self.build(), ["a.o"])
        self.assertEqual(self.build(), [])

    def test_nothing_changed(self):
        self.assertEqual(self.build(), ["a.o", "b.o"])
        lib = x.output_sig(self.lib())
        self.assertEqual(self.build(), [])
        self.assertEqual(self.members(), ["a.o", "b.o"])
        # the archive read objects written just before it: this build's own, so trusted
        self.assertEqual(x.output_sig(self.lib()), lib)

    def test_header_edit(self):
        self.build()
        self.put("include/a.h", "#define A 2\n")
        self.assertEqual(self.build(), ["a.o"])
        self.put("include/a.h", "#define A 2\n")  # same content, new mtime
        self.assertEqual(self.build(), [])

    def test_isystem_header_edit(self):
        self.build()
        self.put("pods/Pod/pod.h", "#define POD 2\n")
        self.assertEqual(self.build(), ["a.o"])

    def test_define_and_flag_change(self):
        self.build()
        self.settings["GCC_PREPROCESSOR_DEFINITIONS"] = "VALUE=2"
        self.assertEqual(self.build(), ["a.o", "b.o"])
        self.settings["GCC_OPTIMIZATION_LEVEL"] = "0"
        self.assertEqual(self.build(), ["a.o", "b.o"])

    def test_clean(self):
        self.build()
        self.assertEqual(self.build(clean=True), ["a.o", "b.o"])

    def test_deleted_source(self):
        self.build()
        os.remove(os.path.join(self.src, "b.c"))
        self.sources = ["a.c"]
        self.assertEqual(self.build(), [])
        self.assertEqual(self.members(), ["a.o"])
        self.assertFalse(os.path.exists(self.obj("b.o")) or os.path.exists(self.obj("b.o.d")))
        steps = json.loads(read(self.temp("xcbuild-steps.json")))
        self.assertNotIn(self.obj("b.o"), steps)

    def killed_after_compile(self):
        """The header goes v1 -> v2, a build compiles a.o and is killed before it saves its
        record, the header goes back to v1. Returns (a clean build's a.o, the next build's)."""
        self.build()
        clean_v1 = read(self.obj("a.o"))
        self.put("include/a.h", "#define A 2\n")
        here = os.path.dirname(os.path.abspath(__file__))
        code = ("import os, sys, json; sys.path.insert(0, %r); import xcbuild as x, test_xcbuild as T\n"
                "x.Build.archive = lambda *a: os._exit(9)\n"  # killed between compile and save
                "b = T.make_build(*json.loads(sys.argv[1]))\n"
                "b.build_target('Lib')\n" % here)
        r = subprocess.run([sys.executable, "-c", code, json.dumps([self.root, self.settings, self.sources])],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 9, r.stdout + r.stderr)
        self.assertNotEqual(read(self.obj("a.o")), clean_v1)
        self.put("include/a.h", "#define A 1\n")
        return clean_v1

    def test_killed_build(self):
        clean_v1 = self.killed_after_compile()
        self.assertEqual(self.build(), ["a.o"])
        self.assertEqual(read(self.obj("a.o")), clean_v1)

    def test_killed_build_output_check_alone(self):
        clean_v1 = self.killed_after_compile()
        journal = self.temp("xcbuild-steps.json.forget")
        os.remove(journal)
        self.build()
        self.assertEqual(read(self.obj("a.o")), clean_v1)

    def test_killed_build_journal_alone(self):
        with mock.patch.object(x, "output_sig", lambda p: "same"):
            clean_v1 = self.killed_after_compile()
            self.build()
        self.assertEqual(read(self.obj("a.o")), clean_v1)

    def test_killed_build_unguarded(self):
        # the case both guard against: without them the stale object stays
        with mock.patch.object(x, "output_sig", lambda p: "same"):
            clean_v1 = self.killed_after_compile()
            os.remove(self.temp("xcbuild-steps.json.forget"))
            self.build()
        self.assertNotEqual(read(self.obj("a.o")), clean_v1)

    def test_script_output_not_written(self):
        # a declared output the script never writes: it runs every build, as in Xcode
        self.put("decl.txt", "declared")
        self.phases = [{"isa": "PBXShellScriptBuildPhase", "name": "Check", "shell": "/bin/sh",
                        "inputs": ["$(SRCROOT)/decl.txt"], "outputs": ["$(DERIVED_FILE_DIR)/never.txt"],
                        "script": "echo run >> runs\n"}]
        self.build()
        self.build()
        self.assertEqual(len(read(os.path.join(self.src, "runs")).splitlines()), 2)

    def test_script_dependency_file(self):
        runs = os.path.join(self.src, "runs")
        self.put("decl.txt", "declared")
        self.put("dep.txt", "listed in the dependency file")
        self.phases = [{"isa": "PBXShellScriptBuildPhase", "name": "Gen", "shell": "/bin/sh", "always": "0",
                        "inputs": ["$(SRCROOT)/decl.txt"], "outputs": ["$(DERIVED_FILE_DIR)/out.txt"],
                        "dependency_file": "$(DERIVED_FILE_DIR)/gen.d",
                        "script": 'echo run >> runs\ncp dep.txt "$DERIVED_FILE_DIR/out.txt"\n'
                                  'echo "$DERIVED_FILE_DIR/out.txt: dep.txt" > "$DERIVED_FILE_DIR/gen.d"\n'}]
        count = lambda: len(read(runs).splitlines())
        self.build()
        self.build()
        self.assertEqual(count(), 1)
        self.put("dep.txt", "changed")
        self.build()
        self.assertEqual(count(), 2)
        os.remove(self.temp("DerivedSources/gen.d"))
        self.build()
        self.assertEqual(count(), 3)
        self.phases[0]["always"] = "1"
        self.build()
        self.assertEqual(count(), 4)


if __name__ == "__main__":
    unittest.main(verbosity=1)
