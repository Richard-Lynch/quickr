#!/usr/bin/env bash
# Run a test plan on a simulator. Usage: test.sh <Unit|UI> <simulator name or UDID> [extra args...]
# The result bundle lands in ios/build/results/<plan>-<udid>.xcresult.
source "$(dirname "$0")/common.sh"
require_xcode
plan="$1"; udid="$(sim_udid "$2")"; shift 2
result="$BUILD_DIR/results/$plan-$udid.xcresult"
rm -rf "$result"; mkdir -p "$BUILD_DIR/results"
runtime="$(xcrun simctl list devices | awk -v id="$udid" '/^-- /{rt=$0} index($0, id){print rt; exit}')"
echo "ios: $plan plan on $udid ${runtime}"
sim_boot "$udid"  # under the simulator cap, before xcodebuild would boot it
# A hung test fails after IOS_TEST_ALLOWANCE seconds (default 300; a test may raise its own
# executionTimeAllowance up to IOS_TEST_MAX_ALLOWANCE, default 600) instead of stalling the run.
xcb -destination "id=$udid" -testPlan "$plan" -resultBundlePath "$result" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance "${IOS_TEST_ALLOWANCE:-300}" \
  -maximum-test-execution-time-allowance "${IOS_TEST_MAX_ALLOWANCE:-600}" "$@" test
