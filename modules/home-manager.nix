# home-manager module: the apple-dev tools, and (optionally) the iOS SDK
# linked where SwiftPM and upstream's scripts look for it. The same links as
# `apple-dev-setup`, but declarative: a switch updates them, and the SDK is
# kept from garbage collection as part of the home generation.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.apple-dev;
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
  bundle = "${cfg.sdk.package}/darwin.artifactbundle";
in
{
  options.programs.apple-dev = {
    enable = lib.mkEnableOption "the apple-dev iOS toolchain environment (apple-dev, apple-dev-setup)";
    package = lib.mkOption {
      type = lib.types.package;
      default = packages.apple-dev;
      defaultText = lib.literalExpression "nix-apple-dev.packages.\${system}.apple-dev";
      description = "The apple-dev package.";
    };
    sdk = {
      enable = lib.mkEnableOption ''
        the iOS SDK, built from Xcode_27.xip and linked for SwiftPM.
        Add the xip to the Nix store first (nix-store --add-fixed sha256 Xcode_27.xip),
        or the switch fails with instructions'';
      package = lib.mkOption {
        type = lib.types.package;
        default = packages.ios-sdk;
        defaultText = lib.literalExpression "nix-apple-dev.packages.\${system}.ios-sdk";
        description = "The SDK package (a darwin.artifactbundle plus version.plist and SiriSSUKitModel).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.file = lib.mkIf cfg.sdk.enable {
      # SwiftPM reads $XDG_CONFIG_HOME/swiftpm when XDG_CONFIG_HOME is set,
      # else ~/.swiftpm: link both.
      ".swiftpm/swift-sdks/darwin.artifactbundle".source = bundle;
      "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/swiftpm/swift-sdks/darwin.artifactbundle".source =
        bundle;
      # upstream's ship.sh and tools/asc.py look next to the SDK cache
      ".cache/xtool/darwin-nix.xtoolsdk.version.plist".source = "${cfg.sdk.package}/version.plist";
      ".cache/xtool/darwin-nix.xtoolsdk.SiriSSUKitModel".source = "${cfg.sdk.package}/SiriSSUKitModel";
    };
  };
}
