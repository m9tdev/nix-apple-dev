#!/usr/bin/env python3
"""apple-dev-xcbuild: build an Xcode workspace made by CocoaPods (React Native,
Expo, One) for an iOS device on Linux, the way xcodebuild would.

It reads the projects with the xcodeproj gem (dump-project.rb), resolves build
settings like Xcode (defaults < project < target xcconfig < target), and builds
each target in dependency order:
  - Swift sources: one swiftc invocation per target (module, ObjC header,
    objects), with C++ interop when SWIFT_OBJC_INTEROP_MODE = objcxx;
  - C, ObjC, C++, ObjC++ sources: clang, with Xcode's header maps;
  - static libraries: llvm-ar;
  - resource bundles: copied resources + Info.plist;
  - shell script phases: /bin/sh with every build setting exported;
  - the application: linked with clang + ld64.lld, Info.plist, asset catalog.

usage: xcbuild.py --workspace-dir ios [--configuration Release] [--target T] [--clean|--incremental]

Debug builds are incremental: a step is redone only when its inputs changed. Other
configurations (Release) rebuild every step unless --incremental is given.
"""
import argparse, fcntl, glob, hashlib, json, os, plistlib, re, shlex, shutil, signal, struct, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xcode_version import XCODE_BUILD, XCODE_VERSION_NUMBER

HERE = os.path.dirname(os.path.abspath(__file__))
RUBY = os.environ.get("XCBUILD_RUBY", "ruby")
JOBS = int(os.environ.get("XCBUILD_JOBS", os.cpu_count() or 4))
VERBOSE = bool(os.environ.get("XCBUILD_VERBOSE"))
# Product types this tool builds ("" is an aggregate target: script phases only), and the
# build phases it runs. Frameworks (use_frameworks!), app extensions and Copy Files
# phases are not supported: the build stops instead of leaving them out.
PRODUCT_TYPES = ("", "com.apple.product-type.library.static", "com.apple.product-type.bundle",
                 "com.apple.product-type.application")
PHASES = ("PBXShellScriptBuildPhase", "PBXSourcesBuildPhase", "PBXHeadersBuildPhase",
          "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase")

def log(*a):
    print("[xcbuild]", *a, flush=True)

# ---------------------------------------------------------------- settings

def parse_xcconfig(path, out=None, seen=None):
    """Ordered list of (key, condition, value) from an .xcconfig (with #include)."""
    out = [] if out is None else out
    seen = set() if seen is None else seen
    path = os.path.abspath(path)
    if path in seen or not os.path.exists(path):
        return out
    seen.add(path)
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    for raw in lines:
        line = raw.strip()
        m = re.match(r'#include\??\s+"(.*)"', line)
        if m:
            parse_xcconfig(os.path.join(os.path.dirname(path), m.group(1)), out, seen)
            continue
        line = strip_comment(line)
        m = re.match(r'([A-Za-z0-9_]+)((?:\[[^\]]*\])*)\s*=\s*(.*)$', line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3).strip().rstrip(";").strip()))
    return out

def strip_comment(line):
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q: q = None
        elif c in "\"'":
            q = c
        elif line.startswith("//", i):
            return line[:i].strip()
    return line

def cond_ok(cond, ctx):
    for c in re.findall(r'\[([^\]]*)\]', cond):
        for part in c.split(","):
            k, _, v = part.partition("=")
            have = ctx.get(k.strip(), "")
            if not glob_match(v.strip(), have):
                return False
    return True

def glob_match(pat, s):
    import fnmatch
    return fnmatch.fnmatchcase(s, pat)

def as_str(v):
    if isinstance(v, list):
        return " ".join(v)
    return "" if v is None else str(v)

class Settings:
    """Layered build settings; $(inherited) refers to the layer below."""

    def __init__(self, ctx):
        self.ctx = ctx          # condition context: sdk, arch, config
        self.vals = {}          # key -> raw (inherited already substituted)

    def layer(self, items):
        """items: iterable of (key, cond, value) in file order."""
        base = dict(self.vals)
        new = {}
        conds = []
        for k, cond, v in items:
            if cond:
                conds.append((k, cond, v))
            else:
                new[k] = v
        for k, cond, v in conds:  # conditional values win over plain ones
            if cond_ok(cond, self.ctx):
                new[k] = v
        for k, v in new.items():
            v = as_str(v)
            inh = base.get(k, "")
            v = re.sub(r'\$\(inherited\)|\$\{inherited\}', lambda _: inh, v)
            self.vals[k] = v

    def layer_dict(self, d):
        items = []
        for k, v in (d or {}).items():
            m = re.match(r'([A-Za-z0-9_]+)((?:\[[^\]]*\])*)$', k)
            if m:
                items.append((m.group(1), m.group(2), v))
        self.layer(items)

    def set(self, k, v):
        self.vals[k] = v

    def raw(self, k, default=""):
        return self.vals.get(k, default)

    def get(self, k, default=""):
        if k not in self.vals:
            return default
        return self.expand(self.vals[k])

    def expand(self, s, depth=0):
        if depth > 40:
            return s
        def rep(m):
            body = m.group(1) or m.group(2)
            name, *mods = body.split(":")
            if name == "inherited":
                return ""
            v = self.expand(self.vals.get(name, os.environ.get(name, "") if name in ("HOME", "USER", "PATH") else ""), depth + 1)
            for mod in mods:
                v = apply_mod(v, mod)
            return v
        prev = None
        while prev != s:
            prev = s
            s = re.sub(r'\$\(([^()]*)\)|\$\{([^{}]*)\}', rep, s)
        return s

    def words(self, k):
        return [w for w in split_words(self.get(k)) if w != ""]

    def yes(self, k, default="NO"):
        return self.get(k, default).strip().upper() in ("YES", "TRUE", "1")

def apply_mod(v, mod):
    if mod == "rfc1034identifier":
        return re.sub(r'[^A-Za-z0-9.-]', "-", v)
    if mod == "c99extidentifier" or mod == "identifier":
        v = re.sub(r'[^A-Za-z0-9_]', "_", v)
        return "_" + v if v[:1].isdigit() else v
    if mod == "lower":
        return v.lower()
    if mod == "upper":
        return v.upper()
    if mod == "dir":
        return os.path.dirname(v) + "/"
    if mod == "file":
        return os.path.basename(v)
    if mod == "base":
        return os.path.splitext(os.path.basename(v))[0]
    if mod == "suffix":
        return os.path.splitext(v)[1]
    if mod == "standardizepath":
        return os.path.normpath(v)
    if mod.startswith("default="):
        return v or mod[len("default="):]
    return v

def split_words(s):
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()

# ---------------------------------------------------------------- header maps

def write_hmap(path, mapping):
    """Apple header map: key (case-insensitive) -> prefix + suffix."""
    strings = bytearray(b"\0")
    offs = {}
    def sidx(s):
        if s not in offs:
            offs[s] = len(strings)
            strings.extend(s.encode() + b"\0")
        return offs[s]
    n = 1
    while n < max(1, len(mapping)) * 2:
        n <<= 1
    buckets = [(0, 0, 0)] * n
    maxlen = 0
    for key, val in mapping.items():
        h = sum(ord(c.lower()) * 13 for c in key) & (n - 1)
        while buckets[h][0]:
            h = (h + 1) & (n - 1)
        d, b = os.path.split(val)
        buckets[h] = (sidx(key), sidx(d + "/"), sidx(b))
        maxlen = max(maxlen, len(val))
    header_size = 24
    string_off = header_size + 12 * n
    # magic 'pmap' as a native (little-endian) uint32: the file starts with "pamh"
    data = struct.pack("<IHHIIII", 0x686D6170, 1, 0, string_off, len(mapping), n, maxlen)
    for b in buckets:
        data += struct.pack("<III", *b)
    data += bytes(strings)
    write_if_changed(path, data)

def write_if_changed(path, data):
    """Leave a file that already has these bytes alone (no new mtime for the next build)."""
    try:
        with open(path, "rb") as f:
            if f.read() == data:
                return
    except OSError:
        pass
    with open(path, "wb") as f:
        f.write(data)

# ---------------------------------------------------------------- up-to-date checks

_digests = {}
_digests_lock = threading.Lock()
RACY_NS = 2 * 10**9

def file_digest(p):
    """sha256 of a regular file's content, or None (missing, a directory...)."""
    try:
        st = os.stat(p)
    except OSError:
        return None
    if not os.path.isfile(p):
        return None
    # memoized by mtime and size, except for a file modified just now (it may change again
    # within the same timestamp tick)
    k = (p, st.st_mtime_ns, st.st_size)
    memo = time.time_ns() - st.st_mtime_ns > RACY_NS
    with _digests_lock:
        if memo and k in _digests:
            return _digests[k]
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if memo:
        with _digests_lock:
            _digests[k] = h.hexdigest()
    return h.hexdigest()

