# Shared, slim iOS simulator leases (`sim-lease`)

`sim-lease` lets independent projects share a fixed set of reusable iOS
simulators on one Mac. It prevents the usual failure mode of CI creating and
booting another simulator for every job:

- a host-wide queue allows at most **two booted simulators** by default,
  counting every booted simulator visible to `simctl`, not just pool members;
- `simslim` disables unneeded background daemons in each pool simulator;
- a lease exports the simulator UDID to the test command and always cleans and
  shuts down the simulator afterwards;
- stale leases are detected by holder PID liveness and recovered by a later run.

The tool is a plain Bash CLI. It does not depend on a particular CI system or
automation tool. Packages are available for `aarch64-darwin`; Xcode and an
installed iOS Simulator runtime are required.

## Install or run without installing

```sh
# Run directly; nothing is added to a profile.
nix run github:m9tdev/nix-apple-dev#sim-lease -- --help

# Or install the two commands in the user's Nix profile.
nix profile install github:m9tdev/nix-apple-dev#sim-lease
```

`sim-lease` includes `simslim` in its runtime PATH. To run `simslim` directly
(for example, for undo), install it too or use
`nix run github:m9tdev/nix-apple-dev#simslim -- COMMAND`.

## One-time pool setup

```sh
sim-lease init
sim-lease status
```

By default this creates two simulators named `pool-iphone-1` and
`pool-iphone-2`, using the highest-numbered base iPhone device type supported by
the newest compatible, generally available installed iOS runtime. It runs `simslim on` and
`simslim verify` for each, then shuts it down. Existing matching pool members
are reused; missing ones are created. `init` refuses to change a simulator with
a live lease.

A normal `run` **never creates a simulator**. Use a separate prefix when a
different device type or runtime is wanted; one prefix cannot contain two
configurations under the same names. For example:

```sh
SIM_LEASE_PREFIX=pool-ipad- \
SIM_LEASE_DEVICE_TYPE='iPad (A16)' \
  sim-lease init --pool-size 2
```

Only use a prefix owned by this pool. Prefixes must start with `pool-`; the
safety checks and cleanup below apply only to exact `${prefix}iphone-N` member
names. In particular, the default `pool-` prefix does not claim `pool-ipad-…`
or any other differently named simulator.

## Run a test

```sh
sim-lease run -- sh -c \
  'xcodebuild test -scheme MyApp -destination "platform=iOS Simulator,id=$SIM_UDID"'
```

`run` leases a free pool member, boots it, verifies its `simslim` state, and
exports these variables to the command:

| Variable | Value |
|---|---|
| `SIM_UDID` | UDID of the leased simulator; use this in the test destination |
| `SIM_LEASE_DEVICE` | Pool name, such as `pool-iphone-1` |

The command's exit status is preserved. Before the command starts, and again in
an EXIT/HUP/INT/TERM trap afterwards, `sim-lease` uninstalls non-Apple user
apps, resets the keychain, and verifies that the slim launchd overrides are
still present. Afterwards it also shuts down the simulator and releases the
lease. Entry cleaning covers a stale simulator that somebody shut down after a
holder crashed. Exit cleaning and shutdown happen even when the test fails.
Cleanup does not use `simctl erase`, so it does not depend on erase preserving
host-side launchd state.

If a holder is killed with `SIGKILL`, its trap cannot run. Its lease record
remains until a later `run` observes that the PID is dead; that run reclaims,
cleans, and shuts down the stale pool member before reuse. `status` reports such
a lease as `STALE` without changing it.

Before booting, `run` executes `xcrun simctl list devices booted --json`. It
reports external booted simulators and orphaned pool members. It cleans and
shuts down only orphaned exact members of the selected pool. **It never shuts
down, erases, uninstalls from, or deletes a non-pool simulator.** Other pool
prefixes and even differently named `pool-…` devices are external too. The
script has no simulator-delete command and never deletes a simulator or runtime.

External programs that do not use `sim-lease` can still boot a simulator after
the capacity check. Run all simulator-launching jobs through the same queue to
enforce the cap consistently.

