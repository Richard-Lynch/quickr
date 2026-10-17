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
xcb -destination "id=$udid" -testPlan "$plan" -resultBundlePath "$result" "$@" test
