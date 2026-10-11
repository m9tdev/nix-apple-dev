# The user package:
# - `apple-dev`: shell / command runner with the Nix-built tools and
#   upstream's scripts (device-run.sh, ship.sh, tools/*) on PATH;
# - `apple-dev-setup`: builds the iOS SDK from the Xcode.xip in the Nix store
#   and links it for SwiftPM in $HOME. The home-manager module makes the same
#   links declaratively; this command is for everyone else.
{ lib, writeShellScriptBin, symlinkJoin, mkFHSEnv, upstream, flakeSrc, tools ? [ ] }:

let
  env = mkFHSEnv {
    name = "apple-dev";
    profile = ''
      export PATH=${lib.makeBinPath tools}:${upstream}:${upstream}/tools:$PATH
      export APPLE_DEV_UPSTREAM=${upstream}
    '';
  };

  setup = writeShellScriptBin "apple-dev-setup" ''
    set -euo pipefail
    state=$HOME/.local/share/nix-apple-dev

    # 1. The SDK. It is not a dependency of this package, so apple-dev works
    #    before Xcode.xip is in the store. Build it now (from this flake's own
    #    source and lock) and keep it as a GC root.
    echo "building the iOS SDK (needs Xcode_27.xip in the Nix store; about 2 minutes)"
    sdk=$(nix build --no-link --print-out-paths "path:${flakeSrc}#ios-sdk")
    mkdir -p "$state"
    nix-store --add-root "$state/ios-sdk" --realise "$sdk" >/dev/null

    # 2. Register it for SwiftPM: a link, through the GC root. SwiftPM uses
    #    $XDG_CONFIG_HOME/swiftpm when XDG_CONFIG_HOME is set, else ~/.swiftpm.
    sdks=''${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/swiftpm}
    sdks=''${sdks:-$HOME/.swiftpm}/swift-sdks
    mkdir -p "$sdks"
    if [ -e "$sdks/darwin.artifactbundle" ] && [ ! -L "$sdks/darwin.artifactbundle" ]; then
      echo "replacing the old SDK install in $sdks/darwin.artifactbundle"
      chmod -R u+w "$sdks/darwin.artifactbundle"
      rm -rf "$sdks/darwin.artifactbundle"
    fi
    ln -sfn "$state/ios-sdk/darwin.artifactbundle" "$sdks/darwin.artifactbundle"

    # 3. What upstream's ship.sh and tools/asc.py look for next to the SDK cache.
    mkdir -p "$HOME/.cache/xtool"
    ln -sfn "$state/ios-sdk/version.plist" "$HOME/.cache/xtool/darwin-nix.xtoolsdk.version.plist"
    ln -sfn "$state/ios-sdk/SiriSSUKitModel" "$HOME/.cache/xtool/darwin-nix.xtoolsdk.SiriSSUKitModel"

    ${lib.getExe' env "apple-dev"} swift sdk list | grep -qx darwin
    echo "SDK registered: $(readlink -f "$sdks/darwin.artifactbundle")"
  '';
in
symlinkJoin {
  name = "apple-dev";
  paths = [ env setup ];
  passthru = { inherit env setup tools upstream; };
  meta = {
    description = "iOS app development on Linux: Swift 6.4, xtool, pymobiledevice3 in an FHS environment";
    mainProgram = "apple-dev";
    platforms = [ "x86_64-linux" ];
  };
}
