#!/usr/bin/env bash
# Tests for simulator admission (common.sh booted_clones/sim_boot) and the make targets' default
# device (target_sim_udid) against a fake `xcrun simctl`: `list [-j] devices [available]` serves
# a JSON file (or its text form), `bootstatus <udid> -b` marks the device booted after
# FAKE_BOOT_SECS (default 1), like a real boot taking a while, and `clone` adds a device.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fake="$(mktemp -d "${TMPDIR:-/tmp}/quickr-simcap.XXXXXX")"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/xcrun" <<'SH'
#!/usr/bin/env bash
case "$*" in
"simctl list -j devices" | "simctl list -j devices available") exec cat "$FAKE_DEVICES" ;;
"simctl list devices" | "simctl list devices available")
  exec python3 -c '
import json, sys
for runtime, ds in json.load(open(sys.argv[1]))["devices"].items():
    print("-- " + runtime + " --")
    for d in ds:
        print("    %s (%s) (%s)" % (d["name"], d["udid"], d["state"]))' "$FAKE_DEVICES" ;;
"simctl clone "*)
  exec python3 - "$FAKE_DEVICES" "$3" "$4" <<'PY'
import json, os, sys, uuid
path, src, name = sys.argv[1:]
data = json.load(open(path))
for devices in data["devices"].values():
    for d in list(devices):
        if d["udid"] == src:
            new = dict(d, udid=str(uuid.uuid4()).upper(), name=name, state="Shutdown")
            devices.append(new)
            print(new["udid"])
json.dump(data, open(path + ".tmp", "w"))
os.replace(path + ".tmp", path)
PY
  ;;
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
printf '#!/bin/sh\n[ "$1" = -version ] && echo "Xcode 27.1"\n' >"$fake/xcodebuild"  # require_xcodebuild
chmod +x "$fake/xcodebuild"
devices() {  # devices "<udid>:<state>:<name>" ...
  python3 -c '
import json, sys
print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
    dict(zip(("udid", "state", "name"), d.split(":", 2)), deviceTypeIdentifier="iPhone-17")
    for d in sys.argv[1:]]}}))' "$@" >"$fake/devices.new"
  mv "$fake/devices.new" "$fake/devices.json"  # atomic: a background rewrite races readers
}
state() {  # state <udid>
  python3 -c '
import json, sys
for ds in json.load(open(sys.argv[1]))["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[2]: print(d["state"])' "$fake/devices.json" "$1"
}
export FAKE_DEVICES="$fake/devices.json" PATH="$fake:$PATH" IOS_SIM_WAIT_POLL=1
export QUICKR_SIM_CAP_LOCK="$fake/cap.lockf" QUICKR_SIM_CLONE_LOCK="$fake/clone.lockf"
# The caller's settings must not leak in: an inherited IOS_SIM_WAIT=1 (check-ios run with it)
# turns the "refused" cases into waits that never end.
unset IOS_SIM_WAIT IOS_SIM_CAP CI IOS_SIM_DEFAULTED IOS_SIM IOS_SIM_MIN  # CI skips the cap in sim_boot
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

devices "a:Booted:$A" "b:Shutdown:$B" "c:Shutdown:$C" "x:Booted:iPhone 17"
boot c; expect "one clone booted: a slot is free (non-quickR devices don't count), and it boots" 0
[[ "$(state c)" == Booted ]] || fail "the admitted clone was not booted"

# The shared base device counts like a clone (a plain `make ios-test` used to boot it uncapped).
devices "m:Booted:quickR iOS-26-0" "c:Shutdown:$C"
boot c; expect "a booted base device counts, leaving one slot" 0
devices "m:Booted:quickR iOS-26-0" "a:Booted:$A" "c:Shutdown:$C"
boot c; expect "the base device and one clone booted: a third is refused at cap 2" 1 "quickR iOS-26-0"
[[ "$(state c)" == Shutdown ]] || fail "a clone refused because of the base device was booted"
devices "m:Booted:quickR iOS-26-0" "a:Booted:$A" "b:Booted:$B"
boot m; expect "the base device re-booting itself is fine" 0
devices "m:Shutdown:quickR iOS27" "a:Booted:$A" "b:Booted:$B"
boot m; expect "a shut-down base device is refused at the cap like a clone" 1

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

# The make targets' device: this worktree's clone unless one was set (or under CI).
BASE=11111111-2222-3333-4444-555555555555
resolve() {  # resolve <name> [VAR=value ...]: target_sim_udid in a subshell; sets status and out
  local name="$1"; shift
  out="$(env "$@" bash -c 'source "$1/../common.sh"; target_sim_udid "$2"' _ "$here" "$name" 2>/dev/null)"; status=$?
}
root_real="$(cd "$here/../../.." && pwd -P)"
mine="quickR iOS-26-0 $(basename "$root_real")-$(printf '%s' "$root_real" | shasum | cut -c1-6)"
devices "$BASE:Shutdown:quickR iOS-26-0"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=0; expect "an explicit device is used as given" 0 "$BASE"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1 CI=true; expect "under CI the defaulted device is used as given" 0 "$BASE"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1; clone="$out"
expect "a defaulted device becomes this worktree's clone" 0
[[ "$clone" =~ ^[0-9A-F-]{36}$ && "$clone" != "$BASE" ]] || fail "the default is not a new clone: $clone"
grep -qF "$mine" "$fake/devices.json" || fail "the clone is not named '$mine'"
[[ "$(state "$clone")" == Shutdown ]] || fail "resolving the default booted the clone"
resolve "quickR iOS-26-0" IOS_SIM_DEFAULTED=1
[[ "$out" == "$clone" ]] && echo "ok   the default resolves to the same clone again" || fail "a second clone: $out"

# The Makefile marks a device defaulted only when neither IOS_SIM nor IOS_SIM_MIN was set.
mk() {  # mk [VAR=value ...] -- <make args>: the test.sh/sim-run.sh line make would run
  local vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env -u IOS_SIM -u IOS_SIM_MIN ${vars[@]+"${vars[@]}"} make -s -n -C "$root_real" "$@" 2>/dev/null \
    | grep -E 'test\.sh|sim-run\.sh'
}
for c in "ios-test|IOS_SIM_DEFAULTED=1" "ios-test IOS_SIM_MIN=x|IOS_SIM_DEFAULTED=0" \
  "ios-test IOS_SIM=x|IOS_SIM_DEFAULTED=1" "ios-uitest|IOS_SIM_DEFAULTED=1" \
  "ios-uitest IOS_SIM=x|IOS_SIM_DEFAULTED=0" "ios-uitest IOS_SIM_MIN=x|IOS_SIM_DEFAULTED=0" \
  "ios-sim-run|IOS_SIM_DEFAULTED=1" "ios-sim-run IOS_SIM=x|IOS_SIM_DEFAULTED=0"; do
  args="${c%%|*}"; want="${c#*|}"
  # shellcheck disable=SC2086 # split on purpose: target and variables
  got="$(mk -- $args)"
  [[ "$got" == "$want "* ]] && echo "ok   make $args: $want" || fail "make $args: '$got' (want $want)"
done
got="$(mk IOS_SIM_MIN=x -- ios-test)"
[[ "$got" == "IOS_SIM_DEFAULTED=0 "* ]] && echo "ok   IOS_SIM_MIN from the environment counts as set" || fail "env IOS_SIM_MIN: $got"

(( fails == 0 )) && echo "sim cap: all passed" || { echo "sim cap: $fails failed"; exit 1; }
