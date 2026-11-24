# shellcheck shell=bash
# xcrun and simctl shim for the sim-lease pool (installed as bin/xcrun and
# bin/simctl). It refuses simctl calls that target a leased pool simulator
# from any process that does not hold that lease, and the ambiguous `booted`
# and `all` targets while any lease is live. Everything else is handed
# unchanged to the next xcrun on PATH.
#
# A lease is held by the process tree of `sim-lease run`: it exports
# SIM_LEASE_TOKEN, which matches the token in its lease record. This guards
# against mistakes (a stale UDID, a helper outside the lease), not against a
# determined caller: anything that calls the real xcrun or simctl by absolute
# path, or talks to CoreSimulator directly, is not seen here.
#
# The packaging puts a shebang, the marker line below, and JQ=<path> in front
# of this file. The marker lets the shim skip itself (and other copies of
# itself) when it looks for the real xcrun.
set -euo pipefail

GUARD_MARKER='# sim-lease-guard: shim for xcrun and simctl'
: "${JQ:=jq}"
GUARD_STATE_DIR=${SIM_LEASE_STATE_DIR:-/tmp/sim-lease}
GUARD_TOOL=${0##*/}
REAL_XCRUN=
LEASE_UDIDS=()
LEASE_NAMES=()
LEASE_PIDS=()
LEASE_TOKENS=()
LEASE_STARTED=()

guard_log() {
  printf 'sim-lease-guard: %s\n' "$*" >&2
}

is_guard() {
  local magic='' line2=''
  IFS= read -r -n 2 magic <"$1" 2>/dev/null || true
  [[ $magic == '#!' ]] || return 1
  { IFS= read -r _ && IFS= read -r line2; } <"$1" 2>/dev/null || return 1
  [[ $line2 == "$GUARD_MARKER" ]]
}

find_real_xcrun() {
  local dir candidate
  local -a dirs
  IFS=: read -r -a dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    candidate=${dir:-.}/xcrun
    [[ -f $candidate && -x $candidate ]] || continue
    is_guard "$candidate" && continue
    REAL_XCRUN=$candidate
    return 0
  done
  return 1
}

# Live leases of every pool prefix under the state directory. A record whose
# PID is gone is stale: sim-lease reclaims it, and it guards nothing.
load_leases() {
  local file udid name pid token started
  for file in "$GUARD_STATE_DIR"/*/leases/*; do
    [[ -f $file && $file != *.tmp.* ]] || continue
    IFS=$'\t' read -r udid name pid token started < <(
      "$JQ" -r '[.udid, .name, (.pid | tostring), (.token // ""), (.started // "")] | @tsv' \
        "$file" 2>/dev/null
    ) || continue
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    LEASE_UDIDS+=("$udid")
    LEASE_NAMES+=("$name")
    LEASE_PIDS+=("$pid")
    LEASE_TOKENS+=("$token")
    LEASE_STARTED+=("$started")
  done
  ((${#LEASE_UDIDS[@]} > 0))
}

# Recorded for the lease's release report and for later inspection.
record_refusal() {
  local token=$1 command=$2 now
  printf -v now '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s\t%s\tpid=%s ppid=%s\t%s\n' "$now" "$token" "$$" "$PPID" "$command" \
    >>"$GUARD_STATE_DIR/guard.log" 2>/dev/null || true
}

refuse_target() {
  local index=$1 subcommand=$2 target=$3
  record_refusal "${LEASE_TOKENS[index]}" "simctl $subcommand $target"
  guard_log "refusing 'simctl $subcommand $target': ${LEASE_NAMES[index]} (${LEASE_UDIDS[index]}) is leased to sim-lease PID ${LEASE_PIDS[index]} since ${LEASE_STARTED[index]:-unknown}, and this process does not hold that lease."
  guard_log "use a pool simulator only inside 'sim-lease run -- COMMAND', through the SIM_UDID it exports; a UDID saved by an earlier lease is stale."
  exit 77
}

refuse_ambiguous() {
  local subcommand=$1 target=$2
  record_refusal - "simctl $subcommand $target"
  guard_log "refusing 'simctl $subcommand $target': '$target' can resolve to a leased pool simulator while ${#LEASE_UDIDS[@]} sim-lease lease(s) are live."
  guard_log "name the simulator by UDID (inside 'sim-lease run', use SIM_UDID)."
  exit 77
}

# check_simctl ARG...: the arguments after `simctl`.
check_simctl() {
  local -a args=("$@") targets=()
  local i=0 subcommand='' arg index all_targets=0
  while ((i < ${#args[@]})); do
    case ${args[i]} in
      --set | --profiles) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *)
        subcommand=${args[i]}
        i=$((i + 1))
        break
        ;;
    esac
  done
  case $subcommand in
    '' | list | help | create | runtime) return 0 ;;
    # These take several devices; every other subcommand takes one device
    # first, and later arguments belong to it (an app, a program, a setting).
    boot | shutdown | erase | delete | pbsync) all_targets=1 ;;
  esac
  for arg in "${args[@]:i}"; do
    [[ $arg == -* ]] && continue
    targets+=("$arg")
    ((all_targets)) || break
  done
  ((${#targets[@]} > 0)) || return 0
  load_leases || return 0

  for arg in "${targets[@]}"; do
    case ${arg,,} in
      booted | all) refuse_ambiguous "$subcommand" "$arg" ;;
    esac
    for index in "${!LEASE_UDIDS[@]}"; do
      if [[ ${arg^^} == "${LEASE_UDIDS[index]^^}" || $arg == "${LEASE_NAMES[index]}" ]]; then
        if [[ -z ${SIM_LEASE_TOKEN:-} || ${SIM_LEASE_TOKEN} != "${LEASE_TOKENS[index]}" ]]; then
          refuse_target "$index" "$subcommand" "$arg"
        fi
      fi
    done
  done
}

guard_main() {
  local -a args=("$@")
  local i=0 tool=''
  if ! find_real_xcrun; then
    guard_log "no xcrun found on PATH besides this guard"
    exit 127
  fi
  if [[ $GUARD_TOOL == simctl ]]; then
    check_simctl "$@"
    exec "$REAL_XCRUN" simctl "$@"
  fi
  # xcrun [OPTIONS] TOOL [ARG...]
  while ((i < ${#args[@]})); do
    case ${args[i]} in
      -sdk | --sdk | -toolchain | --toolchain) i=$((i + 2)) ;;
      -r | -run | --run)
        tool=${args[i + 1]:-}
        i=$((i + 2))
        break
        ;;
      -f | -find | --find) break ;;
      --)
        tool=${args[i + 1]:-}
        i=$((i + 2))
        break
        ;;
      -*) i=$((i + 1)) ;;
      *)
        tool=${args[i]}
        i=$((i + 1))
        break
        ;;
    esac
  done
  if [[ ${tool##*/} == simctl ]]; then
    check_simctl "${args[@]:i}"
  fi
  exec "$REAL_XCRUN" "$@"
}

guard_main "$@"
