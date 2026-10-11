# The user package: `apple-dev` (shell / command runner with the Nix-built
# tools on PATH) and `apple-dev-setup` (builds the iOS SDK from the Xcode.xip
# in the Nix store and registers it for SwiftPM in $HOME).
{ lib, writeShellScriptBin, symlinkJoin, mkFHSEnv, upstream, flakeSrc, tools ? [ ] }:

let
  # The writable copy of upstream: its scripts find their siblings relative to
  # themselves, and some write next to themselves.
  checkout = "$HOME/.local/share/nix-apple-dev/omarchy-apple-dev";

  env = mkFHSEnv {
    name = "apple-dev";
    profile = ''
      export PATH=${lib.makeBinPath tools}:$HOME/.local/bin:${checkout}:${checkout}/tools:$PATH
      export APPLE_DEV_UPSTREAM=${checkout}
    '';
  };

  setup = writeShellScriptBin "apple-dev-setup" ''
    set -euo pipefail
    run=${lib.getExe' env "apple-dev"}
    state=$HOME/.local/share/nix-apple-dev

    # 1. A writable copy of the patched upstream scripts (on PATH in apple-dev).
    dest=${checkout}
    if [ "$(cat "$dest/.nix-apple-dev-src" 2>/dev/null || true)" != "${upstream}" ]; then
      mkdir -p "$dest"
      $run rsync -a --delete --exclude .build --chmod=u+w ${upstream}/ "$dest/"
      echo "${upstream}" > "$dest/.nix-apple-dev-src"
      echo "upstream scripts: $dest"
    fi

    # 2. The SDK. It is not a dependency of this package, so apple-dev works
    #    before Xcode.xip is in the store; build it now (from this flake's
    #    own source and lock) and keep it as a GC root.
    echo "building the iOS SDK (needs Xcode_27.xip in the Nix store; first build about 5 minutes)"
    sdk=$(nix build --no-link --print-out-paths "path:${flakeSrc}#ios-sdk")
    mkdir -p "$state"
    nix-store --add-root "$state/ios-sdk" --realise "$sdk" >/dev/null

    # 3. Register it for SwiftPM: a link, through the GC root.
    sdks=''${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/swiftpm}
    sdks=''${sdks:-$HOME/.swiftpm}/swift-sdks
    mkdir -p "$sdks"
    if [ -e "$sdks/darwin.artifactbundle" ] && [ ! -L "$sdks/darwin.artifactbundle" ]; then
      echo "replacing the old SDK install in $sdks/darwin.artifactbundle"
      chmod -R u+w "$sdks/darwin.artifactbundle"
      rm -rf "$sdks/darwin.artifactbundle"
    fi
    ln -sfn "$state/ios-sdk/darwin.artifactbundle" "$sdks/darwin.artifactbundle"

    # 4. What upstream's ship.sh and tools/asc.py look for next to the SDK cache.
    mkdir -p "$HOME/.cache/xtool"
    ln -sfn "$state/ios-sdk/version.plist" "$HOME/.cache/xtool/darwin-nix.xtoolsdk.version.plist"
    ln -sfn "$state/ios-sdk/SiriSSUKitModel" "$HOME/.cache/xtool/darwin-nix.xtoolsdk.SiriSSUKitModel"
    for old in "$HOME"/.cache/xtool/darwin-iPhoneOS*.xtoolsdk; do
      [ -d "$old" ] && echo "note: $old is an SDK cache from an older setup; you can delete it"
    done

    $run swift sdk list | grep -qx darwin
    echo "SDK registered: $(readlink -f "$sdks/darwin.artifactbundle")"
  '';
in
symlinkJoin {
  name = "apple-dev";
  paths = [ env setup ];
  passthru = { inherit env setup tools; };
}
