# shellcheck shell=bash

PREFIX=${SIM_LEASE_PREFIX:-pool-}
POOL_SIZE=${SIM_LEASE_POOL_SIZE:-2}
MAX_BOOTED=${SIM_LEASE_MAX_BOOTED:-2}
STATE_DIR=${SIM_LEASE_STATE_DIR:-/tmp/sim-lease}
POLL_INTERVAL=${SIM_LEASE_POLL_INTERVAL:-2}
DEVICE_TYPE_REQUEST=${SIM_LEASE_DEVICE_TYPE:-}
RUNTIME_REQUEST=${SIM_LEASE_RUNTIME:-}
DEVICE_TYPE=
RUNTIME=
CURRENT_UDID=
CURRENT_NAME=
CURRENT_STARTED=

usage() {
  cat <<'EOF'
Usage:
  sim-lease init [--device-type TYPE] [--runtime RUNTIME] [--pool-size N]
  sim-lease run [--device-type TYPE] [--runtime RUNTIME] [--max-booted N] -- COMMAND [ARG ...]
  sim-lease status [--device-type TYPE] [--runtime RUNTIME]
  sim-lease --help

Commands:
  init     Create missing fixed pool sims, run simslim on each, then shut them down.
  run      Queue for a boot slot, lease a pool sim, and run COMMAND with SIM_UDID.
  status   Show pool devices, lease liveness, booted devices, and orphans.

Pool sims are named ${SIM_LEASE_PREFIX:-pool-}iphone-1..N. run never creates,
erases, or deletes a simulator. Cleanup uninstalls user apps, resets the
keychain, verifies simslim state, and shuts down only the leased pool sim.
EOF
}

