#!/usr/bin/env python3
"""actool and app icon sets with empty slots, as Xcode's AppIcon template
and the React Native and Expo templates write them.

usage: actool_app_icons.py ACTOOL

- partly filled: the empty slots are skipped, the filled ones compile, and
  actool prints Apple's warning for each empty required size of the target
  devices;
- empty: no icon, no warning, no error."""
import json, os, plistlib, struct, subprocess, sys, tempfile, zlib

ACTOOL = sys.argv[1]
SLOTS = [("iphone", s, sc) for s in ("20x20", "29x29", "40x40", "60x60") for sc in ("2x", "3x")] + [
    ("ios-marketing", "1024x1024", "1x")]


def png(path, side):
    row = b"\x00" + bytes((30, 120, 220, 255)) * side
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(row * side)) + chunk(b"IEND", b""))


def catalog(root, filled):
    cat = os.path.join(root, "Images.xcassets")
    icon = os.path.join(cat, "AppIcon.appiconset")
    os.makedirs(icon)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(cat, "Contents.json"), "w"))
    images = []
    for idiom, size, scale in SLOTS:
        entry = {"idiom": idiom, "size": size, "scale": scale}
        if (idiom, size, scale) in filled:
            entry["filename"] = "icon-%s@%s.png" % (size, scale)
            png(os.path.join(icon, entry["filename"]), int(float(size.split("x")[0]) * int(scale[0])))
        images.append(entry)
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
              open(os.path.join(icon, "Contents.json"), "w"))
    return cat


def compile(root, cat, devices=("iphone",)):
    out = os.path.join(root, "out")
    os.makedirs(out)
    r = subprocess.run([ACTOOL, "--output-format", "human-readable-text", "--notices", "--warnings",
                        "--platform", "iphoneos", "--minimum-deployment-target", "15.1",
                        *[a for d in devices for a in ("--target-device", d)], "--app-icon", "AppIcon",
                        "--output-partial-info-plist", os.path.join(out, "partial.plist"),
                        "--compile", out, cat], capture_output=True, text=True)
    print(r.stdout, r.stderr, sep="")
    assert r.returncode == 0, "actool exited %d" % r.returncode
    return out, r.stdout, plistlib.load(open(os.path.join(out, "partial.plist"), "rb"))


with tempfile.TemporaryDirectory() as root:
    cat = catalog(root, {("iphone", "60x60", "2x"), ("iphone", "60x60", "3x")})
    out, stdout, partial = compile(root, cat)
    warnings = [l for l in stdout.splitlines() if ": warning: " in l]
    assert warnings == [cat + ":./AppIcon.appiconset: warning: A 1024x1024 app store icon is required for iOS apps"], warnings
    car = open(os.path.join(out, "Assets.car"), "rb").read()
    assert car.startswith(b"BOMStore")
    for name in (b"icon-60x60@2x.png", b"icon-60x60@3x.png"):
        assert name in car, name
    assert b"icon-20x20" not in car
    assert sorted(f for f in os.listdir(out) if f.endswith(".png")) == ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png"]
    assert partial["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"] == ["AppIcon60x60"], partial

with tempfile.TemporaryDirectory() as root:
    cat = catalog(root, {("iphone", "60x60", "2x"), ("iphone", "60x60", "3x")})
    out, stdout, partial = compile(root, cat, ("iphone", "ipad"))
    warnings = [l for l in stdout.splitlines() if ": warning: " in l]
    assert warnings == [cat + ":./AppIcon.appiconset: warning: " + w for w in (
        "A 76x76@2x app icon is required for iPad apps targeting iOS 7.0 and later",
        "A 83.5x83.5@2x app icon is required for iPad apps targeting iOS 9.0 and later",
        "A 1024x1024 app store icon is required for iOS apps")], warnings

with tempfile.TemporaryDirectory() as root:
    out, stdout, partial = compile(root, catalog(root, set()))
    assert ": warning: " not in stdout and ": error: " not in stdout
    assert partial == {}, partial
    assert not os.path.exists(os.path.join(out, "Assets.car"))

print("actool app icons ok")
