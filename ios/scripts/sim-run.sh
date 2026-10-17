#!/usr/bin/env bash
# Build, install and launch the app on a simulator, optionally opening a URL afterwards.
# Usage: sim-run.sh <simulator name or UDID> [url]
source "$(dirname "$0")/common.sh"
require_xcode
udid="$(sim_udid "$1")"; url="${2:-}"
sim_boot "$udid"
open -a Simulator --args -CurrentDeviceUDID "$udid" 2>/dev/null || true
"$(dirname "$0")/build.sh" "$udid"
xcrun simctl install "$udid" "$APP_PATH"
xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID"
if [[ -n "$url" ]]; then
  sleep 1
  xcrun simctl openurl "$udid" "$url"
fi
