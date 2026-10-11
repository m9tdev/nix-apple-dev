# nix-apple-dev

Build iOS apps on NixOS, and install them on an iPhone. You do not need a Mac.

This flake packages the Linux iOS toolchain from
[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
for Nix: Swift 6.4, xtool, the iOS SDK from `Xcode.xip`, and pymobiledevice3.

## What Nix builds, what stays in $HOME

| Part | Where it comes from |
|---|---|
| Swift 6.4 toolchain | swift.org Ubuntu 24.04 build, pinned by hash, run in an FHS environment |
| xtool, OpenAppleMacrosServer, actool | built by Nix from source; SwiftPM dependencies pinned in `pkgs/locks/` |
| pymobiledevice3 11.27, cryptography | built by Nix from `python/uv.lock` (uv2nix) |
| rcodesign | nixpkgs |
| ipsw 3.1.736 | the release binary, pinned by hash (the source cannot build: see `pkgs/ipsw.nix`) |
| upstream scripts | pinned revision, patched to use the tools above (`pkgs/patch-upstream.py`) |
| iOS SDK | **`$HOME`**: built from your `Xcode.xip` by `apple-dev-setup`. Apple's files must not go into the Nix store. |

## Install

Choose one of these two ways.

### NixOS module

```nix
# flake.nix
inputs.nix-apple-dev.url = "github:m9tdev/nix-apple-dev";

# in the host's modules list
nix-apple-dev.nixosModules.default

# host config
programs.apple-dev.enable = true;
programs.apple-dev.usb.enable = true;  # usbmuxd, if an iPhone connects to this host with a cable
```

Do not set `inputs.nixpkgs.follows`. The tools are built and tested with
this flake's nixos-unstable.

### Commands only (any Linux with Nix)

```sh
nix run github:m9tdev/nix-apple-dev                  # shell (or: nix run … -- CMD ARGS)
nix run github:m9tdev/nix-apple-dev#setup            # SDK setup in $HOME (see below)
sudo nix run github:m9tdev/nix-apple-dev#usbmuxd     # USB service; run again after each reboot
```

`#usbmuxd` needs root because usbmuxd claims the iPhone's USB device. With
systemd, it starts the transient unit `apple-dev-usbmuxd`. Without systemd, it
runs in the foreground.

The Nix build sandbox must allow user namespaces, because the tools are built
inside the FHS environment with bubblewrap. NixOS allows them by default.

## Set up the SDK (one time per user)

1. Get Xcode 27.0. Its Swift must match 6.4. Download it in a browser
   (<https://developer.apple.com/download/all/?q=Xcode>), or run
   `nix run github:m9tdev/nix-apple-dev#ipsw -- download dev --more --output ~/Downloads`
   (Apple ID + 2FA).
2. `XCODE_XIP=~/Downloads/Xcode_27.xip apple-dev-setup`
   This takes about 3 minutes. At the end, `swift sdk list` shows `darwin`.
3. On a second host, do not download Xcode again. Copy
   `~/.cache/xtool/darwin-*.xtoolsdk` to that host, then run `apple-dev-setup --repair`.

## Sign and install

With a paid account, an App Store Connect API key signs the app. You do not
need `xtool auth`.

```sh
# ~/.appstoreconnect/env (mode 600): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
apple-dev
set -a; . ~/.appstoreconnect/env; set +a
xtool new Hello && cd Hello && xtool dev build
provision-dev.py --bundle-id com.example.hello --udid <UDID>
sign-dev.sh xtool/Hello.app Hello-dev.ipa
pymobiledevice3 apps install Hello-dev.ipa
pymobiledevice3 developer dvt launch com.example.hello
```

With a free Apple ID: run `xtool auth`, then `xtool dev run` in the project directory.

## Notes

- `apple-dev` with no arguments opens a shell. `apple-dev CMD ...` runs one command.
  The Swift-built tools (xtool, the toolchain) run only inside it.
- `pkgs/compat-libs.nix` supplies the library names that the swift.org toolchain
  expects: narrow versioned ncurses, `libedit.so.2` and `libxml2.so.2`.
- Upstream patches a writable toolchain for SwiftBuild. Here that patch is
  applied at build time (`pkgs/patch-xcspec.py`).
- Update a SwiftPM lock: resolve the package inside `apple-dev`, then run
  `scripts/swiftpm-lock.py .build/workspace-state.json > pkgs/locks/NAME.json`.
- x86_64-linux only for now.
- Apple's Xcode licence allows its use only on Apple-branded computers.
  You decide if that matters for your use.
