# The iOS/macOS SDK bundle for SwiftPM ("darwin"), built from Xcode.xip.
#
# The xip is a requireFile: Nix cannot download it (Apple ID). Add it once:
#   nix-store --add-fixed sha256 Xcode_27.xip
# xtool unpacks it in the build directory and keeps only the parts its SDK
# builder needs (`SDKBuilder.wanted`); Xcode.app is never stored.
# Then the same steps as upstream's installer: xtool sdk build + install, and
# sdk-finish.py (upstream's install_darwin_tools / install_oam: actool,
# ibtool, momc, the macro server, the plist/JSON defaults). Output: the
# registered bundle, ready to link into ~/.swiftpm/swift-sdks/.
{ lib, stdenvNoCC, requireFile, fetchurl, xar, pbzx, cpio, python3, swift, xtool, open-apple-macros, actool, upstream }:

let
  xcodeVersion = "27.0";
  xip = requireFile {
    name = "Xcode_27.xip";
    url = "https://developer.apple.com/download/all/?q=Xcode%2027";
    # Xcode 27.0 (its Swift matches the 6.4 toolchain)
    sha256 = "6a270c53a5a0c5e0ac78125342d44c3cfff2716ec390373cd5e30834d80a67c3";
    message = ''
      Nix cannot download Xcode (it needs an Apple ID sign-in).
      1. Download Xcode 27.0 from https://developer.apple.com/download/all/?q=Xcode
         (or: nix run github:m9tdev/nix-apple-dev#ipsw -- download dev --more)
      2. Add it to the Nix store:
           nix-store --add-fixed sha256 Xcode_27.xip
         After that you can delete the downloaded file.
    '';
  };

  # Two small extras that xtool does not keep, taken with cpio: the Xcode
  # version stamp and the App Shortcuts phrase lists that ship.sh uses. Not the
  # SDK itself: Xcode.xip stores many files in Apple's compressed form
  # (decmpfs), which cpio cannot read; xtool's own unxip can.
  extras = [
    "./Xcode.app/Contents/version.plist"
    "./Xcode.app/Contents/Frameworks/SiriSSUKitModel.framework/Versions/A/Resources/*"
  ];


  # xtool's prebuilt Linux toolset for Apple targets (ld64.lld, libtool, …);
  # xtool would download it during `sdk build` (SDKBuilder.darwinToolsVersion).
  toolset = fetchurl {
    url = "https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.1.0/toolset-x86_64.tar.gz";
    hash = "sha256-pRZvLVasRXB+XvLzwgpBqUr47wwEVjVCJN0IZW6HQYg=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "ios-sdk";
  version = xcodeVersion;
  src = xip;
  dontUnpack = true;

  # swift: `xtool sdk install` runs `swift sdk install` (any recent Swift)
  nativeBuildInputs = [ xar pbzx cpio python3 swift xtool ];

  # No network in the sandbox: xtool (patched, see patch-xtool.py) reads these.
  XTOOL_TOOLSET_TARBALL = toolset;
  XTOOL_OAM_SERVER = "${open-apple-macros}/bin/OpenAppleMacrosServer";

  buildPhase = ''
    runHook preBuild
    # SwiftPM takes the home directory from the passwd entry (/build in the
    # sandbox), not from $HOME; make them the same.
    export HOME=$TMPDIR

    xar -xf $src Content
    pbzx -n Content | cpio -idm --quiet ${lib.escapeShellArgs extras}
    rm Content
    if grep -rl NULLcanary Xcode.app; then
      echo "ios-sdk: compressed (decmpfs) files in the cpio extract" >&2; exit 1
    fi

    # xtool unpacks the whole xip to a temporary stage (about 10 GB) and
    # keeps only what its SDKBuilder.wanted list names.
    xtool sdk build "$src" "$TMPDIR/sdk"
    xtool sdk install "$TMPDIR/sdk/darwin.xtoolsdk"

    bundle=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle
    test -f "$bundle/info.json"
    python3 ${./sdk-finish.py} "$bundle" ${actool}/bin/actool ${upstream}/tools \
      ${open-apple-macros}/bin/OpenAppleMacrosServer
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    chmod -R u+w "$bundle"
    cp -a "$bundle" $out/darwin.artifactbundle
    cp Xcode.app/Contents/version.plist $out/version.plist
    cp -a Xcode.app/Contents/Frameworks/SiriSSUKitModel.framework/Versions/A/Resources $out/SiriSSUKitModel
    # No file may still be in compressed (decmpfs) form.
    if grep -rl --exclude-dir=Ruby.framework NULLcanary $out | head -5 | grep .; then
      echo "ios-sdk: compressed (decmpfs) placeholder files in the SDK" >&2; exit 1
    fi
    # The bundle must not point back into the build directory.
    if grep -rIl --exclude-dir=SDKs "$TMPDIR" $out | head -5 | grep .; then
      echo "ios-sdk: output refers to the build directory" >&2; exit 1
    fi
    if find $out -type l -lname "$TMPDIR*" | head -5 | grep .; then
      echo "ios-sdk: output has symlinks into the build directory" >&2; exit 1
    fi
    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "iOS and macOS SDK for SwiftPM, built from Xcode.xip with xtool";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
}
