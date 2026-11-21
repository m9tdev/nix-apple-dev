#!/usr/bin/env bash
set -euo pipefail

SIM_LEASE=${1:?usage: sim-lease-protected.sh /path/to/sim-lease}
PROTECTED=EDD04C40-B5A6-4135-A2BB-19444D4E00B4
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
export SIM_LEASE_PREFIX=pool-test-
export SIM_LEASE_POOL_SIZE=1
export SIM_LEASE_STATE_DIR=$TMP/state
export XCRUN_TRACE=$TMP/trace
: >"$XCRUN_TRACE"

cat >"$TMP/bin/xcrun" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$XCRUN_TRACE"
case "$*" in
  'simctl list devicetypes --json')
    cat <<'JSON'
{"devicetypes":[{"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}
JSON
    ;;
  'simctl list runtimes --json')
    cat <<'JSON'
{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}]}
JSON
    ;;
  'simctl list devices --json' | 'simctl list devices booted --json')
    cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"name":"pool-test-iphone-1","udid":"EDD04C40-B5A6-4135-A2BB-19444D4E00B4","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}}
JSON
    ;;
  *)
    echo "unexpected simulator mutation: $*" >&2
    exit 99
    ;;
esac
SH
chmod +x "$TMP/bin/xcrun"
export PATH=$TMP/bin:$PATH

status=$("$SIM_LEASE" status)
grep -q "pool-test-iphone-1 $PROTECTED Booted PROTECTED (never touched)" <<<"$status"
[[ $(grep -c 'PROTECTED (never touched)' <<<"$status") -eq 2 ]]

set +e
init_output=$("$SIM_LEASE" init 2>&1)
init_rc=$?
set -e
[[ $init_rc -ne 0 ]]
grep -q 'is protected (known non-pool); refusing every simulator operation' <<<"$init_output"
if grep -Eq 'simctl (create|boot|shutdown|uninstall|keychain|erase|delete|launchctl)' "$XCRUN_TRACE"; then
  echo 'protected UDID reached a simulator mutation' >&2
  exit 1
fi

set +e
undo_output=$("$SIM_LEASE" undo "$PROTECTED" 2>&1)
undo_rc=$?
set -e
[[ $undo_rc -ne 0 ]]
grep -q 'is protected (known non-pool); refusing every simulator operation' <<<"$undo_output"

echo 'protected-UDID regression test: PASS'
