#!/usr/bin/env bash
# Clean light and dark screenshots of the running app.
# Usage: shots.sh <simulator name or UDID> <output dir> [name prefix]
# Installs and launches the current build first (see sim-run.sh).
source "$(dirname "$0")/common.sh"
require_xcode
udid="$(sim_udid "$1")"; out="$2"; prefix="${3:-root}"
mkdir -p "$out"
# The status bar and appearance put back on every exit path, then the simulator released (shut
# down if this run booted it; IOS_SIM_KEEP=1 keeps it).
sim_hold "$udid"
trap 'xcrun simctl status_bar "$udid" clear 2>/dev/null; xcrun simctl ui "$udid" appearance light 2>/dev/null; sim_release' EXIT
"$(dirname "$0")/sim-run.sh" "$udid"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork wifi
for mode in light dark; do
  xcrun simctl ui "$udid" appearance "$mode"
  sleep 2
  xcrun simctl io "$udid" screenshot --mask=black "$out/$prefix-$mode.png" >/dev/null 2>&1 || die "screenshot failed"
  echo "ios: wrote $out/$prefix-$mode.png"
done
