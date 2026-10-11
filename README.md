# nix-apple-dev

Build iOS apps on NixOS, and install them on an iPhone. You do not need a Mac.

This flake packages the Linux iOS toolchain from
[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
(Swift 6.4, xtool, the iOS SDK from `Xcode.xip`, pymobiledevice3) for NixOS.

## How it works

- Nix supplies `apple-dev`: an FHS environment that looks like Ubuntu 24.04,
  with the swift.org Swift 6.4 toolchain first on `PATH`.
- `apple-dev-setup` runs upstream's `install-toolchain.sh --user-only --mode full`
  in that environment. It builds xtool and the iOS SDK in your home directory.
  Nothing outside `$HOME` changes.
- Upstream's scripts (`device-run.sh`, `ship.sh`, `tools/*`) are on `PATH` in
  `apple-dev`, from a writable copy in
  `~/.local/share/nix-apple-dev/omarchy-apple-dev`.

## Install (NixOS)

```nix
# flake.nix
inputs.nix-apple-dev = {
  url = "github:m9tdev/nix-apple-dev";
  inputs.nixpkgs.follows = "nixpkgs";
};

# in the host's modules list
nix-apple-dev.nixosModules.default

# host config
programs.apple-dev.enable = true;
programs.apple-dev.usb.enable = true;  # usbmuxd, if the iPhone connects to this host with a cable
```

Without NixOS: `nix run github:m9tdev/nix-apple-dev` opens the shell, and
`nix shell github:m9tdev/nix-apple-dev -c apple-dev-setup` runs the setup.
You must start usbmuxd yourself.

## Set up the toolchain (one time per user)

1. Get Xcode 27.0 (its Swift must match 6.4). Use a browser
   (<https://developer.apple.com/download/all/?q=Xcode>) or:
   `apple-dev ipsw download dev --more --output ~/Downloads` (Apple ID + 2FA;
   use an `ipsw` release from 2026-10 or newer).
2. `XCODE_XIP=~/Downloads/Xcode_27.xip apple-dev-setup`
   This takes about 15 minutes. At the end, `swift sdk list` shows `darwin`.
3. On a second host, do not download Xcode again. Copy
   `~/.cache/xtool/darwin-*.xtoolsdk` to that host, then run `apple-dev-setup --repair`.

## Sign and install

The App Store Connect API key (paid account) is used for signing; you do not
need `xtool auth`:

```sh
# ~/.appstoreconnect/env (mode 600): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
apple-dev
set -a; . ~/.appstoreconnect/env; set +a
~/pymobile3-venv/bin/python "$APPLE_DEV_UPSTREAM/tools/provision-dev.py" --bundle-id com.example.hello --udid <UDID>
sign-dev.sh path/to/Hello.app Hello-dev.ipa
~/pymobile3-venv/bin/pymobiledevice3 apps install Hello-dev.ipa
~/pymobile3-venv/bin/pymobiledevice3 developer dvt launch com.example.hello
```

With a free Apple ID: `xtool auth`, then `xtool dev run` in the project directory.

## Notes

- `apple-dev` with no arguments opens a shell. `apple-dev CMD ...` runs one command.
- The pymobiledevice3 venv (`~/pymobile3-venv`) uses the environment's Python:
  run it inside `apple-dev`, not directly from the host.
- The library names that the swift.org toolchain expects (narrow versioned
  ncurses, `libedit.so.2`, `libxml2.so.2`) come from `pkgs/compat-libs.nix`.
- The SwiftBuild spec patch that upstream applies to a writable toolchain is
  applied at build time (`pkgs/patch-xcspec.py`).
- x86_64-linux only for now.
- Apple's Xcode licence allows its use only on Apple-branded computers.
  You decide if that matters for your use.
