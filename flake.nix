{
  description = "Build and run iOS apps on NixOS (omarchy-apple-dev toolchain in an FHS environment)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The scripts that do the user-space part (xtool, SDK, signing, device runs).
    upstream = {
      url = "github:joshuaswarren/omarchy-apple-dev/b19eb10f8de3b5039746750e21d480002b0a9819";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, upstream }:
    let
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: prev: {
        apple-dev-swift = final.callPackage ./pkgs/swift.nix { };
        apple-dev = final.callPackage ./pkgs/fhs.nix { swift = final.apple-dev-swift; inherit upstream; };
      };

      packages = forAll (pkgs: rec {
        swift = pkgs.callPackage ./pkgs/swift.nix { };
        apple-dev = pkgs.callPackage ./pkgs/fhs.nix { inherit swift upstream; };
        default = apple-dev;
      });

      nixosModules.default = import ./modules/nixos.nix self;
    };
}
