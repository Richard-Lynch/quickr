#!/usr/bin/env bash
# Record the simulator while a flow runs, then convert to a GIF.
# Usage: demo-record.sh <simulator name or UDID> <output gif> [seconds]
# M0 records an app launch; later milestones drive a Demo test plan during the recording.
source "$(dirname "$0")/common.sh"
require_xcode
command -v ffmpeg >/dev/null || die "ffmpeg not found: brew install ffmpeg"
udid="$(sim_udid "$1")"; gif="$2"; seconds="${3:-5}"
mp4="$BUILD_DIR/demo.mp4"
mkdir -p "$BUILD_DIR" "$(dirname "$gif")"
"$(dirname "$0")/build.sh" "$udid"
sim_boot "$udid"
xcrun simctl install "$udid" "$APP_PATH"
xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl io "$udid" recordVideo --codec=h264 --mask=black --force "$mp4" &
rec=$!
sleep 2
xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
sleep "$seconds"
kill -INT "$rec"; wait "$rec" || true
ffmpeg -loglevel error -y -i "$mp4" \
  -vf "fps=15,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$gif"
echo "ios: wrote $gif"