def read_depfile(path):
    """Prerequisites in a Makefile-style depfile (clang -MD, swiftc -emit-dependencies),
    every rule in it; None if there is no depfile."""
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            txt = f.read()
    except OSError:
        return None
    out = []
    for line in txt.replace("\\\n", " ").splitlines():
        m = re.match(r"(?:\\.|[^\\])*?:(?:\s|$)", line)
        if not m:
            continue
        for tok in re.findall(r"(?:\\.|[^\s\\])+", line[m.end():]):
            out.append(re.sub(r"\\(.)", r"\1", tok.replace("$$", "$")))
    return out

def read_dependency_info(path, cwd):
    """Input files in an ld64 -dependency_info file (records: opcode byte, NUL-terminated
    path; 0x10 = input file), or None. cwd: the linker's, for relative paths."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    out = []
    for rec in data.split(b"\0"):
        if rec[:1] != b"\x10":
            continue
        p = os.fsdecode(rec[1:])
        if not os.path.isabs(p):
            # lld also lists each archive member it loaded by its bare name (b.o of libB.a),
            # with the archive itself listed by its path: a relative name that is no file
            # here is such a member, not an input to track
            p = os.path.join(cwd, p)
            if not os.path.isfile(p):
                continue
        out.append(p)
    return out

def output_sig(p):
    """What identifies a step's output as the one it wrote: a regular file's mtime, size and
    inode (a file written again by a later, interrupted run of the step differs); "dir" for
    a directory; None if missing."""
    try:
        st = os.stat(p)
    except OSError:
        return None
    if os.path.isdir(p):
        return "dir"
    return [st.st_mtime_ns, st.st_size, st.st_ino]

class Steps:
    """Up-to-date checks for a target's build steps, as Xcode's build system does: a step
    is skipped when its command line is the same, its outputs are the files it wrote and
    none of its inputs changed. An input counts as changed when its content changed, so a
    file rewritten or copied with the same bytes (header maps, generated headers) does not
    rebuild anything.

    A build that is killed must not leave an output that a later build takes for up to
    date. Two safeguards, each enough on its own: a step about to run is written to a
    journal (path + ".forget") before it starts, and the record is read back without it;
    and an output that is not the file the step wrote (other mtime, size or inode) makes
    the step run again."""

    def __init__(self, path, env, clean=False, ours=None):
        self.path = path
        self.journal = path + ".forget"
        self.env = env        # tools, SDK and this script: a new toolchain rebuilds everything
        self.lock = threading.Lock()
        self.seen = set()     # steps of this build, to prune the others
        # files this build wrote or found up to date as a step's output (in any target), and
        # header maps: nothing else writes them while it runs
        self.ours = set() if ours is None else ours
        self.db = {}
        if clean:
            for f in (path, self.journal):
                if os.path.exists(f):
                    os.remove(f)
            return
        try:
            with open(path) as f:
                self.db = json.load(f)
        except (OSError, ValueError):
            pass
        try:
            with open(self.journal, encoding="utf-8", errors="surrogateescape") as f:
                for line in f.read().splitlines():
                    self.db.pop(line, None)
        except OSError:
            pass

    def key(self, cmd, cwd=None):
        h = hashlib.sha256()
        for x in [self.env, cwd or ""] + list(cmd):
            h.update(x.encode("utf-8", "surrogateescape") + b"\0")
        return h.hexdigest()

    def fresh(self, key, cmd, outputs, cwd=None):
        """key: the step's name in the record (its main output); outputs: files it writes."""
        now = time.time_ns()
        with self.lock:
            self.seen.add(key)
            rec = self.db.get(key)
        if not rec or rec["cmd"] != self.key(cmd, cwd):
            return False
        outs = rec.get("out") or {}
        if sorted(outs) != sorted(outputs):
            return False
        for o in outputs:
            # a declared output the step didn't write: it runs every time, as in Xcode
            sig = output_sig(o)
            if sig is None or sig != outs[o]:
                return False
        # mtime and size are trusted only for files older than the record by more than the
        # file system's timestamp granularity; a newer one may have changed within the same tick
        racy = rec.get("at", 0) - RACY_NS
        rehashed = False
        for p, (mtime, size, d) in list(rec["in"].items()):
            try:
                st = os.stat(p)
            except OSError:
                return False
            if (st.st_mtime_ns, st.st_size) == (mtime, size) and d and mtime < racy:
                continue
            if file_digest(p) != d:
                return False
            rehashed = True
            with self.lock:
                rec["in"][p] = [st.st_mtime_ns, st.st_size, d]
        if rehashed:
            # the inputs are checked as of now: an input rehashed with the same content is
            # trusted by mtime once it is older than this check, not hashed every build
            with self.lock:
                rec["at"] = now
        with self.lock:
            self.ours.update(outputs)
        return True

    def record(self, key, cmd, inputs, since, outputs, cwd=None, skip=()):
        """inputs: the files the step read; since: when it started (time.time_ns()). An input
        modified after that may not be in the output, so the step runs again next time; so
        does one modified within the timestamp margin before it (a write just after the
        start may get an earlier mtime), unless this build wrote it.
        outputs: the files it wrote; skip: path prefixes not to record (the SDK and the
        toolchain, which the record's env identifies)."""
        ins = {}
        for p in inputs:
            p = os.path.join(cwd, p) if cwd and not os.path.isabs(p) else p
            if skip and p.startswith(skip):
                continue
            try:
                st = os.stat(p)
            except OSError:
                ins[p] = [0, 0, ""]
                continue
            settled = st.st_mtime_ns < since - RACY_NS or (p in self.ours and st.st_mtime_ns < since)
            d = file_digest(p) if settled else None
            ins[p] = [st.st_mtime_ns, st.st_size, d or ""]
        outs = {o: output_sig(o) for o in outputs}
        with self.lock:
            self.ours.update(outputs)
            self.seen.add(key)
            self.db[key] = {"cmd": self.key(cmd, cwd), "in": ins, "out": outs, "at": time.time_ns()}

    def forget(self, *keys, outputs=()):
        """Steps about to run: out of the record, here and on disk, before they start.
        outputs: theirs besides the keys (which name the main ones)."""
        with self.lock:
            self.ours.update(keys)
            self.ours.update(outputs)
            for k in keys:
                self.seen.add(k)
                self.db.pop(k, None)
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.journal, "a", encoding="utf-8", errors="surrogateescape") as f:
                f.write("".join(k + "\n" for k in keys))

    def outputs(self, key):
        with self.lock:
            return list((self.db.get(key) or {}).get("out") or {})

    def prune(self):
        """Drop the steps this build didn't have (a removed source); returns their outputs,
        but not those that a step of this build has (its name changed, not its output)."""
        with self.lock:
            gone = [k for k in self.db if k not in self.seen]
            return [o for k in gone for o in self.db.pop(k).get("out") or {}
                    if o not in self.ours and o not in self.seen]

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with self.lock:
            with open(tmp, "w") as f:
                json.dump(self.db, f)
            os.replace(tmp, self.path)
            # after the record: a kill in between leaves the journal, which only reruns steps
            if os.path.exists(self.journal):
                os.remove(self.journal)

def hmap_inputs(cmd):
    """The header maps a compile reads (they decide which header an #include finds)."""
    out = []
    for x in cmd:
        p = x[2:] if x.startswith("-I") else x
        if p.endswith(".hmap"):
            out.append(p)
    return out

HEADER_EXT = (".h", ".hh", ".hpp", ".hxx", ".pch", ".inl", ".ipp", ".tcc", ".def")
SRC_LANG = {
    ".c": "c", ".m": "objective-c", ".mm": "objective-c++", ".cpp": "c++", ".cc": "c++",
    ".cxx": "c++", ".c++": "c++", ".s": "assembler-with-cpp", ".S": "assembler-with-cpp",
}

# ---------------------------------------------------------------- the build

