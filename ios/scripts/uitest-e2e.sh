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
# A signal ends the run through the teardown too. Bash runs a trap only after its foreground
# child exits, so the slow steps run in the background (their own process group, killed whole)
# and the script waits for them.
child=""
on_signal() {
  [[ -n "$child" ]] && kill -TERM -- "-$child" 2>/dev/null
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
run() {  # run <command...>: in the background, in its own process group; its status
  set -m
  "$@" &
  child=$!
  set +m
  local status=0
  wait "$child" || status=$?
  child=""
  return "$status"
}

run "$SCRIPTS/integration-up.sh" >/dev/null
it_load_env
run "$SCRIPTS/integration-smoke.sh"

# xcodebuild hands TEST_RUNNER_<name> to the test runner as <name>. The tests fail, not skip,
# without the stack.
export TEST_RUNNER_QUICKR_IT_BASE_URL="$QUICKR_IT_BASE_URL"
export TEST_RUNNER_QUICKR_IT_DIRECT_URL="$QUICKR_IT_DIRECT_URL"
export TEST_RUNNER_QUICKR_IT_PROXY_CONTROL_URL="$QUICKR_IT_PROXY_CONTROL_URL"
export TEST_RUNNER_QUICKR_IT_REQUIRED=1
# QUICKR_UIT_DEMO=1 also runs the demo scenarios (screenshots for docs/ios/demo/m2).
export TEST_RUNNER_QUICKR_UIT_DEMO="${QUICKR_UIT_DEMO:-0}"
run "$SCRIPTS/test.sh" UI "$sim" -only-testing:QuickRUITests/EndToEndUITests \
  -only-testing:QuickRUITests/TapCountUITests "$@"
