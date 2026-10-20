#!/usr/bin/env bash
# make ios-integration: bring this worktree's stacks up, run the harness smoke test and the
# QuickrDataIntegrationTests target against them, and tear down on exit, pass or fail.
# QUICKR_IT_KEEP=1 leaves the stacks up afterwards (integration-down.sh removes them).
source "$(dirname "$0")/integration-common.sh"
SCRIPTS="$IOS_DIR/scripts"
TARGET="QuickrDataIntegrationTests"

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

if ! grep -q "\"$TARGET\"" "$IOS_DIR/QuickrKit/Package.swift"; then
  echo "integration: no integration tests yet ($TARGET is not in ios/QuickrKit/Package.swift);" \
    "the harness smoke test passed"
  exit 0
fi

require_xcodebuild
# Tests must fail, not skip, when this is set and the stack is unreachable.
export QUICKR_IT_REQUIRED=1
swift_test --filter "$TARGET"
