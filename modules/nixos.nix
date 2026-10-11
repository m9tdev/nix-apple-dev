self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.apple-dev;
in
{
  options.programs.apple-dev = {
    enable = lib.mkEnableOption "the apple-dev iOS toolchain environment (apple-dev, apple-dev-setup)";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.apple-dev;
      defaultText = lib.literalExpression "nix-apple-dev.packages.\${system}.apple-dev";
      description = "The apple-dev package.";
    };
    usb.enable = lib.mkEnableOption "usbmuxd, for an iPhone on a USB cable";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    services.usbmuxd.enable = lib.mkIf cfg.usb.enable true;
  };
}
