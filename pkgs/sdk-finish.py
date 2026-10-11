# Finish a darwin.artifactbundle made by `xtool sdk install`: the steps of
# upstream install-toolchain.sh's install_darwin_tools and install_oam
# (omarchy-apple-dev, MIT), without the parts the Nix packages already do
# (building actool and the macro server, patching the toolchain specs).
#
# usage: sdk-finish.py BUNDLE ACTOOL UPSTREAM_TOOLS_DIR OAM_SERVER
import json, os, plistlib, shutil, sys

bundle, actool, tools, oam = sys.argv[1:5]
platforms = os.path.join(bundle, "Developer/Platforms")


def install(src, dst_dir, mode):
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, os.path.basename(src))
    shutil.copyfile(src, dst)
    os.chmod(dst, mode)


# 1. Linux stand-ins for Xcode's asset/strings/nib/model compilers. SwiftBuild
#    looks for them in each platform's Developer/usr/bin. The Mac nib compiler
#    (ibmac.py) is imported by ibtool from its own directory.
common = [("xcstringstool", 0o755), ("ibtool", 0o755), ("momc", 0o755),
          ("nibarchive.py", 0o644), ("keyorder.py", 0o644), ("xcstrings_symbols.py", 0o644)]
for platform, extra in (("iPhoneOS", []), ("MacOSX", [("ibmac.py", 0o644)])):
    bin_dir = os.path.join(platforms, f"{platform}.platform/Developer/usr/bin")
    install(actool, bin_dir, 0o755)
    for name, mode in common + extra:
        install(os.path.join(tools, name), bin_dir, mode)

# 2. .strings input encoding (SwiftBuild detects encodings only on macOS).
for platform in ("iPhoneOS", "MacOSX"):
    p = os.path.join(platforms, f"{platform}.platform/Info.plist")
    if os.path.isfile(p):
        with open(p, "rb") as f:
            plist = plistlib.load(f)
        plist.setdefault("DefaultProperties", {})["STRINGS_FILE_INPUT_ENCODING"] = "utf-8"
        with open(p, "wb") as f:
            plistlib.dump(plist, f)

# 3. Swift cross-import overlays (StoreKit + SwiftUI = StoreView, ...), and
#    the Swift runtime + -all_load for `type: .dynamic` products.
p = os.path.join(bundle, "toolset-swb.json")
with open(p) as f:
    data = json.load(f)
data.setdefault("swiftCompiler", {})["extraCLIOptions"] = ["-Xfrontend", "-enable-cross-import-overlays"]
data.setdefault("linker", {})["extraCLIOptions"] = ["-lswiftCore", "-L/usr/lib/swift", "-all_load"]
with open(p, "w") as f:
    json.dump(data, f, indent=4)

# 4. SDK defaults: strings encodings, and no text-based stubs (Linux has no tapi).
for platform in ("iPhoneOS", "MacOSX"):
    sdks = os.path.join(platforms, f"{platform}.platform/Developer/SDKs")
    for sdk in sorted(os.listdir(sdks)) if os.path.isdir(sdks) else []:
        if os.path.islink(os.path.join(sdks, sdk)):
            continue
        p = os.path.join(sdks, sdk, "SDKSettings.json")
        if os.path.isfile(p):
            with open(p) as f:
                d = json.load(f)
            dp = d.setdefault("DefaultProperties", {})
            dp["STRINGS_FILE_INPUT_ENCODING"] = "utf-8"
            dp["STRINGS_FILE_OUTPUT_ENCODING"] = "binary"
            dp.setdefault("GENERATE_INTERMEDIATE_TEXT_BASED_STUBS", "NO")
            dp.setdefault("GENERATE_TEXT_BASED_STUBS", "NO")
            with open(p, "w") as f:
                json.dump(d, f)
        p = os.path.join(sdks, sdk, "SDKSettings.plist")
        d = {"DefaultProperties": {}}
        if os.path.isfile(p):
            with open(p, "rb") as f:
                d = plistlib.load(f)
        dp = d.setdefault("DefaultProperties", {})
        dp["GENERATE_INTERMEDIATE_TEXT_BASED_STUBS"] = "NO"
        dp["GENERATE_TEXT_BASED_STUBS"] = "NO"
        with open(p, "wb") as f:
            plistlib.dump(d, f)

# 5. The macro server with SwiftData and #Preview macros; empty plugin stubs
#    make its modules outrank the toolchain's own plugins.
install(oam, bundle, 0o755)
plugins = os.path.join(platforms, "iPhoneOS.platform/Developer/usr/lib/swift/host/plugins")
os.makedirs(plugins, exist_ok=True)
for stub in ("libSwiftDataMacros.so", "libFoundationMacros.so"):
    open(os.path.join(plugins, stub), "w").close()

print(f"sdk-finish: done ({bundle})")
