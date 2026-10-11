# SwiftBuild cannot re-encode .strings files outside Darwin, so the spec
# defaults must name the encodings. Upstream install-toolchain.sh
# (install_darwin_tools) patches a writable toolchain at install time; the Nix
# store is read-only, so do the same edit at build time. Argument: the
# toolchain root (the directory that contains usr/).
import os, re, sys

root = sys.argv[1]
for rel, fixes in (
    ("usr/share/pm/SwiftBuild_SWBUniversalPlatform.bundle/CopyStringsFile.xcspec",
     [("STRINGS_FILE_INPUT_ENCODING", "utf-8")]),
    ("usr/share/pm/SwiftBuild_SWBCore.bundle/CoreBuildSystem.xcspec",
     [("STRINGS_FILE_OUTPUT_ENCODING", "binary")]),
    ("usr/share/pm/SwiftBuild_SWBCore.bundle/NativeBuildSystem.xcspec",
     [("STRINGS_FILE_OUTPUT_ENCODING", "binary")]),
):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        sys.exit(f"patch-xcspec: {rel} is missing")
    lines = open(p).read().split("\n")
    for setting, value in fixes:
        done = False
        for i, line in enumerate(lines):
            if f'Name = "{setting}";' in line or f'Name = {setting};' in line:
                for j in range(i + 1, min(i + 12, len(lines))):
                    if "DefaultValue =" in lines[j]:
                        lines[j] = re.sub(r'"[^"]*"\s*;', f'"{value}";', lines[j])
                        done = True
                        break
        if not done:
            sys.exit(f"patch-xcspec: no DefaultValue for {setting} in {rel}")
    open(p, "w").write("\n".join(lines))
    print(f"patched {rel}")
