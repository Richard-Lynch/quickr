#!/usr/bin/env bash
# A simulator of this worktree's own, so parallel worktrees never boot, install into or
# erase each other's device. Prints the device's UDID on stdout (and nothing else), creating
# it on first use: "<source> <worktree dir>-<hash of the canonical worktree path>", e.g.
# "quickR iOS-26-0 ios-m1-tools-021970", so same-named directories elsewhere never share one.
#
#   sim-clone.sh [--wait|--no-boot] [source]  create (or find) the clone and boot it;
#                                             source defaults to "quickR iOS-26-0"
#   sim-clone.sh --delete [source]            shut down and delete it
#
# Booting is admitted by the simulator cap (common.sh `sim_boot`): it refuses (non-zero,
# naming them) while IOS_SIM_CAP (default 2) other clones are booted, unless this clone is
# booted already; --wait (or IOS_SIM_WAIT=1) polls until a slot frees. --no-boot only prints
# the UDID. test.sh and sim-run.sh boot through the same admission.
#
# A shut-down source is cloned with `simctl clone`; a booted one (in use elsewhere) is never
# touched: the clone is created fresh from the same device type and runtime instead.
# Lookup, creation and deletion are serialised across worktrees by a lock (see below).
# Use it as the IOS_SIM* make variables: make ios-test IOS_SIM_MIN="$(ios/scripts/sim-clone.sh)"
source "$(dirname "$0")/common.sh"
require_xcodebuild

delete=0
if [[ "${1:-}" == --delete ]]; then delete=1; shift; fi
boot=1
if [[ "${1:-}" == --wait ]]; then export IOS_SIM_WAIT=1; shift; fi
if [[ "${1:-}" == --no-boot ]]; then boot=0; shift; fi
source_name="${1:-quickR iOS-26-0}"
root_real="$(cd "$ROOT_DIR" && pwd -P)"
name="$source_name $(basename "$root_real")-$(printf '%s' "$root_real" | shasum | cut -c1-6)"

# A kernel advisory lock (flock(2), via /usr/bin/lockf on fd 9) held for the rest of the
# script. The OS releases it when the last descriptor sharing fd 9's open file closes, i.e.
# when this script and every child that inherited fd 9 have exited or died; nothing stale
# is left on disk. lockf exits 75 (EX_TEMPFAIL) on timeout; anything else is a real error
# (a bad -t value, a descriptor problem) and keeps lockf's own message and status.
lock="${QUICKR_SIM_CLONE_LOCK:-${TMPDIR:-/tmp}/quickr-sim-clone.lockf}"
lock_wait="${QUICKR_SIM_CLONE_LOCK_WAIT:-600}"
exec 9>>"$lock"
# (The lock belongs to the open file, so taking it in a $(...) subshell still holds it here.)
lock_status=0
lock_err="$(/usr/bin/lockf -t "$lock_wait" 9 2>&1)" || lock_status=$?
if (( lock_status == 75 )); then
  echo "ios: timed out after ${lock_wait}s waiting for the lock on $lock (another sim-clone.sh, or a" \
    "child it left running, holds it)" >&2
  exit 75
elif (( lock_status != 0 )); then
  echo "ios: lockf failed on $lock (exit $lock_status): $lock_err" >&2
  exit "$lock_status"
fi

# Prints "<udid> <state> <deviceTypeIdentifier> <runtime>" for the first available device
# with this exact name (or UDID), or nothing.
find_device() {
  xcrun simctl list -j devices available | python3 -c '
import json, sys
want = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if want in (d["name"], d["udid"]):
            print(d["udid"], d["state"], d["deviceTypeIdentifier"], runtime)
            sys.exit()
' "$1"
}

existing="$(find_device "$name")"
if (( delete )); then
  [[ -n "$existing" ]] || { echo "sim-clone: no simulator named '$name'" >&2; exit 0; }
  udid="${existing%% *}"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid"
  rm -f "$SIM_OWNERS/$udid"
  echo "sim-clone: deleted '$name' ($udid)" >&2
  exit 0
fi

if [[ -n "$existing" ]]; then
  udid="${existing%% *}"
else
  src="$(find_device "$source_name")"
  [[ -n "$src" ]] || die "no available simulator named '$source_name' (see: xcrun simctl list devices available)"
  read -r src_udid src_state src_type src_runtime <<<"$src"
  if [[ "$src_state" == Shutdown ]]; then
    udid="$(xcrun simctl clone "$src_udid" "$name")"
    echo "sim-clone: cloned '$source_name' -> '$name'" >&2
  else
    udid="$(xcrun simctl create "$name" "$src_type" "$src_runtime")"
    echo "sim-clone: '$source_name' is $src_state; created '$name' from its device type and runtime" >&2
  fi
fi

# Who it belongs to, for make ios-prune (under the lock prune takes too).
mkdir -p "$SIM_OWNERS" && printf '%s\n' "$root_real" >"$SIM_OWNERS/$udid"

# Booting (and waiting for a slot) must not hold this lock: other worktrees' lookups need it.
exec 9>&-
(( boot )) && sim_boot "$udid"
echo "$udid"
