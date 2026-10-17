#!/usr/bin/env bash
# A simulator of this worktree's own, so parallel worktrees never boot, install into or
# erase each other's device. Prints the device's UDID on stdout (and nothing else), creating
# it on first use: "<source> <worktree dir>", e.g. "quickR iOS-26-0 ios-m1-tools".
#
#   sim-clone.sh [source]           create (or find) the clone; source defaults to "quickR iOS-26-0"
#   sim-clone.sh --delete [source]  shut down and delete it
#
# A shut-down source is cloned with `simctl clone`; a booted one (in use elsewhere) is never
# touched: the clone is created fresh from the same device type and runtime instead.
# Use it as the IOS_SIM* make variables: make ios-test IOS_SIM_MIN="$(ios/scripts/sim-clone.sh)"
source "$(dirname "$0")/common.sh"
require_xcodebuild

delete=0
if [[ "${1:-}" == --delete ]]; then delete=1; shift; fi
source_name="${1:-quickR iOS-26-0}"
name="$source_name $(basename "$ROOT_DIR")"

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
  echo "sim-clone: deleted '$name' ($udid)" >&2
  exit 0
fi

if [[ -n "$existing" ]]; then
  echo "${existing%% *}"
  exit 0
fi

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
echo "$udid"
