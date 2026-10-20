#!/usr/bin/env bash
# Build, install and launch the app on a simulator, optionally opening a URL afterwards.
# Usage: sim-run.sh <simulator name or UDID> [url]
# IOS_LAUNCH_ARGS: arguments for the app, e.g. -QuickrDemoStore (a seeded demo store, debug builds).
source "$(dirname "$0")/common.sh"
require_xcode
udid="$(target_sim_udid "$1")"; url="${2:-}"
sim_boot "$udid"
open -a Simulator --args -CurrentDeviceUDID "$udid" 2>/dev/null || true
"$(dirname "$0")/build.sh" "$udid"
xcrun simctl install "$udid" "$APP_PATH"
# shellcheck disable=SC2086 # split on purpose: several arguments
xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" ${IOS_LAUNCH_ARGS:-}
if [[ -n "$url" ]]; then
  sleep 1
  xcrun simctl openurl "$udid" "$url"
fi
