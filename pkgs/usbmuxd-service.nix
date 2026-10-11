# `apple-dev-usbmuxd`: start usbmuxd without a NixOS module (run as root).
# It needs root because it claims the iPhone's USB device. With systemd it
# starts a transient unit (gone on reboot: run it again after a reboot);
# without systemd it runs in the foreground.
{ writeShellScriptBin, usbmuxd, systemd }:

writeShellScriptBin "apple-dev-usbmuxd" ''
  set -euo pipefail
  if [ "$(id -u)" -ne 0 ]; then
    echo "apple-dev-usbmuxd: run as root, e.g.: sudo nix run github:m9tdev/nix-apple-dev#usbmuxd" >&2
    exit 1
  fi
  unit=apple-dev-usbmuxd
  if [ -d /run/systemd/system ]; then
    if ${systemd}/bin/systemctl is-active --quiet usbmuxd.service; then
      echo "usbmuxd.service (the system one) is already active; nothing to do."
      exit 0
    fi
    if ${systemd}/bin/systemctl is-active --quiet $unit; then
      echo "$unit is already active."
      exit 0
    fi
    ${systemd}/bin/systemd-run --unit=$unit --description="usbmuxd for nix-apple-dev" \
      ${usbmuxd}/bin/usbmuxd --foreground --verbose
    echo "Started $unit. Stop: systemctl stop $unit. Logs: journalctl -u $unit"
  else
    exec ${usbmuxd}/bin/usbmuxd --foreground --verbose
  fi
''
