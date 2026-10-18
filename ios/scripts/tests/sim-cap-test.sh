#!/usr/bin/env bash
# Tests for simulator admission (common.sh booted_clones/sim_boot) against a fake `xcrun simctl`:
# `list -j devices` serves a JSON file, and `bootstatus <udid> -b` marks the device booted
# after FAKE_BOOT_SECS (default 1), like a real boot taking a while.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fake="$(mktemp -d "${TMPDIR:-/tmp}/quickr-simcap.XXXXXX")"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/xcrun" <<'SH'
#!/usr/bin/env bash
case "$*" in
"simctl list -j devices") exec cat "$FAKE_DEVICES" ;;
"simctl bootstatus "*" -b")
  sleep "${FAKE_BOOT_SECS:-1}"
  exec python3 - "$FAKE_DEVICES" "$3" <<'PY'
import json, os, sys
path, udid = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in devices:
        if d["udid"] == udid:
            d["state"] = "Booted"
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, path)
PY
  ;;
esac
exit 1
SH
chmod +x "$fake/xcrun"
devices() {  # devices "<udid>:<state>:<name>" ...
  python3 -c '
import json, sys
print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
    dict(zip(("udid", "state", "name"), d.split(":", 2))) for d in sys.argv[1:]]}}))' "$@" >"$fake/devices.json"
}
state() {  # state <udid>
  python3 -c '
import json, sys
for ds in json.load(open(sys.argv[1]))["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[2]: print(d["state"])' "$fake/devices.json" "$1"
}
export FAKE_DEVICES="$fake/devices.json" PATH="$fake:$PATH" IOS_SIM_WAIT_POLL=1
export QUICKR_SIM_CAP_LOCK="$fake/cap.lockf"
# The caller's settings must not leak in: an inherited IOS_SIM_WAIT=1 (check-ios run with it)
# turns the "refused" cases into waits that never end.
unset IOS_SIM_WAIT IOS_SIM_CAP
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
boot() {  # boot <udid>: sim_boot in a subshell; sets status and out
  out="$(bash -c 'source "$1/../common.sh"; sim_boot "$2"' _ "$here" "$1" 2>&1)"; status=$?
}
expect() {  # expect <name> <status> [output must contain]
  if [[ "$status" == "$2" && ( -z "${3:-}" || "$out" == *"$3"* ) ]]; then echo "ok   $1"
  else fail "$1: status $status (want $2): $out"; fi
}

A="quickR iOS-26-0 ios-m2-form-f74fa0"; B="quickR iOS-26-0 ios-m1-skel-0a1b2c"
C="quickR iOS-26-0 ios-m1-data-123abc"; D="quickR iOS-26-0 ios-m1-sync-456def"

devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" "m:Booted:quickR iOS-26-0" "x:Booted:iPhone 17"
boot c; expect "one clone booted: a slot is free (non-clones don't count), and it boots" 0
[[ "$(state c)" == Booted ]] || fail "the admitted clone was not booted"

devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
boot c; expect "two clones booted: refused, naming them" 1 "ios-m1-skel-0a1b2c"
[[ "$out" == *"ios-m2-form-f74fa0"* ]] || fail "the message names every booted clone"
[[ "$(state c)" == Shutdown ]] || fail "a refused clone was booted"
boot a; expect "your own booted clone doesn't count against you" 0
IOS_SIM_CAP=3 boot c; expect "IOS_SIM_CAP raises the cap" 0
devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
IOS_SIM_CAP=0 boot c; expect "IOS_SIM_CAP=0 turns it off" 0

# --wait: a slot frees while it polls.
devices "a:Booted:$A" "b:Booted:$B" "c:Shutdown:$C"
( sleep 2; devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" ) &
start=$SECONDS
IOS_SIM_WAIT=1 boot c; expect "IOS_SIM_WAIT waits until a slot frees" 0 "waiting for a simulator slot"
(( SECONDS - start >= 2 )) || fail "it returned before the slot freed"
wait

# A race: one slot left, two worktrees admit at once. Exactly one boots, the other is refused.
devices "a:Booted:$A" "c:Shutdown:$C" "d:Shutdown:$D"
FAKE_BOOT_SECS=2 bash -c 'source "$1/../common.sh"; sim_boot c' _ "$here" >"$fake/c.out" 2>&1 &
pc=$!
FAKE_BOOT_SECS=2 bash -c 'source "$1/../common.sh"; sim_boot d' _ "$here" >"$fake/d.out" 2>&1 &
pd=$!
wait "$pc"; sc=$?
wait "$pd"; sd=$?
booted_count=$(( $([[ "$(state c)" == Booted ]] && echo 1 || echo 0) + $([[ "$(state d)" == Booted ]] && echo 1 || echo 0) ))
if (( booted_count == 1 && sc + sd == 1 )); then echo "ok   two concurrent admissions for the last slot: one boots, one is refused"
else fail "concurrent admissions: c=$sc ($(state c)), d=$sd ($(state d)); $(cat "$fake/c.out" "$fake/d.out")"; fi

(( fails == 0 )) && echo "sim cap: all passed" || { echo "sim cap: $fails failed"; exit 1; }
