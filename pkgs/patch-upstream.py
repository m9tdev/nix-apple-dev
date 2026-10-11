# Patch a copy of omarchy-apple-dev to use Nix-built tools (see upstream.nix).
# usage: patch-upstream.py DIR key=value...
import os, sys

root = sys.argv[1]
v = dict(a.split("=", 1) for a in sys.argv[2:])


def replace(rel, old, new, count=1):
    """Replace exactly `count` occurrences (0 = at least one) or fail."""
    p = os.path.join(root, rel)
    s = open(p).read()
    n = s.count(old)
    if n == 0 or (count and n != count):
        sys.exit(f"patch-upstream: {rel}: expected {count or 'some'} of {old[:70]!r}, found {n}")
    open(p, "w").write(s.replace(old, new))


# 1. Hard-coded tool paths, in every text file that has them.
paths = {
    "$HOME/.local/bin/xtool": v["xtool"],
    "$HOME/.local/bin/ipsw": v["ipsw"],
    "$HOME/.local/bin/rcodesign": v["rcodesign"],
    "$HOME/pymobile3-venv/bin/pymobiledevice3": v["python_env"] + "/bin/pymobiledevice3",
}
seen = set()
for d, _, files in os.walk(root):
    if "/.git" in d or "/receipts" in d:
        continue
    for f in files:
        p = os.path.join(d, f)
        try:
            s = open(p).read()
        except (UnicodeDecodeError, OSError):
            continue
        t = s
        for old, new in paths.items():
            if old in t:
                seen.add(old)
                t = t.replace(old, new)
        if t != s:
            open(p, "w").write(t)
for old in paths:
    if old not in seen:
        sys.exit(f"patch-upstream: no file uses {old} any more; check upstream")

I = "install-toolchain.sh"

# 2. xtool: Nix-built; nothing to build or link.
replace(I, '''install_xtool() {
  local src="$HOME/.cache/omarchy-apple-dev/xtool-$XTOOL_SHA"''', '''install_xtool() {
  return 0  # nix-apple-dev: xtool is a Nix package
  local src="$HOME/.cache/omarchy-apple-dev/xtool-$XTOOL_SHA"''')

# 3. OpenAppleMacrosServer: copy the Nix build into the SDK bundle.
replace(I, '''  fetch_commit "$OAM_REPO" "$OAM_SHA" "$src"
  echo "Building OpenAppleMacrosServer $OAM_SHA (first run: about 5 minutes)"
  (cd "$src" && swift build -c release --build-system native --static-swift-stdlib \\
    --product OpenAppleMacrosServer >/dev/null)
  install -m755 "$src/.build/release/OpenAppleMacrosServer" "$DARWIN_SDK_BUNDLE/OpenAppleMacrosServer"''',
        f'''  install -m755 "{v["oam"]}" "$DARWIN_SDK_BUNDLE/OpenAppleMacrosServer"''')

# 4. actool: the Nix build instead of an in-tree SwiftPM build.
replace(I, '''  (cd "$REPO_DIR/tools/darwin-tools" && swift build -c release --product actool >/dev/null)\n''', "")
replace(I, '"$REPO_DIR/tools/darwin-tools/.build/release/actool"', f'"{v["actool"]}"', count=2)

# 5. rcodesign and ipsw: Nix packages; the version checks pass, so no download.
replace(I, "RCODESIGN_VERSION=0.29.0", f"RCODESIGN_VERSION={v['rcodesign_version']}")
replace(I, "IPSW_VERSION=3.1.731", f"IPSW_VERSION={v['ipsw_version']}")

# 6. pymobiledevice3: the Nix Python environment instead of a pip venv.
replace(I, 'VENV="$HOME/pymobile3-venv"', f'VENV="{v["python_env"]}"')
replace(I, '''python3 -m venv "$VENV"
"$VENV/bin/pip" install pymobiledevice3
"$VENV/bin/pip" show pymobiledevice3 | sed -n 's/^Version: /pymobiledevice3 /p\'''',
        '''"$VENV/bin/pymobiledevice3" version | sed 's/^/pymobiledevice3 /\'''')

# 7. xtool copies parts of the toolchain (clang's include dirs) into the SDK
#    bundle and keeps their mode; from the read-only Nix store that is r-x, and
#    `swift sdk remove` / `rm -rf` of the bundle or the SDK cache then fail.
replace(I, '''sdk_install_from() {
  swift sdk remove darwin >/dev/null 2>&1 || true''', '''sdk_install_from() {
  chmod -R u+w "$DARWIN_SDK_BUNDLE" "$1" 2>/dev/null || true
  swift sdk remove darwin >/dev/null 2>&1 || true
  rm -rf "$DARWIN_SDK_BUNDLE"  # a half-removed bundle blocks the install''')
# `swift sdk list` prints a warning that names darwin.artifactbundle when the
# bundle is broken; only an exact "darwin" line means it is registered.
replace(I, "if swift sdk list 2>/dev/null | grep -q darwin; then",
        "if swift sdk list 2>/dev/null | grep -qx darwin; then")
replace(I, '''  rm -rf "$cached"
  mv "$tmpd/darwin.xtoolsdk" "$cached"''', '''  chmod -R u+w "$cached" "$tmpd" 2>/dev/null || true
  rm -rf "$cached"
  mv "$tmpd/darwin.xtoolsdk" "$cached"''')

print("patched upstream for nix-apple-dev")