log() {
  printf 'sim-lease: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

validate_settings() {
  [[ $PREFIX =~ ^pool-[A-Za-z0-9._-]*$ ]] || die "SIM_LEASE_PREFIX must match pool-[A-Za-z0-9._-]*"
  [[ $POOL_SIZE =~ ^[1-9][0-9]*$ ]] || die "pool size must be a positive integer"
  [[ $MAX_BOOTED =~ ^[1-9][0-9]*$ ]] || die "max booted must be a positive integer"
  [[ $POLL_INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] || die "poll interval must be numeric"
  POOL_STATE=$STATE_DIR/$PREFIX
  LEASE_DIR=$POOL_STATE/leases
  LOCK_DIR=$POOL_STATE/locks
  QUEUE_LOCK=$STATE_DIR/queue.lock
}

ensure_state() {
  mkdir -p "$LEASE_DIR" "$LOCK_DIR"
  : >>"$QUEUE_LOCK"
}

all_devices_json() {
  xcrun simctl list devices --json
}

booted_devices_json() {
  xcrun simctl list devices booted --json
}

# Flatten simctl's runtime-keyed object and retain the runtime on each record.
flatten_devices() {
  jq -c '.devices | to_entries[] | .key as $runtime | .value[] |
    select(.isAvailable != false) | . + {runtimeIdentifier: $runtime}'
}

resolve_config() {
  local types_json runtimes_json
  types_json=$(xcrun simctl list devicetypes --json) || die "cannot list simulator device types"
  if [[ -n $DEVICE_TYPE_REQUEST ]]; then
    DEVICE_TYPE=$(jq -er --arg request "$DEVICE_TYPE_REQUEST" '
      [.devicetypes[] | select(.name == $request or .identifier == $request)] |
      if length == 1 then .[0].identifier else error("device type is missing or ambiguous") end
    ' <<<"$types_json") || die "unknown or ambiguous device type: $DEVICE_TYPE_REQUEST"
  else
    DEVICE_TYPE=$(jq -er '
      [.devicetypes[] | select(.identifier |
        test("com[.]apple[.]CoreSimulator[.]SimDeviceType[.]iPhone-[0-9]+$"))] |
      if length > 0 then .[0].identifier else error("no iPhone device type installed") end
    ' <<<"$types_json") || die "no iPhone device type is installed; set SIM_LEASE_DEVICE_TYPE"
  fi

  runtimes_json=$(xcrun simctl list runtimes --json) || die "cannot list simulator runtimes"
  RUNTIME=$(jq -er --arg request "$RUNTIME_REQUEST" --arg type "$DEVICE_TYPE" '
    [.runtimes[] |
      select(.isAvailable == true and .platform == "iOS") |
      select(any(.supportedDeviceTypes[]?; .identifier == $type)) |
      select($request == "" or .name == $request or .version == $request or .identifier == $request) |
      select($request != "" or (.identifier | test("SimRuntime[.]iOS-[0-9-]+$")))
    ] |
    sort_by(.identifier | test("SimRuntime[.]iOS-[0-9-]+$")) |
    if length > 0 then .[-1].identifier else error("no compatible installed iOS runtime") end
  ' <<<"$runtimes_json") || die "no installed iOS runtime matches device type $DEVICE_TYPE and runtime ${RUNTIME_REQUEST:-default}"
}

pool_name() {
  printf '%siphone-%s' "$PREFIX" "$1"
}

lease_file() {
  printf '%s/%s' "$LEASE_DIR" "$1"
}

device_lock_file() {
  printf '%s/%s.lock' "$LOCK_DIR" "$1"
}

lease_pid() {
  jq -er '.pid | select(type == "number" and . > 0)' "$(lease_file "$1")" 2>/dev/null
}

lease_live() {
  local udid=$1 pid
  [[ -f $(lease_file "$udid") ]] || return 1
  pid=$(lease_pid "$udid") || return 1
  kill -0 "$pid" 2>/dev/null
}

drop_stale_lease() {
  local udid=$1 file pid
  file=$(lease_file "$udid")
  [[ -e $file ]] || return 0
  if lease_live "$udid"; then
    return 0
  fi
  pid=$(lease_pid "$udid" 2>/dev/null || printf 'unknown')
  log "stale lease for $udid (PID $pid); reclaiming"
  rm -f "$file"
}

write_lease() {
  local state=$1 file tmp
  file=$(lease_file "$CURRENT_UDID")
  tmp=$file.tmp.$$
  jq -n --arg udid "$CURRENT_UDID" --arg name "$CURRENT_NAME" \
    --arg state "$state" --arg started "$CURRENT_STARTED" --argjson pid "$$" \
    '{udid: $udid, name: $name, pid: $pid, state: $state, started: $started}' >"$tmp"
  mv "$tmp" "$file"
}

remove_user_apps() {
  local udid=$1 plist bundle rc=0
  plist=$(mktemp "${TMPDIR:-/tmp}/sim-lease-apps.XXXXXX") || return 1
  if xcrun simctl listapps "$udid" >"$plist"; then
    while IFS= read -r bundle; do
      [[ -n $bundle && $bundle != com.apple.* ]] || continue
      log "uninstalling $bundle from $udid"
      xcrun simctl uninstall "$udid" "$bundle" || rc=1
    done < <(plutil -convert json -o - "$plist" | jq -r 'keys[]')
  else
    log "warning: cannot list user apps on $udid"
    rc=1
  fi
  rm -f "$plist"
  return "$rc"
}

# The caller must hold the device lease/lock and establish that this is a pool UDID.
cleanup_device() {
  local udid=$1 rc=0
  log "cleaning pool sim $udid"
  remove_user_apps "$udid" || rc=1
  xcrun simctl keychain "$udid" reset || rc=1
  if ! simslim verify "$udid"; then
    log "warning: simslim verification failed for $udid; run init again before reuse"
    rc=1
  fi
  xcrun simctl shutdown "$udid" || rc=1
  return "$rc"
}

release_current() {
  local rc=$? cleanup_rc=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ -n $CURRENT_UDID ]]; then
    cleanup_device "$CURRENT_UDID" || cleanup_rc=$?
    rm -f "$(lease_file "$CURRENT_UDID")"
    exec 8>&-
    log "released $CURRENT_NAME ($CURRENT_UDID)"
    CURRENT_UDID=
  fi
  exec 9>&-
  if [[ $rc -eq 0 && $cleanup_rc -ne 0 ]]; then
    rc=$cleanup_rc
  fi
  exit "$rc"
}

install_cleanup_trap() {
  trap release_current EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

report_external_booted() {
  local json=$1
  while IFS= read -r device; do
    local name udid
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    if [[ $name == "$PREFIX"* ]]; then
      if ! lease_live "$udid"; then
        log "orphan pool sim: $name ($udid)"
      fi
    else
      log "external/orphan booted sim (left untouched): $name ($udid)"
    fi
  done < <(flatten_devices <<<"$json")
}

clean_pool_orphans() {
  local json=$1 device name udid
  while IFS= read -r device; do
    name=$(jq -r '.name' <<<"$device")
    [[ $name == "$PREFIX"* ]] || continue
    udid=$(jq -r '.udid' <<<"$device")
    lease_live "$udid" && continue
    drop_stale_lease "$udid"
    exec 6<>"$(device_lock_file "$udid")"
    if ! flock -n 6; then
      log "pool sim $name ($udid) is locked but has no live lease; leaving it untouched"
      exec 6>&-
      continue
    fi
    cleanup_device "$udid" || log "warning: orphan cleanup failed for $name ($udid)"
    exec 6>&-
  done < <(flatten_devices <<<"$json")
}

booted_count() {
  jq '[.devices[]? | .[] | select(.state == "Booted")] | length' <<<"$1"
}

wait_for_boot_slot() {
  local json announced=0 waiting=0 count
  while true; do
    json=$(booted_devices_json) || die "cannot list booted simulators"
    if [[ $announced -eq 0 ]]; then
      report_external_booted "$json"
      announced=1
    fi
    clean_pool_orphans "$json"
    json=$(booted_devices_json) || die "cannot recount booted simulators"
    count=$(booted_count "$json")
    if ((count < MAX_BOOTED)); then
      return 0
    fi
    if [[ $waiting -eq 0 ]]; then
      log "boot limit reached ($count/$MAX_BOOTED); waiting in the machine-wide queue"
      waiting=1
    fi
    sleep "$POLL_INTERVAL"
  done
}

find_pool_device() {
  local name=$1 json
  json=$(all_devices_json) || return 1
  flatten_devices <<<"$json" | jq -ce --arg name "$name" 'select(.name == $name)' | head -n 1
}

validate_pool_device() {
  local device=$1 name=$2 actual_type actual_runtime
  actual_type=$(jq -r '.deviceTypeIdentifier // empty' <<<"$device")
  actual_runtime=$(jq -r '.runtimeIdentifier // empty' <<<"$device")
  [[ $actual_type == "$DEVICE_TYPE" ]] || die "$name has device type $actual_type, expected $DEVICE_TYPE; use a separate SIM_LEASE_PREFIX"
  [[ $actual_runtime == "$RUNTIME" ]] || die "$name has runtime $actual_runtime, expected $RUNTIME; use a separate SIM_LEASE_PREFIX"
}

cmd_init() {
  local i name device udid count json
  validate_settings
  resolve_config
  ensure_state
  install_cleanup_trap
  exec 9<>"$QUEUE_LOCK"
  flock -x 9
  log "initializing $POOL_SIZE sims ($DEVICE_TYPE, $RUNTIME)"

  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name" || true)
    if [[ -n $device ]]; then
      validate_pool_device "$device" "$name"
      udid=$(jq -r '.udid' <<<"$device")
      if lease_live "$udid"; then
        die "$name has a live lease; init cannot change it"
      fi
    fi
  done

  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name" || true)
    if [[ -z $device ]]; then
      udid=$(xcrun simctl create "$name" "$DEVICE_TYPE" "$RUNTIME") || die "cannot create $name"
      log "created $name ($udid)"
    else
      udid=$(jq -r '.udid' <<<"$device")
    fi
    drop_stale_lease "$udid"
    exec 8<>"$(device_lock_file "$udid")"
    flock -x 8
    while true; do
      json=$(booted_devices_json) || die "cannot list booted simulators"
      report_external_booted "$json"
      clean_pool_orphans "$json"
      json=$(booted_devices_json) || die "cannot list booted simulators"
      count=$(booted_count "$json")
      ((count < MAX_BOOTED)) && break
      log "boot limit reached ($count/$MAX_BOOTED); waiting to slim $name"
      sleep "$POLL_INTERVAL"
    done
    CURRENT_UDID=$udid
    CURRENT_NAME=$name
    simslim on "$udid"
    simslim verify "$udid"
    cleanup_device "$udid"
    CURRENT_UDID=
    exec 8>&-
  done
  log "pool ready; all pool sims are shut down"
}

cmd_run() {
  local command=("$@") i name device udid state
  ((${#command[@]} > 0)) || die "run needs a command after --"
  validate_settings
  resolve_config
  ensure_state
  install_cleanup_trap

  # The queue is held through waiting and boot, but not while COMMAND runs.
  # Cleanups only need their device lock, so they can free capacity for a waiter.
  exec 9<>"$QUEUE_LOCK"
  flock -x 9
  wait_for_boot_slot

  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name" || true)
    [[ -n $device ]] || die "$name is missing; run sim-lease init with the same pool settings first"
    validate_pool_device "$device" "$name"
    udid=$(jq -r '.udid' <<<"$device")
    exec 8<>"$(device_lock_file "$udid")"
    if ! flock -n 8; then
      exec 8>&-
      continue
    fi
    if lease_live "$udid"; then
      exec 8>&-
      continue
    fi
    drop_stale_lease "$udid"
    state=$(jq -r '.state' <<<"$device")
    if [[ $state == Booted ]]; then
      cleanup_device "$udid"
    fi
    CURRENT_UDID=$udid
    CURRENT_NAME=$name
    CURRENT_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_lease booting
    break
  done
  [[ -n $CURRENT_UDID ]] || die "all pool sims are leased; waiting for a device is not possible with the current pool size"

  log "booting $CURRENT_NAME ($CURRENT_UDID) with SIM_UDID"
  if [[ $(jq -r '.state' <<<"$device") != Booted ]]; then
    xcrun simctl boot "$CURRENT_UDID"
  fi
  xcrun simctl bootstatus "$CURRENT_UDID" -b
  simslim verify "$CURRENT_UDID"
  write_lease running
  flock -u 9
  exec 9>&-
  log "leased $CURRENT_NAME to PID $$"

  set +e
  SIM_UDID="$CURRENT_UDID" SIM_LEASE_DEVICE="$CURRENT_NAME" "${command[@]}" 8>&- 9>&-
  local rc=$?
  set -e
  exit "$rc"
}

cmd_status() {
  local i name device udid pid state lease json booted
  validate_settings
  resolve_config
  printf 'Pool: prefix=%s size=%s device-type=%s runtime=%s\n' "$PREFIX" "$POOL_SIZE" "$DEVICE_TYPE" "$RUNTIME"
  for ((i = 1; i <= POOL_SIZE; i++)); do
    name=$(pool_name "$i")
    device=$(find_pool_device "$name" || true)
    if [[ -z $device ]]; then
      printf '  %s MISSING\n' "$name"
      continue
    fi
    udid=$(jq -r '.udid' <<<"$device")
    state=$(jq -r '.state' <<<"$device")
    lease=free
    if [[ -f $(lease_file "$udid") ]]; then
      pid=$(lease_pid "$udid" 2>/dev/null || printf 'unknown')
      if lease_live "$udid"; then
        lease="leased pid=$pid"
      else
        lease="STALE pid=$pid"
      fi
    fi
    printf '  %s %s %s %s\n' "$name" "$udid" "$state" "$lease"
  done

  json=$(booted_devices_json) || die "cannot list booted simulators"
  booted=$(booted_count "$json")
  printf 'Booted: %s (configured cap %s; all sims counted)\n' "$booted" "$MAX_BOOTED"
  while IFS= read -r device; do
    name=$(jq -r '.name' <<<"$device")
    udid=$(jq -r '.udid' <<<"$device")
    if [[ $name == "$PREFIX"* ]]; then
      if lease_live "$udid"; then
        printf '  %s %s leased (not orphan)\n' "$name" "$udid"
      else
        printf '  %s %s ORPHAN pool sim\n' "$name" "$udid"
      fi
    else
      printf '  %s %s ORPHAN/EXTERNAL (never touched)\n' "$name" "$udid"
    fi
  done < <(flatten_devices <<<"$json")
}

COMMAND=${1:-}
if [[ $COMMAND == --help || $COMMAND == -h ]]; then
  usage
  exit 0
fi
[[ -n $COMMAND ]] || {
  usage >&2
  exit 2
}
shift

while (($#)); do
  case $1 in
    --device-type)
      (($# >= 2)) || die "--device-type needs a value"
      DEVICE_TYPE_REQUEST=$2
      shift 2
      ;;
    --runtime)
      (($# >= 2)) || die "--runtime needs a value"
      RUNTIME_REQUEST=$2
      shift 2
      ;;
    --pool-size)
      (($# >= 2)) || die "--pool-size needs a value"
      POOL_SIZE=$2
      shift 2
      ;;
    --max-booted)
      (($# >= 2)) || die "--max-booted needs a value"
      MAX_BOOTED=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

case $COMMAND in
  init)
    (($# == 0)) || die "init takes no positional arguments"
    cmd_init
    ;;
  run)
    (($# > 0)) || die "run requires -- followed by a command"
    cmd_run "$@"
    ;;
  status)
    (($# == 0)) || die "status takes no positional arguments"
    cmd_status
    ;;
  *)
    die "unknown command: $COMMAND (expected init, run, or status)"
    ;;
esac
