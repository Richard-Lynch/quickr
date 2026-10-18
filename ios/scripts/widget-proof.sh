#!/usr/bin/env bash
# The widget half of the App Intents proof (WidgetGalleryTests, the Widgets plan): adds the topic
# widget through SpringBoard, configures it and checks it renders the chosen TopicEntity.
# On demand, not in check-ios: SpringBoard automation can stall indefinitely, so this run has a
# wall-clock limit. Usage: widget-proof.sh <simulator name or UDID> [limit seconds, default 600]
source "$(dirname "$0")/common.sh"
require_xcode
sim="$1"; limit="${2:-600}"
"$(dirname "$0")/test.sh" Widgets "$sim" &
pid=$!
( sleep "$limit"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) &
watchdog=$!
status=0
wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true
(( status == 0 )) || die "Widgets plan failed or exceeded ${limit}s (exit $status); a stalled SpringBoard is the usual cause: rerun, or erase the simulator"
echo "ios: widget proof passed on $sim"
