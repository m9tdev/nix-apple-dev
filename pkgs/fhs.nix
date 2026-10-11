# The user package: `apple-dev` (shell / command runner with the Nix-built
# tools on PATH) and `apple-dev-setup` (upstream's installer, for the parts
# that must live in $HOME: the iOS SDK from Xcode.xip and its registration).
{ lib, writeShellScriptBin, symlinkJoin, mkFHSEnv, upstream, tools ? [ ] }:

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
    # Sync the writable checkout to the pinned upstream revision.
    dest=${checkout}
    if [ "$(cat "$dest/.nix-apple-dev-src" 2>/dev/null || true)" != "${upstream}" ]; then
      mkdir -p "$dest"
      ${lib.getExe' env "apple-dev"} rsync -a --delete --exclude .build --chmod=u+w ${upstream}/ "$dest/"
      echo "${upstream}" > "$dest/.nix-apple-dev-src"
      echo "upstream synced to $dest"
    fi
    exec ${lib.getExe' env "apple-dev"} "$dest/install-toolchain.sh" --user-only --mode full "$@"
  '';
in
symlinkJoin {
  name = "apple-dev";
  paths = [ env setup ];
  passthru = { inherit env setup tools; };
}
