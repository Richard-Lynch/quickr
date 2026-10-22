#!/usr/bin/env bash
# Run a test plan on a simulator. Usage: test.sh <Unit|UI> <simulator name or UDID> [extra args...]
# The result bundle goes to a directory of this run's own,
# ios/build/results/<plan>-<date>-<time>-<random>/<plan>.xcresult (printed first), or to
# IOS_RESULT_BUNDLE when set (a path that mustn't exist yet); no run deletes another's bundle.
# The simulator is held for the run (common.sh sim_hold): shut down afterwards if this run
# booted it, unless another run still uses it or IOS_SIM_KEEP=1.
source "$(dirname "$0")/common.sh"
require_xcode
plan="$1"; udid="$(target_sim_udid "$2")"; shift 2
if [[ -n "${IOS_RESULT_BUNDLE:-}" ]]; then
  result="$IOS_RESULT_BUNDLE"
  [[ ! -e "$result" ]] || die "IOS_RESULT_BUNDLE $result exists already; pick a new path"
  mkdir -p "$(dirname "$result")"
else
  mkdir -p "$BUILD_DIR/results"
  result="$(mktemp -d "$BUILD_DIR/results/$plan-$(date +%Y%m%d-%H%M%S)-XXXXXX")/$plan.xcresult"
fi
runtime="$(xcrun simctl list devices | awk -v id="$udid" '/^-- /{rt=$0} index($0, id){print rt; exit}')"
echo "ios: $plan plan on $udid ${runtime}"
echo "ios: result bundle: $result"
sim_hold "$udid"  # under the simulator cap, before xcodebuild would boot it
# CI's ~3-core runner starves a hosted run that executes every Swift Testing test of every target
# at once (main-actor suites stalled for minutes). There, cap how many run concurrently in the
# test process (IOS_TEST_PARALLEL_WIDTH, default 4; forwarded through TEST_RUNNER_). Local runs
# keep the default, fully parallel.
if [[ -n "${CI:-}" ]]; then
  export TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${IOS_TEST_PARALLEL_WIDTH:-4}"
  echo "ios: CI: at most $TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH tests at a time in the test process"
fi
# A hung test fails after IOS_TEST_ALLOWANCE seconds (default 300; a test may raise its own
# executionTimeAllowance up to IOS_TEST_MAX_ALLOWANCE, default 600) instead of stalling the run.
xcb -destination "id=$udid" -testPlan "$plan" -resultBundlePath "$result" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance "${IOS_TEST_ALLOWANCE:-300}" \
  -maximum-test-execution-time-allowance "${IOS_TEST_MAX_ALLOWANCE:-600}" "$@" test
