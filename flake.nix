{
  description = "Build, sign and install iOS apps on NixOS without a Mac (packages omarchy-apple-dev)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # pymobiledevice3 & co. from python/uv.lock (nixpkgs has 7.7.0; upstream needs 11.26+)
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The scripts that do the user-space part (xtool, SDK, signing, device runs).
    upstream = {
      url = "github:joshuaswarren/omarchy-apple-dev/b19eb10f8de3b5039746750e21d480002b0a9819";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, upstream, pyproject-nix, uv2nix, pyproject-build-systems }:
    let
      systems = [ "x86_64-linux" ];
      # Unfree: only the SDK built from the user's own Xcode.xip.
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = p: builtins.elem (nixpkgs.lib.getName p) [ "ios-sdk" "Xcode_27.xip" ];
      }));
    in
    {
      # The packages, built with this flake's nixpkgs (the tools need its exact
      # toolchain and FHS environment), under apple-dev-* names.
      overlays.default = final: prev:
        let p = self.packages.${final.stdenv.hostPlatform.system}; in {
          apple-dev = p.apple-dev;
          apple-dev-usbmuxd = p.usbmuxd;
          apple-dev-ipsw = p.ipsw;
        };

      packages = forAll (pkgs:
        let
          swift = pkgs.callPackage ./pkgs/swift.nix { };
          mkFHSEnv = pkgs.callPackage ./pkgs/fhs-env.nix { inherit swift; };
          mkSwiftPM = pkgs.callPackage ./pkgs/swiftpm.nix { };
          tools = pkgs.callPackage ./pkgs/tools.nix { inherit mkSwiftPM upstream; };
          ipsw = pkgs.callPackage ./pkgs/ipsw.nix { };
          python-env = pkgs.callPackage ./pkgs/python.nix {
            inherit pyproject-nix uv2nix pyproject-build-systems;
          };
          upstream-patched = pkgs.callPackage ./pkgs/upstream.nix { src = upstream; };
          ios-sdk = pkgs.callPackage ./pkgs/ios-sdk.nix {
            inherit (tools) xtool open-apple-macros actool;
            upstream = upstream-patched;
          };
          apple-dev = pkgs.callPackage ./pkgs/fhs.nix {
            inherit mkFHSEnv;
            flakeSrc = self.outPath;
            upstream = upstream-patched;
            # first on PATH: python-env's python3 has cryptography for upstream's tools
            tools = [ python-env tools.xtool ipsw pkgs.rcodesign ];
          };
        in
        {
          inherit swift ipsw python-env upstream-patched apple-dev ios-sdk;
          inherit (tools) xtool open-apple-macros actool;
          usbmuxd = pkgs.callPackage ./pkgs/usbmuxd-service.nix { };
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
      homeManagerModules.default = import ./modules/home-manager.nix self;
    };
}