## Commands

```text
sim-lease init [--device-type TYPE] [--runtime RUNTIME] [--pool-size N]
sim-lease run [--device-type TYPE] [--runtime RUNTIME] [--max-booted N] -- COMMAND [ARG ...]
sim-lease status [--device-type TYPE] [--runtime RUNTIME]
sim-lease --help
```

- `init`: create missing fixed pool members, apply and verify `simslim`, then
  shut down each member. It uses the same boot cap and queue as `run`.
- `run`: wait for capacity and a free lease, boot, run the command, clean, shut
  down, and release. Two commands can run concurrently with the default cap;
  a third waits.
- `status`: read-only pool, lease, booted-device, and orphan report.

## Environment and flags

Flags override the corresponding environment variable for that invocation.

| Environment variable | Default | Meaning |
|---|---|---|
| `SIM_LEASE_PREFIX` | `pool-` | Owned pool-name prefix; must start with `pool-` |
| `SIM_LEASE_POOL_SIZE` | `2` | Number of fixed pool members, named `iphone-1..N` under the prefix |
| `SIM_LEASE_MAX_BOOTED` | `2` | Maximum booted simulators before a new pool boot; all booted sims count |
| `SIM_LEASE_DEVICE_TYPE` | Highest-numbered base iPhone supported by the selected runtime | Device-type name or identifier; flag: `--device-type` |
| `SIM_LEASE_RUNTIME` | Newest compatible general installed iOS runtime | Runtime name, version, or identifier; flag: `--runtime` |
| `SIM_LEASE_STATE_DIR` | `/tmp/sim-lease` | Shared queue and per-prefix lease/lock state |
| `SIM_LEASE_POLL_INTERVAL` | `2` | Seconds between capacity checks while queued |
| `SIMSLIM_BOOT_TIMEOUT` | `10m` (upstream) | Optional timeout for `simslim on` during `init` |
| `SIMSLIM_SPAWN_TIMEOUT` | `2m` (upstream) | Optional per-launchd-transition timeout during `init` |

The queue lock is `$SIM_LEASE_STATE_DIR/queue.lock`, shared by all prefixes,
rather than living in a project checkout. Keep the state directory consistent
across projects. CoreSimulator itself is per macOS user, so every participating
project must run as that user for a common view of booted devices.

## Add it to a project's CI test steps

Initialize the pool once on the runner, not in every test job. Then replace the
project's simulator destination with the leased UDID:

```yaml
- name: iOS tests
  run: |
    nix run github:m9tdev/nix-apple-dev#sim-lease -- run -- \
      sh -c 'xcodebuild test -workspace MyApp.xcworkspace -scheme MyApp \
        -destination "platform=iOS Simulator,id=$SIM_UDID"'
```

For an npm project, the same pattern works with a test script that reads
`SIM_UDID`:

```sh
sim-lease run -- npm run test:ios
```

Do not wrap the command in another simulator launcher that boots a second
simulator. Use the exact UDID rather than a destination name such as
`iPhone 17`, which can select a non-pool device.

## Undo

First stop users of the pool. Restore each pool UDID to stock and verify that
zero managed launchd labels remain disabled:

```sh
simslim off POOL_UDID
simslim status POOL_UDID    # expected: 0/N managed launchd labels disabled (stock)
```

`simslim off` is the undo operation; do not try to undo slimming by erasing a
simulator. `sim-lease status` lists the pool UDIDs.

Deleting devices is separate and irreversible. Only after the pool owner agrees,
delete the explicitly identified pool UDIDs, never a name pattern or `all`:

```sh
xcrun simctl delete POOL_UDID
```

Never delete other projects' simulators or any installed runtime. Remove the
Nix commands with:

```sh
nix profile remove sim-lease
nix profile remove simslim   # only if it was installed separately
```

`sim-lease` intentionally does not expose `simslim watch`, `disk-clean`, or
`repair-clone`: they respectively affect an entire fleet, delete data, and
perform difficult-to-reverse clone repairs.