class Build:
    def __init__(self, a):
        self.a = a
        self.ws = os.path.abspath(a.workspace_dir)
        self.config = a.configuration
        self.clean = a.clean
        self.ours = set()  # see Steps.ours
        self.sdkroot = a.sdk
        self.devdir = a.developer_dir
        self.toolchain = os.path.join(self.devdir, "Toolchains/XcodeDefault.xctoolchain")
        self.derived = os.path.abspath(a.derived_data)
        self.build_dir = os.path.join(self.derived, "Build/Products")
        self.obj_root = os.path.join(self.derived, "Build/Intermediates.noindex")
        self.module_cache = os.path.join(self.derived, "ModuleCache.noindex")
        # Xcode's toolchain usr/include (<swift/bridging>: SWIFT_COMPUTED_PROPERTY, SWIFT_NAME...)
        # is on every compile's search path; the SDK bundle has none, swift.org's toolchain has it.
        swiftc = shutil.which("swiftc")
        if not swiftc:
            raise SystemExit("xcbuild: swiftc is not on PATH; run apple-dev-xcbuild inside apple-dev")
        self.toolchain_include = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(swiftc)), "../include"))
        # what every step depends on besides its command line: the resolved tools and SDK
        # (paths like ~/.swiftpm/... stay the same when the SDK behind them changes) and this script
        tools = [shutil.which(x) or x for x in ("swiftc", "clang", "llvm-ar")]
        self.step_env = "\n".join([os.path.realpath(x) for x in tools + [self.sdkroot, self.devdir]]
                                  + [file_digest(os.path.abspath(__file__)) or ""])
        # Headers there (the SDK, clang's own headers) are not recorded as a step's inputs: the
        # env above identifies them, and an object's record would otherwise list a thousand
        # SDK headers.
        resource_dir = shutil.which("clang") and subprocess.run(
            ["clang", "-print-resource-dir"], stdout=subprocess.PIPE, text=True).stdout.strip()
        self.skip = tuple(sorted({os.path.join(q, "") for p in (self.devdir, self.sdkroot, resource_dir, self.toolchain_include)
                                  if p for q in (os.path.abspath(p), os.path.realpath(p))}))
        self.projects = []
        self.targets = {}
        for proj in sorted(glob.glob(os.path.join(self.ws, "*.xcodeproj"))) + sorted(glob.glob(os.path.join(self.ws, "Pods/*.xcodeproj"))):
            self.load(proj)
        self.all_headers = {}
        for t in self.targets.values():
            for f in t["headers"]:
                self.all_headers.setdefault(os.path.basename(f), f)

    def load(self, proj):
        cache = os.path.join(self.derived, "projects", "%s.%s.json" % (os.path.basename(proj), self.config))
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        pbx = os.path.join(proj, "project.pbxproj")
        # read again when the project or the reader changed
        dumper = os.path.join(HERE, "dump-project.rb")
        if not os.path.exists(cache) or os.path.getmtime(cache) < max(os.path.getmtime(pbx), os.path.getmtime(dumper)):
            tmp = cache + ".tmp"
            try:
                with open(tmp, "w") as f:
                    r = subprocess.run([RUBY, dumper, proj, self.config], stdout=f)
                if r.returncode != 0:
                    raise SystemExit("xcbuild: reading %s failed (dump-project.rb exited %d)" % (proj, r.returncode))
                os.replace(tmp, cache)
            finally:
                if os.path.exists(tmp):
                    os.remove(tmp)
        with open(cache) as f:
            d = json.load(f)
        self.projects.append(d)
        for t in d["targets"]:
            t["project"] = d
            t["headers"] = [f["path"] for ph in t["phases"] if ph["isa"] == "PBXHeadersBuildPhase" for f in ph["files"] if f.get("path")]
            if t["name"] in self.targets:
                raise SystemExit("duplicate target " + t["name"])
            self.targets[t["name"]] = t

    # -- settings
    def settings(self, t):
        if "_s" in t:
            return t["_s"]
        p = t["project"]
        sdk_version = os.path.basename(os.path.realpath(self.sdkroot))
        m = re.search(r'(\d+\.\d+)', sdk_version)
        sdkv = m.group(1) if m else "27.0"
        s = Settings({"sdk": "iphoneos" + sdkv, "arch": "arm64", "config": self.config, "variant": "normal"})
        tt = os.path.join(self.obj_root, p["name"] + ".build", self.config + "-iphoneos", t["name"] + ".build")
        defaults = {
            "ACTION": "build", "ARCHS": "arm64", "CURRENT_ARCH": "arm64", "NATIVE_ARCH": "arm64",
            "arch": "arm64", "CURRENT_VARIANT": "normal", "variant": "normal",
            "PLATFORM_NAME": "iphoneos", "EFFECTIVE_PLATFORM_NAME": "-iphoneos",
            "SDK_NAME": "iphoneos" + sdkv, "SDK_VERSION": sdkv, "SDKROOT": self.sdkroot, "SDK_DIR": self.sdkroot,
            "PLATFORM_DIR": os.path.join(self.devdir, "Platforms/iPhoneOS.platform"),
            "PLATFORM_DEVELOPER_BIN_DIR": os.path.join(self.devdir, "Platforms/iPhoneOS.platform/Developer/usr/bin"),
            "DEVELOPER_DIR": self.devdir, "DEVELOPER_BIN_DIR": os.path.join(self.devdir, "usr/bin"),
            "TOOLCHAIN_DIR": self.toolchain, "DT_TOOLCHAIN_DIR": self.toolchain,
            "CONFIGURATION": self.config, "BUILD_DIR": self.build_dir, "SYMROOT": self.build_dir,
            "BUILD_ROOT": self.build_dir, "OBJROOT": self.obj_root, "PROJECT_TEMP_ROOT": self.obj_root,
            "CONFIGURATION_BUILD_DIR": "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
            "BUILT_PRODUCTS_DIR": "$(CONFIGURATION_BUILD_DIR)", "TARGET_BUILD_DIR": "$(CONFIGURATION_BUILD_DIR)",
            "PROJECT_TEMP_DIR": os.path.join(self.obj_root, p["name"] + ".build"),
            "CONFIGURATION_TEMP_DIR": os.path.join(self.obj_root, p["name"] + ".build", self.config + "-iphoneos"),
            "TARGET_TEMP_DIR": tt, "TEMP_DIR": tt, "TEMP_FILES_DIR": tt,
            "DERIVED_FILE_DIR": tt + "/DerivedSources", "DERIVED_FILES_DIR": tt + "/DerivedSources",
            "DERIVED_SOURCES_DIR": tt + "/DerivedSources",
            "OBJECT_FILE_DIR": tt + "/Objects", "OBJECT_FILE_DIR_normal": tt + "/Objects-normal",
            "MODULE_CACHE_DIR": self.module_cache,
            "PROJECT_NAME": p["name"], "PROJECT": p["name"], "PROJECT_DIR": p["srcroot"], "SRCROOT": p["srcroot"],
            "SOURCE_ROOT": p["srcroot"], "PROJECT_FILE_PATH": p["path"],
            "TARGET_NAME": t["name"], "TARGETNAME": t["name"], "PRODUCT_NAME": "$(TARGET_NAME)",
            "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
            "DEVELOPMENT_LANGUAGE": "en", "GCC_OPTIMIZATION_LEVEL": "s", "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule", "CLANG_CXX_LIBRARY": "libc++",
            "GCC_C_LANGUAGE_STANDARD": "gnu11", "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14",
            "USE_HEADERMAP": "YES", "HEADERMAP_INCLUDES_PROJECT_HEADERS": "YES",
            "ALWAYS_SEARCH_USER_PATHS": "NO", "ENABLE_BITCODE": "NO", "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO", "EXPANDED_CODE_SIGN_IDENTITY": "", "COMPILER_INDEX_STORE_ENABLE": "NO",
            "XCODE_VERSION_MAJOR": XCODE_VERSION_NUMBER, "XCODE_VERSION_MINOR": XCODE_VERSION_NUMBER,
            "XCODE_VERSION_ACTUAL": XCODE_VERSION_NUMBER, "XCODE_PRODUCT_BUILD_VERSION": XCODE_BUILD, "DEPLOYMENT_TARGET_SETTING_NAME": "IPHONEOS_DEPLOYMENT_TARGET",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.1", "TARGETED_DEVICE_FAMILY": "1,2", "VALID_ARCHS": "arm64",
            "SWIFT_VERSION": "5.0", "SWIFT_PLATFORM_TARGET_PREFIX": "ios", "LLVM_TARGET_TRIPLE_VENDOR": "apple",
            "LLVM_TARGET_TRIPLE_OS_VERSION": "ios$(IPHONEOS_DEPLOYMENT_TARGET)",
            "CORRESPONDING_SIMULATOR_PLATFORM_NAME": "iphonesimulator", "DWARF_DSYM_FOLDER_PATH": "$(CONFIGURATION_BUILD_DIR)",
            "USER": os.environ.get("USER", "user"), "HOME": os.environ.get("HOME", "/"),
            "INSTALL_PATH": "", "SKIP_INSTALL": "NO", "PODS_PODFILE_DIR_PATH": "", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "INFOPLIST_OUTPUT_FORMAT": "binary", "PLIST_FILE_OUTPUT_FORMAT": "binary", "STRINGS_FILE_OUTPUT_ENCODING": "binary",
            "OTHER_CPLUSPLUSFLAGS": "$(OTHER_CFLAGS)",  # Xcode's default: C++ inherits the C flags
            "ENABLE_PREVIEWS": "NO", "SWIFT_EMIT_LOC_STRINGS": "NO", "GCC_PRECOMPILE_PREFIX_HEADER": "NO",
        }
        s.layer_dict(defaults)
        s.layer_dict(p["project"]["settings"])
        if t["config"].get("xcconfig"):
            s.layer(parse_xcconfig(t["config"]["xcconfig"]))
        s.layer_dict(t["config"]["settings"])
        # Xcode resolves an SDK name (SDKROOT = iphoneos) to the SDK's path
        if not os.path.isabs(s.get("SDKROOT")):
            s.set("SDKROOT", self.sdkroot)
        typ = t["type"]
        pn = s.get("PRODUCT_NAME")
        if typ.endswith("library.static"):
            fp = "lib%s.a" % pn
            s.set("EXECUTABLE_NAME", fp); s.set("FULL_PRODUCT_NAME", fp); s.set("EXECUTABLE_PATH", fp)
            s.set("EXECUTABLE_PREFIX", "lib"); s.set("EXECUTABLE_SUFFIX", ".a")
        elif typ.endswith("bundle") or typ.endswith("application"):
            ext = s.get("WRAPPER_EXTENSION") or ("app" if typ.endswith("application") else "bundle")
            wrap = "%s.%s" % (pn, ext)
            s.set("WRAPPER_EXTENSION", ext); s.set("WRAPPER_NAME", wrap); s.set("FULL_PRODUCT_NAME", wrap)
            s.set("CONTENTS_FOLDER_PATH", wrap); s.set("UNLOCALIZED_RESOURCES_FOLDER_PATH", wrap)
            s.set("EXECUTABLE_FOLDER_PATH", wrap); s.set("EXECUTABLE_NAME", pn)
            s.set("EXECUTABLE_PATH", wrap + "/" + pn); s.set("INFOPLIST_PATH", wrap + "/Info.plist")
            s.set("FRAMEWORKS_FOLDER_PATH", wrap + "/Frameworks"); s.set("PLUGINS_FOLDER_PATH", wrap + "/PlugIns")
            s.set("PRODUCT_TYPE", typ)
        t["_s"] = s
        return s

    # -- order
    def order(self, names):
        out, seen = [], set()
        def visit(n, stack=()):
            if n in seen or n not in self.targets:
                return
            if n in stack:
                return
            for d in self.targets[n]["deps"] + self.implicit_deps(n):
                visit(d, stack + (n,))
            seen.add(n)
            out.append(n)
        for n in names:
            visit(n)
        return out

    def implicit_deps(self, n):
        """Xcode's implicit dependencies: a linked product built by another target (lib<X>.a)."""
        if not hasattr(self, "_products"):
            self._products = {}
            for name, t in self.targets.items():
                s = self.settings(t)
                if s.get("FULL_PRODUCT_NAME"):
                    self._products[s.get("FULL_PRODUCT_NAME")] = name
        out = []
        for ph in self.targets[n]["phases"]:
            if ph["isa"] == "PBXFrameworksBuildPhase":
                for f in ph["files"]:
                    bp = os.path.basename(f.get("built_product") or f.get("path") or "")
                    if bp in self._products and self._products[bp] != n:
                        out.append(self._products[bp])
        return out

    def run(self, cmd, cwd=None, env=None, quiet=False):
        if VERBOSE:
            log("$", " ".join(shlex.quote(c) for c in cmd))
        r = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        if r.returncode != 0:
            full = os.path.join(self.derived, "last-failure.log")
            with open(full, "w") as f:
                f.write(" ".join(shlex.quote(c) for c in cmd) + "\n\n" + r.stdout)
            log("full output in", full)
            sys.stdout.write(r.stdout[-20000:])
            raise SystemExit("command failed (%d): %s" % (r.returncode, " ".join(shlex.quote(c) for c in cmd)[:3000]))
        if r.stdout and not quiet and VERBOSE:
            sys.stdout.write(r.stdout[-4000:])
        return r.stdout

    # -- scripts
    def script_env(self, t, s):
        env = dict(os.environ)
        for k in list(s.vals):
            env[k] = s.get(k)
        env["PATH"] = os.environ["PATH"]
        env["SCRIPT_INPUT_FILE_COUNT"] = "0"
        env["SCRIPT_OUTPUT_FILE_COUNT"] = "0"
        return env

    def linux_host_tools(self, s):
        """Pods ship some host tools as macOS binaries. Swap in the Linux build of the
        same version, so script phases that call them by path work:
          - hermes-engine/destroot/bin/hermesc <- node_modules/hermes-compiler linux64-bin
            (only if both have the same version, so bytecode matches the Hermes VM)."""
        pods = s.get("PODS_ROOT") or os.path.join(self.ws, "Pods")
        hc = os.path.join(pods, "hermes-engine/destroot/bin/hermesc")
        if not os.path.exists(hc) or os.path.islink(hc):
            return
        if open(hc, "rb").read(4) not in (b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe"):
            return
        m = re.search(r"hermes-engine \(([^)]+)\)", open(os.path.join(pods, "Manifest.lock")).read())
        npm = os.path.join(self.ws, "..", "node_modules/hermes-compiler")
        lin = os.path.join(npm, "hermesc/linux64-bin/hermesc")
        ver = json.load(open(os.path.join(npm, "package.json")))["version"] if os.path.exists(lin) else None
        if not m or ver != m.group(1):
            raise SystemExit("hermesc: pod hermes-engine %s, npm hermes-compiler %s: need the same version for Linux"
                             % (m and m.group(1), ver))
        os.rename(hc, hc + ".macos")
        os.symlink(os.path.abspath(lin), hc)
        log("  hermesc: using the Linux build of hermes-compiler %s" % ver)

    def run_script(self, t, s, ph):
        name = ph.get("name") or "Run Script"
        self.linux_host_tools(s)
        env = self.script_env(t, s)
        for kind, key in (("inputs", "INPUT"), ("outputs", "OUTPUT")):
            files = [s.expand(x) for x in ph.get(kind) or []]
            env["SCRIPT_%s_FILE_COUNT" % key] = str(len(files))
            for i, f in enumerate(files):
                env["SCRIPT_%s_FILE_%d" % (key, i)] = f
        for kind, key in (("input_lists", "INPUT"), ("output_lists", "OUTPUT")):
            files = [s.expand(x) for x in ph.get(kind) or []]
            env["SCRIPT_%s_FILE_LIST_COUNT" % key] = str(len(files))
            for i, f in enumerate(files):
                env["SCRIPT_%s_FILE_LIST_%d" % (key, i)] = f
        for f in [s.expand(x) for x in ph.get("outputs") or []]:
            os.makedirs(os.path.dirname(f), exist_ok=True)
        tmp = os.path.join(s.get("TARGET_TEMP_DIR"), "Script-%s.sh" % hashlib.sha1(name.encode()).hexdigest()[:10])
        os.makedirs(os.path.dirname(tmp), exist_ok=True)
        shell = ph.get("shell") or "/bin/sh"
        with open(tmp, "w") as f:
            f.write("#!%s\n%s\n" % (shell, ph.get("script") or ""))
        # Like Xcode, a script that declares its inputs and outputs (files or file lists)
        # runs only when an input changed or an output is missing; one without either, or
        # marked "based on dependency analysis" off, runs every time. A dependency file it
        # declares (Makefile style, written by the script) adds the inputs listed there.
        ins, outs = self.script_files(s, ph, "inputs", "input_lists"), self.script_files(s, ph, "outputs", "output_lists")
        cwd = s.get("SRCROOT")
        depfile = s.expand(ph.get("dependency_file") or "")
        depfile = os.path.join(cwd, depfile) if depfile else None
        key = None
        if ins and outs and not xcode_bool(ph.get("always")):
            key = "script:" + tmp
            sig = [shell, ph.get("script") or ""] + ins + ["->"] + outs + ["depfile", depfile or ""] \
                + ["%s=%s" % (k, s.get(k)) for k in sorted(s.vals)]
            if self.steps.fresh(key, sig, outs + ([depfile] if depfile else [])):
                log("  script: %s (up to date)" % name)
                return
            self.steps.forget(key, outputs=outs + ([depfile] if depfile else []))
        log("  script: %s" % name)
        since = time.time_ns()
        shell_argv = shlex.split(shell)
        self.run(shell_argv + [tmp], cwd=cwd, env=env)
        if key:
            found = read_depfile(depfile) if depfile else []
            if found is None:
                log("  warning: %s wrote no dependency file %s; it runs again next build" % (name, depfile))
                return
            found = [os.path.join(cwd, p) for p in found]
            self.steps.record(key, sig, ins + found, since, outs + ([depfile] if depfile else []))

    def script_files(self, s, ph, kind, lists):
        """A script phase's declared files: the paths and the paths in its .xcfilelist files
        (with the lists themselves, for inputs); None if a list can't be read."""
        out = [s.expand(x) for x in ph.get(kind) or []]
        for lst in [s.expand(x) for x in ph.get(lists) or []]:
            try:
                with open(lst) as f:
                    lines = f.read().splitlines()
            except OSError:
                return None
            if kind == "inputs":
                out.append(lst)
            out += [s.expand(l.strip()) for l in lines if l.strip() and not l.strip().startswith("#")]
        return out

    # -- compile
    def search_flags(self, t, s):
        # Same for every source of a target: build (and write its header maps) once.
        memo = getattr(self, "_search_flags", None)
        if memo and memo[0] is t and memo[1] is s:
            return list(memo[2])
        flags = self._search_flags_uncached(t, s)
        self.ours.update(hmap_inputs(flags))  # written above
        self._search_flags = (t, s, flags)
        return list(flags)

    def _search_flags_uncached(self, t, s):
        flags = []
        tt = s.get("TARGET_TEMP_DIR")
        bpd = s.get("BUILT_PRODUCTS_DIR")
        if s.yes("USE_HEADERMAP", "YES"):
            os.makedirs(tt, exist_ok=True)
            own = {}
            pn = s.get("PRODUCT_NAME")
            for h in t["headers"]:
                b = os.path.basename(h)
                own.setdefault(b, h)
                own.setdefault(pn + "/" + b, h)
            write_hmap(tt + "/%s-own-target-headers.hmap" % pn, own)
            write_hmap(tt + "/%s-generated-files.hmap" % pn, {})
            allh = dict(self.all_headers) if s.yes("HEADERMAP_INCLUDES_PROJECT_HEADERS", "YES") else {}
            write_hmap(tt + "/%s-all-non-framework-target-headers.hmap" % pn, allh)
            # project headers: every header file reference in the target's project (Xcode's
            # HEADERMAP_INCLUDES_PROJECT_HEADERS), own target headers first
            proj = {}
            for h in t["headers"] + t["project"].get("header_refs", []):
                proj.setdefault(os.path.basename(h), h)
            write_hmap(tt + "/%s-project-headers.hmap" % pn, proj)
            flags += ["-iquote", tt + "/%s-generated-files.hmap" % pn,
                      "-I" + tt + "/%s-own-target-headers.hmap" % pn,
                      "-I" + tt + "/%s-all-non-framework-target-headers.hmap" % pn,
                      "-iquote", tt + "/%s-project-headers.hmap" % pn]
        flags += ["-I" + bpd + "/include"]
        for p in s.words("HEADER_SEARCH_PATHS"):
            for q in expand_recursive(p):
                flags.append("-I" + q)
        for p in s.words("USER_HEADER_SEARCH_PATHS"):
            for q in expand_recursive(p):
                flags += ["-iquote", q]
        dsd = s.get("DERIVED_FILE_DIR")
        flags += ["-I" + dsd + "/arm64", "-I" + dsd + "/", "-I" + dsd]
        flags += ["-F" + bpd]
        flags += ["-isystem", self.toolchain_include]
        for p in s.words("FRAMEWORK_SEARCH_PATHS"):
            for q in expand_recursive(p):
                flags.append("-F" + q)
        return flags

    def defines(self, s):
        d = s.words("GCC_PREPROCESSOR_DEFINITIONS")
        if not s.yes("ENABLE_NS_ASSERTIONS", "YES"):
            d.append("NS_BLOCK_ASSERTIONS=1")
        return d

    def triple(self, s):
        return "arm64-apple-ios" + s.get("IPHONEOS_DEPLOYMENT_TARGET")

    def clang_flags(self, t, s, lang, extra=()):
        f = ["-x", lang, "-target", self.triple(s), "-isysroot", self.sdkroot,
             "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0",
             "-fno-color-diagnostics", "-Wno-trigraphs", "-Wno-missing-field-initializers",
             "-Wno-unknown-warning-option", "-fpascal-strings", "-fstrict-aliasing", "-g",
             "-O" + s.get("GCC_OPTIMIZATION_LEVEL", "s")]
        cxx = lang in ("c++", "objective-c++")
        objc = lang.startswith("objective-c")
        if cxx:
            f += ["-std=" + s.get("CLANG_CXX_LANGUAGE_STANDARD", "gnu++14"), "-stdlib=" + s.get("CLANG_CXX_LIBRARY", "libc++")]
            # Upstream clang enables C++20 named modules with -std=c++20; with the pods' module
            # maps that turns textual headers into required modules ("needed but not provided",
            # redefinitions). Xcode's clang builds these pods without them.
            f.append("-fno-cxx-modules")
        elif lang != "assembler-with-cpp":
            f += ["-std=" + s.get("GCC_C_LANGUAGE_STANDARD", "gnu11")]
        if objc and s.yes("CLANG_ENABLE_OBJC_ARC"):
            f.append("-fobjc-arc")
        if objc and s.yes("CLANG_ENABLE_OBJC_WEAK"):
            f.append("-fobjc-weak")
        # Xcode: Clang modules for C, ObjC and ObjC++ sources; plain C++ gets none.
        if s.yes("CLANG_ENABLE_MODULES") and lang in ("c", "objective-c", "objective-c++"):
            f += ["-fmodules", "-fmodules-cache-path=" + self.module_cache, "-fmodules-prune-interval=86400",
                  "-fmodules-prune-after=345600", "-fbuild-session-file=" + os.path.join(self.derived, "session"),
                  "-fmodules-validate-once-per-build-session", "-Wnon-modular-include-in-framework-module",
                  "-Werror=non-modular-include-in-framework-module"]
            if s.yes("DEFINES_MODULE") and s.get("PRODUCT_MODULE_NAME"):
                f.append("-fmodule-name=" + s.get("PRODUCT_MODULE_NAME"))
        if s.yes("GCC_NO_COMMON_BLOCKS"):
            f.append("-fno-common")
        if s.yes("ENABLE_STRICT_OBJC_MSGSEND"):
            f.append("-DOBJC_OLD_DISPATCH_PROTOTYPES=0")
        if s.yes("CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES"):
            f.append("-Wno-non-modular-include-in-framework-module")
            f.append("-Wno-error=non-modular-include-in-framework-module")
        for d in self.defines(s):
            f.append("-D" + d)
        f += self.search_flags(t, s)
        pch = s.get("GCC_PREFIX_HEADER")
        if pch and lang != "assembler-with-cpp":
            f += ["-include", pch if os.path.isabs(pch) else os.path.join(s.get("SRCROOT"), pch)]
        if cxx:
            other = s.words("OTHER_CPLUSPLUSFLAGS")
        else:
            other = s.words("OTHER_CFLAGS")
        f += s.words("WARNING_CFLAGS") + other + list(extra)
        return f

    def compile_target(self, t, s):
        srcs = [f for ph in t["phases"] if ph["isa"] == "PBXSourcesBuildPhase" for f in ph["files"] if f.get("path")]
        if not srcs:
            return []
        objdir = os.path.join(s.get("OBJECT_FILE_DIR_normal"), "arm64")
        os.makedirs(objdir, exist_ok=True)
        os.makedirs(s.get("DERIVED_FILE_DIR"), exist_ok=True)
        objs = []
        swift = [f for f in srcs if f["path"].endswith(".swift")]
        other = [f for f in srcs if not f["path"].endswith(".swift")]
        if swift:
            # own directory: Foo.swift and Foo.cpp must not both become Foo.o
            sdir = os.path.join(objdir, "swift")
            if self.clean:
                # swiftc's own incremental mode would reuse what it built before
                shutil.rmtree(sdir, ignore_errors=True)
            os.makedirs(sdir, exist_ok=True)
            objs += self.compile_swift(t, s, swift, sdir)
        jobs = []
        names = {}
        for f in other:
            p = f["path"]
            ext = os.path.splitext(p)[1]
            lang = SRC_LANG.get(ext) or SRC_LANG.get(ext.lower())
            if not lang:
                log("  skip source (unknown type):", p)
                continue
            base = os.path.splitext(os.path.basename(p))[0]
            n = names.get(base, 0); names[base] = n + 1
            o = os.path.join(objdir, base + ("" if n == 0 else "-%d" % n) + ".o")
            extra = split_words(s.expand(as_str((f.get("settings") or {}).get("COMPILER_FLAGS", ""))))
            # -MD: the headers it read, for the next build's up-to-date check; system headers too
            # (pods' headers on -isystem paths, from CocoaPods' inhibit_all_warnings)
            cmd = ["clang"] + self.clang_flags(t, s, lang, extra) + ["-MD", "-MF", o + ".d", "-c", p, "-o", o]
            jobs.append((cmd, o, p))
        todo = [j for j in jobs if not self.steps.fresh(j[1], j[0], [j[1]])]
        if todo:
            self.steps.forget(*[j[1] for j in todo])
        if other and len(todo) < len(jobs):
            log("  clang: %d of %d files (rest up to date)" % (len(todo), len(jobs)))
        self.parallel(todo)
        return objs + [j[1] for j in jobs]

    def parallel(self, jobs):
        """Compile jobs (cmd, object, source); the caller has taken them out of the record."""
        errs = []
        def one(j):
            cmd, o, p = j
            if VERBOSE:
                log("$", " ".join(shlex.quote(c) for c in cmd))
            since = time.time_ns()
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
            if r.returncode != 0:
                errs.append((p, cmd, r.stdout))
            else:
                deps = read_depfile(o + ".d")
                if deps is not None:
                    self.steps.record(o, cmd, deps + hmap_inputs(cmd), since, [o], skip=self.skip)
            return o
        ex = ThreadPoolExecutor(JOBS)
        try:
            out = list(ex.map(one, jobs))
        finally:
            # stopped (a signal, Ctrl-C): let the running compiles end, start no new ones
            ex.shutdown(wait=True, cancel_futures=True)
        if errs:
            fd = os.path.join(self.derived, "failed")
            shutil.rmtree(fd, ignore_errors=True); os.makedirs(fd)
            for i, (p, cmd, txt) in enumerate(errs):
                open(os.path.join(fd, "%03d.sh" % i), "w").write(" ".join(shlex.quote(c) for c in cmd) + "\n")
                open(os.path.join(fd, "%03d.log" % i), "w").write(txt)
            log("failed commands and logs in", fd)
            for p, cmd, txt in errs[:3]:
                print("---- error compiling", p)
                print(txt[-6000:])
            print("---- command:", " ".join(shlex.quote(c) for c in errs[0][1])[:6000])
            raise SystemExit("%d file(s) failed" % len(errs))
        return out

    def swift_flags(self, t, s):
        f = ["-target", self.triple(s), "-sdk", self.sdkroot,
             # the SDK bundle's Swift resources (SwiftShims, Cxx overlays), as swift-sdk.json says
             "-resource-dir", os.path.join(self.toolchain, "usr/lib/swift"),
             "-swift-version", s.get("SWIFT_VERSION", "5").split(".")[0] if s.get("SWIFT_VERSION", "5").startswith(("4", "5", "6")) else "5",
             "-module-cache-path", self.module_cache, "-g", "-Xcc", "-fmodules-validate-once-per-build-session",
             "-Xcc", "-fbuild-session-file=" + os.path.join(self.derived, "session"),
             "-enforce-exclusivity=checked", "-no-color-diagnostics",
             # cross-import overlays (SwiftUI+MapKit -> _MapKit_SwiftUI, ...), on in Xcode and in
             # the SDK bundle's toolset.json
             "-Xfrontend", "-enable-cross-import-overlays"]
        opt = s.get("SWIFT_OPTIMIZATION_LEVEL", "-O").strip() or "-O"
        f.append(opt)
        bpd = s.get("BUILT_PRODUCTS_DIR")
        f += ["-I", bpd, "-F", bpd]
        for p in s.words("SWIFT_INCLUDE_PATHS"):
            f += ["-I", p]
        for p in s.words("FRAMEWORK_SEARCH_PATHS"):
            for q in expand_recursive(p):
                f += ["-F", q]
        for c in s.words("SWIFT_ACTIVE_COMPILATION_CONDITIONS"):
            f += ["-D", c]
        if s.get("SWIFT_OBJC_INTEROP_MODE") == "objcxx":
            # The Swift importer with swift.org's toolchain loses <math.h> macros (NAN, INFINITY)
            # in libc++'s std module under strict ISO modes (-std=c++20/c++17); the GNU dialect of
            # the same standard works. Clang compiles keep the pod's exact standard.
            std = re.sub(r"^c\+\+", "gnu++", s.get("CLANG_CXX_LANGUAGE_STANDARD", "gnu++20"))
            f += ["-cxx-interoperability-mode=default", "-Xcc", "-std=" + std]
        for d in self.defines(s):
            f += ["-Xcc", "-D" + d]
        for x in self.search_flags(t, s):
            f += ["-Xcc", x]
        bh = s.get("SWIFT_OBJC_BRIDGING_HEADER")
        if bh:
            f += ["-import-objc-header", bh if os.path.isabs(bh) else os.path.join(s.get("SRCROOT"), bh)]
        f += s.words("OTHER_SWIFT_FLAGS")
        return f

    def compile_swift(self, t, s, files, objdir):
        mod = s.get("PRODUCT_MODULE_NAME")
        dsd = s.get("DERIVED_FILE_DIR")
        bpd = s.get("BUILT_PRODUCTS_DIR")
        ofm = {}
        objs = []
        used = {}
        deps = []   # per-file dependency files (written in incremental mode)
        for f in files:
            base = os.path.splitext(os.path.basename(f["path"]))[0]
            n = used.get(base, 0); used[base] = n + 1
            o = os.path.join(objdir, base + ("" if n == 0 else "-%d" % n) + ".o")
            stem = o[:-2]
            ofm[f["path"]] = {"object": o, "dependencies": stem + ".d", "swift-dependencies": stem + ".swiftdeps"}
            deps.append(stem + ".d")
            objs.append(o)
        master = os.path.join(objdir, mod + "-master")
        ofm[""] = {"swift-dependencies": master + ".swiftdeps", "dependencies": master + ".d"}
        mapf = os.path.join(objdir, mod + "-OutputFileMap.json")
        with open(mapf, "w") as fh:
            json.dump(ofm, fh)
        moddir = os.path.join(bpd, mod + ".swiftmodule")
        os.makedirs(moddir, exist_ok=True)
        modfile = os.path.join(moddir, "arm64-apple-ios.swiftmodule")
        header = os.path.join(dsd, mod + "-Swift.h")
        cmd = ["swiftc", "-module-name", mod] + self.swift_flags(t, s)
        # like Xcode: library mode unless the module has a main.swift (apps use @main)
        if not any(os.path.basename(f["path"]) == "main.swift" for f in files):
            cmd.append("-parse-as-library")
        # as Xcode: the target's SWIFT_COMPILATION_MODE (default wholemodule); some projects set
        # incremental, which recompiles only the files a change affects
        wmo = s.get("SWIFT_COMPILATION_MODE", "wholemodule") == "wholemodule"
        if wmo:
            cmd += ["-whole-module-optimization", "-num-threads", str(JOBS)]
        else:
            cmd += ["-j%d" % JOBS, "-incremental"]
        cmd += ["-c", "-output-file-map", mapf, "-emit-dependencies", "-emit-module", "-emit-module-path", modfile,
                "-emit-objc-header", "-emit-objc-header-path", header]
        cmd += [f["path"] for f in files]
        outs = objs + [modfile, header]
        if self.steps.fresh(modfile, cmd, outs, cwd=objdir):
            log("  swiftc: %d files (up to date)" % len(files))
            return objs
        before = self.steps.outputs(modfile)
        self.steps.forget(modfile, outputs=outs)
        log("  swiftc: %d files" % len(files))
        # whole-module mode writes one dependency file for the module, incremental mode one
        # per file (an unchanged file keeps the one from its last compile); none from an
        # earlier build in the other mode may stand in for it
        if wmo:
            deps = [master + ".d"]
            if os.path.exists(deps[0]):
                os.remove(deps[0])
        since = time.time_ns()
        self.run(cmd, cwd=objdir)
        inputs = [f["path"] for f in files]
        for d in deps:
            found = read_depfile(d)
            if found is None:
                # inputs unknown: no record, the step runs again next build
                log("  warning: swiftc wrote no %s" % os.path.basename(d))
                return objs
            inputs += found
        self.steps.record(modfile, cmd, sorted(set(inputs + hmap_inputs(cmd))), since, outs, cwd=objdir, skip=self.skip)
        remove_objects(set(before) - set(outs) - self.ours, objdir)  # removed sources
        return objs

    # -- products
    def archive(self, t, s, objs):
        bpd = s.get("BUILT_PRODUCTS_DIR")
        os.makedirs(bpd, exist_ok=True)
        out = os.path.join(bpd, s.get("FULL_PRODUCT_NAME"))
        lst = out + ".objs"
        cmd = ["llvm-ar", "rcs", out, "@" + lst]
        if objs and self.steps.fresh(out, cmd + objs, [out]):
            return
        self.steps.forget(out)
        if os.path.exists(out):
            os.unlink(out)
        if not objs:
            return
        with open(lst, "w") as f:
            f.write("\n".join(objs) + "\n")
        since = time.time_ns()
        self.run(cmd)
        self.steps.record(out, cmd + objs, objs, since, [out])

    def copy_resources(self, t, s, dest):
        for ph in t["phases"]:
            if ph["isa"] != "PBXResourcesBuildPhase":
                continue
            for f in ph["files"]:
                p = f.get("path")
                variants = f.get("variants")
                if variants:
                    for v in variants:
                        if v and os.path.exists(v):
                            lp = os.path.join(dest, os.path.basename(os.path.dirname(v)))
                            os.makedirs(lp, exist_ok=True)
                            self.copy_resource(t, s, v, lp)
                    continue
                if not p:
                    continue
                if not os.path.exists(p):
                    log("  warning: missing resource", p)
                    continue
                self.copy_resource(t, s, p, dest)

    def copy_resource(self, t, s, p, dest):
        os.makedirs(dest, exist_ok=True)
        if p.endswith(".xcassets"):
            self.assets.append(p)
        elif p.endswith(".storyboard"):
            self.storyboards.append(p)
        elif p.endswith(".xib"):
            self.run(["ibtool", "--compile", os.path.join(dest, os.path.basename(p)[:-4] + ".nib"), p])
        elif os.path.isdir(p):
            dst = os.path.join(dest, os.path.basename(p))
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(p, dst, symlinks=True)
        else:
            shutil.copy2(p, os.path.join(dest, os.path.basename(p)))

    def info_plist(self, t, s, dest):
        src = s.get("INFOPLIST_FILE")
        d = {}
        if src:
            src = src if os.path.isabs(src) else os.path.join(s.get("SRCROOT"), src)
            d = plistlib.load(open(src, "rb"))
        def exp(v):
            if isinstance(v, str):
                return s.expand(v)
            if isinstance(v, list):
                return [exp(x) for x in v]
            if isinstance(v, dict):
                return {k: exp(x) for k, x in v.items()}
            return v
        d = exp(d)
        typ = t["type"]
        d.setdefault("CFBundleIdentifier", s.get("PRODUCT_BUNDLE_IDENTIFIER"))
        d.setdefault("CFBundleName", s.get("PRODUCT_NAME"))
        d.setdefault("CFBundleInfoDictionaryVersion", "6.0")
        d.setdefault("CFBundleDevelopmentRegion", s.get("DEVELOPMENT_LANGUAGE", "en"))
        if typ.endswith("application"):
            d.setdefault("CFBundleExecutable", s.get("EXECUTABLE_NAME"))
            d.setdefault("CFBundlePackageType", "APPL")
            d["MinimumOSVersion"] = s.get("IPHONEOS_DEPLOYMENT_TARGET")
            d["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
            d["UIDeviceFamily"] = [int(x) for x in s.get("TARGETED_DEVICE_FAMILY", "1").split(",") if x.strip()]
            d["UIRequiredDeviceCapabilities"] = d.get("UIRequiredDeviceCapabilities") or ["arm64"]
            d.update({"DTPlatformName": "iphoneos", "DTPlatformVersion": s.get("SDK_VERSION"),
                      "DTSDKName": s.get("SDK_NAME"), "DTSDKBuild": "", "DTXcode": XCODE_VERSION_NUMBER, "DTXcodeBuild": XCODE_BUILD,
                      "DTCompiler": "com.apple.compilers.llvm.clang.1_0", "DTPlatformBuild": "", "BuildMachineOSBuild": ""})
        else:
            d.setdefault("CFBundlePackageType", "BNDL")
        if typ.endswith("application"):
            for k, v in (self.partial_plist or {}).items():
                d.setdefault(k, v)
            if d.get("UILaunchStoryboardName") in self.failed_storyboards:
                d.pop("UILaunchStoryboardName")
                d.setdefault("UILaunchScreen", {})
            if self.a.bundle_id:
                d["CFBundleIdentifier"] = self.a.bundle_id
        for k in ("CFBundleIdentifier", "CFBundleName", "CFBundleExecutable"):
            if d.get(k) == "":
                d.pop(k)
        os.makedirs(dest, exist_ok=True)
        plistlib.dump(d, open(os.path.join(dest, "Info.plist"), "wb"), fmt=plistlib.FMT_BINARY)
        return d

    def check_supported(self, names):
        """Stop before building if a target needs what this tool can't build yet."""
        bad = []
        for n in names:
            t = self.targets[n]
            if t["type"] not in PRODUCT_TYPES:
                bad.append("%s: product type %s" % (n, t["type"]))
            for ph in t["phases"]:
                if ph["isa"] not in PHASES and ph.get("files"):
                    bad.append("%s: %s %s" % (n, ph["isa"], ph.get("name") or ""))
        if bad:
            raise SystemExit("xcbuild: not supported (static libraries, resource bundles and the app only;"
                             " no use_frameworks!, app extensions or Copy Files phases):\n  "
                             + "\n  ".join(b.rstrip() for b in bad))

    def build_target(self, name):
        t = self.targets[name]
        s = self.settings(t)
        typ = t["type"]
        t0 = time.time()
        log("target %s (%s)" % (name, typ.replace("com.apple.product-type.", "") or "aggregate"))
        bpd = s.get("BUILT_PRODUCTS_DIR")
        os.makedirs(bpd, exist_ok=True)
        self.assets, self.storyboards = [], []
        self.failed_storyboards, self.partial_plist = set(), {}
        wrap = os.path.join(bpd, s.get("WRAPPER_NAME")) if s.get("WRAPPER_NAME") else None
        self.steps = Steps(os.path.join(s.get("TARGET_TEMP_DIR"), "xcbuild-steps.json"), self.step_env,
                           clean=self.clean, ours=self.ours)
        try:
            self.build_phases(t, s, typ, wrap)
            # objects of removed sources: out of the record and off the disk
            remove_objects(self.steps.prune(), s.get("TARGET_TEMP_DIR"))
        finally:
            self.steps.save()
        if wrap and (typ.endswith("bundle") or typ.endswith("application")):
            self.info_plist(t, s, wrap)
        log("  done %s in %.1fs" % (name, time.time() - t0))

    def build_phases(self, t, s, typ, wrap):
        objs = []
        for ph in t["phases"]:
            isa = ph["isa"]
            if isa == "PBXShellScriptBuildPhase":
                self.run_script(t, s, ph)
            elif isa == "PBXSourcesBuildPhase":
                objs = self.compile_target(t, s)
                if typ.endswith("library.static"):
                    self.archive(t, s, objs)
            elif isa == "PBXResourcesBuildPhase" and wrap:
                self.copy_resources(t, s, wrap)
                self.compile_assets(t, s, wrap)
            elif isa == "PBXFrameworksBuildPhase" and typ.endswith("application"):
                self.link_app(t, s, objs, ph, wrap)

    def compile_assets(self, t, s, wrap):
        if self.assets:
            actool = os.path.join(s.get("PLATFORM_DEVELOPER_BIN_DIR"), "actool")
            partial = os.path.join(s.get("TARGET_TEMP_DIR"), "assetcatalog_generated_info.plist")
            cmd = [actool, "--output-format", "human-readable-text", "--notices", "--warnings",
                   "--platform", "iphoneos", "--minimum-deployment-target", s.get("IPHONEOS_DEPLOYMENT_TARGET"),
                   "--compress-pngs", "--output-partial-info-plist", partial]
            for fam in s.get("TARGETED_DEVICE_FAMILY", "1").split(","):
                cmd += ["--target-device", {"1": "iphone", "2": "ipad"}.get(fam.strip(), "iphone")]
            icon = s.get("ASSETCATALOG_COMPILER_APPICON_NAME")
            if icon and not self.appicon_has_images(icon):
                # Apple's actool only warns about an icon set with no images (the RN template's
                # AppIcon) and the app gets no icon; AssetKit's actool rejects it. Same outcome:
                log("  warning: app icon set '%s' has no images; the app gets no icon (as with Xcode)" % icon)
                icon = None
            if icon:
                cmd += ["--app-icon", icon]
            cmd += ["--compile", wrap] + self.assets
            log("  actool")
            self.run(cmd)
            if os.path.exists(partial):
                self.partial_plist = plistlib.load(open(partial, "rb"))
        for sb in self.storyboards:
            name = os.path.basename(sb)[:-len(".storyboard")]
            # a storyboard in X.lproj lands in the app's X.lproj, as with Xcode
            lproj = os.path.basename(os.path.dirname(sb))
            lproj = lproj if lproj.endswith(".lproj") else ""
            out = os.path.join(wrap, lproj, name + ".storyboardc")
            log("  ibtool", os.path.basename(sb))
            # like Xcode: CompileStoryboard into a temp dir, then LinkStoryboards into the app
            cdir = os.path.join(s.get("TARGET_TEMP_DIR"), "ibtool", lproj)
            shutil.rmtree(os.path.join(s.get("TARGET_TEMP_DIR"), "ibtool"), ignore_errors=True)
            os.makedirs(cdir)
            common = ["--module", s.get("PRODUCT_MODULE_NAME"), "--target-device", "iphone",
                      "--minimum-deployment-target", s.get("IPHONEOS_DEPLOYMENT_TARGET")]
            r = subprocess.run(["ibtool"] + common + [sb, "--compilation-directory", cdir],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            sbc = os.path.join(cdir, name + ".storyboardc")
            if r.returncode == 0 and os.path.isdir(sbc):
                shutil.rmtree(out, ignore_errors=True)
                r = subprocess.run(["ibtool"] + common + ["--link", wrap, sbc],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            ok = r.returncode == 0 and os.path.isdir(out)
            if not ok:
                # The Linux ibtool compiles only a xib subset. A launch storyboard that can't be
                # compiled is replaced by an empty UILaunchScreen (iOS 14+: plain launch screen,
                # full-screen app); any other storyboard is an error.
                log("  warning: ibtool can't compile %s (%s); using a plain UILaunchScreen if it is the launch screen"
                    % (os.path.basename(sb), r.stdout.strip()[-200:]))
                shutil.rmtree(out, ignore_errors=True)
                self.failed_storyboards.add(name)

    def appicon_has_images(self, name):
        for cat in self.assets:
            cj = os.path.join(cat, name + ".appiconset", "Contents.json")
            if os.path.exists(cj):
                return any(i.get("filename") for i in json.load(open(cj)).get("images", []))
        return True  # not in an .xcassets here (e.g. an Icon Composer .icon): let actool decide

    def link_app(self, t, s, objs, ph, wrap):
        os.makedirs(wrap, exist_ok=True)
        exe = os.path.join(wrap, s.get("EXECUTABLE_NAME"))
        bpd = s.get("BUILT_PRODUCTS_DIR")
        # the SDK bundle's ld64.lld (xtool's toolset): the toolchain's own lld refuses iOS
        ld = os.path.join(os.path.dirname(self.devdir), "toolset/bin/ld64.lld")
        cmd = ["clang", "-target", self.triple(s), "-isysroot", self.sdkroot, "-fuse-ld=lld", "--ld-path=" + ld,
               "-L" + bpd, "-F" + bpd]
        for p in s.words("LIBRARY_SEARCH_PATHS"):
            for q in expand_recursive(p):
                cmd.append("-L" + q)
        for p in s.words("FRAMEWORK_SEARCH_PATHS"):
            for q in expand_recursive(p):
                cmd.append("-F" + q)
        swiftlib = os.path.join(self.toolchain, "usr/lib/swift/iphoneos")
        cmd += ["-L" + swiftlib, "-L" + os.path.join(self.sdkroot, "usr/lib/swift")]
        cmd += objs
        for f in ph["files"]:
            bp = f.get("built_product") or os.path.basename(f.get("path") or "")
            if bp.endswith(".a"):
                cmd.append(os.path.join(bpd, os.path.basename(bp)))
            elif bp.endswith(".framework"):
                cmd += ["-framework", os.path.basename(bp)[:-len(".framework")]]
        for r in s.words("LD_RUNPATH_SEARCH_PATHS"):
            cmd += ["-Xlinker", "-rpath", "-Xlinker", r]
        cmd += ["-dead_strip", "-fobjc-link-runtime"]
        # compiler-rt builtins (__isPlatformVersionAtLeast for @available), which Xcode's clang
        # links by itself; the SDK bundle has Apple's
        rt = glob.glob(os.path.join(self.toolchain, "usr/lib/clang/*/lib/darwin/libclang_rt.ios.a"))
        cmd += rt[:1]
        cmd += [w for w in s.words("OTHER_LDFLAGS")]
        # the files the linker read (-l libraries found on the search paths too), as Xcode does
        info = os.path.join(s.get("TARGET_TEMP_DIR"), s.get("EXECUTABLE_NAME") + "_dependency_info.dat")
        cmd += ["-Xlinker", "-dependency_info", "-Xlinker", info, "-o", exe]
        cwd = os.getcwd()  # relative paths in OTHER_LDFLAGS and in the dependency info
        if self.steps.fresh(exe, cmd, [exe], cwd=cwd):
            log("  link", os.path.basename(exe), "(up to date)")
            return
        self.steps.forget(exe)
        log("  link", os.path.basename(exe))
        since = time.time_ns()
        self.run(cmd, cwd=cwd)
        ins = read_dependency_info(info, cwd)
        if ins:
            self.steps.record(exe, cmd, ins + objs, since, [exe], cwd=cwd, skip=self.skip)

def remove_objects(paths, under):
    """Delete the object files (and their dependency files) among paths that are in the
    directory under."""
    under = os.path.join(under, "")
    for o in paths:
        if o.endswith(".o") and o.startswith(under):
            for f in (o, o + ".d", o[:-2] + ".d", o[:-2] + ".swiftdeps"):
                if os.path.isfile(f):
                    os.remove(f)

def xcode_bool(v):
    """A project's boolean attribute: xcodeproj gives strings ("0", "1")."""
    return str(v or "").strip().upper() in ("1", "YES", "TRUE")

def expand_recursive(p):
    if p.endswith("/**"):
        root = p[:-3]
        out = []
        for dp, dn, fn in os.walk(root):
            out.append(dp)
        return out or [root]
    return [p]

def stop_on_signals():
    """SIGTERM and SIGHUP end the build like Ctrl-C: running compiles finish, the record is
    saved. A signal that is ignored (nohup) stays ignored."""
    def stop(sig, frame):
        raise SystemExit("xcbuild: stopped by signal %d" % sig)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(sig) is not signal.SIG_IGN:
            signal.signal(sig, stop)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace-dir", default="ios")
    ap.add_argument("--configuration", default="Release")
    ap.add_argument("--target", action="append", help="build only these targets (and their dependencies)")
    ap.add_argument("--derived-data", default=None)
    ap.add_argument("--sdk", default=os.path.expanduser("~/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"))
    ap.add_argument("--developer-dir", default=os.path.expanduser("~/.swiftpm/swift-sdks/darwin.artifactbundle/Developer"))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--bundle-id", help="override the app's CFBundleIdentifier")
    ap.add_argument("--clean", action="store_true",
                    help="ignore what earlier builds did and redo every step (the default except for Debug)")
    ap.add_argument("--incremental", action="store_true",
                    help="redo only the steps whose inputs changed (the default for Debug)")
    a = ap.parse_args()
    if a.clean and a.incremental:
        ap.error("--clean and --incremental exclude each other")
    a.clean = a.clean or (a.configuration != "Debug" and not a.incremental)
    stop_on_signals()
    a.derived_data = a.derived_data or os.path.join(os.path.abspath(a.workspace_dir), "build", "xcbuild")
    os.makedirs(a.derived_data, exist_ok=True)
    # one build at a time in a build directory: they would share objects and records
    lock = open(os.path.join(a.derived_data, "xcbuild.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another build is using %s; waiting for it to end" % a.derived_data)
        fcntl.flock(lock, fcntl.LOCK_EX)
    b = Build(a)
    open(os.path.join(b.derived, "session"), "a").close()
    os.utime(os.path.join(b.derived, "session"))
    apps = [n for n, t in b.targets.items() if t["type"].endswith("application")]
    names = a.target or apps
    order = b.order(names)
    if a.list:
        for n in order:
            print(n, b.targets[n]["type"])
        return
    b.check_supported(order)
    t0 = time.time()
    if a.clean:
        log("clean build (--incremental to redo only what changed)")
    for n in order:
        b.build_target(n)
    log("build succeeded in %.0fs" % (time.time() - t0))

if __name__ == "__main__":
    main()
