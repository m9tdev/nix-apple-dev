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
| xtool's Linux linker toolset | release tarball, pinned by hash (xtool would download it) |
| upstream scripts | pinned revision, patched to use the tools above (`pkgs/patch-upstream.py`) |
| iOS SDK (`ios-sdk`) | built by Nix from your own `Xcode_27.xip` (a `requireFile`: Nix cannot download it). Only the SDK (1.2 GB) is kept; Xcode.app is never stored. |

Everything is in the Nix store. `$HOME` only has links to the SDK for SwiftPM.
The SDK is unfree (Apple's files): never push it to a public binary cache.

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

## Set up the SDK (one time per host)

1. Get Xcode 27.0 (its Swift matches 6.4). Download it in a browser
   (<https://developer.apple.com/download/all/?q=Xcode>), or run
   `nix run github:m9tdev/nix-apple-dev#ipsw -- download dev --more --output ~/Downloads`
   (Apple ID + 2FA).
2. Add it to the Nix store, then delete the download:
   `nix-store --add-fixed sha256 ~/Downloads/Xcode_27.xip`
3. `apple-dev-setup`
   This builds the SDK (about 2 minutes; xtool unpacks the xip to about 10 GB of
   temporary space) and registers it. At the end, `swift sdk list` shows `darwin`.

Another host does not need the xip: copy the built SDK there
(`nix copy --to ssh://HOST $(nix build --print-out-paths github:m9tdev/nix-apple-dev#ios-sdk)`),
then run `apple-dev-setup` on that host.

After `nix-collect-garbage` the xip can be gone; the SDK stays (setup makes it a
GC root). To build the SDK again (for example after an update of this flake),
add the xip to the store again.

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
- `pkgs/patch-xtool.py` lets `xtool sdk build` run offline (the toolset and the
  macro server come from Nix). Xcode.xip stores many files in Apple's
  compressed form (decmpfs), so the SDK must be unpacked by xtool, not by cpio.
- Update a SwiftPM lock: resolve the package inside `apple-dev`, then run
  `scripts/swiftpm-lock.py .build/workspace-state.json > pkgs/locks/NAME.json`.
- x86_64-linux only for now.
- Apple's Xcode licence allows its use only on Apple-branded computers.
  You decide if that matters for your use.
