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
        apple-dev-usbmuxd = final.callPackage ./pkgs/usbmuxd-service.nix { };
      };

      packages = forAll (pkgs: rec {
        swift = pkgs.callPackage ./pkgs/swift.nix { };
        apple-dev = pkgs.callPackage ./pkgs/fhs.nix { inherit swift upstream; };
        usbmuxd = pkgs.callPackage ./pkgs/usbmuxd-service.nix { };
        ipsw = pkgs.callPackage ./pkgs/ipsw.nix { };
        default = apple-dev;
      });

      # One command each, no NixOS module needed:
      #   nix run github:m9tdev/nix-apple-dev                 shell (or: … -- CMD ARGS)
      #   nix run github:m9tdev/nix-apple-dev#setup           toolchain + SDK in $HOME
      #   sudo nix run github:m9tdev/nix-apple-dev#usbmuxd    USB service (once per boot)
      apps = forAll (pkgs:
        let p = self.packages.${pkgs.stdenv.hostPlatform.system}; in {
          default = { type = "app"; program = "${p.apple-dev}/bin/apple-dev"; };
          setup = { type = "app"; program = "${p.apple-dev}/bin/apple-dev-setup"; };
          usbmuxd = { type = "app"; program = "${p.usbmuxd}/bin/apple-dev-usbmuxd"; };
        });

      nixosModules.default = import ./modules/nixos.nix self;
    };
}
