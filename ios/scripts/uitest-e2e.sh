#!/usr/bin/env bash
# make ios-uitest-e2e: the end-to-end UI tests (UITests/EndToEndUITests, TapCountUITests) on simulator $1 against
# this worktree's integration stack. Brings the stack up, passes its URLs to the test runner as
# TEST_RUNNER_QUICKR_IT_*, runs the class from the UI plan, and tears down on exit, pass or fail.
# QUICKR_IT_KEEP=1 leaves the stack up afterwards (integration-down.sh removes it).
source "$(dirname "$0")/integration-common.sh"
SCRIPTS="$IOS_DIR/scripts"
[[ $# -ge 1 ]] || die "usage: uitest-e2e.sh <simulator name or UDID> [xcodebuild args...]"
sim="$1"; shift

teardown() {
  local status=$?
  if [[ "${QUICKR_IT_KEEP:-0}" == 1 ]]; then
    echo "integration: QUICKR_IT_KEEP=1, leaving $IT_PROJECT up (see $IT_ENV_FILE)" >&2
  else
    "$SCRIPTS/integration-down.sh" || true
  fi
  exit "$status"
}
trap teardown EXIT

"$SCRIPTS/integration-up.sh" >/dev/null
it_load_env
"$SCRIPTS/integration-smoke.sh"

# xcodebuild hands TEST_RUNNER_<name> to the test runner as <name>. The tests fail, not skip,
# without the stack.
export TEST_RUNNER_QUICKR_IT_BASE_URL="$QUICKR_IT_BASE_URL"
export TEST_RUNNER_QUICKR_IT_DIRECT_URL="$QUICKR_IT_DIRECT_URL"
export TEST_RUNNER_QUICKR_IT_PROXY_CONTROL_URL="$QUICKR_IT_PROXY_CONTROL_URL"
export TEST_RUNNER_QUICKR_IT_REQUIRED=1
"$SCRIPTS/test.sh" UI "$sim" -only-testing:QuickRUITests/EndToEndUITests \
  -only-testing:QuickRUITests/TapCountUITests "$@"
