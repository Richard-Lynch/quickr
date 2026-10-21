#!/usr/bin/env bash
# The local iOS gate: gen, the script tests, swift test (strict pool), the real-time tests, the
# Unit and UI plans on both simulators, the Intents plan on the iOS 27+ one, lint, Xcode version.
# Usage: check-ios.sh <min simulator> <current simulator>
# IOS_SIM_MIN_DEFAULTED / IOS_SIM_CUR_DEFAULTED=1 (set by make when IOS_SIM_MIN / IOS_SIM_CUR
# weren't): that runtime runs on this worktree's clone of the device (target_sim_udid).
source "$(dirname "$0")/common.sh"
require_xcode
here="$(dirname "$0")"
"$here/check-xcode-version.sh"
"$here/gen.sh"
"$here/tests/watchdog-test.sh"
"$here/tests/sim-cap-test.sh"
"$here/tests/testflight-test.sh"
"$here/tests/device-run-test.sh"
"$here/tests/dprobe-summary-test.sh"
"$here/swift-test.sh"
"$here/timing-test.sh"
# GRDB's suspension is process-wide: the lifecycle tests get a swift test process of their own.
QUICKR_LIFECYCLE_TESTS=1 "$here/swift-test.sh" --filter QuickrLifecycleTests --no-parallel
defaulted=("${IOS_SIM_MIN_DEFAULTED:-0}" "${IOS_SIM_CUR_DEFAULTED:-0}")
names=("$1" "$2")
for i in 0 1; do
  udid="$(IOS_SIM_DEFAULTED="${defaulted[i]}" target_sim_udid "${names[i]}")"
  sim="$udid"  # test.sh gets the UDID: used as given
  "$here/test.sh" Unit "$sim"
  "$here/test.sh" UI "$sim"
  # AppIntentsTesting only loads on an iOS 27+ runtime (project.yml, QuickRIntentsTests).
  major="$(xcrun simctl list devices | awk -v id="$udid" '/^-- iOS /{split($3, v, "."); m=v[1]} index($0, id){print m; exit}')"
  if (( ${major:-0} >= 27 )); then
    "$here/test.sh" Intents "$sim"
  else
    echo "ios: Intents plan skipped on $sim (iOS ${major:-?}; AppIntentsTesting needs 27+)"
  fi
done
"$here/resolved-check.sh"
"$here/lint.sh"
echo "ios: check-ios passed"
