# nix-apple-dev

Build iOS apps on NixOS, and install them on an iPhone. You do not need a Mac.

This flake packages the Linux iOS toolchain from
[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
for Nix: Swift 6.4, xtool, the iOS SDK from `Xcode.xip`, and pymobiledevice3.

## What Nix builds, what stays in $HOME

| Part | Where it comes from |
|---|---|
| Swift 6.4 toolchain | swift.org Ubuntu 24.04 build, pinned by hash, patched for Nix (`autoPatchelfHook`, a host sysroot, clang config files) |
| xtool, OpenAppleMacrosServer, actool | built by Nix from source with nixpkgs' Swift (ordinary Nix binaries); SwiftPM dependencies pinned in `pkgs/locks/` |
| pymobiledevice3 11.27, cryptography | built by Nix from `python/uv.lock` (uv2nix) |
| rcodesign | nixpkgs |
| ipsw 3.1.736 | built from source (newer than nixpkgs, whose version cannot sign in to Apple any more) |
| xtool's Linux linker toolset | release tarball, pinned by hash (xtool would download it) |
| upstream scripts | pinned revision, patched to call the tools above from `PATH` (`patches/`) |
| iOS SDK (`ios-sdk`) | built by Nix from your own `Xcode_27.xip` (a `requireFile`: Nix cannot download it). Only the SDK (1.2 GB) is kept; Xcode.app is never stored. |

Everything is in the Nix store. `$HOME` only has links to the SDK for SwiftPM.
The SDK is unfree (Apple's files): never push it to a public binary cache.

## Install

Choose one of these ways. The NixOS and home-manager modules can be used together.

### home-manager module (per user, includes the SDK links)

```nix
# home-manager imports
nix-apple-dev.homeManagerModules.default

programs.apple-dev.enable = true;
programs.apple-dev.sdk.enable = true;  # first: nix-store --add-fixed sha256 Xcode_27.xip
```

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

`apple-dev` is a small FHS environment (bubblewrap, so it needs unprivileged
user namespaces). It exists only because SwiftBuild runs some tools by fixed
path (`/usr/bin/touch` is compiled in; `/bin/cp`, `/usr/bin/sed` are in its
specs). The toolchain and the tools are ordinary Nix binaries. Nix builds do
not use bubblewrap.

Plain Swift code for Linux also builds outside `apple-dev`:
`SDKROOT=$(nix build --print-out-paths github:m9tdev/nix-apple-dev#swift)/sysroot swiftc …`.
SwiftPM packages with C targets need `apple-dev` (C files do not get `SDKROOT`).

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
pymobiledevice3 developer dvt pkill --bundle com.example.hello   # a running copy blocks the reinstall
pymobiledevice3 apps install Hello-dev.ipa
pymobiledevice3 developer dvt launch com.example.hello
```

With a free Apple ID: run `xtool auth`, then `xtool dev run` in the project directory.

## Notes

- `apple-dev` with no arguments opens a shell. `apple-dev CMD ...` runs one command.
  The Swift-built tools (xtool, the toolchain) run only inside it.
- Patches are in `patches/`. Upstream's scripts call the tools from `PATH`, and
  `install-toolchain.sh` is replaced: Nix builds everything it installs.
- The toolchain links nixpkgs libraries. Two differ from Ubuntu: `libedit.so.2`
  is nixpkgs' `libedit.so.0` (same ABI), and lldb needs narrow ncurses with
  versioned symbols, which `pkgs/swift.nix` builds.
- Upstream edits a writable toolchain for SwiftBuild. Here that edit is
  `patches/swift-strings-encoding-defaults.patch`.
- `patches/xtool-offline-sdk-build.patch` lets `xtool sdk build` run offline (the
  toolset and the macro server come from Nix). Xcode.xip stores many files in Apple's
  compressed form (decmpfs), so the SDK must be unpacked by xtool, not by cpio.
- Two Swift versions: apps need Swift 6.4 (it matches the Xcode 27 SDK), the
  swift.org build. The tools are built with nixpkgs' Swift 6.2.4.
- Update a SwiftPM lock: resolve the package inside `apple-dev`, then run
  `scripts/swiftpm-lock.py .build/workspace-state.json > pkgs/locks/NAME.json`.
- x86_64-linux only for now.
- Apple's Xcode licence allows its use only on Apple-branded computers.
  You decide if that matters for your use.

## License

MIT, see [LICENSE](LICENSE). Parts are derived from omarchy-apple-dev, xtool and
nixpkgs (all MIT); NOTICE lists them. Xcode and the SDK built from it are Apple's.
